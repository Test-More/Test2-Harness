# Test2::Harness2 refactor findings

This report is analysis only. No implementation work has been done.

## Goal

`lib/Test2/Harness2.pm` is currently a top-level service object, scheduler,
process tracker, preload router, spawn gateway, run-state aggregator, and
subscriber fanout registry all in one file. It is 3,882 lines and carries a
large collection of HashBase state slots.

The desired direction is to keep `Test2::Harness2` as the object that
initializes subsystems, owns the IPC service role, and orchestrates event-loop
order, while moving cohesive state and behavior into plain objects. These
objects should not be services. They should be owned by the harness and called
by it.

## Current shape

The file already has natural method bands:

- Init and defaults: `init`, `_init_logdir`, `_init_default_slots`,
  `_init_resources`.
- Run queue request handling: `request_handler_queue_test_run`, hash-seed
  validation, per-run resource rehydration.
- IPC request handlers: status, list preloads, abort, finish, pending messages,
  run results, subscribe, unsubscribe, detach, spawn script.
- General-message dispatch: preload/resource state, resource service started,
  script spawned, test job lifecycle, collector lifecycle.
- Scheduler: `_scheduler_*`, `_try_launch_next_pending`,
  `_dispatch_pending_job`, resource evaluation, broken-resource handling.
- Job/run lifecycle: `test_job_*` handlers, run flags, aggregate report
  building, completion snapshots, finalization.
- Process tracking: run pid registry, hard-stop pid enumeration, pid reaping.
- Preload routing: preload selection, spawn through preload, pending preload
  request watchdogs, preload-mediated resource service spawn.
- Subscriber fanout: state subscriptions, retry queues, peer-drop cleanup.
- `yath spawn` gateway: fd-pass checks, spawn requests, script exit dispatch.

That clustering is strong enough to split without inventing new behavior.

## Recommended breakouts

### 1. `Test2::Harness2::PidIndex`

Own the run/global pid map and operations over it.

Move:

```perl
run_pids
_register_run_pid
_forget_run_pid
_run_for_pid
_pids_for_run
_kill_run
_await_run_exit
_resource_service_tracked
_resource_service_forgotten
```

Justification:

This is the safest first extraction. It is a small data structure with a clear
API: register, forget, reverse-lookup, list, kill, and await. It has little
policy of its own and no reason to remain mixed into scheduling or preload
logic. Moving it first establishes the extraction pattern with low risk.

`resource_services` itself should stay where `Role::ResourceServiceHost`
expects it unless that role is also refactored. `PidIndex` can mirror resource
service lifecycle into its pid map through explicit calls.

### 2. `Test2::Harness2::SpawnGateway`

Own the `yath spawn` request/notification path.

Move:

```perl
pending_script_spawns
_script_spawn_counter
_script_spawn_exits
request_handler_spawn_script
_handle_script_spawn_exit
_handle_script_spawned
_dispatch_script_exited
_poll_script_exits
_assert_fdpass_transport
```

Justification:

This pathway is self-contained. It has its own pending table, counter, race
stash, transport precondition, and exit notification behavior. Its outside
dependencies are limited to the IPC client, preload lookup, and pid reaping
entry point.

The harness should continue to receive the IPC request and pid-reap callback,
then delegate to the gateway.

### 3. `Test2::Harness2::StateBroadcaster`

Own subscriber registration and reliable state fanout.

Move:

```perl
subscribers
subscriber_retry
request_handler_subscribe
request_handler_unsubscribe
_notify_state_subscribers
_send_state_snapshot
_send_to_subscriber
_drain_subscriber_retries
```

Justification:

Subscriber retry and peer-drop handling are operational concerns, not harness
or scheduling policy. The retry cap and FIFO trimming logic are easier to audit
when isolated.

I would not move `emitter` here. The emitter writes harness service events,
while this module sends IPC state snapshots to subscribers. Those are different
channels. Keep `emit_service_event` on the harness and let the broadcaster
only handle subscription delivery.

### 4. `Test2::Harness2::Scheduler`

Own launch decisions and scheduler-owned queue state.

Move:

```perl
queue
scheduler
in_flight_count
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
run_on_all
_try_launch_next_pending
_dispatch_pending_job
_evaluate_resources_for
_handle_broken_resource
_launch_unavailable_action_job
```

Likely also move:

```perl
broken_resource_behavior
BROKEN_BEHAVIORS
```

Justification:

This is the biggest payoff. The scheduler is already named as a subsystem in
the code and it has an authoritative pending/running view separate from
`Run::State`. It decides which job can run, whether resource state causes
defer/skip/broken behavior, and whether unavailable-action jobs should be
launched.

The harness should still perform the actual launch, because launch code bakes
in harness identity, IPC peer names, logdir, kill timeout, env, and collector
details. A good seam is for the scheduler to return a decision or call a narrow
harness launch callback.

### 5. `Test2::Harness2::PreloadRouter`

Own preload selection and preload-mediated async spawn state.

Move:

```perl
pending_spawn_requests
pending_preload_spawns
resources_awaiting_preload
known_preload_names
preload_spawn_timeout_secs
preload_service_spawn_timeout_secs
_resolve_preload_for_job
_index_preloads_for_run
_classify_preload_state
_spawn_via_preload
_register_pending_preload_spawn
_build_spawn_test_payload
_age_pending_spawn_requests
_preload_peer_name
_resource_peer_name
_find_eligible_preload_service
_spawn_service_via_preload
_handle_preload_state_message
_handle_resource_service_started
_drain_resources_awaiting_preload
_fallback_resources_awaiting_preload
_fallback_single_entry
_check_pending_preload_spawn_timeouts
```

Justification:

Preload handling is one of the most complicated regions because it is both a
router and an async watchdog. It tracks in-flight `spawn_test` requests,
preload-mediated resource-service spawns, wait-for-preload queues, fallback
paths, and timeout behavior.

This should come after `PidIndex` and `Scheduler`, because it currently crosses
both domains. Extracting it later lets it call explicit subsystem APIs instead
of continuing to poke at harness hash slots.

### 6. Possible later `Test2::Harness2::RunLifecycle`

Do not extract this first, but re-evaluate it after the modules above are in.

Possible ownership:

```perl
run_states
run_flags
completed_runs
running_jobs
pending_synth_completions
_run_flags
_handle_test_job_started
_handle_test_job_diagnosing
_handle_test_job_failing
_handle_test_job_completed
_emit_run_completed
_build_collector_report
_broadcast_run_state
_snapshot_run_results
_handle_job_release
_release_job_resources
_handle_test_collector_exit
_synth_release_orphan_job
_finalize_run_if_complete
```

Justification:

This cluster is real, but it is currently the most interconnected. It touches
scheduler state, subscriber broadcasts, pid tracking, preload placeholder jobs,
resource release, run finalization, and report writing. Extracting it too early
would likely produce a module that still reaches everywhere.

After scheduler, pid, broadcaster, and preload responsibilities have narrower
interfaces, the remaining run-lifecycle shape should be clearer. At that point
it may be worth extracting, or it may be small enough to leave on the harness.

## What should stay on `Test2::Harness2`

Keep the orchestration and service identity in the main class:

```perl
init
_init_logdir
_init_default_slots
_strip_legacy_logger_slots
_init_resources
_install_in_flight_ref
start
spawn
ipcm_info
service_host_scope
service_host_run
service_host_logdir
become_sub_reaper
service_on_start
service_pre_hard_stop
hard_stop_pids
service_post_hard_stop
run_on_general_message
run_on_peer_delta
run_on_pid
run_on_interval
run_should_end
run_on_cleanup
emit_service_event
TO_JSON
```

Also keep direct collector/job launch glue for now:

```perl
_launch_job
_announce_run_started_if_first
_build_launch_env
_launch_collector_inline
_spawn_collector_for_job
_ensure_run_service_started
_write_run_spec
_write_run_report
_teardown_run_service
```

Reason:

This code uses harness identity and service configuration directly: name,
logdir, IPC info, parent pids, kill timeout, auditor, process group behavior,
and service event emission. Moving it too early would either drag those slots
out of the harness or create noisy argument passing.

Request handlers can remain as thin wrappers on `Harness2`, delegating to
subsystems where appropriate. A separate request-router object would mostly
collect one-line methods and add indirection without reducing state coupling.

## Suggested execution order

1. `PidIndex`
2. `SpawnGateway`
3. `StateBroadcaster`
4. `Scheduler`
5. `PreloadRouter`
6. Re-evaluate `RunLifecycle`

This order starts with small and isolated state, then moves toward the
cross-cutting scheduler and preload logic once stable subsystem APIs exist.

Each extraction should be its own commit. Keep behavior unchanged first. Add
focused unit tests for each new subsystem while keeping the whole-harness tests
as integration coverage.

## Design constraints for the extraction

- Subsystems should be plain objects, preferably HashBase objects to match the
  project style.
- Subsystems should not consume service roles or talk to IPC as independent
  services.
- The harness owns event-loop order. `run_on_interval`, `run_on_pid`, and
  `run_on_general_message` should remain the orchestration points.
- State writes should live in the owning subsystem. After extraction,
  direct access to the moved slots from `Harness2.pm` should be treated as a
  smell.
- Cross-domain reads should go through explicit methods, not shared hash
  dereferences.
- Launch-side work should either stay on the harness or be exposed as a narrow
  callback because it depends heavily on harness identity.

## Open questions

### Should resource service hosting be its own object?

`Test2::Harness2` consumes `Test2::Harness2::Role::ResourceServiceHost`, which
expects a `resource_services` accessor and provides substantial behavior around
service startup, tracking, and restart handling. That role is already a
separate abstraction, so I would not fold it into `PidIndex` or
`PreloadRouter`.

If resource-service hosting itself becomes a refactor target, that should be a
separate pass. It affects preload-mediated service spawn, process tracking,
status reporting, and hard-stop behavior.

### Should broken-resource policy be separate from Scheduler?

For the first extraction, no. Move it with `Scheduler`. Later, if
skip/fail/abort policy grows or needs isolated tests, it could become something
like `Test2::Harness2::BrokenResourcePolicy`.

### Should `run_states` belong to Scheduler or RunLifecycle?

Initially, scheduler needs enough access to decide what is pending, running,
done, and aborted. But `Run::State` also feeds result snapshots and subscriber
state. This is why `RunLifecycle` should wait. The first scheduler extraction
can expose narrow run-state accessors; after that the better ownership boundary
will be visible.

