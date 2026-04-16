# Test2::Harness2 Service — Design

**Date:** 2026-04-16
**Branch:** 2.0_rewrite
**Stub:** `lib/Test2/Harness2.pm` (design comments, to be replaced)

## Purpose

`Test2::Harness2` is the top-level harness service. It owns a workdir, accepts test-run requests over IPC, and dispatches one test at a time to a `Test2::Harness2::Collector`. It emits structured events about its own lifecycle to a JSONL log under the workdir, and each test's events go to their own JSONL log keyed by run_id/job_id.

This spec implements only what the stub comments ask for. Feature parity with `old/lib` (scheduler, retries, isolation, concurrency, preload, etc.) is a future concern.

## Process lifecycle guarantees

Two invariants are load-bearing and must be enforced everywhere processes are created or signalled. Every later section (interpose plumbing, per-test dispatch, Terminate, finish, cleanup) has to honor them, and the implementation must include tests that exercise each one.

**Invariant 1 — no survivors on hard stop.** When the service is terminated (via `Terminate` request, fatal signal, `run_on_cleanup` from an abnormal exit, or crash), every process descended from the service — test collectors, test processes, and anything those forked — must be killed and reaped. The implementation strategy:

- The service calls `setpgrp(0, 0)` (or `POSIX::setpgid(0, 0)`) on `run_on_start` so it owns its own process group. Every test Collector it launches inherits that process group (and the tests they launch inherit in turn) unless they explicitly set their own.
- Hard stop sends `TERM` to the negative pgid (`kill 'TERM', -$service_pid`), waits up to `kill_timeout` seconds while reaping via `waitpid(-1, WNOHANG)`, then sends `KILL` to the negative pgid for any still-alive pids, then waits without `WNOHANG` until all are reaped. Anything that forked into a new pgid is tracked through `register_worker` and killed the same way as a fallback.
- `Terminate` goes through this path. So does `run_on_cleanup` (even on clean shutdown, verify no stragglers; if any, kill them aggressively).
- `run_should_end` must not return true until `+current` is cleared AND there are no registered workers still alive — otherwise we'd exit and orphan children.
- A SIGTERM/SIGINT to the service itself routes through the role's signal handling, sets state to `'terminating'`, and triggers the same kill-pgroup path.

**Invariant 2 — nothing survives its parent.** If the harness service process exits for any reason (intentional shutdown, crash, SIGKILL from outside), every child process must terminate on its own — we cannot rely on the service's signal handlers, because they may never run.

- Every per-test Collector is launched with `parent_pids => [$service_pid, @caller_parent_pids]`. The Collector role already polls `watch_pids` and self-terminates if any listed pid dies. When a test collector self-terminates, it is responsible (via its existing kill_timeout logic) for also killing the test process it spawned.
- The service itself is launched with `parent_pids` pointing at its caller: for `start()` that's the grandparent of the interpose child (the process that called `start`), and for `spawn()` that's the top-level spawn-caller pid — unless `Spawn->detach()` has been called, in which case the service stops watching that pid.
- The interpose parent (service-log Collector) sits between the spawn caller and the service; it already self-exits when its child dies. It also receives `parent_pids` so it dies with the spawn caller (unless detached).
- "Detach" flows down: `Spawn->detach()` sends a `Detach` IPC request to the service which removes the caller's pid from its `watch_pids` list and propagates the change to the interpose parent. This lets a daemon outlive its creator.

Both invariants must be covered by unit tests — one that kills the service forcibly and verifies all descendants exit, and one that calls `Terminate` mid-run and verifies the running test process is gone (not just the collector).

## Module layout

New files:

- `lib/Test2/Harness2.pm` — the service (replaces the stub)
- `lib/Test2/Harness2/Run.pm` — a queued run
- `lib/Test2/Harness2/Run/Job.pm` — one test within a run
- `lib/Test2/Harness2/Spawn.pm` — parent-side handle returned by `Test2::Harness2->spawn`
- `t/unit/Harness2.t` — unit test

## `Test2::Harness2::Run::Job`

`Object::HashBase` attributes:

- `<job_id` — UUID, auto-generated via `Test2::Util::UUID::gen_uuid` if not supplied
- `<test_file` — path string (no `TestFile` wrapper yet)
- `<job_try` — always `0` for now
- `<run_id` — back-reference to owning run

Minimal behavior. No retry, no args, no test settings. The old `Test2::Harness2::Run::Job` in `old/lib` can be consulted but we are deliberately trimming.

## `Test2::Harness2::Run`

`Object::HashBase` attributes:

- `<run_id` — UUID, auto-generated if not supplied
- `<jobs` — arrayref of `Test2::Harness2::Run::Job`
- `<created_at` — epoch float
- `+pending` — arrayref of job_ids not yet started (ordered)
- `+running` — arrayref of job_ids currently running (0 or 1 entry; the service only runs one at a time, but the shape is per-run)
- `+done` — arrayref of job_ids finished

Constructor helper: `Run->from_files(run_id => $opt, files => [...])` builds jobs. `pending` starts as every `job_id`; as jobs dispatch and complete, they move through `running` → `done`.

## `Test2::Harness2` (the service)

### Role composition

```perl
package Test2::Harness2;
use parent 'Test2::Harness2::Util::HashBase';
use Role::Tiny::With;
with 'IPC::Manager::Role::Service';
```

### Attributes

- `<workdir` — required, must exist
- `<name` — default `'harness'`
- `<job_id` — UUID auto-generated; used in events the service emits (run_id stays undef for service events)
- `<orig_io` — captured stdout/stderr/stdin refs (populated by the role / by `interpose` plumbing)
- `<loggers` — logger specs for the service itself. Default:
  `[ ['Test2::Harness2::Collector::Logger::JSONL', output_file => "$workdir/services/$name.jsonl"] ]`
- `<test_auditor` — auditor spec for per-test collectors. Default: `'Test2::Harness2::Collector::Auditor::Test'`
- `<test_loggers` — logger specs for per-test collectors. Default: `['Test2::Harness2::Collector::Logger::JSONL']` (the `output_file` is injected per-job at dispatch time)
- `<kill_timeout` — default 15 (passed to the running collector on terminate)
- `+state` — one of `'running'`, `'finishing'`, `'terminating'` (default `'running'`)
- `+queue` — arrayref of `Test2::Harness2::Run` objects (FIFO)
- `+current` — hashref or undef: the in-flight job with keys `run`, `job`, `handle` (the Collector Handle), `started_at`
- `+finish_after_initial_run` — bool; set by `start()`/`spawn()` when invoked with an initial `test_run`

### Workdir validation

At construction time:

- Require `workdir` to exist and be a directory.
- **Reject** if `$workdir/services/` or `$workdir/runs/` already exists (would mix old logs with new). Other files in the workdir are fine (the parent tool may use the workdir for its own state).
- Create `$workdir/services/` on init. Create `$workdir/runs/` lazily per run (`$workdir/runs/$run_id/$job_id/` per job; the per-job JSONL is `0.jsonl`).

Logger and auditor specs are validated at construction (class exists, consumes the right role) but instances are only created where they actually run:

- Service loggers are passed to `Collector->interpose` and instantiate inside the interpose parent (the service-log Collector), not in the service process.
- Test auditor/loggers are passed to the per-test Collector and instantiate inside each collector child (existing Collector behavior).

### How interpose is used (architecture)

`Test2::Harness2::Collector->interpose(...)` forks. The **parent** becomes a Collector that reads the child's redirected stdout/stderr pipes and routes every byte through IOParser → auditor → loggers. The parent does not return from `interpose`; it runs the collector to completion and `_exit()`s. The **child** returns from `interpose` with its stdout/stderr remapped to atomic pipes, and continues executing the caller's code.

For the harness service:

- The **service loop** runs in the interpose child.
- The **JSONL logger** that writes `$workdir/services/$name.jsonl` runs in the interpose parent.
- The service emits its own structured events by writing them to stdout; the interpose parent's IOParser picks them up and routes to the JSONL logger. If Stream2-style atomic writes are needed, we add that plumbing during implementation. For now, the simplest path is: the service calls a helper that prints the event JSON to stdout in a format the existing IOParser already recognizes, or adds one if not.

The service's `job_id` is the UUID that tags every event the service emits (set at construction, used by the event-emit helper).

### Entry points

**`Test2::Harness2->start(%args)`** — takes over the current process:

Accepts standard construction args plus:

- `test_run => { files => [...], run_id => $opt }` — optional. If present, this run is queued before the service loop begins.
- `finish_after_initial_run => 1` — optional. If set (commonly together with `test_run`), the service automatically transitions to `'finishing'` when the initial run completes. This is the common case for `start()` — "run one batch, then shut down".

Execution:

1. Validate args. Capture `$caller_pid = $$` for Invariant 2.
2. Call `Collector->interpose(loggers => $service_loggers, parser => 'Test2::Harness2::Collector::Parser::IOParser', parent_pids => [$caller_pid])`. The interpose parent (now the service-log Collector) inherits the parent_pids — if the original caller dies, interpose parent exits, which causes the service to exit (the service watches the interpose parent's pid via its own `parent_pids`).
3. In the child (returned from interpose), `new(%args, parent_pids => [$caller_pid, $interpose_parent_pid])`, queue the initial `test_run` if given (setting `+finish_after_initial_run` if requested), and call `$self->run`. Exit with the service loop's exit code. The interpose parent reaps and exits in lockstep.

**`Test2::Harness2->spawn(%args)`** — service runs in a new process:

Accepts the same args as `start()`, plus IPC spawn info.

1. Use `IPC::Manager::ipcm_spawn(...)` to allocate route/protocol/serializer.
2. Capture `$caller_pid = $$`. `fork`. The top-level parent constructs a `Test2::Harness2::Spawn` handle with the child pid + ipcm_info and returns it to the caller. The top-level child runs the same interpose + `run` path as `start()`, passing `parent_pids => [$caller_pid]` through both the interpose parent and the service child (Invariant 2). If the caller later calls `$spawn->detach`, the pid is removed from the watch list via the `Detach` IPC request.

Note that after both forks resolve, the process tree under `spawn()` is:

```
caller                   (has the Spawn handle, can exit independently)
  top-level child        (interpose parent — the service-log Collector)
    interpose child      (the service loop; accepts IPC; forks collectors for tests)
      test collector     (Collector wrapping one test, at most one at a time)
        test process
```

**Discourage direct `new` calls.** Document in POD and the module body that users should call `start` or `spawn`; `new` alone does not start the service loop.

### Service loop (role overrides)

- **`run_on_start`** — call `POSIX::setpgid(0, 0)` so the service owns its own process group (Invariant 1). Emit a `service_started` event (carries `job_id`, `pid`, `pgid`, `name`, `workdir`). Any bookkeeping internal to the service goes here; service loggers already exist in the interpose parent.
- **`run_on_all($activity)`** — the critical hot path. Runs every iteration (not just on interval), so tests flip over without waiting for the interval timer:
  1. If `+current` is set, check whether its collector Handle is done (non-blocking). If so, `log_event` a `job_complete` event, move the job_id from the run's `running` to `done` list, and clear `+current`. If the run is fully done (`pending` and `running` both empty), drop it from `+queue` and emit `run_complete`.
  2. If `+current` is unset AND `+state eq 'running'` (or `'finishing'`) AND `+queue` is non-empty: pick the head run, pull the next pending job, build the per-job output path (`$workdir/runs/$run_id/$job_id/0.jsonl`), launch a Collector with that logger plus the test auditor, with `env_vars => { T2_FORMATTER => 'Stream2', ... }` so tests auto-engage `Test2::Formatter::Stream2`. **The Collector MUST be launched with `parent_pids => [$service_pid]`** (Invariant 2) so the test dies if the service dies. Store the Handle + metadata in `+current`, register the collector pid as a worker.
- **`run_should_end`** — returns true when `+state eq 'terminating'` AND all workers reaped AND `+current` cleared; OR when `+state eq 'finishing'` AND `+queue` is empty AND `+current` is undef AND no registered workers are alive. The "workers reaped" gate is Invariant 1 — we must not exit while descendants could still be running. Also triggers the `finishing` transition when `+finish_after_initial_run` and the initial run is now fully done.
- **`run_on_cleanup`** — final-chance sweep (Invariant 1). Reap any registered workers; if any remain alive after `kill_timeout` of TERM, escalate to KILL on the whole pgroup. Emit `service_stopped`. Service-logger shutdown happens in the interpose parent when the service process exits.
- **`watch_pids`** — returns the `parent_pids` passed in at construction (Invariant 2: the service self-terminates if any watched parent dies). `start()` passes the grandparent pid of the interpose child; `spawn()` passes the top-level spawn-caller pid. `Detach` IPC handler removes a pid from this list at runtime.

### IPC request handlers

`handle_request($req, $msg)` dispatches on `$req->{request}` (or the bare string — will match whatever the role passes; verify during implementation and adjust):

- **`queue_test_run`** — payload `{files => [...], run_id => $opt}`. If `+state ne 'running'`, return `{ok => 0, error => 'service not accepting new runs'}`. Otherwise build a `Run`, push onto `+queue`, emit `run_queued`, return `{ok => 1, run_id => $run->run_id}`.
- **`status`** — no payload. Return the shape below.
- **`finish`** — no payload. If `+state eq 'running'`, set to `'finishing'`, emit `finish_requested`, return `{ok => 1}`. Otherwise `{ok => 0}` (already finishing or terminating).
- **`Terminate`** — no payload. Hard stop, per Invariant 1: set `+state` to `'terminating'`, clear `+queue`, then `kill 'TERM', -$$` (the service's own pgroup, which includes every test collector and their test processes). Reap via `waitpid(-1, WNOHANG)` in a loop for up to `kill_timeout` seconds, then `kill 'KILL', -$$` on any survivors and block-reap the rest. Emit `terminated`. Return `{ok => 1}`. Idempotent — a second `Terminate` returns `{ok => 1}` and retries the pgroup kill for any stragglers.
- **`Detach`** — payload `{pid => $pid}` (Invariant 2). Remove `$pid` from `watch_pids` so the service stops treating that pid's death as a termination trigger. Returns `{ok => 1}`. Used by `Spawn->detach()`; also propagates to the interpose parent so it also stops watching.

### `status` response

```perl
{
    service => {
        name    => 'harness',
        pid     => 12345,
        job_id  => '...',
        workdir => '/path/to/wd',
        state   => 'running',   # or 'finishing' or 'terminating'
    },
    queue => [
        {
            run_id  => '...',
            pending => ['<job_id>', ...],
            running => ['<job_id>', ...],   # 0 or 1 entry
            done    => ['<job_id>', ...],
        },
        ...
    ],
    running => {   # or undef
        run_id    => '...',
        job_id    => '...',
        test_file => 't/foo.t',
        pid       => 23456,
        started   => 1712345678.123,
    },
}
```

This is a first cut; eventually the status view will show the whole yath process tree.

## `Test2::Harness2::Spawn` (parent-side handle)

`Object::HashBase` attributes:

- `<pid` — service pid
- `<ipcm_info` — whatever `ipcm_spawn` produced (route/protocol/serializer)
- `<workdir` — so the parent can inspect logs without asking the service
- `<name` — service name
- `+connection` — lazy `IPC::Manager` client connection to the service
- `+terminate_on_destroy` — default **true**

Methods:

- `queue_test_run(@files)` / `queue_test_run(files => [...], run_id => $opt)` — sends the request, returns the response.
- `status()` — sends the request.
- `finish()` — sends the request.
- `terminate()` — sends the request, then waitpid's the service. Verifies the service pid is gone (Invariant 1, seen from outside); if it is still alive after a grace period, fall back to sending `SIGKILL` directly to the service pid and reaping.
- `wait()` — blocking waitpid on the service pid.
- `detach()` — sends the `Detach` IPC request for the caller's pid (Invariant 2 opt-out), then sets `terminate_on_destroy => 0`. For daemon use cases where the caller wants to exit without killing the service.
- `DESTROY` — if `terminate_on_destroy` is still true and the service pid is still alive, call `terminate()` + `wait()`. If `detach()` was called, do nothing.

## Events emitted by the service

The service uses its own JSONL logger to record lifecycle events. Each event carries the service's `job_id` (no `run_id`). Minimal event types to start:

- `service_started` — pid, name, workdir, time
- `service_stopped` — exit reason, time
- `run_queued` — run_id, files, time
- `run_started` / `run_complete` — run_id, time
- `job_started` / `job_complete` — run_id, job_id, test_file, collector pid, exit status, time
- `finish_requested`, `terminated` — time

Use `Test2::Harness2::Event` as the base class (already exists).

## Testing (`t/unit/Harness2.t`)

Scope: construction, workdir validation, queue/dispatch flow, and both lifecycle invariants. Run a trivial test file (`t/unit/_scratch/ok.t` or inline temp file) end-to-end through `start()` with `test_run => {...}, finish_after_initial_run => 1` and assert:

- Service exits cleanly.
- `$workdir/services/harness.jsonl` exists and contains `service_started`, `run_queued`, `job_started`, `job_complete`, `service_stopped` events.
- `$workdir/runs/$run_id/$job_id/0.jsonl` exists and contains the test's events.
- Error path: constructing with a workdir that already contains `services/` throws.
- `spawn()` round-trip: spawn a service, queue a run via the Spawn handle, poll status until done, call `finish()`, `wait()`.

Invariant 1 (no survivors on hard stop):

- Spawn the service with a long-running test (one that `sleep`s or prints slowly). Capture the test pid and collector pid from `status()`. Call `Terminate`. After the terminate returns, neither pid should be alive (use `kill 0, $pid` to probe).

Invariant 2 (nothing survives its parent):

- Fork a helper process that calls `Test2::Harness2->spawn(...)`, queues a long-running test, and then deliberately `POSIX::_exit`s or is killed with SIGKILL before reaping the service. The parent of the helper then polls for the service pid, interpose parent pid, collector pid, and test pid — all four must become reaped/absent within the `kill_timeout` window.
- Variant: same setup but call `$spawn->detach` first. The helper exits and the service stays alive. The outer parent then calls `terminate()` explicitly to clean up.

Temp workdir via `File::Temp`.

## Open items deferred to implementation

- Exact shape of the `Collector->interpose` call for a long-running service (vs. a one-shot test). May need to pass `parent_pids`/no `launch` variants. Verify against existing `interpose` signature.
- Whether IPC requests are dispatched by `$req->{request}` name or a direct string — look at existing service examples in `IPC::Manager::Service/` during implementation.
- How to ask `IPC::Manager` for a fresh spawn context vs. connecting to an existing one (use `ipcm_spawn` for `spawn()` path, allow explicit `ipcm_info => ...` override for `start()` when the caller already has one).
- Whether `watch_pids` should be the parent pid (caller) or stay empty when the service is intended to outlive its caller (daemon use case). Default: if the caller passes `parent_pids`, watch them; otherwise, watch none.

These are implementation-time decisions, not design changes. They resolve by reading the role and examples at the point where the code is written.
