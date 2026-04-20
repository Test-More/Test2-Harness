# Stage 9 — Preload reloading (scaffolding)

## Branch

- `plan-stage-09-preload-reload`
- Base: `plan-stage-08-preload` (449a64ad5)

## What landed (three commits, in order)

1. **`Preload: ChangeWatcher role + Stat/Inotify implementations`**
   - `lib/Test2/Harness2/Role/ChangeWatcher.pm` declares the shared
     watcher interface (`watch`, `changed_files`, `viable`).
   - `lib/Test2/Harness2/ChangeWatcher/Stat.pm` is the portable
     mtime-polling backend. Always viable. Rate-limited by
     `min_interval` (default 1s, sub-second honoured via
     `Time::HiRes`).
   - `lib/Test2/Harness2/ChangeWatcher/Inotify.pm` is the
     Linux-native `Linux::Inotify2` backend, gated by `HAS_INOTIFY`.
     Non-viable installations fail construction with a clear error;
     consumers should consult `viable()` first.
   - `lib/Test2/Harness2/Util.pm` gains `file2mod` (inverse of
     `mod2file`). Used by the reloader to derive a module name from
     a `%INC` file path.
   - `t/AI/unit/Harness2/ChangeWatcher.t` exercises both backends.

2. **`Preload: Role::Reloader + Default + KillRestart`**
   - `lib/Test2/Harness2/Role/Reloader.pm` declares
     `reload_module($module, $file, \%info)` with three return
     shapes: `(1)` for in-place success, `(0, reason => ...)` for
     runtime failure, `('not_reloadable', reason => ...)` for
     policy-level refusal. Callers chain reloaders.
   - `lib/Test2/Harness2/Reloader/Default.pm` implements the
     in-place path. Priority: user watch callback > HARNESS-CHURN
     block re-eval > generic stash-clear + re-require. Moose-
     consuming modules get a metaclass `_reinitialize_class` pass
     first when Moose is already loaded. Modules with non-trivial
     `import()` are refused (Exporter-aware reloader is deferred).
   - `lib/Test2/Harness2/Reloader/KillRestart.pm` unconditionally
     returns `not_reloadable`. Intended as the terminal entry in a
     reloader chain, falling into branch pruning per
     `IPC_AND_LOGGERS` section 10.5.1.
   - `t/AI/unit/Harness2/Reloader.t` exercises refusal branches,
     user-callback routing, and a full in-place reload against a
     real temp module.

3. **`STAGE_SUMMARY: Stage 9 summary`** (this file).

## Test results

- `prove -I lib -I t/lib -r -j16 t` — **42 files / 415 tests, all
  passing** on this branch. Same green bar as Stage 8 plus the two
  new Stage 9 test files.

## Explicit Stage 9 deferrals

Stage 9's PLAN entry calls for:

> Teach the preload resource to watch `%INC` per stage via the
> watcher role and to trigger the reloader chain when changes are
> seen.

> Implement deferral: when a reload fails with a reason, defer tests
> needing the broken stage and log a single event per distinct
> reason (tracker resets on stage-state or reason change).

> Port `old/t/Yath/integration/reload*.t` into `t/`.

This stage **ships the scaffolding but not the integration**:

- The `ChangeWatcher` and `Reloader` roles + their initial
  implementations are all in place.
- The `PreloadService` tick loop **does not yet consult a
  ChangeWatcher or dispatch through a Reloader chain**. Plumbing
  the reloader into `PreloadService::run_on_tick` + the branch-
  pruning path from `IPC_AND_LOGGERS` section 10.5.1 is a focused
  follow-up — all the building blocks exist; what's missing is the
  glue.
- Stage deferral (tests held when a stage is `down` /
  `restarting`, one warning per distinct reason) is not yet wired
  into the harness scheduler. The scaffolding (the `not_reloadable`
  return shape from reloaders) is ready for it.
- `old/t/Yath/integration/reload*.t` is not ported: that test
  depends on both the full reload integration and the daemon
  (`yath start` / `yath run`) surface introduced in Stage 14.

Stage 8's `PreloadService` POD already flagged that reload and
stage restartability land together; Stage 9's scaffolding unblocks
that work without landing it outright, so Stage 10 onward can
proceed.

## Deliberate drift from old/'s reloader

- **Exporter-aware reload is not ported.** `old/`'s Reloader had
  `Test2::Harness2::Reloader::Exporter` that tracked imported subs
  and replayed them after reload. Stage 9's Default reloader
  simply refuses any module with a non-trivial `import()`. The
  refusal fails over to `KillRestart`, so callers that chain
  correctly still make forward progress; the optimisation can
  return as its own follow-up when someone has a concrete test
  case.

- **Reload blacklist feature is not ported.** `PLAN` explicitly
  excludes it.

## Points of interest / decisions worth revisiting

### 1. Role::ChangeWatcher vs a single class

`old/` had a base class `Test2::Harness2::Reloader` that picked
Stat vs Inotify2 via a `BEGIN { *USE_INOTIFY = ... }` constant.
Stage 9 instead uses a Role::Tiny role + two sibling classes.

Rationale: the PLAN text said
"Role::ChangeWatcher (or similar — pick the name that reads best)",
and a role lets a consumer swap in a mock watcher for unit tests
without inheritance gymnastics. The preload resource can pick the
concrete class via `viable()` without the class hierarchy guessing
for it.

### 2. Direct-vs-symbolic package-variable access after reload

The Reloader unit test for an in-place reload uses
`${"Pkg::VALUE"}` (symbolic deref) rather than `$Pkg::VALUE`
(direct) to read the module's post-reload state. The direct form
binds at compile time to the SV slot of the pre-reload glob;
since the reloader deletes that glob before re-requiring, the
direct form sees the stale value. Symbolic lookup resolves at
runtime against the current stash.

In-process consumers (the preload stage launch paths that Stage 9's
follow-up will wire in) should be fine because they look up
subs by name / resolve packages at call time. The test comment
calls this out explicitly.

### 3. Construction pattern

`Object::HashBase qw{}` with zero slots does NOT install a
`new()`. Both reloader classes declare their own minimal
`sub new`. The watchers use `Object::HashBase` with real slots and
get `new()` free. This mismatch is small and documented inline; a
follow-up could pull an `::InstanceBase` that always supplies
`new()`, but that's a refactor, not a stage requirement.

## Flip-back notes for the next stage

- **Stage 9 integration follow-up** (can be done as its own
  commits on this branch, or pulled into the Stage 8 /
  `PreloadService` codebase when reload lands): teach
  `PreloadService` to construct a `ChangeWatcher::Inotify` (or
  `Stat` fallback via `viable()`), seed it from `%INC` at
  service startup, poll it in a tick hook, and dispatch each
  change through `Reloader::Default` → `Reloader::KillRestart`.
  The `_build_meta` hook already captures `stage->watches` so
  the watcher can pull those in.
- **Stage 12 (renderers)** doesn't depend on any of this.
- **Any later stage that introduces `Exporter`-based preloads**
  should add `Test2::Harness2::Reloader::Exporter` and insert it
  into the chain before Default's refusal fires.

## Dependencies / what a reviewer should verify

- `Role::Tiny` semantics: both new roles `requires` their core
  methods and provide sensible defaults for hooks.
- The `ChangeWatcher::Inotify` backend is not usable without
  `Linux::Inotify2`; the compile path is fine (gated by
  `HAS_INOTIFY`).
- The Default reloader's `_reload_moose` is best-effort and falls
  through to `_reload_generic` either way. That mirrors the
  `old/` path; deeper metaclass surgery can come back when
  `Test2::Harness2::Reloader::Moose` is reintroduced.
