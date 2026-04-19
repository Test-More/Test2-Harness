# Resource Classes — Resume Notes (Session 2)

**Dates covered:** 2026-04-17 (prior session) through 2026-04-18
**Branch:** `reimplement-resource-classes` (forked from `2.0_rewrite`)
**Worktree:** `/home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-resource-classes`

Supersedes `2026-04-17-reimplement-resource-classes-RESUME.md` for
current status. The 2026-04-17 file remains the authoritative record
of the original design brief and the prior session's request trail.
The supplemental `RESOURCE_IMPL_CONTEXT.md` at the worktree root is
still the reference for deferred scope and `old/`/`legacy/` pointers.

---

## Commits on this branch

```
5ab06eeaf Address code-review feedback on restart + per-run lifecycle
220c580fe Integration tests: adjust status shape for running arrayref
ac27474d3 Harness2: resource-gated scheduler with restart and per-run lifecycle
e1c72b9a4 Run/Job: carry TestFile objects, add mark_skipped and per-run resources
c8f395eba Resource framework: role, JobCount, stub resources, TestFile
2b098eb64 docs(plans): resume notes for resource-class reimplementation   (prior session)
```

Base: `9323c49c1` (first commit on this branch's history) -> rebased
onto `2.0_rewrite` at `18df142f3` during the prior session.

All 281 tests pass (`prove -Ilib -r -j16 t/`). Nothing is pushed
upstream. The WIP that was left uncommitted at the end of the prior
session has been split into four clean commits plus a fifth for
review-response fixes.

---

## What is implemented

### Role and concrete resources (c8f395eba)

- `Test2::Harness2::Role::Resource` (`Role::Tiny`): requires
  `available` / `assign` / `release` / `status`; provides
  `is_job_limiter` / `applicable` / `resource_name`, state helpers
  (`is_broken` / `is_permanent_broken` / `is_paused` / `is_usable`,
  `mark_*` with sticky permanent), `service_methods` introspection
  (now uses `mro::get_linear_isa`), and a no-op `teardown`.
- `Test2::Harness2::Resource::JobCount` ported from `old/` to the
  keyword-arg shape. `min_slots`/`max_slots` on each `TestFile`,
  `T2_HARNESS_MY_JOB_CONCURRENCY` env injection on assign, `-1` when
  the job's `min_slots` exceeds the pool.
- `Resource::Memory` / `Resource::Disk` / `Resource::SharedJobs` are
  stubs: attribute scaffolding, `status` returns a shape compatible
  with JobCount (including `assignments => []`), runtime hooks
  `croak "not implemented yet"`.
- `Test2::Harness2::TestFile` value object (no file scanning, no
  HARNESS-* directive parsing). `TO_JSON` deep-copies nested refs.

### Run / Run::Job integration (e1c72b9a4)

- `Run::Job::test_file` is now a `TestFile` instance. Bare path
  strings auto-wrap; non-TestFile blessed refs croak.
  `test_file_abs` / `test_file_rel` shortcut the TestFile fields.
- `Run::resources` arrayref (per-run separate from harness-global).
- `Run::mark_skipped` moves pending -> done directly (no fake
  running transition for resource-declared-unsatisfiable jobs).
- `Run::from_files` accepts TestFile objects, hashrefs (rehydrated
  via `TestFile->new(%$h)`), or bare path strings. Hashref support
  fixes the IPC `queue_test_run` path that previously JSON-collapsed
  TestFile attributes to defaults on the receiving side.
- `Run::resources_started` / `Run::resources_torn_down` idempotency
  flags that the harness scheduler uses for lazy start + cleanup.

### Harness2 resource-gated scheduler (ac27474d3 + 5ab06eeaf)

- `resources` attribute on the harness; `_init_resources` fallback
  installs a `JobCount(slots => 1)` limiter if the caller didn't
  supply any job-count limiter (preserves legacy "one at a time").
- `+current` scalar is gone. `+running_jobs` is a hash keyed by
  `job_id`; multiple concurrent jobs are supported, gated by the
  resource stack.
- `_evaluate_resources_for($run, $job)` walks global + per-run
  resources and returns `('skip' | 'defer' | 'launch', \@use)`.
  `assign()` is **never** called during evaluation; only `_launch_job`
  calls it, after the walk returns `launch`. All-or-nothing commit.
- `_launch_job` wraps `Collector->spawn` in eval and releases
  already-committed assignments on failure so slots cannot leak.
- Resource-service lifecycle:
  - `_invoke_service_method` is the single call site for
    `service_*` invocation (initialization + restart).
  - Authoritatively overwrites the `restart` flag on newly-tracked
    entries from the method's return value (enforces POD contract).
    Uses a pre-call snapshot so pre-existing sibling pids aren't
    clobbered.
  - `track_resource_service` stores pid / resource / method / scope /
    run / restart / started_at / attempts. The `run` key is only
    stored when defined.
- `run_on_pid`'s resource-service branch re-invokes the `service_*`
  method for restartable resources. Spiral protection:
  - consecutive `attempts` counter
  - `MAX_RESTART_ATTEMPTS = 5` cap -> `permanent_broken` + warn
  - `RESTART_HEALTHY_SECS = 30` runtime threshold resets counter
    (one-shot per long-lived window)
  - method dies -> resource stays `broken` (operator-intervention)
  - method returns -1 -> `permanent_broken`
- Per-run lifecycle:
  - `_ensure_run_resources_started` fires lazily in
    `_try_launch_next_pending` the first time a run is considered.
  - `_teardown_run_resources` deletes tracked entries **before**
    TERM (so `run_on_pid` doesn't try to restart a service we're
    stopping), then `kill(0)`-probes and TERMs, then calls
    `teardown` on each per-run resource. Called from three sites:
    `_check_completions` (normal), `_try_launch_next_pending`
    (all-skipped), `run_on_cleanup` (leftover queued). Idempotent.
  - `run_on_cleanup`'s global-teardown loop is eval-guarded so a
    throwing `teardown` cannot skip `service_stopped`.
- `run_on_general_message` routes `resource_{paused,resumed,ready,
  broken,permanent_broken}` IPC messages through
  `_handle_resource_state_message`. Permanent is sticky across
  `resource_ready`/`resource_resumed` reanimation attempts.
- `request_handler_status` now returns `running` as an arrayref
  of `{run_id, job_id, test_file, pid, started}` hashrefs plus a
  `resources` key with each resource's `status()` output.

### Tests

- `t/unit/Harness2/Role/Resource.t` — role composition, defaults,
  state transitions (including sticky permanent), service_methods.
- `t/unit/Harness2/Resource/JobCount.t` — validation, available
  -1/0/>0 spectrum, assignment lifecycle, env injection, broken
  state, duplicate-id / unknown-release-id rejection.
- `t/unit/Harness2/TestFile.t` — defaults, abs/rel handling.
- `t/unit/Harness2/Run/Job.t` — TestFile wrapping, validation.
- `t/unit/Harness2/Run.t` — `from_files` with TestFile / hashref /
  string, `mark_skipped`, `is_complete`, state invariants.
- `t/unit/Harness2.t` — all-or-nothing commit, permanent-broken skip
  path, every resource-state message kind, restart (success /
  attempts cap / healthy-runtime reset / declined-restart / method-
  died), per-run lazy start / completion teardown / cleanup teardown
  / participate in evaluate, plus the prior session's coverage.

Total: 281 tests across 24 files.

### Process notes

- Config sync in this worktree (`.claude/settings.local.json` and
  `CLAUDE.md` symlinks) was done manually; the prior session did
  not have CLAUDE.md loaded, so style-rule compliance was
  re-established as part of the fixes in this session.
- Perltidy with `.perltidyrc` was applied to every modified file
  after edits.
- Two independent code-review dispatches were used during the
  session; the second one caught two real bugs (C1 unguarded global
  teardown, C2 restart-flag clobbering pre-existing sibling entries)
  plus a pid-reuse race window (I1) that the review-response commit
  `5ab06eeaf` addresses.

---

## What is deliberately deferred

**From `RESOURCE_IMPL_CONTEXT.md`, unchanged from prior session:**

### §3d — Skip-result events

When `_evaluate_resources_for` returns `skip`, the job is moved to
`done` with no result event. Renderer/auditor cannot show "skipped
because resource X is permanent-broken."
**Fix:** synthesize an event with a `plan => {skip => $reason}`
facet through the same JSONL logger a collector would use. Needs
knowledge of the event shape; see `old/`'s `Scheduler::advance`
calling `$self->runner->skip_job($run, $job, $env, $skip)`.

### §3e — Test retry on broken-resource failure

A test that fails while an assigned resource is broken should be
flagged for re-run.
**Fix:** snapshot the broken-flag state of each assigned resource at
job-completion time on the `running_jobs` entry so a future retry
policy can consult it.

### §3f — Memory / Disk / SharedJobs

All three still `croak "not implemented yet"` on runtime hooks.
- **Memory** (easiest): read `MemAvailable` from `/proc/meminfo`.
  Jobs declare memory need via a new TestFile attribute or a
  per-resource named argument on `available` (prefer the latter). `assign`
  should reserve a tracked counter so a burst of launches doesn't
  each see the same headroom.
- **Disk**: `Filesys::Df` on a declared mountpoint, or shell out
  to `df -Pk`. `{mount => '/tmp', need => 500_000_000}` arguments on
  `available`.
- **SharedJobs**: port `legacy/lib/Test2/Harness/Runner/Resource/
  SharedJobSlots/{.pm,Config.pm,State.pm}`. **Do not** apply the
  "harness is the only writer" simplification — SharedJobs
  coordinates across peer harness processes on the same host and
  needs the fcntl-locked state file + stale-runner GC preserved
  from legacy.

### §4 — Full scheduler

Bucketed lookup (smoke/stage/cat/dur/confl), category/duration
ordering, running-conflict map, start timeout, halt-on-bail. Resource
API should remain compatible; none of it is wired. See `old/
Scheduler.pm` and `old/Scheduler/Run.pm` for the source of truth.

---

## What is open but not blocking

These are code-review findings or things I noticed that did not make
the cut for the review-response commit. None of them are correctness
bugs today; most are ergonomics, perf, or symmetry.

### Real-fix I1 — pid-reuse race in teardown

Current code `kill(0)`-probes before TERM, which narrows but does
not close the race. The intended real fix: mark tracked entries as
`terminating` rather than `delete`-then-TERM; have `run_on_pid` drop
the entry without attempting restart when it sees the flag.

### I2 — `_perform_hard_stop` and per-run teardown asymmetry

`_perform_hard_stop` kills pids and wipes `RESOURCE_SERVICES` but
does not call `teardown` on any resources. Today the only callers
that matter (`run_on_cleanup`, `request_handler_terminate` ->
service-loop-exit -> `run_on_cleanup`) are paired with teardown.
Documented in code. For symmetry, fold resource-teardown into
`_perform_hard_stop` or assert-at-callers.

### I3 — O(N-ticks) skip drain

A run with thousands of jobs behind a permanent-broken resource
burns one event-loop tick per skip. `_try_launch_next_pending`
returns `1` after each skip so the outer `run_on_all` re-enters.
**Fix:** inner while-loop to drain consecutive skips for one run
in a single pass.

### M2 — `test_file_rel` hard dependency in status

`request_handler_status` assumes every running job has a TestFile
with `relative`. Lightweight test_file representations would break.
**Fix:** `eval { $cur->{job}->test_file_rel } // '(unknown)'`.

### M7 — Quadratic job_id lookup

`grep { $_->job_id eq $job_id } @{$run->jobs}` per pending iteration.
**Fix:** lazy `by_job_id` hash in `Run` built on first lookup.

### Orphaned zombie tracking entries

If `track_resource_service` succeeds and then the `service_*` method
dies, the tracked pid lives as a zombie tracking entry until its
process exits.
**Fix:** in `_invoke_service_method`'s `unless ($ok)` branch, drop
any entries that appeared during the call (the `%pre_existing`
snapshot is already there).

### Restart -> ready cycle uncovered end-to-end

Individual pieces (restart re-invocation, IPC `resource_ready`
handling) work, but no integration test ties them together.
**Fix:** integration test that forks a small service, messages
`resource_ready` over IPC, and verifies `is_usable` returns true.

### No IPC support for per-run resources

`Run::resources` works programmatically. The IPC
`request_handler_queue_test_run` doesn't accept resources in the
payload. Resource classes have no `from_json` / `new_from_json`.
**Fix:** when first needed, define a `from_json` on resource
classes and accept `resources => [{class => '...', ...}]` in the
handler.

### Test stubs accept surplus named arguments (I5)

`Test::Restart::Res` / `Test::RunRes::Res` inline test resources
silently absorb any named arguments the harness might add later.
**Fix:** `croak "unexpected args: @{[sort keys %p]}"` after
filtering known arguments.

### Pre-existing podchecker warning

`L</service_methods>` in `Role/Resource.pm` resolves ambiguously
between the `=head1 SERVICE METHODS` section and the
`=item @methods = $resource->service_methods`. Predates this
branch.
**Fix:** change to `L</"SERVICE METHODS">` or add a plain
`=item service_methods` alias.

### RESOURCE_IMPL_CONTEXT.md §3g is now outdated

Claims `_launch_job` passes `$job->job_id` as `id`. Actually uses a
distinct `$assign_id = gen_uuid()` stored separately on the
running-job record.
**Fix:** update §3g to note the gap is already handled; retry-in-
place concern is now §3e only.

### Pre-existing stale Collector processes

Two `Test2-Harness2-Collector` children from earlier `harness2_
start.t` runs (PIDs 3854646, 3861700; elapsed >1h when observed).
Predate this worktree session. Left alone because I didn't spawn
them.
**Fix:** `kill -9 3854646 3861700` if they're still around.

---

## Resume steps for next session

1. `cd /home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-resource-classes`
2. `git status` — expect clean tree.
3. `git log --oneline 2b098eb64..HEAD` — review the 5 commits on this
   branch.
4. `prove -Ilib -r -j16 t/` — expect 281 tests green.
5. Decide on next work item. Reasonable order:
   - §3d skip-result events (modest, isolated, valuable)
   - §3e retry snapshot (small, prereq for retry logic)
   - §3f Memory (simplest real resource; unblocks SharedJobs
     by-example)
   - §3f Disk
   - Real-fix I1 (terminating sentinel) if pid reuse starts
     showing up in CI
   - §3f SharedJobs (largest; port legacy)
   - §4 Scheduler (largest; own plan document)

If the next session is picking up this work, consider squashing
`5ab06eeaf` into `ac27474d3` before pushing upstream — the
review-response fixes are conceptually part of the feature commit,
not a separate change. I kept them split so the review context is
visible here.

---

## Design decisions worth remembering

- **All-or-nothing resource commit**: `_evaluate_resources_for`
  returns `('launch', \@use)` only when every applicable resource
  returned positive `available`. `assign` is never called during
  evaluation. This removed the need for `sort_weight` (ordering is
  observational).
- **Resource state is in-process only**: per brief, only the harness
  service mutates state. Role state flags live directly on the
  resource hash with private `_resource_*` keys. SharedJobs is the
  documented exception — it must preserve the legacy peer-safe
  locking model.
- **`service_methods` excludes itself**: introspection skip for
  `service_methods` is by name, not by coderef identity.
- **String paths auto-wrap**: `Run::Job` and `Run::from_files`
  accept bare path strings for caller convenience.
- **Restart-flag authority**: the method's return value wins. The
  `restart` argument to `track_resource_service` is advisory; the
  harness authoritatively rewrites it in `_invoke_service_method`
  based on the return code. Only newly-tracked entries are
  rewritten, using a pre-call snapshot.
- **Teardown deletes-before-signal**: `_teardown_run_resources`
  removes tracked entries before TERM so `run_on_pid` does not try
  to restart a service we're stopping. `kill(0)` probes narrow the
  pid-reuse window.
- **Restart reset is one-shot**: a service that survived
  `RESTART_HEALTHY_SECS` gets its attempts counter reset on its
  next exit. If the replacement immediately crash-loops, attempts
  climbs normally from 1 until the cap is hit.
- **Per-run resource lifecycle is lazy + idempotent**: services
  start on first evaluation of their run, not at queue time.
  Teardown is idempotent via a flag on the Run so all three call
  sites can safely invoke it.
- **Global resource teardown is eval-guarded**: in `run_on_cleanup`
  a throwing teardown on one resource cannot skip subsequent
  teardowns or the `service_stopped` emit.

---

## Worktree config inheritance

This worktree's `.claude/settings.local.json` and `CLAUDE.md` are
symlinked back to the primary repo per the Worktree Config
Inheritance protocol in `CLAUDE.md`. Do not break those symlinks;
they carry the permissions / hooks / skill allowlist / style rules.
