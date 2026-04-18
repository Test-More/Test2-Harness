# Preloader Reimplementation — Design Brief

**Worktree:** `.claude/worktrees/reimplement-preloader`
**Branch:** `reimplement-preloader` (forked from `2.0_rewrite`)
**Scope:** FEATURES_TODO items #2, #3, #4, #5, #6
- #2 Test runners (only the preload-launched path, not the scheduler)
- #3 Preload system (DSL + stages + persistent stage processes)
- #4 Dependency tracer
- #5 File-watch / reloader (Inotify2 + stat fallback)
- #6 Preloaded-test collector (fork-from-stage variant)

> **This branch does NOT touch the scheduler or the current test-run loop.**
> It builds the preload stack plus a public API the scheduler will eventually
> call. Running tests through preloads will be wired up by a later branch.

> **Status:** landed. See `PRELOADER_STATUS.md` for a module/test inventory
> and the list of deliberately-deferred follow-ups.

---

## 1. Architectural Requirements (authoritative, from user)

### 1a. DSL preservation

Keep the existing DSL exactly as it is in `old/lib/Test2/Harness2/Preload.pm`.
Only change a DSL function if there is no way to achieve the required behavior
otherwise. **Adding new DSL functions / options is fine** — subtractions and
renames are not.

The DSL surface to preserve:

- `stage NAME => sub { ... }` (nestable)
- `preload $mod / @mods / sub { ... }`
- `pre_fork sub { ... }` / `post_fork sub { ... }` / `pre_launch sub { ... }`
- `eager()` / `default()`
- `watch $file => sub { ... }` (works inside `stage`, inside `preload` subs,
  and dynamically via `Reloader->ACTIVE` from within already-loaded app code)
- `reload_inplace_check sub { ... }`
- `TEST2_HARNESS_PRELOAD()` marker sub for module identification

`file_stage` / `add_file_stage` were already deprecated in `old/` and should
stay deprecated.

### 1b. Better reload for Moose (and exporters)

Current reload behavior in `old/` + `legacy/` does a decent job on simple
modules but struggles with:

- **Moose classes** — sometimes reload does nothing, sometimes partially.
  The meta-object machinery, roles, accessors, and BUILD chain all need to
  be torn down and rebuilt in the right order, and symbol-table deletion
  alone leaves stale metaclass state behind.
- **Exporter-based modules** — callers have already bound the old coderefs.
  Symbol-table re-blessing alone does not update callers' imports.

Both need better handling. For Moose this probably means: detect via
`$pkg->can('meta') && $pkg->meta->isa('Moose::Meta::Class')`, then clear the
metaclass (`Moose::Util::MetaRole` / `Class::MOP::remove_metaclass_by_name`),
delete the stash, and re-`require` the file. Audit what the Moose dev
community does for hot-reload (Plack::Middleware::Refresh, Moose::Meta::Class
->reinitialize).

For exporters, **audit whether a simple universal strategy exists**. Candidates:
- Track @EXPORT/@EXPORT_OK/%EXPORT_TAGS per-package at first load, then on
  reload re-run `$pkg->import(@original_args)` on every package that imported
  from it. Requires tracking importers, which `DepTracer` is perfectly placed
  to do.
- Re-point the glob entries rather than deleting them, so existing coderef
  references held by callers stay valid (won't work for new subs, but covers
  the common rename-free reload case).
- Hybrid: glob-repoint for existing names, forcible re-`import` for callers
  who took `*name` aliases.

Document the chosen strategy in the relevant module's POD.

### 1c. Preloader is a service tree

Each preload stage is an `IPC::Manager::Role::Service`, not an ad-hoc forked
process. The tree mirrors the DSL nesting:

```
  preloader (base)         -- service, IPC peer of the harness
    Moose                  -- child service, forked from base
      Types                -- child service, forked from Moose
    Moo                    -- child service, forked from base
```

Parent-restarts-child semantics already exist in `IPC::Manager` — use them.
If `Moose` dies, `preloader` restarts it; if `preloader` dies, the harness
restarts it.

### 1d. Scheduler launches tests via IPC

The scheduler (written later) kicks off a test by sending an IPC message to
the stage service that should host it. The stage's service loop receives the
message and performs `fork → collector-setup → fork → exec-into-test`. The
harness and scheduler do NOT reach into stage internals; they send one
message.

The public API surface to land on this branch:

```perl
$harness->launch_test_in_preload(
    stage => 'Moose',
    job   => $run_job,       # Test2::Harness2::Run::Job
    run   => $run,           # Test2::Harness2::Run
    # optional: logger specs, auditor spec, env overrides
);
```

Under the hood this sends an IPC request to the `Moose` stage service, waits
for the stage to acknowledge with a collector Handle (or returns the handle
asynchronously via ipcm_info), and returns control. The scheduler will call
this when it is written.

### 1e. Empty-stack test launch (CRITICAL)

The base preloader service must `exec` immediately on startup so its Perl
stack and lexical state are empty. All real work — including loading the DSL
meta-object and all `preload`ed modules — happens inside a `BEGIN { ... }`
block at the top of the exec'd script.

The reason is the test-launch path:

1. Stage service receives "run test T" message.
2. Stage forks (post_fork callbacks fire in the child).
3. The child sets up the collector, then forks AGAIN; the grandchild is the
   test process. Parent of the grandchild pipes stdio to the collector.
4. In the grandchild, `pre_launch` callbacks run.
5. The grandchild **calls `Long::Jump::long_jump`** back to the BEGIN block
   at the top of the stage's exec'd script — which unwinds the Perl stack to
   zero.
6. Immediately after the `long_jump` return point, the grandchild calls
   `goto::file $test_path` — which continues execution from a truly empty
   stack, as if the test had been the `perl -e` target from the start.

Without the initial `exec` + BEGIN-block staging, `goto::file` would still
inherit frames from the original harness's dispatch path. That breaks tests
that introspect `caller()`, rely on `END` block timing, or use modules that
snapshot `%INC` ordering.

### 1f. No Settings object

`old/` and `legacy/` have a `Test2::Harness::Settings` / `Test2::Harness2::Settings`
object that carries configuration. **Do not port it.** That structure lives in
`App::Yath2` (which is not being written yet).

The harness service accepts preload configuration as plain constructor /
start-time parameters: a list of module names. For each entry:

- If the module defines `TEST2_HARNESS_PRELOAD()` (i.e., it `use`d
  `Test2::Harness2::Preload`), treat it as a DSL preload: import its meta
  object, walk its stage tree, spawn the service tree.
- Otherwise treat it as a plain module: load it once in the base preloader
  service. No stages, no fork tree, no DSL processing.

Example API shape (to be refined):

```perl
Test2::Harness2->new(
    ...,
    preload => ['My::App', 'Moose', 'My::Custom::Preload'],
);
# or
$harness->configure_preloads(['My::App', 'Moose', 'My::Custom::Preload']);
```

### 1g. Out of scope on this branch

- The scheduler loop (leave `run_on_all` as-is).
- Making the existing simple-fork test launch path go through the preloader.
- Any `HARNESS-*` comment-directive scanning on test files (TestFile stays
  value-only for now).
- The `App::Yath2` preload CLI surface.
- Per-test `TestSettings` (separate future work).

---

## 2. Reference files

### `old/` — preferred reference

| Concept | Path |
|---|---|
| DSL entry-point + meta-object | `old/lib/Test2/Harness2/Preload.pm` |
| Stage value object | `old/lib/Test2/Harness2/Preload/Stage.pm` |
| Persistent stage process | `old/lib/Test2/Harness2/Runner/Preloading/Stage.pm` |
| Preload-aware runner | `old/lib/Test2/Harness2/Runner/Preloading.pm` |
| Reloader base + impls | `old/lib/Test2/Harness2/Reloader.pm`, `Reloader/Inotify2.pm`, `Reloader/Stat.pm` |
| Preloaded collector | `old/lib/Test2/Harness2/Collector/Preloaded.pm` |

### `legacy/` — older but has pieces `old/` lacks

| Concept | Path |
|---|---|
| Dependency tracer (`@INC` hook) | `legacy/lib/Test2/Harness/Runner/DepTracer.pm` |
| Reloader with churn-block support | `legacy/lib/Test2/Harness/Runner/Reloader.pm` |
| Multi-stage persistent preloader | `legacy/lib/Test2/Harness/Runner/Preloader.pm`, `Preloader/Stage.pm` |
| DSL variant | `legacy/lib/Test2/Harness/Runner/Preload.pm`, `Preload/Stage.pm` |

`old/` dropped DepTracer; port it from `legacy/`. The churn-block reload
pattern (`# HARNESS-CHURN-START` / `# HARNESS-CHURN-STOP`) is documented in
the `old/` DSL POD but only implemented in `legacy/`'s reloader — bring that
over too.

### Current tree — integration points

| What | Path |
|---|---|
| Harness service (service-tree root) | `lib/Test2/Harness2.pm` (look at `IPC::Manager::Role::Service` composition + `ipcm_info` wiring) |
| Collector (will need a Preloaded sibling) | `lib/Test2/Harness2/Collector.pm` |
| Formatter (event injection) | `lib/Test2/Formatter/Stream2.pm` |
| Resources (no touch needed) | `lib/Test2/Harness2/Role/Resource.pm` — only relevant because JobCount's `T2_HARNESS_MY_JOB_CONCURRENCY` env-var injection happens during assign; the preloaded-test launch path must still honor that env hand-off. |

---

## 3. Proposed module layout

New files this branch should land. Names are suggestions; adjust as the
implementation clarifies them.

```
lib/Test2/Harness2/Preload.pm                    # DSL entry + meta
lib/Test2/Harness2/Preload/Stage.pm              # stage value object
lib/Test2/Harness2/Preloader.pm                  # base preloader service
lib/Test2/Harness2/Preloader/Stage.pm            # per-stage service
lib/Test2/Harness2/DepTracer.pm                  # @INC hook + dep map
lib/Test2/Harness2/Reloader.pm                   # reloader base + factory
lib/Test2/Harness2/Reloader/Inotify2.pm          # Linux::Inotify2 backend
lib/Test2/Harness2/Reloader/Stat.pm              # polling fallback
lib/Test2/Harness2/Reloader/Moose.pm             # (new) Moose-aware reload helper
lib/Test2/Harness2/Reloader/Exporter.pm          # (new) exporter-aware reload helper
lib/Test2/Harness2/Collector/Preloaded.pm        # fork-from-stage collector
```

Plus integration in:

```
lib/Test2/Harness2.pm                            # accept preload param,
                                                 # spawn base preloader as a
                                                 # child service, expose
                                                 # launch_test_in_preload()
```

Unit test files (prefixed `t/unit/Harness2/`) and a couple of integration
tests under `t/integration/` that cover the fork-tree + message round-trip.

---

## 4. Design notes per concept

### 4a. DSL (`Preload.pm`)

Port `old/`'s implementation nearly verbatim. The meta-object is a plain
HashBase holding `stage_list`, `stage_lookup`, `stack`, `default_stage`.
`import` exports the DSL subs into the caller. The `watch()` sub's three-way
dispatch (active stage → active reloader → active preloading stage) stays.

Change-only-if-necessary list:

- `file_stage` / `add_file_stage` — stay as `confess "deprecated..."`.
- No new DSL functions needed for the service-tree move; each stage already
  becomes its own service naturally through the existing `children` list.

### 4b. Stage value object (`Preload/Stage.pm`)

Port `old/`'s verbatim. It's purely data.

### 4c. Preloader service tree (`Preloader.pm` + `Preloader/Stage.pm`)

Key design points:

1. `Test2::Harness2::Preloader` is the **base** service. It is spawned by the
   harness, gets its own `ipcm_info`, and on startup:
   - Validates config (which preloads, which are DSL vs plain).
   - **Immediately `exec`s** `$^X -I@INC -mTest2::Harness2::Preloader -e '...bootstrap...'`
     where the bootstrap code lives inside a `BEGIN { ... }` block, closed
     by `Long::Jump::setjump` so later `long_jump`s have somewhere to land.
   - After `exec`, the BEGIN block loads each plain module via `require`,
     loads each DSL preload via `use Test2::Harness2::Preload` semantics,
     constructs the stage service tree, spawns child stage services,
     registers them with IPC::Manager so restart semantics apply.

2. `Test2::Harness2::Preloader::Stage` is the **per-stage** service. Spawned
   by the base preloader (or by another stage, for nesting). On startup:
   - Runs the stage's `load_sequence` (modules + coderefs, in order).
   - Registers its watch list with the Reloader if one is configured.
   - Fires `post_fork` callbacks for the immediate stage boot (from the
     parent's perspective this was a fork; from the stage's perspective this
     is the service starting up).
   - Enters the IPC service loop, listening for `launch_test` requests.

3. On a `launch_test` request:
   - Stage calls `pre_fork` callbacks.
   - Forks. Parent stays in the service loop (no blocking the tree on a
     single test). Child continues.
   - Child calls `post_fork` callbacks.
   - Child sets up the collector (fork again → parent is collector, child is
     test process — same topology as the existing `Test2::Harness2::Collector`
     but mounted from within the stage).
   - In the test-process grandchild, `pre_launch` callbacks run.
   - `long_jump` back to the BEGIN-block landing point (the base preloader's
     exec'd script defines it so the landing is stack-zero).
   - `goto::file $test_file`.

4. Parent-restart semantics come from IPC::Manager. Nothing special for us
   to implement — just make sure we register each stage as a child service
   of its parent, not as a flat list under the base.

### 4d. DepTracer (`DepTracer.pm`)

Straight port from `legacy/`. Installs an `@INC` coderef hook that wraps
`require`, records `parent_module => [loaded_mods]` as `require`s proceed.
Provides:

- `exclude` list (skip standard core modules).
- `callback_per_require` hook (used by the reloader to build the inverse
  map).
- `current_dependencies($mod)` query.
- `importers_of($mod)` — **new** capability this branch adds, driven by the
  exporter-reload audit. Hook `Exporter::import` (and any other known export
  entry points) to record who imported what from where.

### 4e. Reloader (`Reloader.pm` + backends)

Port `old/`'s base factory (choose Inotify2 if `Linux::Inotify2` is
installed, else `Stat`). Each backend watches files; on change:

1. Call any user-supplied `watch` coderef instead of reloading (escape hatch
   preserved from DSL).
2. Try churn-block reload (from `legacy/` — scan the file for `HARNESS-CHURN-START`
   / `HARNESS-CHURN-STOP` markers and `eval` the block as a redefinition).
3. Try in-place reload:
   - If the module has a Moose metaclass → `Reloader::Moose` pathway
     (reinitialize metaclass, reload roles in dependency order, rebuild
     accessors, rerun BUILD chain if instances exist).
   - If the module exports → `Reloader::Exporter` pathway (glob-repoint
     where possible, fall back to re-import on tracked importers).
   - Else → stash-clear + `require` (old/legacy default).
4. If in-place fails or the stage says `reload_inplace_check` returned false
   → mark the stage for restart, parent preloader kills + respawns it.

### 4f. Preloaded collector (`Collector/Preloaded.pm`)

`old/` has a working implementation. Port it with the following changes:

- Use the current `Test2::Harness2::Collector` as the parent class / role
  basis so the parser / auditor / logger chain is shared.
- Stdio handoff uses the current Atomic::Pipe + Stream2 plumbing, not
  `old/`'s `/proc/$pid/fd/` dance (keep the proc-fd path as a fallback only
  if cross-platform stdio dup'ing turns out to be hard).
- Emit the same `service_started` / `service_stopped` envelope events the
  main collector emits, so downstream loggers don't need a special case.

---

## 5. Integration points on `lib/Test2/Harness2.pm`

Minimal-footprint changes to the harness service:

- Add a `preload` constructor attribute (arrayref of module names).
- During `run_on_start`, if `preload` is non-empty, spawn the base preloader
  as a child service of the harness. Register its pid, mount its
  ipcm_info, and wait for it to emit a "ready" event before proceeding.
- Add `launch_test_in_preload(%args)` method: looks up the target stage
  service by name, sends an IPC request, returns a collector `Handle`.
- Do NOT replace the current direct-launch path in `run_on_all`. Both paths
  must coexist for this branch; the scheduler rewrite later chooses which
  to use per-job.

---

## 6. Work plan (sequenced so you can stop at any step and still have value)

1. **DSL + stage value object** — port `Preload.pm` and `Preload/Stage.pm`
   from `old/`. No services yet. Unit tests verify the DSL builds the stage
   tree correctly.
2. **DepTracer** — port from `legacy/`. Add `importers_of` tracking. Unit
   tests verify dep + importer maps after a synthetic `use` sequence.
3. **Reloader base + Stat backend** — port from `old/`, add factory. Hard
   dep on `DepTracer`. Unit tests with a tmpdir of test modules and
   synthetic `touch` events.
4. **Inotify2 backend** — viable-loaded, no hard dep on `Linux::Inotify2`.
   Unit tests gated on the module being installed.
5. **Moose + Exporter reload helpers** — `Reloader/Moose.pm`,
   `Reloader/Exporter.pm`. Each is optional (viable-gated). Unit tests
   reload a real Moose class and a real Exporter module, verify callers
   see the new behavior.
6. **Preloader base service** — `Preloader.pm`. This is the one that exec's
   and uses BEGIN + Long::Jump. Prove the exec + setjump + long_jump +
   goto::file pipeline end-to-end with a trivial "echo test" before wiring
   anything else. Service registers with the harness as a child service.
7. **Stage services** — `Preloader/Stage.pm`. Service tree spawning, parent
   restarts child, handles `launch_test` message.
8. **Preloaded collector** — port from `old/`, adapted to current Collector.
9. **Harness integration** — `preload` constructor attr,
   `launch_test_in_preload()` public API, "base preloader is ready" wait
   in `run_on_start`. Integration tests round-trip a test launch through a
   simple 1-stage preload.
10. **Docs + POD cleanup**. FEATURES_TODO entries 2-6 can be marked done in
    the main-branch TODO at this point.

Each step above should be its own commit (per CLAUDE.md).

---

## 7. Open questions to resolve in-session

1. **Exporter reload strategy** — pick one of the three audit candidates in
   §1b after prototyping. Document the choice in `Reloader/Exporter.pm` POD.
2. **Long::Jump availability** — it is already a dep (see commit
   `6c758be7d Harness2: optional Long::Jump unwind via jump_to`). Verify
   the existing usage pattern in `Test2::Harness2::Spawn` / the harness
   service, and match it.
3. **goto::file availability** — confirm the module is installed in this
   project's toolchain; if not, add to the dep list (cpanfile / Makefile.PL).
4. **Service message format** — match whatever the current Collector
   uses for `service_started` / `service_stopped` envelope events so the
   logger layer does not need a new code path.
5. **Windows** — `old/` and `legacy/` are Linux-biased (inotify, /proc/fd).
   The current rewrite explicitly targets Unix per CLAUDE.md, but double-
   check whether the collector's Windows spawn path needs a
   `Collector/Preloaded/Windows.pm` sibling or whether preloading is
   declared unsupported on Windows.

---

## 8. Style reminders (from CLAUDE.md)

- `Object::HashBase` for attributes, `Role::Tiny` for roles, `parent` for
  inheritance.
- `my $pid = fork // die "fork: $!"` — never separate defined-check.
- Three-step `my $ok = eval { ...; 1 }; my $err = $@;` pattern when
  branching on eval result.
- `croak` for user-facing, `die` for internal re-throws.
- Never swallow exceptions. Only acceptable exception: `viable()` methods
  gating optional module loading.
- Constants over package vars for "is module X installed" checks.
- Postfix conditionals for single-statement guards.
- `push @a => $v` fat-comma convention.
- Run `perltidy` with the project's `.perltidyrc` on everything new or
  modified.
- No trailing whitespace. No emojis.

---

## 9. Testing

Canonical test runner (per project memory):

    perl -Ilib scripts/yath test -D -j24

For verbose single-run of a specific file drop `-j24`:

    perl -Ilib scripts/yath test -D t/unit/Harness2/Preload.t

Because this branch introduces long-running service trees, some integration
tests will want an explicit timeout and pid cleanup in their teardown — see
`t/integration/harness2_ipc_notify.t` for the pattern.

---

## 10. When this branch is done

Before merging, update the primary repo's `FEATURES_TODO`:

- Mark items 2, 3, 4, 5, 6 as complete.
- Add a new "Scheduler uses preload path" item pointing at this work as the
  dependency.

Also update the project memory note `project_phase4_in_progress.md` (or
whichever successor is current) to reflect what landed.
