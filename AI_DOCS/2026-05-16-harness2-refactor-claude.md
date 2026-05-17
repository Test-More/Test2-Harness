# Test2::Harness2 refactor: subsystem extraction proposal

**Goal:** split `lib/Test2/Harness2.pm` (3,882 lines, 114 subs, ~30 HashBase slots) into a thin orchestrator plus a handful of focused subsystem objects that the harness loads, initializes, and calls. Subsystems are plain objects, not services.

This document is analysis only. No code changes have been made.

---

## Why split at all

Three concrete pains:

1. **State sprawl.** Roughly 30 HashBase slots, half of which only matter to a narrow region of the file. Reading any one method requires understanding which slots are read vs. mutated vs. left alone; the surface area is too large for that to be cheap.
2. **Method density.** 114 subs in one file. Almost every change touches a region that someone else also has to understand to reason about correctness. There is no natural "I only need to read this part" boundary today.
3. **Coupling-by-proximity.** Because everything is co-located on `$self`, helpers reach into unrelated state ad hoc. Concretely: the scheduler peeks at the resource service registry; the preload router peeks at `RUN_STATES`; the script-spawn pathway peeks at `RUN_PIDS`. Those coupling points should be deliberate accessor calls, not direct hash dereferences across concerns.

The proposed split does not change behavior — it makes the coupling visible.

---

## Inventory

### HashBase slots, by ownership cluster

The slots already cluster by concern. Most slots are written by ≤3 methods and read by ≤5. The clustering below is derived from `grep -nE '\+SLOT\\b' lib/Test2/Harness2.pm` and reading the touching sites.

**Identity / config (immutable after `init`)** — stays on `Harness2` itself.
- `workdir`, `logdir`, `name`, `ipc_parent`, `job_id`, `test_auditor`, `kill_timeout`, `parent_pids`, `jump_to`, `resources`, `broken_resource_behavior`, `hash_seed`, `collector_grace_secs`, `preload_spawn_timeout_secs`, `preload_service_spawn_timeout_secs`, `watch_pids`, `own_pgroup`

**Lifecycle** — stays on `Harness2`.
- `state`, `finish_after_initial_run`

**Scheduler cluster** — extractable.
- `queue` (17 refs), `scheduler` (11), `run_states` (17), `run_flags` (8), `completed_runs` (6), `run_ord_counter` (2), `in_flight_count` (6)

**Preload-router cluster** — extractable.
- `pending_spawn_requests` (5), `pending_preload_spawns` (5), `resources_awaiting_preload` (3), `known_preload_names` (1)

**Spawn-gateway cluster** (the `yath spawn` SCM_RIGHTS pathway) — extractable.
- `pending_script_spawns` (7), `_script_spawn_counter` (2), `_script_spawn_exits` (3)

**State-broadcaster cluster** — extractable.
- `emitter` (5), `subscribers` (9), `subscriber_retry` (8)

**Pid-index cluster** — extractable.
- `run_pids` (8), `resource_services` (8)

**Job-tracker cluster** — *not* recommended for immediate extraction (see "What I would NOT split yet" below).
- `running_jobs` (18), `pending_synth_completions` (3), shares `run_flags` with the scheduler

### Sub families, by extraction target

Names in this list are exactly those defined in `lib/Test2/Harness2.pm`. Count after each cluster is "subs that would move, % of total file body".

**Scheduler** (~15 subs, ~25% of body)
```
_scheduler_queue_run
_scheduler_pending_for_run
_scheduler_is_running
_scheduler_started
_scheduler_mark_running
_scheduler_mark_pending
_scheduler_mark_done
_scheduler_skip
_scheduler_drop_run
_scheduler_run_complete
_try_launch_next_pending
_dispatch_pending_job
_evaluate_resources_for
_handle_broken_resource
_launch_unavailable_action_job
_finalize_run_if_complete
```

**PreloadRouter** (~17 subs, ~17% of body)
```
_resolve_preload_for_job
_index_preloads_for_run
_classify_preload_state
_find_eligible_preload_service
_spawn_via_preload
_spawn_service_via_preload
_register_pending_preload_spawn
_build_spawn_test_payload
_age_pending_spawn_requests
_check_pending_preload_spawn_timeouts
_preload_peer_name
_resource_peer_name
_drain_resources_awaiting_preload
_fallback_resources_awaiting_preload
_fallback_single_entry
_handle_resource_service_started
_handle_preload_state_message
```

**SpawnGateway** (~6 subs, ~7% of body)
```
request_handler_spawn_script
_handle_script_spawn_exit
_handle_script_spawned
_dispatch_script_exited
_poll_script_exits
_assert_fdpass_transport
```

**StateBroadcaster** (~7 subs, ~8% of body)
```
request_handler_subscribe
request_handler_unsubscribe
_notify_state_subscribers
_send_state_snapshot
_send_to_subscriber
_drain_subscriber_retries
_broadcast_run_state
```

**PidIndex** (~8 subs, ~4% of body)
```
_register_run_pid
_forget_run_pid
_run_for_pid
_pids_for_run
_kill_run
_await_run_exit
_resource_service_tracked
_resource_service_forgotten
```

What remains on `Harness2` after these five extractions:

```
init, _init_logdir, _init_default_slots, _strip_legacy_logger_slots,
_init_resources, _install_in_flight_ref
start, spawn, service_on_start, run_on_cleanup, run_should_end,
emit_service_event, TO_JSON, service_pre_hard_stop, service_post_hard_stop,
hard_stop_pids, become_sub_reaper, service_host_scope, service_host_run,
service_host_logdir, ipcm_info
request_handler_queue_test_run, request_handler_status,
request_handler_list_preloads, request_handler_abort_run,
request_handler_finish, request_handler_has_pending_messages,
request_handler_run_results, request_handler_detach
_validate_run_hash_seed, _rehydrate_run_resources
_ensure_run_service_started, _teardown_run_service
_write_run_spec, _write_run_report
_launch_job, _announce_run_started_if_first, _build_launch_env,
_launch_collector_inline, _spawn_collector_for_job
_handle_collector_start, _handle_collector_end, _run_flags
_handle_test_job_started, _handle_test_job_diagnosing,
_handle_test_job_failing, _handle_test_job_completed
_emit_run_completed, _build_collector_report, _snapshot_run_results
_handle_job_release, _release_job_resources, _synth_release_orphan_job
_handle_test_collector_exit
run_on_general_message, run_on_peer_delta, run_on_pid, run_on_interval,
run_on_all
_handle_resource_state_message
```

Estimated remaining size: ~1.2-1.4k lines (down from 3.8k).

---

## Recommended extractions

Five modules. Justification for each below.

### 1. `Test2::Harness2::Scheduler`

**Why first / why biggest win:**
- The scheduler already has a discrete naming convention (`_scheduler_*`), which means the seams are already partially there.
- The slots it owns (queue, scheduler, run_states, run_flags, completed_runs, run_ord_counter, in_flight_count) are not directly read by anyone outside scheduler concerns, except for a small read surface used to build status snapshots and run-results responses.
- It is the single biggest sub family — ~25% of the file body collapses into one module.

**API the harness would call:**
```perl
$harness->scheduler->queue_run($run);
$harness->scheduler->mark_running($run_id, $job_id);
$harness->scheduler->mark_pending($run_id, $job_id);
$harness->scheduler->mark_done($run_id, $job_id, $result);
$harness->scheduler->run_complete($run_id);
$harness->scheduler->snapshot($run_id);            # for status / run_results
$harness->scheduler->try_launch_next($harness);    # called from run_on_interval
$harness->scheduler->in_flight_count;
$harness->scheduler->all_run_ids;
```

`try_launch_next($harness)` takes the harness as an argument because the actual launch step (`_launch_job`, `_spawn_collector_for_job`, `_spawn_via_preload`) stays on the harness — the scheduler decides *what* to launch and the harness executes the launch. This is the seam that lets the scheduler be testable in isolation while keeping the IPC- and fork-flavored launch glue out of it.

**Risk:** moderate. Run state is touched from many places. Mitigation: keep the read accessors generous; require all writers to go through scheduler methods.

### 2. `Test2::Harness2::PidIndex`

**Why early:**
- Smallest module. Builds confidence.
- Pure data structure plus lookup; zero IPC, zero fork, zero race-prone code.
- Slot ownership is unambiguous (RUN_PIDS, RESOURCE_SERVICES); the touching methods all have `_run_pid` / `_pids_for_run` / `_resource_service_*` in their name.

**API:**
```perl
$harness->pids->register($run_id, $pid);
$harness->pids->forget($run_id, $pid);
$harness->pids->run_for_pid($pid);             # returns $run_id or undef
$harness->pids->pids_for_run($run_id);         # returns @pids
$harness->pids->kill_run($run_id, $signal);
$harness->pids->await_run_exit($run_id, $deadline);
$harness->pids->resource_service_tracked($pid, $entry);
$harness->pids->resource_service_forgotten($pid);
```

**Risk:** very low. The methods are already cohesive. Almost a mechanical move.

### 3. `Test2::Harness2::StateBroadcaster`

**Why early:**
- Self-contained pub/sub. The only state it reads from outside is what it needs to build a state snapshot (RUN_STATES, RUNNING_JOBS) — and those reads happen at well-defined moments (subscribe, run-state delta).
- Its write surface (EMITTER, SUBSCRIBERS, SUBSCRIBER_RETRY) is local.
- The retry queue logic (with its `SUBSCRIBER_RETRY_CAP` invariant) is the kind of bounded state that benefits from being walled off — a leak there is easier to see when it's in its own module.

**API:**
```perl
$harness->broadcaster->subscribe($peer, %opts);
$harness->broadcaster->unsubscribe($peer);
$harness->broadcaster->notify_state_change($snapshot);
$harness->broadcaster->broadcast_run_state($run_id, $delta);
$harness->broadcaster->drain_retries;          # called from run_on_interval
```

**Risk:** low. The snapshot-construction logic needs to either accept the snapshot as an argument (preferred) or accept a callback the harness provides; either way the broadcaster does not directly poke harness slots.

### 4. `Test2::Harness2::PreloadRouter`

**Why fourth, not earlier:**
- It's the most cross-cutting of the five. It reads RESOURCES (config), RESOURCE_SERVICES (PidIndex's domain), RUN_STATES (Scheduler's domain), and writes its own four slots.
- Doing it after Scheduler and PidIndex means the cross-reads can use the new accessor APIs from the start, rather than being written against `$self->{+RUN_STATES}` and then rewritten.

**API:**
```perl
my ($preload, $verdict) = $harness->preload_router->resolve_for_job($run, $job);
$harness->preload_router->spawn_via_preload($run, $job, $preload_resource, %opts);
$harness->preload_router->spawn_service_via_preload($resource, $host_scope);
$harness->preload_router->handle_resource_service_started($msg);
$harness->preload_router->handle_preload_state_message($msg);
$harness->preload_router->tick($harness);     # age + timeout + drain awaiting-preload
```

**Risk:** moderate. The `_fallback_resources_awaiting_preload` / `_drain_resources_awaiting_preload` / `_fallback_single_entry` group is the most procedurally tangled — it gates run startup on preload readiness. Mitigation: extract behavior unchanged first; revisit only after the move proves stable.

**Sub-question worth raising:** the `_age_pending_spawn_requests` and `_check_pending_preload_spawn_timeouts` watchdogs both run from `run_on_interval`. Consolidating them into one `->tick` entry point in PreloadRouter is cleaner; the current two-function shape only exists because they happen to be near each other in the file.

### 5. `Test2::Harness2::SpawnGateway`

**Why last:**
- It is the most independent module of the five — it could honestly be done any time.
- Last only because of size triage: doing the bigger extractions first frees up the most reviewer attention; SpawnGateway is small enough that it would be a quick follow-on once the patterns are settled.

**API:**
```perl
$harness->spawn_gateway->handle_request($payload, $msg);
$harness->spawn_gateway->handle_spawned($msg);     # script_spawned IPC
$harness->spawn_gateway->handle_exit($pid, $exit); # reaped pid
$harness->spawn_gateway->poll;                     # called from run_on_interval
```

**Risk:** low. It owns its own counter and exit-stash; the only outside dependency is the IPC client + the `_assert_fdpass_transport` precondition.

---

## What I would NOT split yet

### JobTracker (RUNNING_JOBS + test_job_* lifecycle)

Tempting on paper, but premature. Reasons:

1. **It is the most interconnected cluster.** RUNNING_JOBS is read or written by 18 different methods, including the scheduler (when launching), the preload router (when registering a pending spawn), the broadcaster (when building snapshots), and the pid index (when reaping a collector). Five out of the six other clusters touch RUNNING_JOBS.

2. **PENDING_SYNTH_COMPLETIONS straddles the scheduler-vs-job-tracker boundary.** A synthesized completion is created by the pid-reaping path but consumed by the run-finalization path. Until the scheduler extraction lands, it is not clear which side it belongs to.

3. **The right shape is unclear before the other extractions.** Specifically, once the Scheduler owns RUN_FLAGS and the PreloadRouter owns pending spawns, the residual job-state surface is much smaller — possibly small enough that "extract a JobTracker" stops being the right answer and we just leave the rest on Harness2.

Defer this decision until after extractions 1-5 are in.

### RunRegistry (RUN_STATES + RUN_FLAGS rehydration)

Same argument. RUN_STATES is currently the scheduler's primary data structure. If the Scheduler extraction takes ownership of it (recommended), there is nothing left for a separate RunRegistry to own. If for some reason RUN_STATES stays on Harness2 after the Scheduler move, then RunRegistry becomes a real candidate. Decide after the Scheduler is done.

### `request_handler_*` thin wrappers

These are 200-300 lines total. Tempting to extract a "RequestRouter" but it would only collect thin wrappers that immediately delegate. Not worth the indirection. They stay on `Harness2`, and they call into the subsystem objects.

### Launch glue (`_launch_job`, `_spawn_collector_for_job`, etc.)

Keep on Harness2 deliberately. The launch step is the place where the harness's identity (IPC info, harness pid, parent pids, kill timeout, env, signal handling) actually gets baked into the collector / preload-service spawn. Putting this on a separate object would either drag those identity slots out of Harness2 (bad — they belong here) or require passing seven arguments to every helper (bad — noise). Leave it.

---

## Patterns to enforce across all five extractions

These are the rules that make the split worth doing. Without them the new modules end up as namespaced bags of state with the same coupling as before.

1. **Subsystems are plain objects.** Use HashBase. Construct during `Harness2->init`. Store in a slot. No `with` clauses, no services, no IPC role. The harness handles all IPC; subsystems get called *by* the harness's IPC handlers.

2. **Subsystems do not call back into the harness with `$harness`** unless they need launch-side work that genuinely belongs on the harness (`Scheduler->try_launch_next($harness)` is the canonical example). When in doubt, the subsystem returns a decision; the harness acts on it.

3. **Slot writes stay inside the owning subsystem.** After the move, `$self->{+QUEUE}` should not appear anywhere in `Harness2.pm`. If it does, that's a bug in the extraction.

4. **Cross-reads go through accessors.** PreloadRouter needs RUNNING_JOBS? It asks `$harness->running_jobs->{$job_id}`, where `running_jobs` is an accessor on Harness2 (or, if we extract JobTracker later, `$harness->job_tracker->running($job_id)`).

5. **Per-tick orchestration stays in Harness2's `run_on_interval`.** Sequence:
   ```perl
   sub run_on_interval {
       my $self = shift;
       $self->scheduler->try_launch_next($self);
       $self->preload_router->tick($self);
       $self->spawn_gateway->poll;
       $self->broadcaster->drain_retries;
       # ...existing watchdogs that stay on Harness2 (synth completions, etc)
   }
   ```
   The order matters and is the harness's responsibility, not any subsystem's.

6. **Test coverage moves with the extraction.** Each new module gets its own `t/AI/unit/Harness2/<Subsystem>.t`. The existing whole-Harness tests stay green throughout; new subsystem tests are *added*, not migrated, to keep the integration-level safety net intact.

7. **Function-length rule (ARCHITECTURE.md §25) still applies.** Every new method must be ≤75 lines of executable Perl. `perl author/find-long-subs` is the tripwire.

---

## Suggested execution order

The ordering is not arbitrary. It minimizes the number of times any one piece of state has to be touched.

1. **PidIndex** — smallest, safest, mechanical. Establishes the extraction pattern.
2. **SpawnGateway** — small, isolated, exercises the pattern on a slightly more complex case.
3. **StateBroadcaster** — exercises the "subsystem needs to read cross-cutting state" pattern.
4. **Scheduler** — biggest payoff. Lands the dispatch loop in its own home.
5. **PreloadRouter** — last, because it builds on the accessor APIs that PidIndex and Scheduler will have introduced.

Each as its own commit. Full test suite must pass between each. If any step regresses, revert that single extraction; do not stack failures.

After all five are in, re-examine RUNNING_JOBS / RUN_STATES distribution. At that point JobTracker either becomes obvious or becomes unnecessary — both are good outcomes.

---

## Open questions worth raising before any code moves

1. **Does the harness need to keep being a Resource Service Host?** Currently it consumes `Test2::Harness2::Role::ResourceServiceHost`. If the resource-service hosting concern is itself worth extracting (separate question), the Scheduler's view of resource-availability changes. Worth a focused thread.

2. **Should Scheduler own the broken-resource policy?** `BROKEN_BEHAVIORS` and `_handle_broken_resource` / `_launch_unavailable_action_job` are scheduler-adjacent but encode a policy decision. They probably move with the Scheduler, but the policy itself might deserve naming (e.g. `Test2::Harness2::BrokenResourcePolicy`) once it's not buried in 3,800 lines.

3. **`_handle_resource_state_message` is currently on Harness2 but logically belongs near PreloadRouter or near a future `ResourceMonitor`.** Worth deciding which side owns it before moving anything.
