# Reimplement Resource Classes — Resume Notes

**Session date:** 2026-04-17
**Branch:** `reimplement-resource-classes` (forked from `2.0_rewrite`)
**Worktree:** `/home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-resource-classes`

This document captures the full context of the resource-class reimplementation
so the work can be resumed in a fresh session.

## Original request (session start)

The user created an empty stub at `lib/Test2/Harness2/Role/Resource.pm`
containing only comments describing the goals and scope. The full stub text
is reproduced below. It was replaced wholesale during implementation, so
this copy is the authoritative record of the original design brief.

```
package Test2::Harness2::Role::Resource;

# This will be modeled largely on the resource model in old/ and in legacy/ favoring old/
#
# Instead of a base class we will use a role for resources.
#
# The JobCount role will be ported from old/ and/or legacy to this new system
#
# JobCount will be used to throttle test jobs in the harness service instead of its current "one at a time" built in logic.
#
# At least one resource to limit job count should always be present for the harness service, not having one is a failure condition, but can fallback to the JobCount one with a limit of 1 as a default
#
# Resources should indicate if they are a job-count-limiter or not, default to 0 unless overriden
#
# Resources need the following methods:
# available - returns true if there are resources available, can take key/value params as arguments, for example some tests may need 2+ slots, they should be able to ask if 2 are available. Not all resources are job slots, so make this flexible
# assign - requests the resource(s) be assigned to the test
# release - release the resource(a) back to other tests
# status - returns a hashref of what resources are assigned ot what tests (when applicable)
#
# A resource may also define service_XXX methods, During resource
# initialization the harness service should run these and they may start new
# services, or simply return if the resource decides the service is not
# necessary. If the method call returns -1 it means the service is not needed,
# not started, ignore moving forward. returning 0 means the service was
# started, but do not restart it. returning 1 means service is started, and
# call the method again if the service exits before the harness service enters
# shutdown. If a resource service ends (process exits) then the resource should
# be put into a "broken" state. When broken a resource cannot have new
# allocations, and any test that has had the resource assigned fails while the
# resource is broken then the test should be flagged to be run again (re-run
# logic can be implemented later, ok to put in a todo). If the service_XXX call
# returned 0 then the resource stays broken (mark it as perminently broken) any
# tests that cannot run (or be re-run) as a result of the resource being broken
# forever will be failed or skipped based on an attribute to be set on the run
# object. If the service_XXX call returned 1 and then broke, the method should
# be called again to restart the service, one it reports it is back up (it can
# notify the harness service using the IPC system ipcm_info already in place on
# the harness service) the resource can be assigned to new tests again. Also
# add IPC api's for a resource service to notify the harness service of pauses,
# temporary brokenness perminent brokenness, and any other states that make
# sense. If perminent broken is set then the harness service should not make
# further attempts to restart the service.
#
# Look at how the scheduler works in old/ to see how resources are used, use the same type of logic with the new services.
#
# Do not implement these yet, but we will also be implementing resource classes that throttle tests when memory gets low, or when disk space on specific mounts get low. Go ahead and create files for these, also create a stub for the SharedJobs resource in old/ and/or legacy/, but only stubs for now. Same for any resource classes I am forgetting from old/ and legacy/
#
# Do not worry about copying or porting all the TestFile logic from old/ or
# legacy/. For now assume tests will be passed in to the Harness service with
# important details like how many job slots they need already set (default to 1
# if not set). But do create a simple TestFile class based on whats in old/,
# just assume it gets the attributes already set and does not need to
# recalculate or build anything. Update the harness service to require the
# tests be passed in inside the run object as TestFile objects. This includes
# absolute and relative paths to the test file to be run.
#
# Critical design changes:
# legacy wrote services such that different processes could change the state, with our new rewrite that does not happen, only the harness service process will modify the state, so we do not need to track state in an IPC safe way
# The main harness init can be created with services that are globally applied to all runs. Runs may also have their own services that sre started for the run, then cleaned up when the run is complete. IPC calls will be needed to tell a resource service to shut down when the run is complete.
# Do not worry about preload logic yet
```

## Subsequent user requests (chronological)

1. **"Read it and implement."** — executed; see "What was implemented" below.
2. **"There are stuck Test2-Harness2 processes in busyloops, investigate, did
   any start from this session, only look at ones from this session."** —
   Identified six stuck pids from two test runs of `t/integration/harness2_ipc_notify.t`
   started during this session. Root cause was the pre-existing Collector
   busy-loop bug documented in
   `docs/superpowers/plans/2026-04-17-collector-busy-loop-fix.md`.
3. **"Double check, the collector fix is merged in the main tree, is it not
   merged in our worktree?"** — Correct. `2.0_rewrite` had landed
   `04440d941 Collector: park the read loop on IO::Select instead of busy-spinning`
   after the worktree was created. Rebased `reimplement-resource-classes` onto
   `2.0_rewrite` to pick it up.
4. **"yes"** (to rebase + re-run `ipc_notify` to confirm fix) — done; no new
   stuck processes.
5. **"yes"** (to `kill -9` the six stale pids) — done.
6. **"Add the untracked files to git as empty so a `git diff` shows me all the
   changes, not just the modifications of existing files."** — ran
   `git add -N` on the six new files so `git diff` shows full additions.
7. **"Availability of all required resources for a given test should be
   checked before any commitments are made, make sure that is how it works,
   then remove the weight as it is not necessary if we only assign resources
   when all needed ones are available."** — verified `_evaluate_resources_for`
   already implements all-or-nothing (it walks every applicable resource,
   returns early on any defer/skip, and only hands back the list when every
   resource returned >0; `assign` is only called inside `_launch_job` after
   a `'launch'` decision). Removed `sort_weight` from the role (method + POD)
   and the sort step in `_init_resources`. Added a new Harness2 unit test
   ("run_on_all commits no resource when any is unavailable") to guard the
   invariant.
8. **"Write a file with everything needed to pick this back up... then make a
   commit including that file, then rebase onto the main tree..."** — this
   document plus the rebase.

## What was implemented

### New modules

- `lib/Test2/Harness2/Role/Resource.pm` — Role::Tiny role. `requires`
  `available/assign/release/status`. Provides `is_job_limiter` (default 0),
  `applicable` (default 1), `resource_name`, `is_broken`/`is_permanent_broken`/
  `is_paused`/`is_usable`, state transitions `mark_broken/mark_permanent_broken/
  mark_paused/mark_resumed` (permanent is sticky), `service_methods`
  introspection of `service_*` subs on the consumer, `teardown` hook.
- `lib/Test2/Harness2/Resource/JobCount.pm` — concrete limiter ported from
  `old/`. Honors `min_slots`/`max_slots` on each `TestFile`, sets
  `T2_HARNESS_MY_JOB_CONCURRENCY`, returns -1 when the job's `min_slots`
  exceeds the pool.
- `lib/Test2/Harness2/Resource/Memory.pm`, `Disk.pm`, `SharedJobs.pm` — stubs
  with `status`, attribute scaffolding, and `croak "not implemented yet"` on
  the runtime hooks.
- `lib/Test2/Harness2/TestFile.pm` — simple value object (no file scanning).
  Defaults for slots, category, duration, conflicts, features, etc.

### Updated modules

- `lib/Test2/Harness2/Run/Job.pm` — `test_file` now holds a `TestFile` object
  (bare path strings are auto-wrapped for convenience). `test_file_abs`/
  `test_file_rel` are shortcuts.
- `lib/Test2/Harness2/Run.pm` — `from_files` accepts `TestFile` objects or
  path strings.
- `lib/Test2/Harness2.pm`:
  - New `resources` attribute; `_init_resources` ensures at least one
    `is_job_limiter` (default fallback: `JobCount(slots=1)`).
  - `+current` → `+running_jobs` hash keyed by `job_id`; multiple concurrent
    jobs supported, gated by the resource stack.
  - `run_on_all` calls `_try_launch_next_pending` in a loop; the helper uses
    `_evaluate_resources_for` (`applicable`/`is_permanent_broken`/`is_usable`/
    `available`) to decide `skip`/`defer`/`launch` per job. Only `launch`
    triggers `_launch_job`, which calls `assign` on each resource (all-or-
    nothing).
  - `run_on_pid` handles both collector pids and resource-service pids; a
    resource-service exit flips the resource to `broken` (if restartable) or
    `permanent_broken` (if one-shot).
  - `run_on_start` invokes `_start_resource_services` for global resources.
    `track_resource_service` records pids for later `run_on_pid` handling.
  - `run_on_general_message` routes `resource_{paused,resumed,ready,broken,
    permanent_broken}` IPC messages through `_handle_resource_state_message`
    which calls the appropriate `mark_*` helper on the named resource.
  - `_perform_hard_stop` sweeps all running-job pids + resource-service pids.
  - `run_on_cleanup` calls `teardown` on every resource.
  - `request_handler_status` emits `running` as an arrayref and adds a
    `resources` key with each resource's `status` output.

### New/updated tests

- New:
  - `t/unit/Harness2/Role/Resource.t`
  - `t/unit/Harness2/Resource/JobCount.t`
  - `t/unit/Harness2/TestFile.t`
- Updated:
  - `t/unit/Harness2.t` (replaced `current` with `running_jobs`, updated
    status shape assertions, added all-or-nothing invariant test)
  - `t/unit/Harness2/Run.t`, `t/unit/Harness2/Run/Job.t`
  - `t/integration/harness2_ipc_notify.t`, `harness2_lifecycle.t`,
    `harness2_spawn.t` (new `running` arrayref shape in status)

All 265 tests pass as of the commit preceding this file.

## Deliberately deferred

- **Per-run resources**: infrastructure exists (`scope => 'run'` arg, `run`
  context in `_start_resource_services`) but only global resources are
  currently started. Per-run startup and teardown need to be wired into the
  run queue/finalize lifecycle.
- **Resource-service restart**: `run_on_pid` flags a resource broken or
  permanent-broken when its service exits, but it does NOT yet re-invoke the
  `service_*` method to restart a restartable service. To do later.
- **Skip-result events**: when `_try_launch_next_pending` skips a job
  because a resource returned `-1`, the job is just moved to done. Real
  skip-result events (that propagate to collectors/UI) are not emitted.
- **Test retry logic**: the stub says a test that fails while an assigned
  resource is broken should be flagged for re-run. Not implemented.
- **Resource::{Memory,Disk,SharedJobs}**: stubs only; attribute surface and
  `status` implemented, runtime hooks `croak`.
- **`HARNESS-*` directive scanning** on TestFile: out of scope per the
  original brief; callers construct TestFile objects with attributes
  pre-computed.
- **Preload logic**: explicitly out of scope.

## Current branch state

- **Base commit before this session's work:** `9323c49c1`
- **My session commits (in order on the branch):**
  1. `74bae7f2b gitignore: exclude /.claude/ session state`
  2. (this commit) `docs/superpowers/plans/2026-04-17-reimplement-resource-classes-RESUME.md`
- **Uncommitted WIP on top:** the entire resource work (role, JobCount,
  stubs, TestFile, Run/Job + Run updates, Harness2 scheduler + lifecycle +
  IPC message routing, all tests).

The WIP is deliberately uncommitted so the user can review the full diff as
one unit. To commit it, a clean split would be:

1. Role + JobCount + stubs + TestFile (new files)
2. Run/Job + Run + unit tests (TestFile integration)
3. Harness2 resource wiring + status shape + running_jobs + IPC notify
   handlers + new unit test
4. Integration test updates (status->running shape)

## Resume steps for next session

1. `cd /home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-resource-classes`
2. `git status` — expect the same WIP the previous session left behind
   (unless it has since been committed).
3. `prove -Ilib -r t/` — confirm still green.
4. Review `git diff` and decide how to split into commits (see above).
5. Pick up deferred work (most likely in this order):
   - Per-run resource lifecycle
   - Skip-result events when a resource returns -1
   - Resource-service restart handling
   - Test-retry on broken-resource failure
   - Fill in one of the stubs (Memory is simplest; use
     `/proc/meminfo` on Linux)

## Key design decisions worth remembering

- **All-or-nothing assignment**: `_evaluate_resources_for` returns
  `('launch', \@resources)` only when every applicable resource returned a
  positive `available`. `assign` is never called during evaluation; it only
  runs inside `_launch_job` after the decision is fixed. This removed the
  need for a `sort_weight` because ordering is purely observational.
- **Resource state is in-process only**: per the original brief, only the
  harness service mutates state. The role's state flags live directly on
  the resource hash with private `_resource_*` keys (Object::HashBase
  allows extra keys not declared in the attribute list).
- **`service_methods` excludes itself**: the introspection helper starts
  with `service_` and had to explicitly skip its own name to avoid returning
  it.
- **String paths are wrapped**: `Run::Job` and `Run::from_files` accept
  bare path strings and wrap them in a default `TestFile` so callers that
  do not care about slot counts or scheduler hints do not have to construct
  `TestFile` objects explicitly.
- **Collector busy-loop was not mine**: the stuck processes investigated
  mid-session came from a pre-existing Collector bug fixed in
  `04440d941`. After rebasing onto `2.0_rewrite` the fix is in place.
