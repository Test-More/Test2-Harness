# Test2::Harness2 Refactoring Plan

## Overview
`Test2::Harness2` currently operates as a "God Object," comprising nearly 4,000 lines of code and managing a vast array of internal state attributes. It handles everything from low-level IPC subscription retries to test scheduling, process reaping, and complex preload spawning logic.

To transform `Test2::Harness2` into a lean orchestrator, the internal logic should be decoupled into smaller, domain-specific state-bearing objects. The main Harness module will instantiate these objects during initialization and coordinate between them, dramatically reducing its own complexity.

Below are the proposed modules to extract from `Test2::Harness2`.

---

## 1. `Test2::Harness2::Scheduler`

### Responsibilities
This object will encapsulate the "thinking" behind what tests can run and when. It evaluates available resources, checks job requirements against limits, and makes the decision to launch, defer, or skip tests.

### Attributes to Move
*   `scheduler` (internal queue states)
*   `in_flight_count`
*   `broken_resource_behavior`

### Key Logic to Extract
*   The `_scheduler_*` state-management methods (`_scheduler_queue_run`, `_scheduler_mark_running`, etc.).
*   `_try_launch_next_pending` and `_dispatch_pending_job`.
*   Resource evaluation logic (`_evaluate_resources_for`).
*   Handling of broken resources (`_handle_broken_resource`) and the "unavailable action" (skip/fail) logic (`_launch_unavailable_action_job`).

### Justification
Scheduling is currently deeply intertwined with the main service loop. By extracting it, the Harness only needs to call `$self->scheduler->tick()` during `run_on_all`. The Scheduler itself remains easily testable in isolation by mocking resource availability.

---

## 2. `Test2::Harness2::StateTracker`

### Responsibilities
This object will manage the "ground truth" of what is currently happening across all active and completed runs. It tracks running PIDs, aggregates test pass/fail results, and handles process exit mappings.

### Attributes to Move
*   `run_states`
*   `run_flags`
*   `running_jobs`
*   `run_pids`
*   `completed_runs`
*   `pending_synth_completions`

### Key Logic to Extract
*   PID-to-Run mappings (`_register_run_pid`, `_forget_run_pid`, `_run_for_pid`).
*   Job lifecycle message handling (`_handle_test_job_started`, `_handle_test_job_completed`, etc.).
*   Reaping mapping logic (`_handle_test_collector_exit`).
*   The watchdog for synthetic completions (`run_on_interval` logic for collector orphan timeouts).
*   Run finalization aggregations (`_build_collector_report`, `_snapshot_run_results`).

### Justification
State tracking currently requires the Harness to maintain parallel hashes (`RUNNING_JOBS`, `RUN_PIDS`, `RUN_STATES`). Moving this into a dedicated tracker provides a single, unified interface for querying "What is this PID?" or "Is this run finished?"

---

## 3. `Test2::Harness2::SpawnManager` (or `PreloadManager`)

### Responsibilities
This object will handle the complex mechanics of actually starting test processes, specifically managing the intricate asynchronous state of preload-mediated spawns and resource fallback queuing.

### Attributes to Move
*   `pending_spawn_requests`
*   `pending_preload_spawns`
*   `pending_script_spawns`
*   `resources_awaiting_preload`
*   `known_preload_names`
*   `preload_spawn_timeout_secs`

### Key Logic to Extract
*   Preload resolution (`_resolve_preload_for_job`, `_index_preloads_for_run`).
*   The mechanics of async spawning (`_spawn_via_preload`, `_spawn_service_via_preload`).
*   Timeout management for in-flight spawn requests (`_age_pending_spawn_requests`).
*   The wait-for-preload queues (`_drain_resources_awaiting_preload`, `_fallback_resources_awaiting_preload`).
*   `yath spawn` script handling (`request_handler_spawn_script`, `_handle_script_spawned`).

### Justification
The preload/spawn logic is heavily asynchronous, requiring pending tables, timeouts, and multi-step IPC handshakes. Isolating this complexity allows the SpawnManager to abstract a simple `launch_job` interface for the Scheduler, hiding whether the job was direct-forked or routed through a preload service.

---

## 4. `Test2::Harness2::Notifier`

### Responsibilities
This object will manage IPC subscribers and the fan-out of harness state events, ensuring robust delivery of updates to clients like the test runner UI.

### Attributes to Move
*   `subscribers`
*   `subscriber_retry`
*   `emitter`

### Key Logic to Extract
*   Subscription request handlers (`request_handler_subscribe`, `request_handler_unsubscribe`).
*   Broadcast logic (`_notify_state_subscribers`, `_send_state_snapshot`).
*   Retry and congestion management (`_send_to_subscriber`, `_drain_subscriber_retries`).

### Justification
Notification fan-out and retry logic clutters the core message loop. By extracting this, the StateTracker simply fires a local `run_state_changed` event, and the Notifier autonomously handles the queueing, IPC dispatch, and peer-disconnect handling.

---

## Conclusion: The New Orchestrator

By breaking out these objects, `Test2::Harness2` will focus solely on its primary role: acting as the `Role::Service` IPC endpoint. The initialization process will be drastically simplified:

```perl
sub init {
    my $self = shift;
    
    # ... directory validation ...

    $self->{+STATE_TRACKER} = Test2::Harness2::StateTracker->new(harness => $self);
    $self->{+SCHEDULER}     = Test2::Harness2::Scheduler->new(harness => $self);
    $self->{+SPAWN_MANAGER} = Test2::Harness2::SpawnManager->new(harness => $self);
    $self->{+NOTIFIER}      = Test2::Harness2::Notifier->new(harness => $self);
    
    # ... remaining minimal setup ...
}
```

This refactor will significantly improve maintainability, testing isolation, and code readability.

---

## Addendum: Synthesis of Multi-Agent Refactor Reports

After reviewing alternative architectural analyses (Codex and Claude reports) alongside this one, there is strong consensus on the core subsystems (Scheduler, Notifier/Broadcaster, Preload/Spawn logic) but valuable divergence in tactical execution. 

### Key Refinements to the Plan

1.  **Extract `PidIndex` First:** Both Claude and Codex correctly identified `Test2::Harness2::PidIndex` as the safest, lowest-risk first move. It is a pure data structure representing the PID-to-Run mappings, with almost no policy. Moving this first establishes the extraction pattern cleanly.
2.  **Separate `SpawnGateway` from `PreloadRouter`:** Codex correctly points out that the `yath spawn` (SCM_RIGHTS) pathway is fully self-contained. It should be its own module (`SpawnGateway`), independent of the broader async preload mechanics.
3.  **Defer "Job Tracker" / "Run Lifecycle" Extraction:** Claude wisely noted that `RUNNING_JOBS` and `RUN_STATES` are too deeply entangled with the Scheduler right now. Extracting a "State Tracker" or "Run Lifecycle" module too early will just result in a new module that reaches everywhere. This extraction should be deferred until after the Scheduler and Preload modules are isolated.
4.  **Keep "Launch Glue" on the Harness:** The actual `fork` or `Collector->spawn` invocation depends heavily on Harness identity slots (IPC info, Auditor, kill timeout, names). Moving this to the Scheduler would require passing noisy context objects. The Scheduler should return *decisions*, and the Harness should execute the launch.

### Final Recommended Execution Order

To minimize risk and ensure subsystem stability, the refactoring should proceed in the following order:

1.  **`Test2::Harness2::PidIndex`**: Move `RUN_PIDS` and `RESOURCE_SERVICES` mapping logic.
2.  **`Test2::Harness2::StateBroadcaster`** (Notifier): Move subscriber pub/sub and IPC retry queues.
3.  **`Test2::Harness2::SpawnGateway`**: Isolate the `yath spawn` script execution pathway.
4.  **`Test2::Harness2::Scheduler`**: The highest-impact extraction. Move queue management, limits, and the `try_launch_next` decision loop.
5.  **`Test2::Harness2::PreloadRouter`**: Move the async wait-for-preload queues, timeout watchdogs, and resource fallback logic.

Each extraction should be performed as a single commit, preserving existing tests as integration coverage while introducing new unit tests for the extracted subsystem.