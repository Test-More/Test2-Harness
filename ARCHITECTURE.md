# Test2::Harness2 Architecture

This document describes the architecture of the `Test2-Harness2` distribution
as it currently exists on the `2.0_rewrite` branch. It is intended for
contributors who need a map of the moving parts before reading code, and as
the canonical reference for design decisions that span more than one module.

## 1. Scope and Responsibilities

### Test2::Harness2

The `Test2::Harness2` namespace is the primary harness runtime. Its job
is to spin up the services and resources needed for tests to execute,
run them, capture their output and final results, and clean up so no
process lingers afterward.

The harness operates on **runs**. A run is an ordered collection of
tests submitted as a single unit of work. The harness:

- Executes runs **sequentially**, in the order they were added.
- Within a run, picks test order with its own scheduler based on
  duration, resource requirements, smoke vs. non-smoke status, and any
  other scheduling metadata attached to the tests.
- Manages services, preloads, resources, and loggers as specified by
  the incoming run and its tests.
- Tracks every process it spawns and guarantees nothing survives the
  run (see section 3 — Invariants 1 and 2).

By the time a run reaches the harness, most decisions are already made.
The caller has declared which preloads, resources, and loggers each
test needs, which formatters to use, and which tests belong to which
run. The harness does not revisit those inputs — its only scheduling
decision is **when** to run each test under the scheduler's
constraints.

### Namespaces in this distribution

`Test2-Harness2` is a single distribution carrying **five top-level
namespaces**, each with its own responsibility:

| Namespace                  | Responsibility                                                                                                                                                                                                                                                                                                                                  |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Test2::Harness2`          | The primary harness runtime. Spins up services and resources, executes runs, captures output and results, cleans up processes. Described above.                                                                                                                                                                                                |
| `Test2::Formatter::Stream2` | The in-test Test2 formatter that serialises events over atomic pipes to the collector. Lives outside the `Test2::Harness2` namespace because it loads inside test processes. See section 8.                                                                                                                                                    |
| `App::Yath2`               | The new application layer. Built on `App::Yath::Script` and `Getopt::Yath`. Turns user input (`yath ...` commands, config files) into requests to start or utilise `Test2::Harness2` services. Handles test discovery, deciding which loggers to attach, assembling runs, starting and stopping harness services, rendering results, and reading or saving log files. |
| `App::Yath2::DB`             | Optional. Defines how to store and reference logs of runs in a database.                                                                                                                                                                                                                                                                        |
| `App::Yath2::UI`             | Optional. A web interface over an `App::Yath2::DB` database.                                                                                                                                                                                                                                                                                      |

There is no separate `yath2` command. The single `yath` script ships
in the `App-Yath-Script` distribution — not a legacy artefact, but a
shared launcher used by both the legacy `Test2-Harness` distribution
(driving `App::Yath`) and this `Test2-Harness2` distribution (driving
`App::Yath2`). It inspects what the user invoked and dispatches to the
appropriate code path.

### Namespace dependency contract

Even though all five namespaces live in this single distribution, the
internal dependencies between them are strictly one-way:

- `Test2::Harness2` **must not** `use`, `require`, or otherwise
  name-reach into any `App::Yath2*` namespace. Classes or objects
  from those namespaces are accepted only when the caller passes them
  in as construction or runtime arguments — at which point the harness
  treats them as opaque Perl objects, not as `App::Yath2*` specifically.
- `App::Yath2`, `App::Yath2::DB`, and `App::Yath2::UI` may freely depend
  on `Test2::Harness2` classes. The harness is their platform.
- Dependencies of `Test2::Harness2`, `Test2::Formatter::Stream2`, and
  `App::Yath2` may be hard-required by the distribution. Nothing
  about the core harness or the new application layer needs to be
  optional on the CPAN-dep side.
- `App::Yath2::DB` and `App::Yath2::UI` are optional at runtime. Running
  `yath` against the `App::Yath2` code path without DB or UI support
  must work. Modules in those two namespaces must not throw
  exceptions about missing dependencies unless the user's
  configuration or command-line options explicitly request a DB or
  UI feature. Any CPAN dep that exists solely for `App::Yath2::DB` or
  `App::Yath2::UI` must be marked optional (Suggests / Recommends) in
  `dist.ini` / the generated `cpanfile`.

This contract keeps the harness usable as a library from contexts
that have nothing to do with `App::Yath2` — custom runners, CI
integrations, and the harness's own test suite.

### Reference trees

The repo also carries three reference trees that are **not** part of
the shipped distribution:

| Path        | Origin                              | Status                  |
|-------------|-------------------------------------|-------------------------|
| `legacy/`   | `yath` 1.0 source                   | Read-only reference     |
| `old/`      | First 2.0 attempt (mostly complete) | Donor code, read-only   |
| `botched/`  | Failed refactor                     | Read-only reference     |

Code is copied wholesale out of these trees as the rewrite catches up;
nothing in `lib/` should `use` anything from them.

## 2. Repository Layout

All five namespaces from section 1 ship as one distribution out of
`lib/`:

```
lib/Test2/Harness2/                harness runtime: service, collector, pipeline
lib/Test2/Harness2.pm
lib/Test2/Formatter/Stream2.pm     in-test formatter that feeds the collector
lib/App/Yath2/                     user-facing application layer (planned)
lib/App/Yath2.pm
lib/App/Yath2/DB/                  optional DB persistence (planned)
lib/App/Yath2/DB.pm
lib/App/Yath2/UI/                  optional web UI over App::Yath2::DB (planned)
lib/App/Yath2/UI.pm

scripts/yath_collector             CLI harness for the Collector alone
t/AI/                              AI-generated tests
t/unit/, t/integration/            human-authored test suite

old/, legacy/, botched/            reference trees (not shipped)
```

"(planned)" marks namespaces whose `lib/` directories do not yet
exist but whose code will land here as the rewrite progresses — they
are part of this distribution by design, not new dists to be spun off.

## 3. Process Model

The harness runs as a **tree of long-lived processes** linked by
`IPC::Manager`. Two invariants govern the tree and are load-bearing — every
shutdown path must honour them.

### Invariant 1 — no survivors on hard stop

When the service is terminated (by `terminate` request, fatal signal, abnormal
exit, or crash), every descendant — collector, test process, anything they
forked — must be killed and reaped before the service exits.

Mechanism: a two-layer process-group discipline.

- The **service** calls `POSIX::setpgid(0, 0)` on `run_on_start`, taking
  ownership of its own pgroup. Per-test collectors inherit that pgroup.
- The **collector's launched test child** calls `POSIX::setpgid(0, 0)` again
  post-fork / pre-exec when the collector was constructed with
  `new_pgroup => 1`. This puts each test in its own fresh pgroup so a test
  doing `kill 'TERM', 0` cannot reach the harness.

Hard-stop sweep (`Test2::Harness2::_perform_hard_stop`):

1. Set state to `terminating` and clear the queue.
2. Build a per-pid signal-state map seeded from `+current` and any registered
   workers.
3. On each iteration: optionally re-enumerate direct children (subreaper
   case), send the first signal (`TERM` on Unix, `INT` on Win32) to fresh
   pids, escalate to `KILL` once `kill_timeout` has elapsed without exit,
   reap with `waitpid(-1, WNOHANG)`, and sleep briefly only if no work
   happened.
4. Exit the loop when every tracked pid is either reaped or has been past its
   `KILL` deadline long enough to be considered unreachable.

The service signals **by pid**, not by pgroup, to avoid signalling itself.

### Invariant 2 — nothing survives its parent

If the service process dies for any reason — including SIGKILL — every
descendant must terminate without help from the service's signal handlers
(which may never run).

Mechanism: every long-lived process the service spawns is launched with
`parent_pids => [...]`. Collectors poll those pids each iteration; when any
listed pid disappears, the collector self-terminates and (via its own
`kill_timeout`) cleans up its test child. This is a chain:

- The interpose parent (service-log collector) watches the spawn caller.
- The service watches the interpose parent (and the spawn caller).
- Each per-test collector watches the service.

`detach` flows down the chain: `Spawn->detach()` issues a `detach` IPC
request to the service which removes the caller pid from `watch_pids_ref`.

### The full tree under `spawn()`

```
caller process                             holds Spawn handle, may exit
  spawn child                              the interpose parent / service-log Collector
    interpose child                        the service loop (Test2::Harness2)
      per-test Collector                   one per running test, at most one in flight today
        test process                       launched by Collector, in its own pgroup
```

Under `start()` the caller becomes the spawn child directly — there is no
extra fork.

### Subreaping

On Linux, when the optional `Test2::Harness2::ChildSubReaper` module is
installed, `run_on_start` enables `PR_SET_CHILD_SUBREAPER` so any descendant
that gets orphaned (test double-forks then exits its parent) reparents to the
service rather than to `init(1)`. That makes the orphan visible to
`waitpid(-1, ...)` and to `list_direct_children($$)` so the hard-stop sweep
can actually reach it. Without the module the harness still works; it just
loses cleanup for detached grandchildren.

## 4. Top-Level Service: `Test2::Harness2`

A single object that consumes `IPC::Manager::Role::Service` and runs an event
loop over an IPC bus. The full source lives in `lib/Test2/Harness2.pm`.

### Construction and entry points

- `new(...)` constructs the object but **does not** start the service loop.
  Direct `new` is discouraged.
- `start(%args)` runs the service in the current process. Steps:
  1. Optionally `ipcm_spawn()` if no `ipcm_info` was passed.
  2. Construct `$self`.
  3. Hand the service loggers to `Collector->interpose`. The interpose parent
     becomes the service-log collector; the interpose child returns to start.
  4. The interpose child wraps STDOUT in an `Atomic::Pipe`, builds an
     `EventEmitter`, queues any initial `test_run`, calls `$self->run`, and
     `POSIX::_exit`s with the result.
  5. Optional `jump_to => $name` parameter unwinds the stack to a matching
     `Long::Jump::setjump` so the service runs from a clean frame.
- `spawn(%args)` runs the service in a child process and returns a
  `Test2::Harness2::Spawn` handle to the caller. The IPC bus is created in
  the caller (with `guard => 0`) so both sides share the same `ipcm_info`.

### Workdir layout

`workdir` is required and must already be a directory. All harness
logging lives under `$workdir/logs/`. The service refuses to start if
`$workdir/logs/` already exists and is non-empty (would mix old logs
with new); other contents of the workdir are tolerated. The service
creates:

```
$workdir/
  logs/
    services/
      <name>.jsonl          service-lifecycle event stream (default name=harness)
      <name>.json           service JSON snapshot (init fields + final verdict)
    runs/
      <run_id>.json         per-run JSON snapshot (written by the harness itself)
      <run_id>/
        <job_id>/
          0.jsonl           per-test event stream
          0.json            per-test JSON snapshot (init + exit + pass/fail)
```

`logs/runs/` and its subdirectories are created lazily as runs and
jobs dispatch. Every `.jsonl` stream has a `.json` sidecar produced
by the `Collector::Logger::JSON` snapshot logger (attached as a
default alongside `Logger::JSONL`). The per-run `<run_id>.json`
sidecar is a stopgap written directly by the harness — the commented
TODO in the code points at a future migration where each run becomes
its own service and owns its own snapshot file.

### Service-loop hooks

`IPC::Manager::Role::Service` drives the lifecycle; `Test2::Harness2`
overrides the relevant callbacks:

- `run_on_start` — `setpgid(0, 0)`, optional subreaper, emit
  `service_started` event.
- `run_on_all($activity)` — runs every iteration. Calls
  `_check_current_completion` (drains a finished collector's exit code,
  marks the job done, emits `job_completed` + possibly `run_ended`,
  rewrites the `<run_id>.json` snapshot, may transition state to
  `finishing`). If no job is in flight and the queue is non-empty and
  state is not `terminating`, builds the next job's log path, emits
  `run_started` when starting a run's first job, emits `job_started`,
  and launches a `Collector` with `new_pgroup => 1`, the test auditor
  + loggers, and an `IPCNotify` logger pointed at the service. Stores
  the handle in `+current` and registers the collector pid as a
  worker.
- `run_on_pid($pid, $exit)` — the IPC loop already reaped the child;
  hand the exit code to the matching collector handle.
- `run_on_general_message($msg)` — recognises two message kinds from
  per-test collectors:
  - `job_complete_notify` (from `Logger::IPCNotify`) — wake-up only;
    receipt itself bumps the event loop.
  - `loggers_ready` (from the collector itself, after all loggers
    have finished `startup()`) — carries `{run_id, job_id, job_try,
    loggers => { ClassName => [{metadata}, ...], ... }}`. The service
    turns this into a `job_loggers` event so downstream consumers
    know which logger instances produced which files / IPC handles.
- `run_should_end` — true once the queue is drained, `+current` is clear,
  and (in `terminating` state) all pids have been reaped.
- `run_on_cleanup` — final hard-stop sweep; emit `service_stopped`.

### IPC request handlers

Dispatch is done in `handle_request` by looking up
`request_handler_<type>`:

| Request           | Payload                       | Effect                                                             |
|-------------------|-------------------------------|--------------------------------------------------------------------|
| `queue_test_run`  | `{files => [...], run_id?}`   | Build a `Run` from files, push onto `+queue`, return `run_id`.     |
| `status`          | none                          | Return the service/queue/running snapshot.                         |
| `finish`          | none                          | Transition `running` → `finishing`; loop drains then exits.        |
| `terminate`       | none                          | Hard stop (Invariant 1). Idempotent.                               |
| `detach`          | `{pid => $pid}`               | Remove pid from `watch_pids_ref` (Invariant 2 opt-out).            |

All requests refuse to queue new work once the service is past `running`.

### `status` response shape

```perl
{
    service => { name, pid, job_id, workdir, state },
    queue   => [ { run_id, pending => [...], running => [...], done => [...] }, ... ],
    running => { run_id, job_id, test_file, pid, started } || undef,
}
```

### Lifecycle events

The service emits a structured event stream through its own
`EventEmitter` (section 9); the events land in
`logs/services/<name>.jsonl` via the service-log collector, and a
final merged snapshot is written to `logs/services/<name>.json` by
`Logger::JSON`. Every event carries a `kind` field and the shapes
below are the fields inside the event's `harness` facet:

| Kind                | When                                                          | Payload                                                                   |
|---------------------|---------------------------------------------------------------|----------------------------------------------------------------------------|
| `service_started`   | `run_on_start`                                                | `pid`, `pgid`, `name`, `workdir`                                           |
| `run_queued`        | `queue_test_run` request                                      | `run_data => $run->TO_JSON`                                                |
| `job_queued`        | once per job inside a newly-queued run                        | `job_data => $job->TO_JSON`                                                |
| `run_started`       | before the first job of a run dispatches                      | `run_data => { run_id }`                                                   |
| `job_started`       | when a per-test collector is launched                         | `job_info => { run_id, job_id, job_try }`                                  |
| `job_loggers`       | on receipt of the collector's `loggers_ready` message         | `job_info`, `loggers => { ClassName => [{metadata}, ...], ... }`           |
| `job_completed`     | when the collector handle reports done                        | `job_info`, `exit` (parsed wait-status), `pass` (0/1)                      |
| `run_ended`         | when a run's last job completes                               | `run_data => { run_id }`                                                   |
| `service_stopped`   | `run_on_cleanup`                                              | none                                                                       |

The service also writes `logs/runs/<run_id>.json` directly (outside
the logger stack) at `run_queued` time and again at `run_ended` time,
using `Util::JSON::write_json_file_atomic`. This is the stopgap
sidecar noted above.

`Test2::Harness2` itself implements `TO_JSON` returning
`{name, job_id, workdir, pid}`.

## 5. Run / Job Model

`Test2::Harness2::Run` and `Test2::Harness2::Run::Job` are plain
`Object::HashBase` value objects.

- `Run` carries a `run_id` (UUID), an ordered `jobs` arrayref, and three
  parallel id lists tracking lifecycle: `pending`, `running`, `done`.
  `mark_running($job_id)` and `mark_done($job_id)` move ids between lists
  and croak on misuse. `is_complete` is true when both `pending` and
  `running` are empty. `TO_JSON` returns a shallow copy of the hash so
  the full run (ids + job list + status) is serialisable into the
  `run_queued` event payload and the per-run JSON sidecar.
- `Run->from_files(files => \@paths, run_id => $opt)` is the only
  expected constructor; it builds one `Job` per path with a shared `run_id`.
- `Run::Job` carries `job_id` (UUID), `test_file` (relative), `test_file_abs`
  (absolute), `job_try` (always `0` for now), and a back-reference `run_id`.
  The constructor accepts either form, classifies inputs by
  `File::Spec::file_name_is_absolute`, and resolves the missing form in the
  caller's CWD at construction time so a later `chdir` does not redirect
  the launch. `TO_JSON` likewise returns a shallow copy of the hash for
  the `job_queued` event and the per-job JSON sidecar.

The current rewrite runs **one job at a time per service** — the loop in
`run_on_all` only dispatches when `+current` is unset.

## 6. Parent-Side Handle: `Test2::Harness2::Spawn`

Returned by `spawn()` to the calling process. Wraps an
`IPC::Manager::Service::Handle` and proxies the IPC request set as ordinary
methods: `queue_test_run`, `status`, `finish`, `terminate`, `detach`, `wait`.

`terminate_on_destroy` is true by default. `DESTROY` runs `terminate` if the
service pid is still alive — leaked background services are a recurring
class of bug, so the safe default is opt-out. `detach` clears the flag.

`queue_test_run` accepts three calling conventions: a plain list of files,
a hashref, or even-length kv args.

## 7. Collector Subsystem

The collector lives in `lib/Test2/Harness2/Collector.pm` (largest module in
the tree). It owns the parent/child fork that captures another process's
output and routes it through a parser → auditor → logger pipeline.

### Three construction interfaces

Every interface forks; the parent becomes the long-lived collector, the
child either runs the launched program or returns to the caller.

| Interface | Constructor key | What it does                                                                 |
|-----------|-----------------|------------------------------------------------------------------------------|
| **A**     | `launch => ...` | Open new pipes for stdout/stderr, fork+exec the launched program in the child. The parent reads the pipes. Captures the child's exit code via `waitpid`. Default for `yath_collector` and the harness service. |
| **B**     | `stdout => $fh`, `stderr => $fh`, `pid => $pid` | Read pre-existing handles for a process the caller already started. Cannot capture exit code; designed to consult IPC for exit later (placeholder comment in code). |
| **C**     | `stdout => $path`, `stderr => $path`, `pid => undef` | Read regular files (or fifos). Completes on EOF. Used to replay output without a live process. |

`Atomic::Pipe` is used in interfaces A and B (mixed-data mode); interface C
uses `Collector::FileLineReader` (an adapter that exposes the same
`read_lines`/`get_line_burst_or_data` shape over a regular filehandle).

### `interpose` — fork that returns to the caller

Class method used by the harness service. The parent becomes a collector
that reads the redirected stdout/stderr and runs them through its
parser/auditor/loggers; it never returns. The child returns from
`interpose` with stdout/stderr remapped to atomic pipes and continues
executing the caller's code. Optional `jump_to`/`jump_payload` parameters
unwind the call stack to a `Long::Jump::setjump` before continuing.

### Parent ↔ child split

After fork:

- **Parent** returns a `Collector::Handle` (just a pid + exit-code slot)
  and, in non-interpose modes, then runs `_run_collector` which never
  returns — it `_exit`s when the child finishes.
- **Child** either `exec`s the launch program, or (for interpose)
  continues with the caller's code.

The handle exposes `is_done` (non-blocking) and `wait` (blocking) so the
service loop and other parents can poll completion without owning a heavy
collector object.

### The four-stage event pipeline

Once `_run_collector` is running, every line of stdout/stderr (or every
JSON message burst from `Stream2`) traverses:

```
raw stdout/stderr line
    -> Parser   (IOParser, IOParser::Stream, TapParser)
        -> Auditor   (Auditor::Test or none)
            -> Loggers   (JSONL, IPCNotify, TestState, ...)
                -> file / IPC bus / wherever
```

#### Parsers

Live under `lib/Test2/Harness2/Collector/Parser/`. They turn raw lines and
message bursts into `Test2::Harness2::Event` objects and stamp every event
with the `harness` facet (`event_id`, `stamp`). Parsers do **not** stamp
`run_id` / `job_id` / `job_try` onto events — that provenance is carried
by the log's on-disk path (`logs/runs/<run_id>/<job_id>/0.jsonl`) and by
the service-level events that bracket each job (`job_started`,
`job_completed`).

- `IOParser` — base. Wraps each line in `from_stream` + `info` facets. No
  protocol parsing.
- `IOParser::Stream` — base + delegates to `TapParser` to recognise TAP,
  falling back to base behaviour on non-TAP lines.
- `TapParser` — stateless regex-based recogniser for TAP constructs
  (`ok`/`not ok`, plans, comments, subtest open/close, `bail out`).

#### Auditors

`Test2::Harness2::Collector::Auditor::Test` consumes the
`Test2::Harness2::Role::Auditor` role. It tracks assertions, plans,
nested subtests (recursively, by spawning sub-auditors), errors, halt
status, and the child's exit code. It may emit synthetic events for
subtest announcements, plan/count mismatches, and recovery from malformed
TAP. `passing()` / `failing()` query its verdict at any time. The role
itself requires `audit_event($event)`, `fail_count()`, `pass_count()`
and provides default no-op `set_process_info` / `set_ipcm_info`.

#### Loggers

Implement `Test2::Harness2::Role::Collector::Logger`. The role supplies
default no-op implementations of all lifecycle hooks; a logger only needs
to override what it cares about.

| Hook                       | When                                               |
|----------------------------|----------------------------------------------------|
| `startup($collector)`      | Once, at child-side init                           |
| `log_event($event)`        | Per event, only if `log_events()` returns true     |
| `failing(1)`               | Once, when auditor flips passing → failing         |
| `shutdown($collector)`     | Once, at child-side teardown                       |
| `metadata()`               | Return a hashref describing this logger instance (file path, fileno, etc.) or `undef` to opt out. Gathered into the `loggers_ready` IPC message and surfaced as a `job_loggers` event. |
| `set_process_info(...)`    | Pass `run_id`/`job_id`/`job_try`/pid in            |
| `set_ipcm_info(...)`       | Hand over the IPC connection info                  |
| `set_auditor($auditor)`    | Give the logger access to the auditor              |
| `set_loggers_lookup(...)`  | Sibling-logger map for cross-references            |
| `depends_on()`             | Names of other loggers that must be present        |

Provided loggers:

- **`Logger::JSONL`** — writes one JSON-encoded event per line to a
  file. Default for both service-lifecycle events and per-test events.
  `metadata` reports `{jsonl_file => $path}` for file-backed instances
  and `{jsonl_fileno => fileno, pid => $pid}` when the caller passed a
  pre-opened handle.
- **`Logger::JSON`** — snapshot logger, also a default wherever
  `Logger::JSONL` is. At `startup` writes the collector's `source`
  (its owner object's `TO_JSON`) to a `.json` file via
  `Util::JSON::write_json_file_atomic`. At `shutdown` atomically
  rewrites that same file with the original fields merged with the
  parsed child `exit` status (read from the collector's
  public `child_exit` accessor) and — when an auditor is attached —
  the `pass`/`fail` verdict. `metadata` reports `{json_file => $path}`.
  Produces `<name>.json` for the service interpose collector and
  `0.json` for every per-job collector. Does not subscribe to events
  (`log_events` returns false).
- **`Logger::IPCNotify`** — sends a `job_complete_notify` IPC message
  from the per-test collector to the service when the test finishes.
  The service's `run_on_general_message` recognises this and uses the
  wake-up to drive `_check_current_completion` immediately, instead of
  waiting for the next `~0.2s` poll tick. `metadata` returns `undef`.
- **`Logger::TestState`** — sends per-test lifecycle messages
  (`test_started`, `test_failing`, `test_completed`) to an IPC peer with
  pass/fail/assertion counts and the JSONL log path. Useful for status
  panels and external monitors. `metadata` returns `undef`.

When all loggers have completed `startup`, the collector calls
`metadata` on each one, gathers the non-`undef` results keyed by
class (multiple instances of the same class accumulate into an
arrayref), and sends a single `loggers_ready` IPC message to its
`ipc_peer` carrying `{run_id, job_id, job_try, loggers => { ... }}`.
The service turns that into a `job_loggers` lifecycle event so later
consumers (UI, DB) can find the logger outputs for a given job by
inspecting the event stream alone.

### Spec normalisation, lazy instantiation

Loggers and auditors are passed as **specs** — class name, `[class, %args]`,
or pre-built instance. The parent normalises specs (loads classes, checks
`DOES()`, resolves `depends_on`) without constructing them, so the parent
process never opens a logger's file handle or IPC socket. The child
instantiates everything inside `_init_event_sinks` once it owns the
descriptors. Every `Collector` family class requires `ipcm_info` to be
present at construction (an `undef` value is allowed but must be passed
explicitly) so callers cannot silently default away the IPC connection.
A per-test collector also requires `ipc_peer` — the service name to
address `loggers_ready` and `job_complete_notify` messages to — and
registers itself on the IPC bus under its own `job_id` so the peer
can identify the sender.

### Stream-ordering buffer

The `Stream2` formatter sends two streams:

- **stdout**: JSON event bursts (atomic) plus any plain stdout the test
  prints itself.
- **stderr**: short JSON sync markers (`{"event_id": "..."}`) followed by
  any plain stderr.

The collector buffers each side until both have produced the matching
sync `event_id`, then flushes in order — so stdout/stderr lines appear
interleaved correctly relative to the events that bracket them. For
processes that never emit JSON (plain text only), the collector flushes
eagerly to avoid stalls.

### IO loop discipline

`_run_collector`'s main `while` loop drives reads through `IO::Select` so
the collector parks when both pipes are idle, instead of busy-spinning on
non-blocking reads. The select timeout (~0.2s) bounds how long the loop
waits before re-checking parent pids and `waitpid(WNOHANG)` on the child.
`Atomic::Pipe` and `FileLineReader` both return `undef` synchronously
when nothing is ready, so without the `select` the outer loop would burn
a CPU core whenever the upstream sat idle; the `select` is what converts
"nothing ready" into a parked wait.

### Signal handling

Installed in `_run_collector`, scoped via `local`:

- `__WARN__` — collector-side warnings are routed through the parser +
  loggers so they end up in the same JSONL log as the test's events.
- `USR1`, `USR2`, `HUP`, `PIPE` — ignored. Tests may use these for their
  own coordination; the collector must survive them.
- `TERM`, `INT`, `QUIT` — set a `$got_signal` latch. The main loop breaks
  after draining remaining output, then `_perform_hard_stop`-style cleanup
  kills the child child and finishes writing the log.

### Exit code mirroring

The collector's own exit code carries one of three signals:

1. **255** if the collector itself failed.
2. **The launched child's `wait()` status** (interface A) — including
   re-raising the same signal the child died from, so the collector's
   exit faithfully mirrors the child. The collector exposes this
   `child_exit` as a public attribute so downstream loggers (notably
   `Logger::JSON`) can read it at shutdown.
3. **The auditor's verdict** (1 fail / 0 pass) when no live child exit is
   available (interface B, interface C).

## 8. The In-Test Formatter: `Test2::Formatter::Stream2`

Lives at `lib/Test2/Formatter/Stream2.pm` (outside the `Test2::Harness2`
namespace because it loads inside test processes).

Tests opt in via `T2_FORMATTER=Stream2` (the harness service sets this in
the per-job env when launching). Stream2:

1. Wraps the test's STDOUT (and STDERR, when separate) as `Atomic::Pipe`s
   in `mixed_data_mode`. The collector child is on the other side of those
   pipes already.
2. Builds a `Test2::Harness2::Util::EventEmitter` over the STDOUT pipe.
3. For each event Test2 hands it: extracts facet data, assigns a
   `stream_id`/`event_id`, and calls `EventEmitter->emit_raw($event)` —
   which JSON-encodes and `write_message`s the event as an atomic burst,
   then writes the matching tiny `{"event_id":"..."}` sync to STDERR (when
   STDERR is separate) so the collector can keep stderr text ordered
   against events.
4. Detects when `Test::Builder`'s stdout/stderr/todo handles have been
   swapped (legacy capture pattern) and routes those events through TB's
   TAP formatter instead — preserving compatibility with old TB-driven
   tests that intercept output.

`T2_HARNESS2_PIPE_COUNT` is set to 1 (merged) or 2 (separate) so Stream2
knows whether STDERR is its own pipe.

## 9. Utility Layer

### `Test2::Harness2::Util`

Small bag of shared helpers: `mod2file`, `apply_encoding` (UTF-8-safe
`binmode` wrapper that avoids known thread bugs), `hub_truth` (extract the
canonical hub/trace facet from a facet_data hash), `parse_exit` (decode
`waitpid` status into `{sig, err, dmp, all}`), and `write_file_atomic`
(write-to-tempfile-then-`rename` for any string payload — the base of
the JSON snapshot writer).

### `Test2::Harness2::Util::EventEmitter`

Standalone JSON-event writer that does **not** depend on Test2::API or
Stream2. Used by the harness service itself to emit the structured
lifecycle events catalogued in section 4 through the same atomic-pipe
protocol the formatter uses, so the service-log collector parses them
with exactly the same `IOParser` it uses for everything else. UUID
generation and `event_id` consistency between the top-level field and
the `harness` facet are guaranteed at emit time. The emitter does
**not** stamp `run_id` / `job_id` / `job_try` — that provenance comes
from the event payload's `run_data` / `job_info` fields and from the
log-file path.

### `Test2::Harness2::Util::IPC`

Low-level process helpers used by the collector and the harness's
hard-stop path:

- `pid_is_running($pid)` — 1 (running, ours), 0 (gone), -1 (running, not
  ours).
- `set_procname(...)` — annotate `$0` so `ps` shows what each collector is
  doing (e.g. `Test2-Harness2-Collector - <pid>`).
- `swap_io($fh, $to)` — redirect a handle to another fd while preserving
  the original fd number.
- **`list_direct_children($parent)`** — enumerate the immediate children
  of `$parent`. On Linux/FreeBSD/DragonFlyBSD prefers `/proc/<pid>/status`
  (parsing `PPid:` or positional field 3); falls back to
  `ps -A -o pid= -o ppid=` elsewhere. Used by `_perform_hard_stop` to
  reach reparented descendants when subreaping is on; pgroups do not
  follow reparenting, so this enumeration is what makes the
  subreaper-orphan cleanup actually fire.

### `Test2::Harness2::Util::JSON`

Thin `Cpanel::JSON::XS` wrapper configured for the project's needs:
UTF-8, `convert_blessed`, `allow_nonref`. Exports `encode_json`,
`encode_pretty_json` (canonical sort for human-facing files),
`decode_json`, file-level `encode_json_file` / `decode_json_file`,
`write_json_file_atomic($path, \%data)` (pretty-printed atomic write
via `Util::write_file_atomic` — used by `Logger::JSON` and by the
harness's per-run sidecar), and `json_true` / `json_false` boolean
values.

### `Test2::Harness2::Event`

The single event class everything emits. `Object::HashBase` attributes:
`facet_data`, `stream_id`, `event_id` (required), `stamp`. `as_json`
caches the encoded form; `TO_JSON` deep-copies `facet_data` to avoid
serialisation surprises.

## 10. Wire Protocols

### Atomic-pipe message format (formatter / EventEmitter → collector)

`Atomic::Pipe` in mixed-data mode interleaves two kinds of payloads on
the same pipe without corruption:

- **Plain text lines** — anything the test or service prints with normal
  `print`/`say`. Read by the collector as `[line => $text]`.
- **JSON message bursts** — written via `write_message`, read by the
  collector as `[message => $decoded]`. Each is a single Test2 event
  hashref.

### Per-test logs (`logs/runs/<run_id>/<job_id>/0.{jsonl,json}`)

The `0.jsonl` file holds one JSON-encoded `Test2::Harness2::Event` per
line — the full event stream from the test. Every event carries the
`harness` facet with `event_id` and `stamp`; `run_id` / `job_id` /
`job_try` are **not** stamped onto events and come from the file path
instead.

The `0.json` sidecar is a single JSON document written by
`Logger::JSON`. At the collector's `startup` it contains the source
object's `TO_JSON` snapshot (for a per-test collector, the `Run::Job`
fields); at `shutdown` it is atomically rewritten with those same
fields plus `exit` (parsed from `child_exit`) and, when an auditor is
attached, `pass` (0/1).

### Per-run snapshot (`logs/runs/<run_id>.json`)

A single JSON document written directly by the harness (not by a
logger) via `Util::JSON::write_json_file_atomic`. Rewritten twice:
once at `run_queued` time with the initial `Run->TO_JSON`, and once
at `run_ended` time with the final state (all jobs moved to `done`).
Marked TODO in the code — the intent is to retire this in favour of
a future "run as a service" model where each run's own JSON logger
owns its snapshot file.

### Service logs (`logs/services/<name>.{jsonl,json}`)

Same JSONL shape as per-test logs, but the events are the service's
own lifecycle records (section 4). They carry the service's `job_id`
(set at construction) and no `run_id` — per-run and per-job IDs ride
inside the event payload's `run_data` / `job_info` fields instead.

A `<name>.json` sidecar is also written by `Logger::JSON` attached
to the service-log collector: startup snapshot uses the harness's
`TO_JSON` (`{name, job_id, workdir, pid}`), shutdown merges in the
final exit status.

### IPC requests

Synchronous request/response over `IPC::Manager`. The Spawn handle wraps
each call as `{ request => $name, ...payload }`. Dispatch on the service
side is `request_handler_<name>`; unknown names return
`{ ok => 0, error => "unknown request '<name>'" }`. Responses are plain
hashrefs returned by the handler.

### IPC general messages

Asynchronous fire-and-forget. Currently used message kinds:

- `{kind => 'job_complete_notify', ...}` — from `Logger::IPCNotify`
  on every per-test collector to the service, used purely as a
  wake-up signal. Receipt itself bumps the service's event loop, and
  the next `run_on_all` iteration drains the completed collector.
- `{kind => 'loggers_ready', run_id, job_id, job_try, loggers => {...}}`
  — from a per-test collector to the service once every logger has
  finished `startup`. `loggers` maps logger class names to arrayrefs
  of that class's `metadata()` hashrefs. The service emits a
  `job_loggers` lifecycle event carrying the payload.

Both messages are addressed to the collector's `ipc_peer` (the
service name). Senders register on the IPC bus under their own
`job_id` so the peer can identify the sender.

## 11. External Dependencies

The shipped runtime depends on a small set of foundational modules from
the same author/ecosystem:

| Module                            | Role                                                   |
|-----------------------------------|--------------------------------------------------------|
| `IPC::Manager`                    | Service framework, role, transport, message envelopes  |
| `Atomic::Pipe`                    | Mixed-data pipes for formatter ↔ collector             |
| `Object::HashBase`                | Object/attribute base class for everything             |
| `Role::Tiny` / `Role::Tiny::With` | Role composition                                       |
| `Long::Jump`                      | Stack-clearing jump for `start(jump_to => ...)`        |
| `Test2::Util::UUID`               | UUID generation                                        |
| `Cpanel::JSON::XS`                | JSON                                                   |
| `Test2::API` and friends          | The Test2 event model the harness consumes             |
| `App::Yath::Script`, `Getopt::Yath` | Used by the `App::Yath2` namespace                   |

Optional dependencies, gated by `HAS_*` constants and loaded lazily:

| Module                            | Platform   | Used for                                              |
|-----------------------------------|------------|-------------------------------------------------------|
| `Test2::Harness2::ChildSubReaper` | Linux      | `PR_SET_CHILD_SUBREAPER` for orphan reparenting       |
| `Win32::Job` (or `Win32::Process`) | Windows   | Job-object isolation when collector wants `new_pgroup` |

The **`cpanfile`** in the repo is generated from `dist.ini` and
includes some leftovers from `yath` 1.0 as well as deps used only by
the `App::Yath2::DB` / `App::Yath2::UI` namespaces (DBI, DBIx::Class::*,
Plack, Email, XML, etc.). The DB / UI deps must be marked optional
per the namespace dependency contract in section 1; deps used by
`Test2::Harness2`, `Test2::Formatter::Stream2`, or `App::Yath2` may
remain hard requirements.

## 12. Coding Conventions

The conventions that shape the shape of the code in `lib/`:

- `Object::HashBase` for objects, `Role::Tiny` / `Role::Tiny::With` for
  roles, `parent` (not `base`) for inheritance.
- `Carp::croak` for user-facing errors; `die` for internal re-throws;
  never silently discard exceptions. The only exceptions are `viable()`
  feature-detection methods and optional-module loading where failure is
  expected.
- The eval pattern is always `my $ok = eval { ...; 1 }; my $err = $@;`
  for if/else branching. Short single-line evals use the postfix or
  inline form (`warn $@ unless eval { ...; 1 }`). A multi-line eval block
  must never appear inside the parens of a conditional.
- `//=` for defaults. `use constant` (not package vars) for "is module
  installed" gating.
- `my $pid = fork // die "fork: $!"` — fork failure is always `die`,
  never `croak`, and never a separate conditional after the fork.
- `push @target => @values` — fat comma to visually separate destination
  from values.
- Single-statement conditional blocks use postfix form
  (`do_thing() if $cond`); multi-statement blocks keep the block form.
- One commit per change; amend only to fix bugs in unpushed commits.
- No trailing whitespace, no emojis, perltidy applied (config in
  `.perltidyrc`).

## 13. Test Suite

`t/unit/` holds focused tests for individual modules (`Collector.t`,
`Auditor/Test.t`, parsers, loggers, run/job, util/IPC, util/JSON,
formatters, etc.). `t/integration/` holds end-to-end tests that exercise
the service through `start()` or `spawn()`:

- `harness2_start.t` — single-process service start path.
- `harness2_spawn.t` — daemon spawn path with `Spawn` handle.
- `harness2_lifecycle.t` — terminate/finish/detach behaviours, both
  invariants.
- `harness2_ipc_notify.t` — verifies `IPCNotify` wakes the service loop
  on test completion.

Canonical runner is `perl -Ilib scripts/yath test -D -j24 [files...]`.
Verbose runs drop `-j24`.

### Authorship layout

`t/` is partitioned by who originally wrote the test:

- **`t/AI/`** — tests generated entirely by AI live here, in any
  subdirectory layout that mirrors the rest of `t/`.
- **All other `t/` locations** — reserved for tests originally written
  by humans. AI may modify these tests later as long as they remain
  clear and readable.
- Tests copied into `t/` from `old/` or `legacy/` count as
  human-authored (those trees were originally authored by humans) and
  do **not** need to live under `t/AI/`.

The split lets reviewers know what level of human design went into a
test up front, without changing how the suite is run.
