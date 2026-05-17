# Test2::Harness2 subsystem extraction plan

**Status:** plan only. No code changes yet.

**Triggered by:** `refactor_harness2` request + three independent analyses
(`refactor_harness2_claude.md`, `refactor_harness2_codex.md`,
`refactor_harness2_gemini.md`) + user answers in
`refactor_harness2_questions.md`. This plan extracts seven new modules plus
one shared role from `lib/Test2/Harness2.pm`, in a specific order, keeping
the harness as a thin orchestrator.

**Goal:** `lib/Test2/Harness2.pm` shrinks from 3,882 lines to ~700 lines.
The harness keeps service-role glue (`Role::Service`,
`Role::ResourceServiceHost`), identity/config, event-loop orchestration,
direct collector-launch glue, and thin request-handler shims. Seven new
objects own discrete state clusters; one shared role provides the harness
backref pattern.

**Non-goals:** no behavior change. No API change at the IPC boundary.
No test rewrites except adding new unit coverage for the new modules.

---

## Architectural rules

These rules apply to every extraction. Violating them defeats the point.

### R1. Subsystems are plain HashBase objects, not services.

```perl
package Test2::Harness2::PidIndex;
use Object::HashBase qw{
    +run_pids
    +harness
};
use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';
```

No `Role::Service`, no `Role::ResourceService`, no IPC peer registration.
Subsystems exist as in-process collaborators of the harness.

### R2. Every subsystem consumes `Test2::Harness2::Role::Subsystem`.

The role provides the harness backref slot, an `init` hook that weakens
the backref, and a `harness` accessor.

```perl
package Test2::Harness2::Role::Subsystem;
use Role::Tiny;
use Scalar::Util qw/weaken/;

# Consumer must declare a +harness HashBase slot.
# Role wraps init to weaken it if present.

around init => sub {
    my ($orig, $self, @args) = @_;
    $self->$orig(@args);
    if ($self->{$self->HARNESS}) {
        weaken($self->{$self->HARNESS});
    }
};

sub harness { $_[0]->{$_[0]->HARNESS} }

1;
```

`harness` is OPTIONAL — pure data modules (RunStates) may not pass it.
When present, weakening is automatic.

If a subsystem method dereferences `$self->harness` after the harness has
gone away (deferred timer, etc.), it gets `undef` and MUST handle that:

```perl
sub tick {
    my $self = shift;
    my $h = $self->harness or return;
    # ...
}
```

### R3. Slot-write discipline.

After an extraction lands, the moved slot must NOT appear in
`lib/Test2/Harness2.pm`. If `grep '+QUEUE\b' lib/Test2/Harness2.pm`
finds anything after the Scheduler extraction, that's a bug.

### R4. Cross-domain reads go through objects, not the harness.

This is the user-requested model (Q1, Q2): state objects (RunStates,
JobTracker, PidIndex) are first-class. Anything that needs the state holds
a direct reference. The harness does not gatekeep.

Construction order: harness creates RunStates first, then passes it into
every subsystem ctor that needs to read run-state. Same for JobTracker,
PidIndex. Subsystems then hold strong refs to these state objects —
state objects do not back-ref subsystems, so no cycle.

```perl
sub init {
    my $self = shift;
    # ... defaults / validation ...

    $self->{+RUN_STATES} = Test2::Harness2::RunStates->new();
    $self->{+JOB_TRACKER} = Test2::Harness2::JobTracker->new(
        harness => $self,
    );
    $self->{+PID_INDEX} = Test2::Harness2::PidIndex->new();
    # ...
    $self->{+SCHEDULER} = Test2::Harness2::Scheduler->new(
        harness     => $self,
        run_states  => $self->{+RUN_STATES},
        pid_index   => $self->{+PID_INDEX},
        job_tracker => $self->{+JOB_TRACKER},
    );
    # ...
}
```

Refs to state objects are strong on the consumer side; only the harness
backref is weakened (Role::Subsystem handles that automatically).

### R5. Launch glue stays on the harness.

`_launch_job`, `_spawn_collector_for_job`, `_launch_collector_inline`,
`_build_launch_env`, `_announce_run_started_if_first`,
`_ensure_run_service_started`, `_teardown_run_service`, `_write_run_spec`,
`_write_run_report`. These bake harness identity (IPC info, harness pid,
parent pids, kill timeout, auditor, logdir, name, env) into the spawn.
Moving them off the harness either drags identity slots out (bad) or
forces seven-argument calls (bad). They stay.

The Scheduler returns decisions (which job, which preload binding).
The harness executes the launch via `$self->harness->_launch_job(...)`.

### R6. Per-tick orchestration stays in `run_on_interval`.

```perl
sub run_on_interval {
    my $self = shift;
    $self->scheduler->try_launch_next;
    $self->preload_router->tick;
    $self->spawn_gateway->poll;
    $self->broadcaster->drain_retries;
    $self->job_tracker->check_synth_completions;
}
```

Order matters. The harness owns the order.

### R7. Function-length limit (ARCHITECTURE.md §25) still applies.

Every method in every new module must be ≤75 lines of executable Perl.
`perl author/find-long-subs` is the tripwire. Run it after every
extraction commit. Exit 0 is a hard requirement.

### R8. Each extraction is one commit. Tag between them.

Tags: `refactor-harness2-baseline` (before anything),
`refactor-harness2-role-subsystem`,
`refactor-harness2-pidindex`,
`refactor-harness2-spawngateway`,
`refactor-harness2-broadcaster`,
`refactor-harness2-runstates`,
`refactor-harness2-scheduler`,
`refactor-harness2-jobtracker`,
`refactor-harness2-preloadrouter`.

### R9. Full test suite must be green between extractions.

`AUTHOR_TESTING=1 prove -j16 -Ilib -It/lib -r t/` must pass. Known
SQLite-WAL flakes under `-j16` are allowed if they pass on rerun;
persistent failures are NOT.

If a regression appears mid-extraction, revert the in-progress commit and
re-plan that specific module's slice. Never paper over a failure to
move forward.

---

## Decisions (from `refactor_harness2_questions.md`)

| # | Decision | Source |
|---|---|---|
| D1 | `emitter` stays on harness. | Codex |
| D2 | `broken_resource_behavior` + `BROKEN_BEHAVIORS` move with Scheduler. | Codex |
| D3 | `RUN_STATES` + `RUN_FLAGS` + `COMPLETED_RUNS` + `RUN_ORD_COUNTER` extract to standalone `Test2::Harness2::RunStates`. Harness, Scheduler, JobTracker, broadcaster all hold direct refs. **(User: Q1 → C variant.)** | User |
| D4 | Sixth extraction is `Test2::Harness2::JobTracker` (RUNNING_JOBS + test_job_* + collector_* + job_release + synth-completions). **(User: Q2 → B.)** | User |
| D5 | Module names: `PidIndex`, `SpawnGateway`, `StateBroadcaster`, `RunStates`, `Scheduler`, `JobTracker`, `PreloadRouter`. **(User: Q3 confirmed.)** | User |
| D6 | Request handlers stay as thin shims on the harness. **(User: Q4 → A.)** | User |
| D7 | `_handle_resource_state_message` stays on harness; add followup to re-evaluate after refactor. **(User: Q5 → A + followup.)** | User |
| D8 | Only `RUN_PIDS` moves into PidIndex; `RESOURCE_SERVICES` stays on the harness for `Role::ResourceServiceHost`. **(User: Q6 → A.)** | User |
| D9 | Create `Test2::Harness2::Role::Subsystem`. Every subsystem consumes it. Role provides weakened harness backref + accessor. **(User: Q7 → A + new role.)** | User |
| D10 | Execution order: see "Execution order" below. **(User: Q8 → my call.)** | Claude |

---

## Module catalog

### State objects (no behavior beyond accessors)

| Module | Slots owned | Notes |
|---|---|---|
| `Test2::Harness2::RunStates` | `RUN_STATES`, `RUN_FLAGS`, `COMPLETED_RUNS`, `RUN_ORD_COUNTER` | Pure data. No harness backref. Multiple consumers. |
| `Test2::Harness2::PidIndex` | `RUN_PIDS` | Pure data + `kill_run`/`await_run_exit` helpers. |

### Behavior subsystems (consume `Role::Subsystem`)

| Module | Owns | Reads | Notes |
|---|---|---|---|
| `Test2::Harness2::SpawnGateway` | `PENDING_SCRIPT_SPAWNS`, `_SCRIPT_SPAWN_COUNTER`, `_SCRIPT_SPAWN_EXITS` | preload_router (for peer lookup), pid_index | `yath spawn` SCM_RIGHTS pathway. |
| `Test2::Harness2::StateBroadcaster` | `SUBSCRIBERS`, `SUBSCRIBER_RETRY` | run_states, job_tracker | IPC fanout to subscribed peers. |
| `Test2::Harness2::Scheduler` | `QUEUE`, `SCHEDULER`, `IN_FLIGHT_COUNT`, `BROKEN_RESOURCE_BEHAVIOR` | run_states, pid_index, job_tracker | Owns decision logic; harness owns launch glue. |
| `Test2::Harness2::JobTracker` | `RUNNING_JOBS`, `PENDING_SYNTH_COMPLETIONS` | run_states, pid_index, scheduler | Owns test_job_* + collector_* lifecycle. |
| `Test2::Harness2::PreloadRouter` | `PENDING_SPAWN_REQUESTS`, `PENDING_PRELOAD_SPAWNS`, `RESOURCES_AWAITING_PRELOAD`, `KNOWN_PRELOAD_NAMES`, `PRELOAD_SPAWN_TIMEOUT_SECS`, `PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS` | run_states, pid_index, scheduler, harness (for launch glue) | Async preload-spawn watchdogs + fallback queues. |

### Shared role

| Role | Purpose |
|---|---|
| `Test2::Harness2::Role::Subsystem` | Provides `harness` accessor + weaken-on-init hook. Consumed by every subsystem that takes a harness backref. (RunStates and PidIndex don't need it; consume for uniformity only if desired.) |

---

## Execution order

1. **`Test2::Harness2::Role::Subsystem`** — foundational. Lands first because every subsequent extraction consumes it.
2. **`Test2::Harness2::PidIndex`** — smallest, mechanical, exercises the role.
3. **`Test2::Harness2::SpawnGateway`** — small, isolated, exercises request-handler shim pattern.
4. **`Test2::Harness2::StateBroadcaster`** — first extraction with non-trivial cross-domain reads.
5. **`Test2::Harness2::RunStates`** — foundational state object. Must land before Scheduler + JobTracker.
6. **`Test2::Harness2::Scheduler`** — biggest payoff. Consumes RunStates + PidIndex.
7. **`Test2::Harness2::JobTracker`** — consumes RunStates + PidIndex + Scheduler accessors.
8. **`Test2::Harness2::PreloadRouter`** — most cross-cutting. Done last so it can call into Scheduler/JobTracker accessors from day one.

Eight commits, eight tags, full suite green between each.

---

## Per-extraction plan

### Extraction 1: `Test2::Harness2::Role::Subsystem`

**Why first:** every later extraction consumes this. Landing alone gives the
five-line role its own commit so the diff is reviewable.

**File:** `lib/Test2/Harness2/Role/Subsystem.pm`

**Content:** the role shown in R2 above.

**Tests:** `t/AI/unit/Harness2/Role/Subsystem.t` — construct a synthetic
consumer, assert harness is weakened, assert accessor works, assert no-op
when no harness passed.

**Verification:**
- `perl -Ilib -c lib/Test2/Harness2/Role/Subsystem.pm`
- `perl author/find-long-subs lib/Test2/Harness2/Role/Subsystem.pm` (exit 0)
- Full suite green (no consumers yet; should be a no-op for the harness)
- Tag `refactor-harness2-role-subsystem`

**Size:** ~50 lines including POD.

---

### Extraction 2: `Test2::Harness2::PidIndex`

**Why second:** smallest cohesive cluster. Mechanical move. First real
consumer of `Role::Subsystem`.

**File:** `lib/Test2/Harness2/PidIndex.pm`

**Slots moved:** `RUN_PIDS` only (D8).

**Methods moved:**
- `_register_run_pid` → `register($run_id, $pid)`
- `_forget_run_pid` → `forget($run_id, $pid)`
- `_run_for_pid` → `run_for_pid($pid)`
- `_pids_for_run` → `pids_for_run($run_id)`
- `_kill_run` → `kill_run($run_id, $signal)`
- `_await_run_exit` → `await_run_exit($run_id, $deadline)`
- `_resource_service_tracked` → `resource_service_tracked($pid, $entry)` (touches RUN_PIDS only; RESOURCE_SERVICES stays on harness)
- `_resource_service_forgotten` → `resource_service_forgotten($pid)`

**Harness changes:**
- New slot `+pid_index`.
- `init` constructs `PidIndex->new(harness => $self)`.
- Strip `+run_pids` from HashBase.
- Rewrite every `$self->_register_run_pid(...)` → `$self->pid_index->register(...)` etc.

**Backref need:** optional. PidIndex's logic doesn't currently need the harness, but takes it for uniformity.

**New tests:** `t/AI/unit/Harness2/PidIndex.t`

**Verification:**
- `perl author/find-long-subs lib/Test2/Harness2/PidIndex.pm` (exit 0)
- `grep '+RUN_PIDS\b' lib/Test2/Harness2.pm` returns nothing
- Full suite green
- Tag `refactor-harness2-pidindex`

**Size:** ~150 lines including POD.

---

### Extraction 3: `Test2::Harness2::SpawnGateway`

**Why third:** small, isolated, exercises the request-handler shim pattern.

**File:** `lib/Test2/Harness2/SpawnGateway.pm`

**Slots moved:** `PENDING_SCRIPT_SPAWNS`, `_SCRIPT_SPAWN_COUNTER`, `_SCRIPT_SPAWN_EXITS`

**Methods moved:**
- `request_handler_spawn_script` stays on harness as a 2-line shim → `$self->spawn_gateway->handle_request(@_)`.
- `_handle_script_spawn_exit` → `handle_pid_exit($pid, $exit)` (returns true when pid mapped to a known script spawn; harness's `run_on_pid` uses that to short-circuit).
- `_handle_script_spawned` → `handle_spawned($msg)`
- `_dispatch_script_exited` → `dispatch_exited($sid, $entry, $exit)`
- `_poll_script_exits` → `poll`
- `_assert_fdpass_transport` → `assert_fdpass_transport`

**Harness changes:**
- New slot `+spawn_gateway`.
- `run_on_pid` calls `return if $self->spawn_gateway->handle_pid_exit($pid, $exit);` (race-case semantics preserved: stash speculatively + report not-handled so resource-service handler still runs).
- `run_on_interval` adds `$self->spawn_gateway->poll;`
- `request_handler_spawn_script` becomes shim.

**Backref need:** required (needs harness client + name + ipcm_info + interim access to `_find_eligible_preload_service`).

**Cross-domain reads:** Interim direct call to `$h->_find_eligible_preload_service(...)`. Swap to `$h->preload_router->find_eligible(...)` in extraction 8.

**New tests:** `t/AI/unit/Harness2/SpawnGateway.t`

**Verification:** existing `t/AI/unit/Harness2/spawn_script_dispatch.t`, `t/AI/unit/Harness2/script_spawned_handler.t` still pass. Tag `refactor-harness2-spawngateway`.

**Size:** ~250 lines including POD.

---

### Extraction 4: `Test2::Harness2::StateBroadcaster`

**Why fourth:** first extraction with non-trivial cross-cutting reads. If
discipline breaks here, stop before touching state-heavy extractions.

**File:** `lib/Test2/Harness2/StateBroadcaster.pm`

**Slots moved:** `SUBSCRIBERS`, `SUBSCRIBER_RETRY`. **NOT moved:** `EMITTER` (D1).

**Methods moved:**
- `request_handler_subscribe` → shim → `subscribe($peer, %opts)`
- `request_handler_unsubscribe` → shim → `unsubscribe($peer)`
- `_notify_state_subscribers` → `notify_state($delta)`
- `_send_state_snapshot` → `send_snapshot($peer)`
- `_send_to_subscriber` → `send($peer, $msg)`
- `_drain_subscriber_retries` → `drain_retries`
- `_broadcast_run_state` → `broadcast_run_state($run_id, $delta)`
- `SUBSCRIBER_RETRY_CAP` constant moves alongside.

**Harness changes:**
- New slot `+broadcaster`.
- `run_on_interval` adds `$self->broadcaster->drain_retries;`
- `run_on_peer_delta` calls `$self->broadcaster->forget_peer($peer)`.

**Backref need:** required (reads run_states + running_jobs via interim
harness accessors; uses harness IPC client to send). In extraction 5
(RunStates) and 7 (JobTracker), the broadcaster's direct accesses get
swapped for direct refs to those state objects.

**Cross-domain reads:** interim reads via the harness; swapped to direct
refs after RunStates + JobTracker land.

**New tests:** `t/AI/unit/Harness2/StateBroadcaster.t`

**Verification:** full suite green + tag.

**Size:** ~320 lines including POD.

---

### Extraction 5: `Test2::Harness2::RunStates`

**Why fifth:** foundational state object. Must land before Scheduler +
JobTracker because both hold direct refs to it.

**File:** `lib/Test2/Harness2/RunStates.pm`

**Slots moved:** `RUN_STATES`, `RUN_FLAGS`, `COMPLETED_RUNS`, `RUN_ORD_COUNTER`

**Methods moved:**
- `_run_flags` → `flags($run_id)`
- (most existing access is via raw slot deref; promote to explicit accessors here)

**New methods:**
- `state($run_id)` — return run state hashref
- `flags($run_id)` — return run flags hashref (lazy-initialized)
- `record_completed($run_id, $result)` — add to COMPLETED_RUNS
- `completed($run_id)` — lookup in COMPLETED_RUNS
- `next_run_ord` — atomic increment of RUN_ORD_COUNTER
- `all_run_ids` — keys of RUN_STATES
- `register_run($run_id, $state)` — adds a run
- `drop_run($run_id)` — removes a run + its flags
- (additional narrow accessors as call sites demand)

**Harness changes:**
- New slot `+run_states`.
- `init` constructs `RunStates->new()`.
- Strip the four moved slots from HashBase.
- Replace every direct slot access (`$self->{+RUN_STATES}->{$rid}` etc.) with the appropriate accessor call. There are 17+ such sites; this is the bulk of the diff.
- Pass `run_states => $self->{+RUN_STATES}` into StateBroadcaster (rewire its interim harness-mediated reads).

**Backref need:** NONE (pure data object; not a `Role::Subsystem` consumer).

**Cross-domain reads:** RunStates does not read anything; it is read by everyone.

**New tests:** `t/AI/unit/Harness2/RunStates.t` — round-trip per accessor, lazy flag init, ord counter atomicity.

**Verification:** the broadcaster's snapshot path now reads via the direct
RunStates ref instead of harness; verify subscribe-then-receive still works
end-to-end. Tag.

**Size:** ~250 lines including POD.

---

### Extraction 6: `Test2::Harness2::Scheduler`

**Why sixth:** consumes RunStates + PidIndex. Biggest single payoff.

**File:** `lib/Test2/Harness2/Scheduler.pm`

**Slots moved:** `QUEUE`, `SCHEDULER`, `IN_FLIGHT_COUNT`, `BROKEN_RESOURCE_BEHAVIOR`

**Constants moved:** `BROKEN_BEHAVIORS`

**Methods moved:**
- All `_scheduler_*` → un-prefixed scheduler methods (`queue_run`, `mark_running`, `mark_pending`, `mark_done`, `skip`, `drop_run`, `run_complete`, `pending_for_run`, `is_running`, `started`).
- `_try_launch_next_pending` → `try_launch_next` (calls `$self->harness->_launch_job` for the actual launch)
- `_dispatch_pending_job` → `dispatch_pending($run, $job, ...)`
- `_evaluate_resources_for` → `evaluate_resources($run, $job, $resources)`
- `_handle_broken_resource` → `handle_broken_resource($run, $job)`
- `_launch_unavailable_action_job` → `launch_unavailable_action(...)`
- `_finalize_run_if_complete` → `finalize_run_if_complete($run_id)`
- `run_on_all` (Role::Service tick) stays on harness as shim → `$self->scheduler->try_launch_next;`

**Construction:**
```perl
$self->{+SCHEDULER} = Test2::Harness2::Scheduler->new(
    harness     => $self,
    run_states  => $self->{+RUN_STATES},
    pid_index   => $self->{+PID_INDEX},
    broken_resource_behavior => $self->{+BROKEN_RESOURCE_BEHAVIOR},
);
```

**Harness changes:**
- New slot `+scheduler`.
- Strip QUEUE / SCHEDULER / IN_FLIGHT_COUNT / BROKEN_RESOURCE_BEHAVIOR from HashBase.
- `request_handler_run_results` reads from `$self->scheduler->snapshot($run_id)` (or `$self->run_states->state($run_id)` for the pure state read).

**Backref need:** required. Scheduler calls launch glue: `$self->harness->_launch_job(...)`, `$self->harness->_spawn_collector_for_job(...)`.

**Behavior preservation traps:**
- `_handle_broken_resource` + `_launch_unavailable_action_job` mutate run-state via narrow paths; preserve order.
- `_finalize_run_if_complete` depends on `IN_FLIGHT_COUNT` decrement-before-check ordering. Preserve.
- BROKEN_BEHAVIORS validation moves to Scheduler's `init`.

**New tests:** `t/AI/unit/Harness2/Scheduler.t`

**Verification:** tag `refactor-harness2-scheduler`.

**Size:** ~550 lines including POD.

---

### Extraction 7: `Test2::Harness2::JobTracker`

**Why seventh:** depends on RunStates + Scheduler accessors. Cleanest after
those are in.

**File:** `lib/Test2/Harness2/JobTracker.pm`

**Slots moved:** `RUNNING_JOBS`, `PENDING_SYNTH_COMPLETIONS`

**Methods moved:**
- `_handle_collector_start` → `handle_collector_start($msg)`
- `_handle_collector_end` → `handle_collector_end($msg)`
- `_handle_test_job_started` → `handle_test_job_started($msg)`
- `_handle_test_job_diagnosing` → `handle_test_job_diagnosing($msg)`
- `_handle_test_job_failing` → `handle_test_job_failing($msg)`
- `_handle_test_job_completed` → `handle_test_job_completed($msg)`
- `_emit_run_completed` → `emit_run_completed($run_id)`
- `_build_collector_report` → `build_collector_report($job_id)`
- `_snapshot_run_results` → `snapshot_run_results($run_id)`
- `_handle_job_release` → `handle_job_release($msg)`
- `_release_job_resources` → `release_job_resources($job_id)`
- `_synth_release_orphan_job` → `synth_release_orphan_job($job_id)`
- `_handle_test_collector_exit` → `handle_collector_exit($pid, $exit)` (returns true when handled; harness `run_on_pid` uses to short-circuit)
- `check_synth_completions` — new entry point that contains the synth-completion watchdog code currently inside `run_on_interval`.

**Construction:**
```perl
$self->{+JOB_TRACKER} = Test2::Harness2::JobTracker->new(
    harness    => $self,
    run_states => $self->{+RUN_STATES},
    pid_index  => $self->{+PID_INDEX},
    scheduler  => $self->{+SCHEDULER},
);
```

**Harness changes:**
- New slot `+job_tracker`.
- Strip `+running_jobs` + `+pending_synth_completions` from HashBase.
- `run_on_pid` calls `return if $self->job_tracker->handle_collector_exit($pid, $exit);`
- `run_on_interval` calls `$self->job_tracker->check_synth_completions;`
- `run_on_general_message` routes test_job_* / collector_* messages to job_tracker.
- `request_handler_status` and `request_handler_run_results` read via job_tracker accessors where they previously read RUNNING_JOBS.
- Broadcaster's interim harness-mediated `running_jobs` reads swap to direct ref to job_tracker.

**Backref need:** required (needs scheduler for run_complete signals, needs harness for launch glue when triggering retries).

**Behavior preservation traps:**
- Synth-completion grace window logic is timing-sensitive. Preserve exactly.
- `_handle_test_job_completed` triggers `_emit_run_completed` which broadcasts; broadcaster ref must be set up before job_tracker is constructed, OR job_tracker is given a deferred-emit callback. **Decision:** harness constructs broadcaster first, then job_tracker, and passes `broadcaster => $self->{+BROADCASTER}` into job_tracker's ctor.

**New tests:** `t/AI/unit/Harness2/JobTracker.t`

**Verification:** tag `refactor-harness2-jobtracker`.

**Size:** ~600 lines including POD.

---

### Extraction 8: `Test2::Harness2::PreloadRouter`

**Why last:** most cross-cutting. Calls into Scheduler + JobTracker + PidIndex; by now all accessors exist.

**File:** `lib/Test2/Harness2/PreloadRouter.pm`

**Slots moved:**
- `PENDING_SPAWN_REQUESTS`, `PENDING_PRELOAD_SPAWNS`,
  `RESOURCES_AWAITING_PRELOAD`, `KNOWN_PRELOAD_NAMES`,
  `PRELOAD_SPAWN_TIMEOUT_SECS`, `PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS`

**Methods moved:**
- `_resolve_preload_for_job` → `resolve_for_job($run, $job)`
- `_index_preloads_for_run` → `_index_for_run($run)` (private)
- `_classify_preload_state` → `_classify_state($preload)` (private)
- `_find_eligible_preload_service` → `find_eligible($resource, $scope)`
- `_spawn_via_preload` → `spawn_via_preload($run, $job, $preload, %opts)`
- `_spawn_service_via_preload` → `spawn_service_via_preload($resource, $host_scope)`
- `_register_pending_preload_spawn` → `_register_pending(...)`
- `_build_spawn_test_payload` → `_build_spawn_test_payload(...)`
- `_age_pending_spawn_requests` → folded into `tick`
- `_check_pending_preload_spawn_timeouts` → folded into `tick`
- `_preload_peer_name` → `peer_name_for_preload($preload)`
- `_resource_peer_name` → `peer_name_for_resource($resource)`
- `_drain_resources_awaiting_preload` → `drain_awaiting`
- `_fallback_resources_awaiting_preload` → `_fallback_awaiting`
- `_fallback_single_entry` → `_fallback_entry`
- `_handle_resource_service_started` → `handle_service_started($msg)`
- `_handle_preload_state_message` → `handle_preload_state($msg)`
- `request_handler_list_preloads` stays on harness as shim → `$self->preload_router->list`

**Construction:**
```perl
$self->{+PRELOAD_ROUTER} = Test2::Harness2::PreloadRouter->new(
    harness     => $self,
    run_states  => $self->{+RUN_STATES},
    pid_index   => $self->{+PID_INDEX},
    scheduler   => $self->{+SCHEDULER},
    job_tracker => $self->{+JOB_TRACKER},
);
```

**Harness changes:**
- New slot `+preload_router`.
- `run_on_interval` adds `$self->preload_router->tick;`
- `run_on_general_message` routes preload-state + resource-service-started messages.
- SpawnGateway's interim `$h->_find_eligible_preload_service(...)` (extraction 3) swaps to `$self->preload_router->find_eligible(...)`.

**Backref need:** required (calls launch glue for preload-mediated spawns; calls harness IPC client).

**Behavior preservation traps:**
- Watchdog ordering: `_age_pending_spawn_requests` and `_check_pending_preload_spawn_timeouts` run in a specific order today. Folded into `tick`; preserve order.
- `_drain_resources_awaiting_preload` interacts with `Role::ResourceServiceHost` startup ordering. Preserve.

**New tests:** `t/AI/unit/Harness2/PreloadRouter.t`. Existing preload-related unit + integration tests must still pass with shim updates.

**Verification:** full suite green + tag `refactor-harness2-preloadrouter`.

**Size:** ~550 lines including POD.

---

## Final shape of `lib/Test2/Harness2.pm`

**Slots retained:**
- Identity/config: `workdir`, `logdir`, `name`, `ipc_parent`, `job_id`, `test_auditor`, `kill_timeout`, `parent_pids`, `jump_to`, `resources`, `hash_seed`, `collector_grace_secs`, `watch_pids`, `own_pgroup`
- Subsystem refs (new): `pid_index`, `spawn_gateway`, `broadcaster`, `run_states`, `scheduler`, `job_tracker`, `preload_router`
- Role-required: `resource_services`, `emitter`
- Other: `state`, `finish_after_initial_run`

**Methods retained:**
- Lifecycle: `init`, `start`, `spawn`, `service_on_start`, `run_on_cleanup`, `run_should_end`, `TO_JSON`
- Service-host role glue: `service_host_*`, `become_sub_reaper`, `service_pre_hard_stop`, `service_post_hard_stop`, `hard_stop_pids`, `emit_service_event`, `ipcm_info`
- Request handlers (thin shims): `request_handler_queue_test_run`, `request_handler_status`, `request_handler_list_preloads`, `request_handler_abort_run`, `request_handler_finish`, `request_handler_has_pending_messages`, `request_handler_run_results`, `request_handler_detach`, `request_handler_subscribe`, `request_handler_unsubscribe`, `request_handler_spawn_script`
- Run rehydration: `_validate_run_hash_seed`, `_rehydrate_run_resources`
- Run-service glue: `_ensure_run_service_started`, `_teardown_run_service`, `_write_run_spec`, `_write_run_report`
- Launch glue: `_launch_job`, `_announce_run_started_if_first`, `_build_launch_env`, `_launch_collector_inline`, `_spawn_collector_for_job`
- Tick orchestration: `run_on_pid`, `run_on_interval`, `run_on_all`, `run_on_general_message`, `run_on_peer_delta`
- `_handle_resource_state_message` (D7 — to re-evaluate later)

**Estimated final size:** ~700 lines (from 3,882).

---

## Followups for after the refactor lands

1. **Re-evaluate `_handle_resource_state_message`** ownership (D7). Possibly extract a `ResourceMonitor` module if patterns emerge.
2. **Re-evaluate `RESOURCE_SERVICES` ownership** (D8). If `Role::ResourceServiceHost` is refactored, move slot into PidIndex.
3. **Audit Role::Service for dispatch-table support** (Q4 → B path). If supported, drop request_handler shims into subsystems directly.
4. **Verify final `lib/Test2/Harness2.pm` size** matches the ~700-line estimate. If significantly larger, audit residual subs for further extraction candidates.

---

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Behavior drift mid-extraction | Full suite green between each commit. Tag each step. |
| Backref cycle leak | `Role::Subsystem` weakens automatically; consumers MUST declare `+harness` slot for the hook to fire. |
| Late-tick null harness | Subsystem methods check `$h or return` after `$self->harness` deref. |
| Hidden cross-domain read added accidentally | Post-extraction grep: `grep '+SLOT\b' lib/Test2/Harness2.pm` must return nothing for moved slots. |
| Long sub introduced during extraction | `perl author/find-long-subs` is the gate. Run after every commit. |
| SQLite WAL flakes under -j16 | Documented previously. Allow on rerun; investigate only if persistent. |
| Per-tick order changes silently | `run_on_interval` is the only orchestration point; review the sequence in every commit's diff. |
| Lost POD coverage | Per-method POD must be added with each new helper. |
| State-object access leaks pre-refactor patterns | After RunStates lands, `grep '+RUN_STATES\b' lib/Test2/Harness2.pm` must return nothing. |

---

## Rollback plan

Each extraction is one commit, tagged. Rolling back any single extraction:

```
git revert <commit>
git tag -d refactor-harness2-<step>
```

For deeper rollback, reset to a tag:

```
git reset --hard refactor-harness2-baseline    # nuclear: undo everything
git reset --hard refactor-harness2-scheduler   # rewind to last good step
```

Baseline tag goes on at the start of the work, before extraction 1.

---

## Out of scope

- `Test2::Harness2::PreloadService` refactor (separate concern)
- `Test2::Harness2::Collector` refactor (already touched in the recent long-sub pass)
- `Test2::Harness2::Role::ResourceServiceHost` refactor (separate effort)
- IPC protocol changes (none)
- DB layer (none)
- ARCHITECTURE.md §16 module-map update (will happen as part of each extraction commit, not separately)
