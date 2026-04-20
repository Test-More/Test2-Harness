# Stage 8 — Initial preload system (no reloading)

## Branch

- `plan-stage-08-preload`
- Base: `plan-stage-07-plugins` (8186ee153)

## What landed (six commits, in order)

1. **`Preload DSL: port stage builder and stage value object`** —
   `lib/Test2/Harness2/Preload.pm` (the DSL importer + meta-object)
   and `lib/Test2/Harness2/Preload/Stage.pm` (the pure-data stage
   value object), ported from the `reimplement-preloader` branch.
   `watch`, `reload_inplace_check`, and the `Reloader::ACTIVE`
   fallback are present so DSL code stays portable from old/, but
   the reloader path is inert until Stage 9 lands it.
   - `t/AI/unit/Harness2/Preload.t` — 11 subtests covering stage
     basics, add_to_load_sequence, callback dispatch, watch, the
     DSL's build_stage + nesting + duplicate detection, default
     stage resolution, eager stages, import exports, and merge.

2. **`Preload: resource class + root service + BEGIN bootstrap`** —
   three coordinated modules:
   - `lib/Test2/Harness2/Resource/Preload.pm` consumes
     `Role::Resource` and declares `service_preload_start`. It's
     not a job limiter; `available` never gates; `assign` stamps
     `T2_HARNESS_PRELOAD_STAGE` into the child env when a stage is
     known. `service_preload_applicable` returns 0 for an empty
     preload list, `service_preload_restartable` returns 0 (Stage 8
     preload is non-restartable; Stage 9 will add reloading and
     with it restartability).
   - `lib/Test2/Harness2/PreloadService.pm` is the root preload
     service. Consumes `Role::Service`. `request_handler_launch_job`
     forks a child that calls `Collector->interpose` and runs the
     test via `do $test_file` inside the forked test grandchild.
   - `lib/Test2/Harness2/PreloadService/Bootstrap.pm` is the tiny
     BEGIN-time module referenced by `service_preload_start`'s
     `ipcm_service(exec => {...stay_in_begin => 1...})` argv. Its
     `import` reads the config file and `require`s each preload
     module before `IPC::Manager::Service::State::import` takes over
     and enters the service loop.
   - `t/AI/unit/Harness2/Resource/Preload.t` — 4 subtests covering
     construction validation, applicability gating, the
     Role::Resource contract methods, and the env-stamp path.

3. **`Harness2: route launch_job to the preload service when a
   preload resource is present`** — adds `_preload_target_for` and
   `_wait_for_service_ready` helpers and teaches `_launch_job` to
   target `"preload"` instead of `"run-$run_id"` when a Preload
   resource is configured and its service has come up. The
   synthetic-skip / synthetic-fail paths (`opts{launch}` supplied)
   always bypass the preload route. The launch payload now carries
   `run_bus_name` so the preload service's collector can address
   its `ipc_run` without having to reconstruct the run service's
   bus name from the `run_id`.

4. **`Command::test: wire --preload to a
   Test2::Harness2::Resource::Preload`** — drops the placeholder
   stderr warning and instead attaches a `Resource::Preload` to
   the harness spawn when `--preload=Module` is passed. Empty
   `--preload` leaves the resource out entirely (non-preload path
   unchanged).

5. **`Tests: end-to-end Stage 8 preload smoke coverage`** —
   `t/AI/integration/preload_basic.t` runs two scenarios through a
   spawned harness with a `Resource::Preload` attached:
   - A trivial pass with `Scalar::Util` preloaded — verifies
     routing from harness to preload service to collector to test
     actually lands a pass/fail tally back via `run_status` IPC.
   - A sentinel test that asserts its preloaded module is ALREADY
     in `%INC` at test startup, before the test file itself does
     any `require`. That is the actual preload benefit: the test
     child inherits the preload root's `%INC` via fork.

6. **`STAGE_SUMMARY: Stage 8 summary`** (this file).

## Test results

- `prove -I lib -I t/lib -r -j16 t` — **40 files / 405 tests, all
  passing** on this branch.
- End-to-end CLI smoke via `perl -Ilib scripts/yath test
  --preload=Scalar::Util /tmp/preload_test.t` — `pass=1 fail=0`,
  with `$INC{'Scalar/Util.pm'}` observable in the test before the
  test's own `use Scalar::Util`.

## Points of interest / decisions worth revisiting

### 1. Stage-subtree services are NOT implemented in Stage 8

`IPC_AND_LOGGERS` section 10.1 calls for each DSL stage to be its
own service in its own process, with nested stages forked from
their parents. Stage 8's PreloadService is a single flat root: the
`_build_meta` hook does merge DSL meta-objects from preloaded
libraries (so `stage`/`preload`/`eager`/`default` declarations
are captured), but every `launch_job` runs from the root's own
forked child, not from a per-stage service.

The net effect for Stage 8 users: `--preload=Module` works, and
`use Test2::Harness2::Preload; stage foo => sub { preload 'X' };`
in `Module` is honoured at the DSL-data level (the modules get
loaded at root startup), but a test cannot yet be routed to a
specific named stage — every test goes through the root.

Adding per-stage services is a natural follow-up; the DSL, the
Resource, and the launch-routing hook are already shaped to
accommodate it without reworking callers.

### 2. No detach pattern in `launch_job`

`IPC_AND_LOGGERS` section 10.4 specifies that test-job collectors
launched from a preload stage must be detached via an intermediary
fork+exit so the stage can be pruned or reloaded without killing
running tests. Stage 8's PreloadService keeps the collector as a
direct child of the preload service — short-term this is
harmless because:

- Stage 8 doesn't implement stage reload or pruning, so the
  stage can't disappear mid-run.
- The preload service's `service_on_reaped` cleans up
  launch-tracking state, and its `run_should_end` waits for every
  launched collector before unwinding the loop.

**Stage 9 will need to introduce the detach pattern** because
reloading requires the stage's collector-parentage to be
discardable. That's explicitly flagged in `PreloadService`'s POD.

### 3. No `Long::Jump + goto::file` test-body substitution

Stage 8 uses `do $test_file` inside the forked test child rather
than the `Long::Jump + goto::file` unwind-to-BEGIN pattern that
`old/` and `reimplement-preloader` use. The preloaded `%INC` is
still inherited via fork, which is the essential preload benefit
— the `goto::file` refinement is about stack depth / $0 handling,
not about preload correctness. Deferred to later.

### 4. `run_bus_name` in the launch payload

`IPC_AND_LOGGERS` section 5.4 specifies that run services use the
`run_id` directly as their bus name. The current `RunService`
implementation actually names itself `"run-$run_id"`, which is a
drift from the spec. Rather than change the existing naming
mid-stage (risky: breaks every in-flight rebase on the chain),
this stage threads the authoritative run-service bus name through
the launch payload. When the RunService naming gets realigned
with the spec, dropping `run_bus_name` from the payload is a
two-line edit.

### 5. Preload is harness-global only in Stage 8

Per `IPC_AND_LOGGERS` section 9, a Preload resource can be
attached at harness-global scope (resource lives in the harness,
its service is `ipc_parent = harness`, no `ipc_run`) or
run-scoped (lives in a run service, `ipc_parent = run service`,
`ipc_run = run_id`). Stage 8 implements only the global-scope
flavour: `Command::test` attaches the resource to the harness,
and `_preload_target_for` walks the harness's `resources` list
only.

Run-scoped preloads are a follow-up: `Run.pm` already supports
per-run resources; wiring them into the preload-routing path is
a targeted change to `_preload_target_for` and a symmetric
lookup on `run->resources`.

### 6. PreloadService is non-restartable (Stage 8 compromise)

A preload-service crash flips the resource `permanent_broken`
and the scheduler's `broken_resource_behavior` (skip / fail /
abort) covers the pending tests. Stage 9 will add reloading and
with it the restartability companion
(`service_preload_restartable` returning 1 instead of 0).
Reloading and restart are two sides of the same work.

## Flip-back notes for the next stage

- **Stage 9 (preload reloading)** should pick up the detach
  pattern in `PreloadService::request_handler_launch_job` and
  the restartability flip on the resource, both flagged in
  POD. The existing DSL surfaces (`watch`,
  `reload_inplace_check`) are already in place.
- **Stage 12 (renderers)** may want the preload service to
  emit `collector_artifacts` announcements for its own
  interpose collector (when one is eventually added). Today
  the preload service doesn't have a service collector
  wrapping it; adding one is a self-contained change to
  `Resource::Preload::service_preload_start` + the exec argv.
- **Any stage that rebases onto a re-aligned RunService**
  (bus name = `run_id`, per `IPC_AND_LOGGERS` section 5.4)
  needs to drop `run_bus_name` from the launch payload.

## Dependencies / what a reviewer should verify

- `Test2::Harness2::Role::Resource` and `Role::Service` contracts
  are honoured by the new classes.
- `ipcm_service` with `exec => { stay_in_begin => 1 }` — the
  `IPC::Manager` version on this system (0.000027) has this
  path; any prior version that lacked it would break startup.
  The POD flags this; CPAN metadata does not, so a future
  `META.json` bump may be warranted.
- `Collector::interpose` is called from a forked child of the
  preload service; the parent of that interpose fork becomes
  the collector (`_interpose_parent` → `_run_collector` →
  `_exit_mirroring_child`). This is the same shape RunService
  uses for its `launch_job` handler, so no new ground there.
