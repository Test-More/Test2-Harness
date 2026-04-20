# Stage 7 — Plugin roles

## Branch

- `plan-stage-07-plugins`
- Base: `plan-stage-06-options` (post-rebase, on top of the
  harness-explicit-loggers chain now landed on
  `reimplement-resource-classes`)

## Notes — post-rebase / architectural realignment

- The plan-stage chain has been rebased onto a new
  `reimplement-resource-classes` (option A from PLAN_RESUME.md).
  Both the resource-class work and the logger overhaul (formerly
  on the `harness-explicit-loggers` side branch) are now part of
  every plan-stage's base.
- PLAN gained a new "State and control flow: IPC, not on-disk
  artifacts" section. That change is absorbed in Stage 5 (a
  commit there rewrites `Command::test` to tally via IPC query to
  the harness service). A stage-7 cleanup commit that previously
  supplied a spec-less `Logger::JSON` to Command::test (a
  file-tally workaround, now an explicit PLAN violation) has been
  dropped from this branch.
- End-to-end single-file `yath test` works on this chain. The
  many-files IPC-recipient issue documented at the bottom of this
  summary was first observed under the dropped file-tally
  workaround; it is still open and belongs to the base, not to
  Stage 7.

## What landed (eight commits)

1. **`Test2::Harness2::Role::Plugin`** — new Role::Tiny role at
   `lib/Test2/Harness2/Role/Plugin.pm` declaring the harness-side
   hook surface. Every hook has a no-op or no-answer default so a
   bare consumer round-trips cleanly and callers can dispatch
   without `can()` checks. Hooks: `tick`, `run_queued`,
   `run_complete`, `run_halted`, `instance_setup`,
   `instance_teardown`, `instance_finalize`, `setup`, `teardown`,
   `munge_search`, `munge_files`, `claim_file`, `duration_data`,
   `coverage_data`, `post_process_coverage_tests`, `changed_files`,
   `changed_diff`, `TO_JSON`.

2. **`App::Yath2::Role::Plugin`** — new Role::Tiny role at
   `lib/App/Yath2/Role/Plugin.pm` that consumes the harness role
   via `Role::Tiny::With` and adds CLI-layer hooks: `client_setup`,
   `client_teardown`, `client_finalize`, `sort_files_2`,
   `sort_files` (deprecated alias), `args_from_settings`. A
   consumer of this role also satisfies the harness role and can
   be handed to `Test2::Harness2` directly.

3. **`App::Yath2::Options::Yath: activate --plugin / -p`** —
   uncomments the `plugins` Map option inside
   `lib/App/Yath2/Options/Yath.pm` (shape unchanged from the
   verbatim copy that landed in Stage 6). Short-form `-p` and
   long-form `--plugin=` both accept comma-split constructor
   args; fully-qualified class names pass through via the `+`
   prefix, while bare names resolve under `App::Yath2::Plugin::*`.
   `mod_adds_options => 1` is preserved so a plugin class's own
   option libraries are still auto-picked-up.

4. **`Test2::Harness2: accept a 'plugins' slot`** — adds
   `<plugins` to the HashBase slot list and validates in `init`
   that it is an arrayref (default `[]`). Per-hook dispatch into
   Scheduler / RunService / Collector is deliberately not wired
   yet — this stage's contract is just "the harness accepts the
   plugin list and does not lose it". Actual hook dispatch into
   the harness-side pipeline will land as each downstream
   consumer grows a real use for a specific hook (stage 8+).

5. **`App::Yath2::Plugins`** — new helper module at
   `lib/App/Yath2/Plugins.pm` with two entry points:
   - `load_plugins(\%spec)` turns the option Map into an ordered
     arrayref of plugin handles: instances for classes that
     define `new()`, bare class names otherwise. Sort order is
     alphabetical by class name for determinism.
   - `dispatch(\@plugins, $hook, @args)` walks the handle list
     and only calls plugins that actually implement `$hook`
     (rather than hitting the role's no-op default), so
     list-returning hooks do not accumulate empty answers.

6. **`Command::test: load plugins and dispatch client lifecycle
   hooks`** — extends `App::Yath2::Command::test` with
   `include_options('App::Yath2::Options::Yath')` so `--plugin`
   reaches the command's option set. Adds `_load_plugins` (built
   on `App::Yath2::Plugins->load_plugins`), dispatches
   `client_setup` before the harness spawn, then
   `client_teardown` and `client_finalize` in reverse order
   after the spawn completes (whether the run succeeded or
   threw). The loaded plugin list is threaded through to
   `Test2::Harness2->spawn()` via the new `plugins` slot.

7. **Role unit tests** — `t/AI/unit/Test2/Harness2/Role/Plugin.t`
   (4 subtests) and `t/AI/unit/App/Yath2/Role/Plugin.t`
   (4 subtests). Each covers role consumption (including the
   transitive composition), default hook return values on a bare
   consumer, overriding consumers dispatched in order, and the
   `TO_JSON` serialization shape.

8. **CLI / loader / slot tests** — three additional test files:
   - `t/AI/unit/App/Yath2/Plugins.t` (10 subtests) — empty and
     error inputs, stateful / stateless instantiation, missing-
     class error, `dispatch()` skip-non-implementers, order.
   - `t/AI/unit/App/Yath2/Command/test-plugins.t` (6 subtests) —
     `-p` / `--plugin` parsing end-to-end through `Command::test`,
     including the `+` fully-qualified escape and
     multiple-plugin argv.
   - `t/AI/unit/Test2/Harness2-plugins.t` (3 subtests) —
     Harness2's new plugins slot: default, preservation, and
     arrayref validation.

## Tests

- `prove -j16 -I lib -I t/lib -r t`
- Result: 38 files / 396 tests, all passing (~60s wall clock
  with `-j16`; ~76s serial). No pre-existing test was modified.
- End-to-end single-file `yath test` is no longer blocked — the
  Stage 5 regression documented in PLAN_RESUME.md was the
  missing caller-supplied logger specs, which the logger-overhaul
  commits + this branch's Command::test update together resolve.
  Smoke runs: `yath test trivial-pass.t` -> pass=1 fail=0 exit=0;
  `yath test trivial-fail.t` -> pass=0 fail=1 exit=1.

- **Known gap**: `yath test -j16 t/` on the full 38-file suite
  hangs after the "running 38 test file(s)" banner. Stderr emits
  two IPC errors --
  `Collector IPC send failed (kind 'collector_started'):
  'harness' is not a valid message recipient`
  and the same for `loggers_ready` -- then no further progress.
  This is _not_ introduced by Stage 7; it only became visible now
  that single-file `yath test` works. Likely a concurrency /
  IPC-recipient-resolution bug in the many-collectors-at-once
  path. Needs investigation in a separate branch. Prove still
  passes the same suite in 60s with `-j16` so the underlying
  tests and harness plumbing are fine in isolation.

## Points of interest / decisions to revisit

- **Plugins are stored on the harness but not yet dispatched.**
  `Test2::Harness2` just records the plugin list; nothing inside
  Scheduler, RunService, or Collector calls `run_queued`,
  `instance_setup`, `tick`, etc. The roles declare the surface;
  the call sites land when the consuming subsystem needs them
  (stage 8 preloads will most likely be first). If you want an
  earlier dispatch boundary, this is where to open it.

- **`client_*` hooks fire around `_run_tests`, unconditionally.**
  `client_teardown` and `client_finalize` run even when
  `_run_tests` threw. A plugin that wants "only on success"
  teardown needs to check `exit` itself. This matches the old
  behaviour where teardown was a best-effort callback.

- **`send_event` and `shell_call` are intentionally not ported.**
  Both depended on `Test2::Harness2::Collector::Child` and
  `Test2::Harness2::IPC::Util`, neither of which exists in the
  new rewrite yet. They can come back once their collector-side
  hosts do; adding empty stubs now would be worse than leaving
  the hooks off the role.

- **Renderer-facing hooks (`annotate_event`, `finish`,
  `finalize`) are deferred to Stage 12** by design. They are
  documented in `App::Yath2::Role::Plugin`'s POD as "coming in
  stage 12" rather than silently omitted, so a port of
  `App::Yath2::Plugin::SysInfo` / `Git` / `Cover` in Stage 15
  that relies on `finish` for end-of-run reporting can be
  recognised as "waiting on Stage 12" rather than "lost in the
  shuffle".

- **`sort_files_2` is declared but not yet called.** Finder /
  scheduler integration happens in a later stage once the
  post-discovery flow has a clear owner; right now the hook
  just exists for plugins to implement without needing a
  downstream call site.

- **Plugin args on a class-only plugin croak.** If you write
  `-pStateless=a,b` but `App::Yath2::Plugin::Stateless` has no
  `new()`, the loader croaks with a message that names the
  plugin and prints the args. Old yath silently ignored the
  args in that case; the new behaviour surfaces the mismatch
  loudly. If that turns out to be too strict for real-world
  use, flip `App::Yath2::Plugins::load_plugins` to a
  warn-and-drop.

- **`dispatch()` helper vs direct `for @$plugins` loop.**
  `Command::test` uses the direct loop for `client_setup`
  because every plugin has the role's default available and we
  want that default hit for consistency. `dispatch()` is there
  for list-returning hooks (`changed_files`, `coverage_data`,
  `duration_data`) where the empty default would pollute the
  aggregate. Pick whichever matches the hook's semantics.

- **`fqmod` eagerly `require`s the plugin module during option
  parsing.** The test fixtures for `-p+Other::NS::Plug`
  therefore have to inline-define the class and prime `%INC`;
  real plugins outside the `App::Yath2::Plugin::*` namespace
  need to be installed before `-p+Some::Mod` will even parse.
  This mirrors old behaviour; flag for a second look if the
  CPAN-loadable-at-parse-time requirement becomes awkward.

## What this branch needs from the user

No blockers. Stage 8 can begin on top of this branch. The only
interaction point with the `harness-explicit-loggers` side
branch (PLAN_RESUME.md decision A / B / C) is that once
`yath test` is end-to-end runnable, Command::test will want to
pass explicit logger specs alongside the plugins it already
threads through — a mechanical follow-up that can happen in
either order relative to Stage 8.

## Next stage

Stage 8 — initial preload system (no reloading). Create the
worktree off this branch:

    git -C /home/exodist/projects/Test2/Test2-Harness worktree add \
      .claude/worktrees/plan-stage-08-preloads \
      -b plan-stage-08-preloads plan-stage-07-plugins
    # then mirror .claude/ + CLAUDE.md symlinks
    # (snippet in CLAUDE.md under "Worktree Config Inheritance")

Stage 8's plan calls for using the `reimplement-preloader` branch
as a starting point — cherry-pick / rebase its DSL / DepTracer /
Reloader / exec+BEGIN+Long::Jump work onto this chain rather
than re-deriving it.

## Post-refactor rebase (2026-04-20)

Rebased through the full plan-stage chain onto the updated
`reimplement-resource-classes` base (`0c46805cf`). Refactor
headline items (IPC kind renames, direct artifact routing,
`collector:` bus name, configurable `launch_job_timeout`) land
here automatically from the base.

During cascade, the intermediate replay of stage-5's
`pass_count`/`fail_count` + IPC-tally commit on top of the stage-6
reshape of `App::Yath2::Command::test` produced merge-content
conflicts in `lib/App/Yath2/Command/test.pm` and
`lib/Test2/Harness2/Run.pm`. Resolution kept the HEAD (stage-7)
version of `Command::test.pm`, which is a proper superset of the
stage-5 incoming version, and kept all three Run.pm init lines
(pass/fail/launch_job_timeout). The `TestFile.t` rename/rename was
resolved by keeping `t/AI/unit/App/Yath2/TestFile.t`. No Stage-7
commits themselves needed edits. (Live branch tip recorded in
`PLAN_RESUME.md` on the primary repo, not pinned here.) Full
`prove -j16 -I lib -I t/lib -r t` green (382 tests).
