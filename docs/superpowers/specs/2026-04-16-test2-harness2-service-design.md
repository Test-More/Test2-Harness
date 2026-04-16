# Test2::Harness2 Service — Design

**Date:** 2026-04-16
**Branch:** 2.0_rewrite
**Stub:** `lib/Test2/Harness2.pm` (design comments, to be replaced)

## Purpose

`Test2::Harness2` is the top-level harness service. It owns a workdir, accepts test-run requests over IPC, and dispatches one test at a time to a `Test2::Harness2::Collector`. It emits structured events about its own lifecycle to a JSONL log under the workdir, and each test's events go to their own JSONL log keyed by run_id/job_id.

This spec implements only what the stub comments ask for. Feature parity with `old/lib` (scheduler, retries, isolation, concurrency, preload, etc.) is a future concern.

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

1. Validate args.
2. Call `Collector->interpose(loggers => $service_loggers, parser => 'Test2::Harness2::Collector::Parser::IOParser', parent_pids => [$$, ...])`. The parent process becomes the service-log collector.
3. In the child (returned from interpose), `new(%args)`, queue the initial `test_run` if given (setting `+finish_after_initial_run` if requested), and call `$self->run`. Exit with the service loop's exit code. The interpose parent reaps and exits in lockstep.

**`Test2::Harness2->spawn(%args)`** — service runs in a new process:

Accepts the same args as `start()`, plus IPC spawn info.

1. Use `IPC::Manager::ipcm_spawn(...)` to allocate route/protocol/serializer.
2. `fork`. The top-level parent constructs a `Test2::Harness2::Spawn` handle with the child pid + ipcm_info and returns it to the caller. The top-level child runs the same interpose + `run` path as `start()`, then exits.

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

- **`run_on_start`** — emit a `service_started` event (carries `job_id`, `pid`, `name`, `workdir`). Any bookkeeping internal to the service goes here; service loggers already exist in the interpose parent.
- **`run_on_all($activity)`** — the critical hot path. Runs every iteration (not just on interval), so tests flip over without waiting for the interval timer:
  1. If `+current` is set, check whether its collector Handle is done (non-blocking). If so, `log_event` a `job_complete` event, move the job_id from the run's `running` to `done` list, and clear `+current`. If the run is fully done (`pending` and `running` both empty), drop it from `+queue` and emit `run_complete`.
  2. If `+current` is unset AND `+state eq 'running'` (or `'finishing'`) AND `+queue` is non-empty: pick the head run, pull the next pending job, build the per-job output path (`$workdir/runs/$run_id/$job_id/0.jsonl`), launch a Collector with that logger plus the test auditor, with `env_vars => { T2_FORMATTER => 'Stream2', ... }` so tests auto-engage `Test2::Formatter::Stream2`. Store the Handle + metadata in `+current`, register the collector pid as a worker.
- **`run_should_end`** — returns true when `+state eq 'terminating'`, OR when `+state eq 'finishing'` AND `+queue` is empty AND `+current` is undef. Also true if `+finish_after_initial_run` and the initial run is now fully done — implemented by flipping `+state` to `'finishing'` when that run completes.
- **`run_on_cleanup`** — waitpid any remaining workers (test collectors), emit `service_stopped`. Service-logger shutdown happens in the interpose parent when the service process exits.
- **`watch_pids`** — returns the parent pid(s) passed in (so the service exits if the parent dies, matching Collector's model).

### IPC request handlers

`handle_request($req, $msg)` dispatches on `$req->{request}` (or the bare string — will match whatever the role passes; verify during implementation and adjust):

- **`queue_test_run`** — payload `{files => [...], run_id => $opt}`. If `+state ne 'running'`, return `{ok => 0, error => 'service not accepting new runs'}`. Otherwise build a `Run`, push onto `+queue`, emit `run_queued`, return `{ok => 1, run_id => $run->run_id}`.
- **`status`** — no payload. Return the shape below.
- **`finish`** — no payload. If `+state eq 'running'`, set to `'finishing'`, emit `finish_requested`, return `{ok => 1}`. Otherwise `{ok => 0}` (already finishing or terminating).
- **`Terminate`** — no payload. Set `+state` to `'terminating'`. If `+current`, kill its collector (SIGTERM, then SIGKILL after `kill_timeout`) and waitpid it. Clear `+queue`. Emit `terminated`. Return `{ok => 1}`. Idempotent — a second `Terminate` just returns `{ok => 1}` again.

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
- `terminate()` — sends the request, then waitpid's the service.
- `wait()` — blocking waitpid on the service pid.
- `detach()` — sets `terminate_on_destroy => 0`. For daemon use cases where the caller wants to exit without killing the service.
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

Scope: construction, workdir validation, queue/dispatch flow. Run a trivial test file (`t/unit/_scratch/ok.t` or inline temp file) end-to-end through `start()` with `test_run => {...}, finish_after_initial_run => 1` and assert:

- Service exits cleanly.
- `$workdir/services/harness.jsonl` exists and contains `service_started`, `run_queued`, `job_started`, `job_complete`, `service_stopped` events.
- `$workdir/runs/$run_id/$job_id/0.jsonl` exists and contains the test's events.
- Error path: constructing with a workdir that already contains `services/` throws.
- `spawn()` round-trip: spawn a service, queue a run via the Spawn handle, poll status until done, call `finish()`, `wait()`.

Temp workdir via `File::Temp`.

## Open items deferred to implementation

- Exact shape of the `Collector->interpose` call for a long-running service (vs. a one-shot test). May need to pass `parent_pids`/no `launch` variants. Verify against existing `interpose` signature.
- Whether IPC requests are dispatched by `$req->{request}` name or a direct string — look at existing service examples in `IPC::Manager::Service/` during implementation.
- How to ask `IPC::Manager` for a fresh spawn context vs. connecting to an existing one (use `ipcm_spawn` for `spawn()` path, allow explicit `ipcm_info => ...` override for `start()` when the caller already has one).
- Whether `watch_pids` should be the parent pid (caller) or stay empty when the service is intended to outlive its caller (daemon use case). Default: if the caller passes `parent_pids`, watch them; otherwise, watch none.

These are implementation-time decisions, not design changes. They resolve by reading the role and examples at the point where the code is written.
