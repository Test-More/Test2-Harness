# Test2::Harness2 Architecture

This document is the single authoritative description of the yath 2.0
rewrite: the process tree, the IPC protocol, the collector and logger
pipelines, the preload-as-resource model, and the module layout that
implements it all. Any stage in `PLAN` that touches the harness
service, a run service, a resource service, a preload service, a
test-job collector, an artifact-producing logger, or a renderer must
honour what is described here.

It is organised in two parts:

- **Part I — Specification (§1–§15).** Protocol, topology, and
  lifecycle semantics. Process-independent: describes *what* the
  system does and *how* the pieces talk to each other.
- **Part II — Implementation map (§16–§26).** Code-level
  reference: namespaces, module responsibilities, on-disk layout,
  utility helpers, conventions, and the test suite.

Companion: `PLAN` — stage-by-stage implementation backlog.

---

# Part I — Specification

## 1. Terminology

- **Command** — the user-facing `yath …` process. `yath test`, `yath start`,
  `yath run` are all commands. Commands are the root of the process tree.
- **Harness service** — the `Test2::Harness2` service process. Exactly one
  per harness invocation. Owns scheduling, global resources, run services.
- **Run service** — `Test2::Harness2::RunService`. One per queued run.
  Owns run-scoped resources, test-job scheduling within the run, and
  per-run aggregation.
- **Resource service** — service wrapping a `Test2::Harness2::Role::Resource`
  that chose to run out-of-process. May be global (spawned by the harness)
  or run-scoped (spawned by a run service).
- **Preload resource** — a `Test2::Harness2::Role::Resource` implementation
  that, when active, runs out-of-process and spawns a preload service
  subtree. Preload is **just another resource** — it can be attached
  to the harness as a global resource, or to a specific run as a
  run-scoped resource, exactly like any other resource type.
- **Preload service** — the root preload service that a preload
  resource starts. Inside, it forks a tree of **preload stage**
  services; every node in the tree is a service. See §10.
- **Test-job collector** — `Test2::Harness2::Collector` in its test-job
  role. Interposes on a test process's stdio, parses events, runs an
  auditor, runs configured loggers. Every test job has one.
- **Service collector** — a `Test2::Harness2::Collector` in interpose-on-
  service-process mode. Every service above runs under its own interpose
  collector. Service collectors do not have an auditor. They do have
  loggers when the harness is configured for them.
- **IPC identity** — the name a process registers on the `IPC::Manager`
  bus. Uniquely addresses a sender/receiver.
- **Artifact** — anything a logger produces: a file path, a database row,
  a POST to an HTTP endpoint, etc. Artifacts are discoverable via IPC
  announcements.
- **Event** — a framed structured record flowing through a collector's
  parser pipeline. Test processes emit events via Stream2. Services
  emit events via a direct framed write to their own stdout (see §7).

## 2. Process topology & IPC parentage

```
command process  (yath test / yath start / yath run …)
 └── harness service  (interposed by its service collector)
      ├── global resource services   (each interposed by a service collector)
      │    └── a Preload resource (if configured as global) is just
      │        another global resource service here; it in turn spawns
      │        a preload service subtree — see §10.
      ├── run service  (interposed by a service collector)
      │    ├── run-scoped resource services   (each interposed)
      │    │    └── a Preload resource (if configured as run-scoped)
      │    │        is just another run-scoped resource service here;
      │    │        same preload service subtree.
      │    └── test-job collectors   (interpose their test process)   — the direct path when the test does not need a preload stage; otherwise a preload stage spawns the test-job collector itself.
      └── (repeat run service subtree per concurrent run)
```

Preloads are never a separate entity alongside resources; they **are**
resources that happen to bring a service subtree with them. Anywhere
below that says "preload resource", treat it as "a resource service
whose resource class is a preload".

Every collector has **three** IPC identities it may need to send to:

| Key                | Meaning                                                   | Who it points at                                      |
|--------------------|-----------------------------------------------------------|-------------------------------------------------------|
| `ipc_harness`      | Canonical harness service bus name                        | Always the harness (passed down, never hardcoded)     |
| `ipc_run`          | Run service bus name for the collector's run (if any)     | The run service = `run_id`                            |
| `ipc_parent`       | The immediate parent service that spawned this collector  | Usually the run service; a preload stage when preloads; the command's handle for the harness's own service collector |

Notes:

- `ipc_parent` always points at the parent **service**, never at a
  collector. Collectors do not receive IPC; only services do.
- Without preloads, `ipc_parent` and `ipc_run` are the same bus name for
  a test-job collector. With preloads, `ipc_parent` points at the preload
  stage that forked the test; `ipc_run` still points at the run service.
- The harness service is the top of the tree. Its `ipc_parent` is the
  command process's handle identity (see §3). Its `ipc_run` is
  undefined; its `ipc_harness` is itself.
- Resource services and preload services follow the same rules: their
  collectors know about `ipc_harness`, know about `ipc_run` when the
  resource/preload is run-scoped, and have `ipc_parent` pointing at
  whichever service spawned them (harness for globals; run for run-scoped).

## 3. Command ↔ harness handshake

1. The command initialises `IPC::Manager` **before** constructing the
   harness. The command's IPC identity is `<command-name>-<pid>` —
   e.g. `yath-test-12345`, `yath-start-12345`, `yath-run-12345`.
2. The command creates the workdir (see §11) and hands it, along with
   `ipcm_info` and (optionally) a configured logs directory name and
   harness service name, into the harness constructor.
3. The command spawns the harness. Spawning returns a handle whose IPC
   identity is the command's bus name. The harness accepts this as its
   own `ipc_parent`. The harness's interpose collector also uses this
   identity as its `ipc_parent`.
4. The command uses the handle to send requests (queue run, stop after
   queued, status, run_status, etc.) and to receive IPC events that
   the harness forwards to it.
5. The command is reachable on the IPC bus under its `<command>-<pid>`
   identity. That identity is how the harness addresses it for
   unsolicited messages (artifact announcements forwarded up, aggregate
   results from the run, final pass/fail summary, etc.).

The harness **does not vivify its own IPC bus.** If `ipcm_info` is
missing from construction, construction fails.

## 4. Run queueing and lifecycle

Runs can be queued via two channels:

- **At construction**, as a `runs => [ {files => [...], …}, … ]` list
  passed to the harness constructor. The harness enqueues these in
  order at startup before accepting IPC.
- **Via IPC**, as a `queue_run` (or `queue_test_run`) request from the
  command to the harness. The response carries the `run_id`.

### "No more runs are coming" signal

Two equivalent forms, pick the one that fits the context:

- **Construction flag**: `finish_after_queued => 1` (or the previously
  equivalent `finish_after_initial_run`; rename during the upcoming
  refactor). Effect: once every run queued at construction completes,
  the harness enters `finishing` state. No IPC response (there's no
  channel at construction time).
- **IPC request**: `finish_after_queued` kind, sent from the command
  to the harness. Harness acks immediately with `{ok => 1}`. Effect:
  the harness enters `finishing` state once the currently-queued set
  drains.

If a command queues a new run AFTER a `finish_after_queued` signal has
been processed, the harness rejects the queue request with an
informative error. The signal is one-way; to submit more runs, the
caller must spawn a new harness.

## 5. IPC communication rules

### 5.1 Service ↔ service

Services can exchange either **messages** (fire-and-forget) or
**requests** (synchronous, response expected):

- **Informational messages** are fire-and-forget. Use when the sender
  must not block. Artifact announcements, test-job-complete
  notifications from run→harness, per-run aggregate results at run
  end, etc.
- **Important operational requests** use requests with an ack + a
  timeout. Starting a test is the canonical example: harness sends
  `launch_job` to the run service (or to a preload stage), expects
  an ack within a bounded time.

### 5.2 Timeout handling for operational requests

If an operational request times out (the ack never arrives in time):

1. The sender marks the operation as **deferred** (e.g. the harness
   puts the job back into its scheduling pool).
2. It retries after a back-off interval, with a fresh request.
3. **Reconciliation on late ack / late start notification:** if a
   late confirmation arrives *after* the sender has already deferred
   — for example, the run service sends a `test_process_start`
   notification (the test actually did start, the ack was just
   slow) — the sender:
   - Logs an IPC warning so the root cause (slow bus, noisy peer,
     dropped packet) can be investigated.
   - Marks the target as **started** regardless; the world is already
     in that state and it would be worse to launch a duplicate.

This makes the system tolerant of transient bus problems without
inventing phantom tests or hanging on a single slow ack.

### 5.3 Collector → service

- Collectors only **send** messages. They never receive.
- Collectors only send **messages** (not requests). Nothing the
  collector does should depend on receiving a response; its lifecycle
  is independent of the service layer's availability.
- Collectors send upward — to `ipc_parent`, `ipc_run`, or
  `ipc_harness` — never downward to whatever the collector is
  monitoring.
- **A collector must not outlive the service that spawned it.** Send
  failures (including EPIPE / "Disconnected pipe") are genuine
  errors: they indicate either a shutdown ordering bug or a crashed
  peer. They should surface as warnings so the underlying problem
  can be investigated, not be silently suppressed.

### 5.4 IPC identity rules

**Maximum length.** IDs on the IPC-Manager bus are limited to
varchar(512) on some transport protocols; every identity defined
in this document must stay well under that cap. Implementations
should refuse to register identities longer than 512 characters.

- **Services need purpose-shaped identities.** Run services use the
  `run_id` directly as their bus name. Resource services derive
  their name from the resource class and the service method that
  started them (see §9). The harness uses `harness` **by default**
  but that name is passed through from the command — downstream
  clients must not hardcode it.
- **Collectors are addressed by the service they interpose.** The
  canonical format is:
    - `collector:<service_name>` for a collector attached to a
      service that is not itself run-scoped (harness, global
      resources, global-scope preload stages).
    - `collector:<service_name>:<run_id>` for a collector attached
      to a service that lives under a specific run (the run
      service's own collector, run-scoped resource-service
      collectors, run-scoped preload stage collectors, test-job
      collectors launched under a run).
  The `<service_name>` is the same name the interposed service
  registered on the bus. This makes the collector's identity
  self-describing ("I'm the collector for service X, in run Y")
  without needing a separate lookup.
- Preload stage services use `<stage_name>` when the stage belongs
  to a global preload, and `<stage_name>:<run_id>` when the stage
  belongs to a run's preload. This disambiguates a per-run override
  of a global stage name. Their collectors follow the
  `collector:<stage_name>` / `collector:<stage_name>:<run_id>`
  convention above.

## 6. Event framing and the service echo-to-collector contract

### 6.1 How a collector sees its child's output

Collectors interpose on their child process's stdout and stderr by
replacing those handles with **mixed-mode `Atomic::Pipe`s**.
Mixed-mode means the same pipe carries two kinds of traffic:

- **Raw text** — ordinary `print`, `warn`, or `printf` output from
  the child. The collector's parser turns it into STDOUT / STDERR
  events.
- **Framed event bursts** — structured events written through the
  Atomic::Pipe's data-burst API. The collector's parser decodes
  each burst into an event directly (no line-parsing).

Both kinds coexist cleanly on the same pipe, so a child that
mostly prints text but occasionally wants to emit a structured
event does not need a second channel.

**STDOUT event bursts are always paired with a STDERR sync
burst.** Every time the producer emits an event on STDOUT it also
writes a small sync record on STDERR so the collector can
synchronise the two streams and keep interleaved raw STDOUT /
STDERR output in the same relative order as the events. This is
the same contract `Test2::Formatter::Stream2` already honours for
test processes; it applies equally to service event emission.

### 6.2 Who emits events

- **Test processes** use `Test2::Formatter::Stream2`. The test-job
  collector sets `T2_FORMATTER=Stream2` in the test's environment;
  `Test2::API` then uses Stream2 to write each `Test2::Event`
  through the pipe's burst API in the shared frame format.
- **Services** (harness, run, resource, preload) do **not** use
  Stream2. Stream2 is Test2-framework-specific and only belongs
  inside a test process. Services emit events via a small
  service-side helper library that calls the same Atomic::Pipe
  burst API with the same on-wire frame. The library is the
  recommended wrapper around "open my stdout and stderr as
  mixed-mode Atomic::Pipe write ends, hand me events, I frame
  and burst them — and drop the sync marker on stderr for each
  stdout event so the collector can order everything correctly."
- The **wire frame is identical** between Stream2 and the service
  emitter so a single collector parser consumes both. Only the
  producer is different.

### 6.3 Every service echoes its received IPC as an event

**Every service** — not only the run service — echoes every IPC
message it receives into its own stdout as a framed event burst
(using the service emitter library from §6.2). The service's
interpose collector then parses the burst through the same
pipeline test-job collectors use, and the event flows out through
that collector's loggers, auditors (test-only, N/A here), and
upward-facing announcements.

The event envelope places the echoed-IPC information **inside the
`harness` facet**, not as a top-level facet:

- **Recognised kinds** (the ones defined in this document) get a
  kind-specific slot under `harness`. Examples:
  - `{ harness => { test_job_started   => { run_id, job_id, job_try, pid, started_at } } }`
  - `{ harness => { test_job_completed => { run_id, job_id, job_try, pass, exit, started_at, ended_at } } }`
  - `{ harness => { collector_artifacts => { collector_id, loggers => {...} } } }` (see §8)
  - `{ harness => { run_complete => { run_id, pass_count, fail_count, duration, jobs => [...] } } }`
- **Unrecognised kinds** — messages the service received but does
  not have a registered slot for — go under `ipc_received` on the
  same facet: `{ harness => { ipc_received => \%original_payload } }`.
  Every incoming IPC is observable in the log, even when its
  `kind` is not one this document defines.

Keeping the harness-produced observations under the `harness`
facet mirrors how per-job events carry their harness metadata
inside a `harness` facet already, so a single consumer can ask
"what harness-layer information is in this event?" without
juggling multiple top-level keys.

## 7. Lifecycle messages

These are the named kinds all services need to recognise and
facet-decode when received. The "From → To" column describes the
direct IPC path.

| Kind                        | From              | To            | Shape                                                |
|-----------------------------|-------------------|---------------|------------------------------------------------------|
| `collector_started`         | any collector     | `ipc_parent`  | run_id?, job_id, collector_id, stamp                 |
| `collector_artifacts`       | any collector     | `ipc_run` if set, else `ipc_harness` | `loggers => { Class => [ {instance_1_artifacts}, {instance_2_artifacts}, … ] }` |
| `collector_exiting`         | any collector     | `ipc_parent`  | run_id?, job_id, exit, stamp                         |
| `test_job_started`          | test-job collector| `ipc_run`     | run_id, job_id, job_try, started_at, pid             |
| `test_job_completed`        | test-job collector| `ipc_run`     | run_id, job_id, job_try, pass, exit, started_at, ended_at |
| `test_job_completed`        | run service       | `ipc_harness` | same shape, forwarded — so the harness scheduler can free resources and the command's IPC stream has both per-run and global views |
| `run_started`               | run service       | `ipc_harness` | run_id, started_at                                   |
| `run_complete`              | run service       | `ipc_harness` | run_id, pass_count, fail_count, duration, [{job_id, pass, exit, started_at, ended_at}, …] |
| `launch_job` (request)      | harness           | run or stage  | run_id, job_id, job_try, test_file, env, loggers, auditor |
| `launched_job`              | run or stage      | harness       | run_id, job_id, job_try, pid — the post-launch notification; name mirrors the `launch_job` request that prompted it. May arrive after a launch_job ack timeout; see §5.2 |

Forwarding rule for `test_job_completed`:

1. Test-job collector sends to its run service.
2. Run service echoes the received IPC into its own event stream
   (see §6) so its log reflects the message.
3. Run service forwards the same payload to the harness.
4. Harness echoes the received IPC into its own event stream.

This keeps the "all state flows via IPC" invariant while also giving
the harness scheduler the per-job completion signal it uses to free
resources and advance scheduling.

### Collector ID

Every collector identifies itself via the `collector:<service_name>`
/ `collector:<service_name>:<run_id>` convention defined in §5.4.
That identity appears as the `collector_id` field on lifecycle
messages so receiving services can correlate `collector_started`,
`collector_artifacts`, and `collector_exiting` from the same
collector without any separate lookup.

## 8. Artifact announcements

### 8.1 Shape

```
{
  kind    => 'collector_artifacts',
  run_id  => $run_id,                        # optional (omit when the collector is global)
  job_id  => $job_id,                        # always present
  loggers => {
      'Test2::Harness2::Collector::Logger::JSONL' => [
          { output_file => '/abs/path/harness.jsonl' },
      ],
      'App::Yath2::Logger::SomeOther' => [
          { output_file => '/abs/path/other-0.log' },
          { output_file => '/abs/path/other-1.log' },  # two instances of the same class
      ],
      'App::Yath2::Logger::DB' => [
          { uri => 'postgres://.../runs/42' },          # not all artifacts are files
      ],
  },
}
```

- Outer hash keys are **logger classes**.
- Values are **arrays** of per-instance artifact hashes; a collector
  may have multiple instances of the same logger class with different
  configuration, so the key is one-to-many.
- Each artifact hash is free-form but must identify the artifact
  uniquely enough for a consumer to locate it. Common fields:
  `output_file`, `uri`, `table`, `topic`, etc.

### 8.2 Timing

- A `collector_artifacts` message is sent **at startup**, after the
  collector has instantiated all its loggers and each logger has
  resolved its final locators (opened its file, established its DB
  connection, …).
- If a logger produces a **new** artifact mid-run (rotation, a
  per-retry file, a lazily-created uploader), the collector re-sends
  a `collector_artifacts` message listing the new artifact(s). The
  receiving service treats successive announcements as additive,
  not replacing — each announcement is "here are additional
  artifacts I now own."

### 8.3 Routing

Artifact announcements do **not** travel up through
`ipc_parent` — the intermediate parent (a preload stage, a
resource service) has no use for them and wouldn't know what to
do with the payload. Every `collector_artifacts` message is
addressed directly at the aggregator that actually needs it:

- If the collector has an `ipc_run` (i.e. it is associated with a
  run — test-job, run-scoped resource, any preload stage inside a
  run-scoped preload tree, the run service's own interpose
  collector) → send to `ipc_run`. The run service then forwards
  an aggregated view to the harness at run end (see `run_complete`
  in §7).
- Otherwise (no run context — harness's own interpose collector,
  global resource services, any preload stage inside a **global**
  preload tree) → send to `ipc_harness`.

This is a direct point-to-point announcement, not a tree walk.
The preload propagation rules of §10 concern lifecycle signals
(child stage exiting, subtree pruning); artifact announcements
short-circuit straight to the aggregator.

The goal: **every announcement made by any collector anywhere in
the tree lands at either the run service (when run-scoped) or the
harness (when global), once.** Renderers only query those two
services (see §13), so those two must see everything.

## 9. Resources and resource-supporting services

### 9.1 What a resource is

A **resource** is a class that consumes
`Test2::Harness2::Role::Resource`. The role's concrete obligations
(`available`, `assign`, `release`, `status`) are pure in-process
methods — they answer questions ("is there a slot free?"), they
mutate the resource's own state ("mark this slot taken"), and
they return lightweight structured answers. Nothing about the
role itself requires a service to exist. `JobCount` is the
canonical example: it runs entirely inside the harness's memory,
with no out-of-process helper.

A resource may be **global** (installed on the harness) or
**run-scoped** (installed on a specific run). That scope is not a
property of the class — it is a property of where the resource
instance is attached. The same resource class can be used in
either scope.

### 9.2 When a resource needs services

Some resources cannot answer `available` / `assign` / `release`
from a bare process. A database-connection resource, for
example, needs an actual database to hand out connections to; a
shared-job-slots resource needs a coordinator process reachable
by every harness sharing the slot pool. For these cases, a
resource class declares one or more **service methods**:
methods on the resource named `service_<name>_start` (matched
by `Role::Resource::service_methods`). Each `service_*_start`
method is the starter for a distinct service the resource needs.

A resource with zero `service_*_start` methods (`JobCount`) needs
no services at all and lives entirely inside its host. A resource
with N `service_*_start` methods spawns N distinct services when
it is attached.

### 9.3 Services are started *for* the resource, not as the resource

The services spawned by a resource are **not the resource**. The
resource class still lives in the host process (harness for
global resources, run service for run-scoped resources). The
services it declares are helper processes that exist solely to
support the resource's in-process API. When the resource's
`assign` method needs to reach out to "its" database, it talks
to the database service it started via IPC.

This is why §2 talks about "resource services" as an optional
extra subtree underneath a resource — not as a mandatory
wrapper around every resource. Most resources do not spawn any
services.

### 9.4 Where the services live

The host of a resource-supporting service is the same host as the
resource itself:

- **Global resources** — the harness calls the resource's
  `service_*_start` methods via the `ResourceServiceHost` role.
  The spawned services have the harness as their `ipc_parent`
  and no `ipc_run`. Their collectors are
  `collector:<service_name>`. Artifacts route to `ipc_harness`
  (no `ipc_run`).
- **Run-scoped resources** — the run service calls the
  resource's `service_*_start` methods the same way. Spawned
  services have the run service as their `ipc_parent` and
  `ipc_run = run_id`. Their collectors are
  `collector:<service_name>:<run_id>`. Artifacts route to
  `ipc_run`.

The `service_name` passed to the service at construction is
derived from the `service_*_start` method name (the
`Role::ResourceServiceHost::_resource_service_name_from_method`
helper in the existing tree: `service_foo_start` → `foo`). A
resource may override this if it needs a specific well-known
identity.

### 9.5 Teardown

When a resource is released — globally when the harness shuts
down, per-run when the run completes — the resource's
`teardown` method runs. Services the resource started are
expected to exit in response; the host reaps them via the normal
service-shutdown path. A resource service that declines to exit
is terminated by the host's shutdown escalator.

**Escalation signals are platform-dependent.** On POSIX the
escalator is TERM then KILL. On Windows and similar platforms
where TERM is not a reliable shutdown signal, the escalator is
INT then KILL. Every place in this document that names the
TERM → KILL sequence — kill-of-last-resort on a stuck
collector, per-test-process timeout escalation, preload stage
pruning, etc. — follows the same platform substitution:
TERM on POSIX, INT on Windows, KILL last on both.

## 10. Preloads (as a resource)

A preload is a `Test2::Harness2::Role::Resource` implementation
like any other — see §9. Its distinguishing feature is that it
declares a `service_preload_start` method (by whatever name; the
exact method name is an implementation detail of the resource
class). That single service method starts the **preload root
service**, which is the entry point to the stage tree described
below.

The scope of a preload follows the resource scope rules from §9:

- **Global preload** — attached to the harness; the harness is
  the root preload service's `ipc_parent`; no `ipc_run`; the
  root service and every stage below it run with `ipc_harness`
  pointing at the harness.
- **Run-scoped preload** — attached to a specific run; the run
  service is the root preload service's `ipc_parent`;
  `ipc_run = run_id` for the root and every stage below it.

The preload **resource itself** stays in the host process
(harness or run service) just like any other resource. The
preload root service and its stage tree are the out-of-process
helpers the resource needs to actually serve "start a test in a
preloaded state" — the resource delegates to them when its
`assign` is called.

### 10.1 Tree shape

A preload resource's stage tree looks like:

```
preload-root service        # from the resource; loads the base modules
├── stage A service         # loads more, on top of root
│   ├── stage A.1 service   # loads even more, on top of A
│   └── stage A.2 service
└── stage B service
    └── stage B.1 service
```

Every node in the tree is its own service in its own process.
Stages are forked from their parent after the parent has finished
loading; a child stage starts with its parent's preloaded module
set intact.

The root preload service is the resource service; its **parent
service** is determined by the resource's scope — the harness for
a global preload, the run service for a run-scoped preload.
Stages below the root have the stage one level up as their parent
service (IPC `ipc_parent`).

### 10.1.1 BEGIN-block bootstrap (why the root must be fresh)

The root preload service must be a **fresh process** started from
inside a `BEGIN` block — no other Perl code may have executed
before that point in the root's process, and every module the
preload is supposed to cache must be loaded inside that `BEGIN`.
This is not an aesthetic choice; it is load-bearing for how tests
execute out of a preload stage:

1. The `BEGIN` block declares a `Long::Jump` point at the top
   of its body.
2. Inside that `BEGIN`, the requested modules are `use`d /
   `require`d so they end up in `%INC` in the root's process.
3. When a test needs to run out of this stage, the preload stage
   forks. In the forked child, the preload framework triggers the
   `Long::Jump` back up to the `BEGIN`'s top and uses
   `goto::file` to substitute the test script for the body of
   the `BEGIN`. The child process then runs the test's code as
   if the test had been started normally, but with every
   preloaded module already present in `%INC`.
4. Because the `BEGIN` is the only place execution has reached
   in the fresh root, there is no before-`BEGIN` state to roll
   back; `Long::Jump` + `goto::file` cleanly replace the
   preload body with the test body.

Child stages (stage A, stage A.1, …) inherit the root's
preloaded module set through a normal `fork`; they do **not**
need their own fresh-process `BEGIN` bootstrap because their
starting state already contains the parent stage's modules. Each
child stage may do additional loading in the usual way after the
fork. The "fresh + BEGIN + Long::Jump + goto::file" requirement
applies only to the root.

The existing implementation in `reference/old2/lib/` is the reference for
this mechanism — specifically where it uses `goto::file` to
swap in a test script from a preload point. The new preload
resource must preserve those semantics even as the surrounding
service framework is modernised.

#### IPC-Manager's exec path is how you get a fresh root process

`IPC::Manager` exposes an `exec` parameter on the service spawn
API specifically so a service can be started in a freshly
`exec`'d process (not a `fork` that inherits Perl state from
its parent). The preload root service uses this to get the
"fresh process" §10.1.1 requires:

    my $handle = ipcm_service(
        ...
        exec => { cmd => \@inc_flags },   # <-- triggers exec path
    );

When `exec` is present, `ipcm_service` spawns the service by
`fork` + `exec` rather than `fork` alone, handing the child
process's argv via `cmd`. The preload resource supplies the
`@inc_flags` (plus the perl binary, the script to run, and any
other startup arguments) so the new process starts with
nothing already loaded, then the preload's top-level `BEGIN`
block runs the preload recipe inside that clean process.

Child stages do not use the `exec` path. They are forked from
their parent stage (which is already in the post-`BEGIN`
state) and inherit `%INC` in the normal way.

### 10.2 Stage names and IPC identity

Stage names are **unique within a single preload tree**. Because a
harness can run a global preload tree and one or more run-scoped
preload trees concurrently, names collide across trees. The IPC
identity therefore encodes the scope:

- `<stage_name>` for a stage in a **global** preload (no run_id
  context).
- `<stage_name>:<run_id>` for a stage in a **run-scoped** preload.

The root preload service uses the same naming with a canonical
placeholder stage name (e.g. `preload-root`) when no explicit name
was supplied by the resource.

### 10.3 IPC identity inherited by stage collectors

Every preload stage service has its own interpose collector, and
that collector inherits `ipc_harness` from its parent and
`ipc_run` from its scope:

- **Global preload**: every stage's `ipc_run` is undefined; its
  `ipc_harness` is the canonical harness identity.
- **Run-scoped preload**: every stage's `ipc_run` is the run's
  `run_id`; its `ipc_harness` is the harness identity.
- Every stage's `ipc_parent` is the service one level up in the
  preload tree (the root for direct children of root; the next
  stage up otherwise).

### 10.4 Launching a test from a preload stage

When the harness schedules a test that should run under preload
stage S, the harness sends a `launch_job` request to S (not to
the run service). S forks a child to run the test, but the
test's collector and test process are **detached from S's
process tree** on purpose: S must be free to exit or be
reloaded at any time without killing tests it already
launched.

The detachment pattern is a three-process dance:

1. S forks a short-lived **intermediary** child (call it I).
2. I forks again, producing the **collector + test**
   sub-process. The collector is the direct parent of the
   test process (it forks the test itself as part of its
   normal `spawn` flow).
3. I exits immediately. The collector + test pair are
   reparented away from S — to `init` on platforms without
   `ChildSubReaper`, or to the nearest subreaper in the tree
   when `ChildSubReaper` support is available.

#### Who reaps the detached collector

The answer depends on whether the preload is run-scoped or
global, because the nearest subreaper up the tree differs:

- **Run-scoped preload**: the run service is a subreaper. On
  `ChildSubReaper` platforms, the detached collector
  reparents to the run service; the run service `waitpid`-
  reaps when the collector exits. On platforms without
  `ChildSubReaper`, the run service polls + kills but cannot
  reap.
- **Global preload**: the preload tree lives under the
  harness, not under any run service, so the nearest
  subreaper above the detached collector is the **harness**
  (not the run). On `ChildSubReaper` platforms, the harness
  reaps the detached collector. The run service is still the
  collector's **monitor** (see below) — but not its reaper.

Either way, the detached collector's IPC identities are:

- `ipc_parent` = **the run service**. Detachment moved the
  collector out of S's process subtree, and the run service
  is the service that owns run-scoped test tracking — so
  `ipc_parent` for purposes of collector lifecycle messages
  (§7) is always the run service, regardless of who reaps.
- `ipc_run` = the run's `run_id`.
- `ipc_harness` = the canonical harness identity.

#### `launched_job` tells the run which pid to watch

Immediately after the detached collector comes up, it sends a
`launched_job` message to the run service carrying its own pid.
The run service records that pid so it can:

- Track the collector's liveness by polling the pid.
- Kill the collector if the run is aborted early, or if the
  test overruns its timeout (see below) — on any platform,
  with or without `ChildSubReaper`. Killing does not require
  being the reaper; the run signals the pid and waits for it
  to disappear.
- Reap the collector when it exits, **only** when the run is
  the collector's direct parent or subreaper (i.e. run-scoped
  preload). For global-preload detached tests the harness
  reaps; the run observes the pid going away via its own
  polling rather than via `waitpid`.

#### Timeouts live in the collector, not in the run

Per-test-process timeouts are owned by the **collector**, not
by the run service. The collector has direct oversight of the
test process (it is the test's parent); it is the right place
to arm a timer, noticing a hang, and escalate (TERM → grace →
KILL) when the test overruns.

The run service's role around timeouts is limited to: forced
kill-of-last-resort if the collector itself has become
unresponsive. The run service notices an unresponsive
collector via pid polling + message silence; if it decides
the collector is stuck, it kills the collector's pid. The
collector's own timeout machinery is expected to be the
first line of defence; the run's kill is a fallback.

#### Test-job collectors monitor the run, not the preload

The collector polls the **run service's pid** and watches the
run's IPC identity. If either signal indicates the run is
gone (pid disappeared, IPC identity deregistered), the
collector:

1. Terminates its test process cleanly if it can (TERM →
   grace → KILL).
2. Terminates itself.

**The collector does not monitor the preload stage** it was
spawned from — once detachment is complete the stage has no
authority over the collector's lifetime, and the whole
point of detachment is that the stage can disappear freely.
Monitoring the stage would re-entangle the lifetimes we
specifically went to trouble to separate.

#### Summary of routing and lifecycle

- `test_job_started`, `test_job_completed`, `launched_job`,
  `collector_started`, `collector_exiting`, artifact
  announcements: all go to `ipc_run` or `ipc_harness` per
  the general rules of §7 and §8.3.
- The preload stage S is only involved in the **launch**:
  after the intermediary exits and the collector announces
  itself to the run service, S's role is done. S can exit,
  be pruned, or be reloaded without disturbing the running
  test.

Run-scoped preloads are the typical case. Global preloads are
the same mechanism but with the harness as the subreaper of
the detached tests; the run service still monitors the
collector on behalf of the run that asked for the test.

### 10.5 Reload

Reloading a preload has **two avenues**, and the preload
resource picks between them based on whether the changed
modules can be reloaded in place:

1. **In-place reload** (preferred when possible). Each stage
   watches the files in its own `%INC` for changes via a
   `Test2::Harness2::Role::ChangeWatcher` consumer (see
   §10.5.0). When a watched file changes and the preload's
   reload policy says it is safely reloadable, the stage
   re-reads the file into its already-running process using
   the normal module-reload path. No process restart, no
   subtree prune, no affect on already-launched tests. This
   is by far the common case — edits to a pure-data config
   module, a leaf library with no XS or package globals, etc.
2. **Branch pruning** (fallback). Used when in-place reload
   is not possible — the changed module has XS, has Moose
   metaclass state, uses `use constant` values other code
   has already captured at load time, or the preload
   policy simply refuses to attempt it. Pruning kills the
   affected stage's subtree and re-forks it fresh, exactly
   as described below.

The resource is responsible for deciding which avenue applies.
Each consumer of the preload role may implement any reload
policy it wants; the important architectural constraint is
that branch pruning is the fallback, not the default.

### 10.5.0 `Role::ChangeWatcher` and its implementations

Every preload stage is responsible for watching the files
in its `%INC` for changes. A role named
`Test2::Harness2::Role::ChangeWatcher` (or similar — pick
the name that reads best) declares the shared interface.
Two initial implementations ship:

- **Inotify** — uses `Linux::Inotify2` when it is available.
  Events are delivered by the kernel; cheap to watch many
  files.
- **Mtime fallback** — used when `Linux::Inotify2` is not
  available. Records the mtime of each file in `%INC` and
  compares against the current mtime on each check. More
  expensive than the inotify path but portable.

Reference implementations of the watcher + reload logic
already exist in `reference/old2/lib/` and should be the starting
point for the new role's implementations. The new code
only needs to surface the behaviour behind the
`ChangeWatcher` role interface so the preload resource can
pick whichever watcher implementation applies on the
current platform.

### 10.5.1 Branch pruning (the fallback path)

When in-place reload cannot apply, a preload reload is
modelled as **pruning a branch**:

1. The reload target is a stage S.
2. All of S's descendants in the preload tree are terminated.
3. S itself is terminated.
4. **Tests S already launched are not affected.** They detach
   from S at launch time (§10.4), so pruning S leaves the
   collector + test pair running under the run service's
   supervision. The tests complete on their own timeline; the
   run service reaps their collectors and records their
   verdicts regardless of what is happening in the preload
   tree.
5. S's parent (or the root) re-forks S. Re-forking S rebuilds
   the entire subtree by running S's original preload recipe
   again.
6. Any NEW tests that would have launched out of S (or a
   descendant of S) while S is down are deferred. The preload
   resource reports S (and its descendants) as "down" to the
   scheduler; the scheduler holds those tests. When the new S
   announces itself ready, the resource flips the stage state
   back to "up" and the scheduler releases the held tests.

Propagation of "I'm going away" through the killed subtree
uses the normal `collector_exiting` signal path from each
stage's collector up to its parent stage. The parent learns a
child is gone via `collector_exiting` (or by reaping the
child's pid, whichever comes first) and initiates the re-fork.

#### 10.5.2 "Stage gone" implies "descendants gone"

When a parent stage observes that one of its direct children
has exited (via `collector_exiting`, via pid reap, or via a
liveness check), it assumes **every descendant stage below the
gone child is also gone**. Descendants do not need to send
their own `collector_exiting` up through the tree for the
parent to accept the whole subtree as down; they cannot
outlive their parent stage's process. This cuts redundant
signalling and makes the "stage up/down" accounting snap to
the branch boundary instantly.

#### 10.5.3 Stages self-terminate when their parent goes away

Every preload stage watches its parent's liveness on two axes:

- **Parent pid**: each stage knows its parent stage's pid and
  polls / reaps-notifies to catch the parent going away. On
  platforms with `ChildSubReaper` this is straightforward
  (`waitpid`/`WNOHANG`); on others the stage polls with
  `kill 0, $parent_pid`.
- **Parent IPC active status**: if the parent's identity stops
  responding on the bus (e.g. its service has deregistered),
  the stage treats that as "parent is gone" as well.

On either signal, the stage **terminates itself** cleanly. Its
own children repeat the cascade. This makes pruning by killing
a single mid-tree stage safe — the whole branch below it unwinds
without central coordination.

#### 10.5.4 PID monitoring catches hard failures

The preload resource (and every stage service that has
children) keeps each child's pid under active monitoring. If a
child dies so hard it cannot send its own `collector_exiting`
(segfault, SIGKILL from the OOM killer, `POSIX::_exit` before
the collector can flush) the pid monitor detects the absence
and the parent reacts:

- For the resource-level monitor: flip the affected stage (and,
  per §10.5.2, its descendants) to "down"; schedule a restart
  of the stage per §10.5.1.
- For the stage-level monitor: propagate the pid-gone signal
  through the same channels a `collector_exiting` would have
  produced.

### 10.5.5 Stage up/down state is the scheduler's input

The preload resource keeps a table of `stage_name` → `up` /
`down` / `restarting`. The scheduler consults this table when
deciding whether a given test (which may require a specific
stage) can launch right now:

- If the target stage is **up**, normal path: send `launch_job`
  to the stage.
- If the target stage is **down** or **restarting**, the test is
  held. When the stage flips back to **up**, held tests are
  released in submission order.
- A stage flip to **down** also implies that any tests waiting
  on any of its descendants are still held — the restart will
  rebuild the whole subtree.

#### How the resource decides a stage's state

The preload resource maintains each stage's state by combining
three signals:

1. **Explicit lifecycle messages from the stage.** Every stage
   sends an `up` (or `ready`) message when its preload recipe
   has finished and it is prepared to accept `launch_job`
   requests. Every stage sends a `down` message when it is
   about to exit cleanly. These messages go to whichever
   service owns the preload — the **harness** for a global
   preload, the owning **run service** for a run-scoped
   preload — so the preload resource (which lives in that
   same host) can consume them.
2. **IPC peer availability.** The resource checks whether the
   stage's IPC identity still responds on the bus. An
   identity that has deregistered is a strong signal the
   stage is gone, even if no `down` message arrived.
3. **PID + message history.** The resource records the pid
   the stage was running under at the time of its most
   recent `up`. On each health check it verifies the pid
   still matches and that the `up` has not been followed by
   a `down`. A pid that no longer matches (process died and
   was replaced), or an `up` with no known pid trail, is
   treated as "stage down" regardless of what the bus says.

Together these three signals keep the resource's view
truthful even when a stage fails so hard it cannot send a
`down` message. Explicit lifecycle messages are the fast,
cheap path; the other two are fallbacks that catch hard
failures.

### 10.6 Lifecycle propagation guarantee

Because stages form a tree of services, each stage needs to know
when its children come and go. The rule is just the general
rule from §5 and §7 applied recursively:

- A stage's collector sends `collector_started`, `collector_exiting`
  to its `ipc_parent` — i.e. the stage above it.
- That parent stage echoes the received IPC into its own collector
  as an event (per §6), so its own collector's logger chain sees
  the subtree's shape, and so further-up aggregators observing the
  parent see an accurate picture.
- Artifact announcements from anywhere in the tree do **not** use
  this path — they short-circuit to `ipc_run` / `ipc_harness` per
  §8.3.
- "I'm going away" can also reach the parent via pid monitoring
  (§10.5.3) when the orderly IPC path is unavailable.

The guarantee we need is narrow: **every collector_started /
collector_exiting message from any stage lands at its parent
stage, no matter how deep the tree, either via IPC or via pid
reap.** That's what keeps the subtree-supervision and stage
up/down picture coherent; artifact correctness is handled by
the direct-to-aggregator routing elsewhere.

## 11. Workdir and logdir

There are exactly two cases:

### 11.1 Any command that starts a harness creates a workdir

If a command starts its own harness service, it is
responsible for creating the workdir and passing it to the
harness at construction. The harness does not vivify its own
workdir — missing a workdir at construction is a fatal error.

- Workdirs are temporary: `File::Temp::tempdir('yath2-$$-XXXXXX',
  TMPDIR => 1)`. The default TMPDIR is `/tmp`.
- The default logs directory name is `logs`; this is also a
  construction arg (the full path becomes
  `$workdir/$logdir_name`).
- Cleanup is the responsibility of whichever process created
  the workdir, and runs once the command (or daemon) observes
  the harness process has exited. For a short-lived command
  (`yath test` running standalone, `yath run` running
  standalone) this is the command itself. For `yath start`,
  the daemon process is the parent of the harness service
  process; the daemon creates the workdir, hands it in, and
  cleans it up when it observes the harness has exited. The
  harness service itself never cleans up the workdir.

### 11.2 Any command that does not start a harness does not create a workdir

A command that does not need a harness at all, or that
attaches to a harness someone else already started, does not
create a workdir. If it needs to know where to look for
artifacts or what the harness's workdir / logdir paths are,
it asks the harness over IPC via the handle it already holds:

- `get_workdir` → returns the absolute path of the harness's
  workdir and the configured logs directory name.

In the attached case the workdir's lifecycle belongs to
whichever process created it; the attached command does not
own it.

### 11.3 General rule

Commands must not assume a workdir path based on any
convention — even for their own short-lived harness, the
exact path is the return of `File::Temp::tempdir`. The
harness's `get_workdir` (or the status response) is always
the authoritative source for any consumer that needs to know
the actual path.

## 12. Logger defaults and behaviour

### 12.1 Harness default: no loggers, no assumptions

The harness itself **does not install any loggers by default**
and makes no assumptions about what the command driving it
wants. Tests still run, every IPC lifecycle message described
above still flows, and the harness still aggregates per-job
pass/fail via `test_job_completed` — the IPC path alone is
enough for a command to exit with the correct status without
any logger producing any file.

Which loggers to enable is the **command's** responsibility, not
the harness's. `yath test`, `yath run`, `yath start`, etc. each
decide — based on the user's command-line options — which
loggers to attach to which collectors, and pass that list to
the harness at construction (or in per-run settings). The
harness applies them; it does not pick.

### 12.2 `yath test` early-development default

During early development of the rewrite, `yath test` enables two
loggers on every collector (service collectors, resource
collectors, test-job collectors) as a placeholder default:

- `Test2::Harness2::Collector::Logger::JSONL`
- `Test2::Harness2::Collector::Logger::JSON`

These give the command enough on-disk artifact to feed a renderer
and exercise the artifact plumbing end to end.

This default is a **stopgap, not the final behaviour.** In the
real `yath test`, the set of active loggers is derived from
command-line argument combinations (verbose / quiet / qvf,
`--no-log`, explicit `--logger=Foo`, `--archive`, etc.). Until
the argument layer lands, the two-logger default stands in as a
known-good configuration to test against.

### 12.3 Collector input the loggers write about

Every collector (service or test-job) accepts:
- framed event bursts on its stdout (from Stream2 in test
  processes, from the service event emitter in service
  processes), each paired with the STDERR sync marker described
  in §6.1 so the collector can order events against interleaved
  raw output;
- raw stdout / stderr output (tests and services may print
  outside the event frame; the collector's parser wraps such
  output in `STDOUT`/`STDERR`-tagged events).

**TAP is a test-collector-only input.** Test-job collectors
recognise direct TAP output as a graceful fallback for older
or external producers (a test that uses `Test::More` without
switching to the Stream2 formatter, say), and their parser
turns TAP lines into Test2 events. **Service collectors do
not parse TAP** — a service that prints a line that happens
to look like TAP is just regular stdout / stderr output as
far as its collector is concerned, and ends up wrapped in a
`STDOUT` / `STDERR` event like any other raw output.

### 12.4 Logger pipeline

Inside a **test-job collector**:

```
test process stdout/stderr
  → parser   (frames → events; TAP lines → events; raw lines → STDOUT/STDERR events)
  → auditor  (tracks pass/fail, counts, duration — ONLY on test-job collectors)
  → loggers  (each active logger sees the event stream in order)
```

Inside a **service collector** (harness, run, resource, preload):

```
service stdout/stderr
  → parser   (frames → events; raw lines → STDOUT/STDERR events; TAP is NOT recognised)
  → loggers  (no auditor — service collectors don't have verdicts)
```

## 13. Artifacts and the output pipeline

Events produced by tests flow through collectors into on-disk
artifacts (JSONL files). The **output pipeline** in the command
process reads those artifacts, filters the event stream
per-renderer, and delivers events to one or more renderers that
format and emit output.

The pipeline has three distinct stages:

```
ArtifactLayer  (TBD — dispatches every event, no mode filtering)
    │
    ▼
OutputManager
    │  (groups renderers by filter chain; each chain runs once)
    ├─► [Filter chain A] ──► Renderer A  (e.g. Default TUI)
    │                   └──► Renderer B  (same chain, one run)
    └─► [Filter chain B] ──► Renderer C  (e.g. DB / JUnit)
```

### 13.0 ArtifactLayer — reading and replaying

**Not yet implemented.** `App::Yath2::ArtifactLayer` will bridge
the harness and the `OutputManager`. It learns when individual
jobs complete, reads the corresponding per-job JSONL artifacts
from disk, and dispatches every event it finds via
`$output_manager->dispatch($event)`.

**The ArtifactLayer makes no filtering decisions.** It does not
know or care which renderers are active or what modes they
operate in. When a job JSONL file exists it is replayed in full;
when no JSONL exists a synthesised `test_job_completed` event
is dispatched as a fallback so renderers can still print a
summary. A final synthesised `run_complete` event is dispatched
after all jobs are done.

The preferred mechanism for learning when jobs complete is a
subscription to the harness event stream (§6.3). Until §6.3
lands a polling approach over IPC is an acceptable interim
implementation.

### 13.1 Harness IPC requests the ArtifactLayer uses

These are requests the harness answers; the **command** (not the
renderer or the OutputManager) is the caller.

- `list_global_artifacts` → artifacts for every non-run-scoped
  collector (harness collector, global resource-service
  collectors, global preload stage collectors).
- `list_run_artifacts(run_id => $id)` → artifacts for every
  collector associated with that run.

### 13.2 OutputManager — shared filter chains, multiple renderers

`App::Yath2::OutputManager` holds
an ordered list of pipelines. Each pipeline owns a filter chain
and a list of one or more renderers that share it.

**Building a pipeline.** When `add_renderer($renderer)` is
called the manager calls `$renderer->desired_filters` to obtain
an ordered list of filter class names or pre-built instances. A
pipeline key is derived from the spec list (class names
contribute their name; pre-built instances contribute their
stringified address). If an existing pipeline has an identical
key the renderer is appended to it — the chain runs only once
per event for all renderers in that group. Otherwise a new
pipeline is created. `start()` is called on the renderer
immediately at registration.

```
$manager->add_renderer($r1);   # desired_filters => ('Filter::Verbose')
$manager->add_renderer($r2);   # desired_filters => ('Filter::Verbose')
# result: one pipeline, key='Filter::Verbose', renderers=[$r1,$r2]

$manager->add_renderer($r3);   # desired_filters => ('Filter::Quiet')
# result: second pipeline, key='Filter::Quiet', renderers=[$r3]
```

**Dispatching an event.** For each pipeline, the manager runs
the filter chain once. If the event survives, it is handed to
every renderer in that pipeline's renderer list:

```
for my $pipeline (@pipelines) {
    my $ev = $event;
    for my $f (@{$pipeline->{filters}}) {
        $ev = $f->filter_event($ev);
        last unless defined $ev;
    }
    next unless defined $ev;
    $_->render_event($ev) for @{$pipeline->{renderers}};
}
```

**Lifecycle.** `start()` fires on each renderer at `add_renderer`
time. `finish()` fires on all renderers when the `OutputManager`
is destroyed (via `DESTROY`) or when `finish()` is called
explicitly; a guard prevents double-firing. `signal` and
`end_of_events` are forwarded to every renderer. Filters are
not involved in lifecycle.

### 13.3 Filters — per-event pass / drop

A filter is a lightweight stateless (or minimally stateful)
object that inspects one event at a time and returns either the
(possibly transformed) event or `undef` to drop it.

**Interface** (`App::Yath2::Filter` base class):

```perl
# Returns $event to pass it downstream, undef to drop it.
sub filter_event { croak "override me" }
```

Filters are declared by renderers, not by the command. The
renderer reads its settings (log level, verbosity, etc.) in its
constructor and returns the appropriate filter list from
`desired_filters`. A renderer with no opinion returns `()`.

**Built-in filters:**

- `App::Yath2::Filter::Verbose` — passes events that carry
  meaningful displayable content (assertions, diagnostics, plan,
  errors, job/run summaries). Drops pure framework-housekeeping
  events that carry no user-visible output.
- `App::Yath2::Filter::Quiet` — passes only job-level and
  run-level summary events (`test_job_completed`,
  `run_complete`). Drops individual test assertions and
  diagnostics.

**QVF note.** "Quiet-verbose-on-failure" buffering — hold all
of a job's events and flush only if the job fails — is a
stateful operation that requires knowing when a job ends. This
is handled upstream in the `ArtifactLayer` or a dedicated
command-level component, **not** in the filter layer. Filters
are for stateless (or near-stateless) event selection only.

### 13.4 Renderers — format and emit

A renderer receives a pre-filtered event stream and is
responsible only for **formatting** that stream and **writing**
it to its destination (STDOUT, a file, a database, a web
service, etc.).

Renderers **must not** make filtering decisions themselves —
that separation is what makes renderers composable with
different filter chains without modification.

**Base class** (`App::Yath2::Renderer`):

```perl
sub desired_filters { () }          # override to declare filter chain
sub render_event { croak "override" }
sub start        { }
sub finish       { }
sub signal       { }
sub end_of_events { }
sub is_async     { 0 }
```

### 13.5 Why this split

- **ArtifactLayer** (TBD) is dumb about renderers: it just reads
  and dispatches. Adding a new renderer never requires touching
  the artifact layer.
- **OutputManager** is dumb about what filters and renderers do:
  it just runs each chain once and fans out. Adding a new filter
  or renderer never requires touching the manager.
- **Filters** are independent modules: the same `Quiet` filter
  can be used by the Default TUI renderer, a JUnit renderer, or
  a custom renderer. Renderers with identical filter chains
  automatically share a single chain run.
- **Renderers** are dumb about filtering: they only format and
  emit. They are trivial to write and test in isolation.
- **QVF** is kept out of the filter layer intentionally: its
  buffering semantics belong upstream where full job context is
  available.

## 14. Scheduler

The harness is the scheduler. It decides when a run should start
(based on global resource availability) and when a test inside a
run should start (based on the run's resource availability and
job-count limiters).

When the harness decides to launch a test:

1. It picks the target service. Normally this is the run service.
   If the test requires a specific preload stage, the target is
   that stage instead.
2. It sends a `launch_job` request (not a message — a request,
   because losing this would mean losing the test).
3. It sets a timeout on the request. The timeout is
   **configurable** and lives in the run's data (one of the
   per-run settings). When unset the default is **5 seconds**.
   A future CLI option will expose this to the user; until then
   callers pass it via the run-data construction arg.
4. On timeout:
   - Mark the job deferred.
   - Retry after the same configured interval.
   - If a late `launched_job` arrives for this job (the target
     did actually start it but the ack was slow), reconcile:
     warn once (IPC diagnostic), mark the job started (not
     deferred), and do not launch it again. See §5.2.

Per-job resource assignment happens on the harness before the
request is sent; the target service (run service or preload
stage) only performs the launch and reports back. When the
target is a preload stage, launch is the detached-fork flow from
§10.4; the resulting collector's `launched_job` still addresses
the harness the same way.

### 14.1 Unavailable-action launches

When a job cannot be run because a needed resource is unavailable
— either the resource is permanently broken, or the resource is
healthy but can never grant THIS specific job (e.g. the test
declares `HARNESS-JOB-SLOTS 8` but the per-job cap is 4) — the
scheduler does not silently drop the job. Instead it routes the
job through an **unavailable-action launch**: a real Collector
launch of a `perl -e ...` one-liner that either calls `skip_all`
or `die`, with the resource name baked into the reason string.

The two unavailable-action kinds are `skip` and `fail`. For the
permanent-broken case, the choice is governed by the harness-
level `broken_resource_behavior` attribute (`skip`, `fail`, or
`abort`; `abort` runs the `fail` kind for every remaining job in
the run). For the cap-exceeds-min case, the kind is always
`skip`. Either way the launch goes through the normal Collector
path so loggers, auditor, and on-disk artifacts look the same as
they would for a real test that called `skip_all` or died.

The launch consults every resource that reports `needed(job => $job)`
and is not `is_permanent_broken`, requesting `need=1` from each. It
may defer if any of those resources is saturated. Resources that
genuinely should not participate in unavailable-action launches opt
out via `needed`. If the resource set yields no viable launcher at
all, the unavailable-action launch is itself skipped and the run
finalizes.

> *Naming note:* this concept used to be called the "synthetic
> skip / synthetic fail" path internally. The word "synthetic"
> is reserved for event fabrication on the auditor side
> (subtest-start announcements, plan/count mismatches, etc., see
> §20); the resource-side fabrication is "unavailable action".

## 15. Error handling & ready semantics

- Services wait for each other via `IPC::Manager::Service::Handle`'s
  `ready(N)`. A collector does the same when its parent is a
  service spawned concurrently (see the existing `_ipc_handle`
  warmup path).
- A service whose `ipc_harness` is undefined (the harness itself)
  does not try to send `ipc_harness`-destined messages; those
  would be self-addressed and are no-ops.
- Any send failure from a collector — including EPIPE / "Disconnected
  pipe" — warns. Collectors should shut down before the services
  they depend on; a broken pipe indicates that invariant was
  violated and wants investigation, not suppression.
- Shutdown ordering: a service's interpose collector is the service's
  peer, not a child that survives it; the service waits for all of
  its children's collectors to cleanly report `collector_exiting`
  and exit before tearing down its own collector.

---

# Part II — Implementation map

## 16. Scope and responsibilities

### Test2::Harness2

The `Test2::Harness2` namespace is the primary harness runtime. Its job
is to spin up the services and resources needed for tests to execute,
run them, capture their output and final results, and clean up so no
process lingers afterward.

The harness operates on **runs**. A run is an ordered collection of
tests submitted as a single unit of work. The harness:

- Accepts runs via construction args or via IPC requests from the
  command process (see §4).
- May run **multiple runs concurrently**, each under its own run
  service; the topology diagram in §2 shows the run-service subtree
  repeated per concurrent run. `yath test` submits one run at a
  time; `yath start`-driven daemons can be driven to process
  several.
- Schedules tests within and across runs based on global resource
  availability, per-run resource requirements, job-count limiters,
  and any scheduling metadata (duration, smoke vs. non-smoke, etc.)
  attached to the tests.
- Manages services, preloads (as resources), resources, and loggers
  as specified by the caller.
- Tracks every process in each subtree and guarantees nothing
  survives the service that owned it (see §18 — Invariants 1 and 2).

By the time a run reaches the harness, most decisions are already
made. The caller has declared which preloads, resources, and loggers
each test needs, which formatters to use, and which tests belong to
which run. The harness does not revisit those inputs — its only
scheduling decision is **when** to run each test under the
scheduler's constraints.

## 17. Namespaces and dependency contract

`Test2-Harness2` is a single distribution carrying **five top-level
namespaces**, each with its own responsibility:

| Namespace                  | Responsibility                                                                                                                                                                                                                                                                                                                                  |
|----------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Test2::Harness2`          | The primary harness runtime. Spins up services and resources, executes runs, captures output and results, cleans up processes. Described above.                                                                                                                                                                                                |
| `Test2::Formatter::Stream2` | The in-test Test2 formatter that serialises events over atomic pipes to the collector. Lives outside the `Test2::Harness2` namespace because it loads inside test processes. See §21.                                                                                                                                                          |
| `App::Yath2`               | The new application layer. Built on `App::Yath::Script` and `Getopt::Yath`. Turns user input (`yath ...` commands, config files) into requests to start or utilise `Test2::Harness2` services. Handles test discovery, deciding which loggers to attach, assembling runs, starting and stopping harness services, the artifact-reading layer that feeds renderers (see §13), and log-archive create / extract utilities. |
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

| Path                  | Origin                              | Status                  |
|-----------------------|-------------------------------------|-------------------------|
| `reference/legacy/`   | `yath` 1.0 source                   | Read-only reference     |
| `reference/old2/`     | First 2.0 attempt (mostly complete) | Donor code, read-only   |
| `reference/botched/`  | Failed refactor                     | Read-only reference     |

Code is copied wholesale out of these trees as the rewrite catches up;
nothing in `lib/` should `use` anything from them.

## 18. Process model invariants

§2 defines the topology and IPC parentage. Two invariants govern
the tree and must be honoured by every shutdown path.

### Invariant 1 — no survivors on hard stop

When any service is terminated (by `terminate` request, fatal signal,
abnormal exit, or crash), every descendant of that service must be
killed and reaped before the service exits. The harness is
responsible for its subtree; each run service is responsible for
its own subtree; each preload stage is responsible for its own
children (but not for tests it detached per §10.4).

Mechanism: a two-layer process-group discipline.

- Each **service** calls `POSIX::setpgid(0, 0)` on `run_on_start`,
  taking ownership of its own pgroup. Its direct child processes
  inherit that pgroup.
- Each **test process** calls `POSIX::setpgid(0, 0)` again post-fork
  / pre-exec when its collector was constructed with
  `new_pgroup => 1`. This puts the test in its own fresh pgroup so a
  test doing `kill 'TERM', 0` cannot reach the harness or run
  service.

Hard-stop sweep (`Test2::Harness2::Role::Service::perform_hard_stop`
and equivalents):

1. Set state to `terminating` and clear any in-flight queue.
2. Build a per-pid signal-state map seeded from the service's
   tracked children.
3. On each iteration: re-enumerate direct children (subreaper case),
   send the first signal (`TERM` on POSIX, `INT` on Windows) to
   fresh pids, escalate to `KILL` once `kill_timeout` has elapsed
   without exit, reap with `waitpid(-1, WNOHANG)`, and sleep briefly
   only if no work happened.
4. Exit the loop when every tracked pid is either reaped or has been
   past its `KILL` deadline long enough to be considered
   unreachable.

The service signals **by pid**, not by pgroup, to avoid signalling
itself. Signal-name substitution on Windows (INT for TERM) is per
§9.5.

### Invariant 2 — nothing survives its parent

If a service process dies for any reason — including SIGKILL — every
direct descendant of that service must terminate without help from
the service's signal handlers (which may never run).

Mechanism: every long-lived process a service spawns monitors the
pid(s) it depends on. When a watched pid disappears, the monitor
self-terminates and cleans up its own subtree.

The exact dependency tree follows §2:

- **Service collectors** watch the service they interpose; if that
  service's pid is gone the collector self-terminates.
- **Test-job collectors** watch the run service's pid (and the run
  service's IPC identity on the bus) — **not** the service that
  spawned the collector (which might be a preload stage). See
  §10.4: a detached test-job collector's parent service (the
  preload stage) can be pruned at any time without affecting the
  test; the collector tracks the run instead.
- **Preload stages** watch their direct parent stage (via pid and
  via parent IPC identity); on either signal they self-terminate
  and their own children repeat the cascade. See §10.5.3.
- **Services spawned by the command** (harness service) watch the
  command process's pid via the handle identity the command
  registered on the IPC bus; the detach request removes the
  caller's pid from the service's watch list.

`detach` flows down the chain: the command sends a `detach` IPC
request to the service, which removes the command's pid from its
watch list so the service stays up when the command exits.

### Subreaping

On Linux, when the optional `Test2::Harness2::ChildSubReaper` module
is installed, each service enables `PR_SET_CHILD_SUBREAPER` on
`run_on_start` so any descendant that gets orphaned (a test that
double-forks then exits its parent) reparents to the service rather
than to `init(1)`. That makes the orphan visible to
`waitpid(-1, ...)` and to `list_direct_children($$)` so the
hard-stop sweep can actually reach it.

Subreaping matters especially for **global preloads** (see §10.4):
detached test-job collectors spawned under a global preload
reparent to the harness (the nearest subreaper above the preload
subtree); the run service still monitors them but the harness reaps
them.

Without the `ChildSubReaper` module the harness still works; orphans
that the run service or the harness needs to monitor fall back to
`kill 0, $pid` polling and signal-based cleanup instead of
`waitpid`, per §10.4.

## 19. Top-Level Service: `Test2::Harness2`

A single object that consumes `IPC::Manager::Role::Service` and runs
an event loop over an IPC bus. The full source lives in
`lib/Test2/Harness2.pm`.

### Workdir ownership

Per §11, the command that starts the harness creates the workdir
and passes it in at construction. The harness does not vivify its
own workdir — missing a workdir is a fatal error. Commands that
attach to an existing harness do not create a workdir; they ask
the harness for its workdir path via IPC.

Workdir is a `File::Temp::tempdir('yath2-$$-XXXXXX', TMPDIR => 1)`
temporary directory. The creating command (or for `yath start`, the
parent yath daemon process) owns cleanup once the harness has
exited.

### On-disk layout

When loggers are configured (they are not installed by default —
see §12.1), the default JSONL + JSON pair that `yath test` uses as
an early-development stopgap produces this layout:

```
$workdir/
  logs/
    services/
      <name>/
        events.jsonl        service-lifecycle event stream (default name=harness)
        state.json          service JSON snapshot (init fields + final verdict)
    runs/
      <run_id>.json         per-run JSON snapshot (Logger::JSON on the run-service collector; see note below)
      <run_id>/
        services/
          <svc-name>/
            events.jsonl    per-run-service event stream
        <job_id>/
          0.jsonl           per-test event stream
          0.json            per-test JSON snapshot (init + exit + pass/fail)
```

`logs/runs/` and its subdirectories are created lazily as runs and
jobs dispatch.

**The harness installs no loggers by default.** Everything above
appears only when the command (or caller) supplies a logger
configuration that produces those artifacts. `yath test` currently
supplies a JSONL + JSON pair on every collector as a placeholder
while the CLI-arg-driven logger-selection layer is being built; see
§12.2.

The per-run `<run_id>.json` sidecar is now produced by a
`Logger::JSON` attached to the run service's own collector. The
run service emits a `run_mutation` event carrying the full
`Run->TO_JSON` payload on every state change; the JSON logger
caches the most recent snapshot and writes it atomically at
shutdown. There is no longer a direct file write from the
harness, so the "functional state flows via IPC, not files" rule
(see §13.0) holds end-to-end. See §19 of `AI_DOCS/2026-04-23-run-service-aggregation.md`.

## 20. Collector Subsystem

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

Class method used by **every service** in the harness tree
(harness, run services, resource services, preload stage services)
to wrap its own stdout and stderr with a collector. The parent
becomes a collector that reads the redirected stdout/stderr and
runs them through its parser + loggers pipeline; it never returns.
The child returns from `interpose` with stdout/stderr remapped to
atomic pipes and continues executing the caller's code — i.e.
becomes the service process proper.

Optional `jump_to`/`jump_payload` parameters unwind the call stack
to a `Long::Jump::setjump` target before continuing. The preload
root service relies on this to land in its top-level `BEGIN`
block for the `goto::file` swap described in §10.1.1.

Service collectors created via `interpose` have no auditor (see
the pipeline diagram above); only test-job collectors do.

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

### The event pipeline

Two pipeline shapes, depending on collector role. Both consume the
same framed-event-burst-plus-raw-text protocol on stdout (see §21
and §6.1), but the parser's behaviour and the presence or absence
of an auditor differ.

**Test-job collector:**

```
test process stdout/stderr
  → Parser   (framed bursts → events; TAP lines → events; raw lines → STDOUT/STDERR events)
  → Auditor  (tracks pass/fail, counts, duration — test-job only)
  → Loggers  (each active logger sees the event stream in order)
```

**Service collector** (harness, run, resource, preload stage):

```
service stdout/stderr
  → Parser   (framed bursts → events; raw lines → STDOUT/STDERR events; TAP is NOT recognised)
  → Loggers  (no auditor — service collectors don't have verdicts)
```

Per §12.3: **TAP is a test-collector-only input.** Service
collectors do not parse TAP; lines that happen to look like TAP
are treated as regular STDOUT/STDERR.

#### Parsers

Live under `lib/Test2/Harness2/Collector/Parser/`. They turn raw lines
and message bursts into `Test2::Harness2::Event` objects and stamp
every event with the `harness` facet (`event_id`, `stamp`). Parsers
do **not** stamp `run_id` / `job_id` / `job_try` onto events — that
provenance is carried by the log's on-disk path (when loggers are
configured) and by the service-level events that bracket each job
(`test_job_started`, `test_job_completed`; see §7).

- `IOParser` — base. Wraps each line in `from_stream` + `info` facets.
  No protocol parsing.
- `IOParser::Stream` — base + delegates to `TapParser` to recognise
  TAP, falling back to base behaviour on non-TAP lines. Used only in
  test-job collectors.
- `TapParser` — stateless regex-based recogniser for TAP constructs
  (`ok`/`not ok`, plans, comments, subtest open/close, `bail out`).
  Not used in service collectors.

#### Auditors (test-job only)

`Test2::Harness2::Collector::Auditor::Test` consumes the
`Test2::Harness2::Role::Auditor` role. It tracks assertions, plans,
nested subtests (recursively, by spawning sub-auditors), errors, halt
status, and the child's exit code. It may emit synthetic events for
subtest announcements, plan/count mismatches, and recovery from
malformed TAP. `pass()` / `pass_count()` / `fail_count()` query its
verdict at any time; these are the values the test-job collector
includes in its `collector_exiting` message to `ipc_harness` (see §7).

Service collectors have **no auditor**. See §12.4.

#### Loggers

Implement `Test2::Harness2::Role::Collector::Logger`. The role
supplies default no-op implementations of all lifecycle hooks; a
logger only needs to override what it cares about.

| Hook                       | When                                               |
|----------------------------|----------------------------------------------------|
| `startup($collector)`      | Once, at child-side init                           |
| `log_event($event)`        | Per event, only if `log_events()` returns true     |
| `failing(1)`               | Once, when auditor flips passing → failing (test-job only) |
| `shutdown($collector)`     | Once, at child-side teardown                       |
| `metadata()`               | Return a hashref describing this logger instance's artifacts (`output_file`, `uri`, `table`, etc.) or `undef` to opt out. Gathered into the `collector_artifacts` IPC message (see §8). |
| `set_process_info(...)`    | Pass `run_id`/`job_id`/`job_try`/pid in            |
| `set_ipcm_info(...)`       | Hand over the IPC connection info                  |
| `set_auditor($auditor)`    | Give the logger access to the auditor (test-job only) |
| `set_loggers_lookup(...)`  | Sibling-logger map for cross-references            |
| `depends_on()`             | Names of other loggers that must be present        |

Provided loggers (artifact-producing only — the
`Test2::Harness2::Role::Collector::Logger` role is reserved for
classes that produce observable artifacts; see §12 and the
drift-2 correction in `PLAN`):

- **`Logger::JSONL`** — writes one JSON-encoded event per line to a
  file. `metadata` reports `{output_file => $path}` for file-backed
  instances. See §8.1 for the wider per-logger-class artifact shape.
- **`Logger::JSON`** — snapshot logger. At `startup` writes the
  collector's `source` (its owner object's `TO_JSON`) to a `.json`
  file via `Util::JSON::write_json_file_atomic`. At `shutdown`
  atomically rewrites that same file with the original fields
  merged with the parsed child `exit` status (test-job collectors)
  or the service's final-state fields (service collectors) and,
  when an auditor is attached, the `pass`/`fail` verdict.
  `metadata` reports `{output_file => $path}`. Does not subscribe
  to events (`log_events` returns false). Requires a `spec`
  attribute at construction (spec-less `Logger::JSON` was
  disallowed as part of the drift correction; see `PLAN`'s
  "Drift 1" description).

The previous in-tree loggers `Logger::IPCNotify` and
`Logger::TestState` have been **removed** — see `PLAN`'s "Drift 2"
correction. Their role was to emit IPC messages that pretended to
be artifacts, which entangled functional control flow with
logger configuration. The functionality now lives on the collector
directly (collectors send `test_job_completed` and the related
lifecycle messages to their `ipc_run` / `ipc_harness` per §7),
with no logger in the path.

#### Artifact announcements (`collector_artifacts`)

Once every logger has completed `startup`, the collector calls
`metadata` on each one and gathers the non-`undef` results keyed by
class (multiple instances of the same class accumulate into an
arrayref). The collector sends a single `collector_artifacts` IPC
message with the gathered payload directly to:

- `ipc_run` if the collector has one (test-job, run-scoped resource,
  run-scoped preload stage, run service's own collector), or
- `ipc_harness` otherwise (harness's own collector, global resource,
  global-scope preload stage).

Artifact messages do **not** traverse `ipc_parent`. See §8 for the
complete routing rules, payload shape, and re-announcement policy.

### Spec normalisation, lazy instantiation

Loggers and auditors are passed as **specs** — class name, `[class,
%args]`, or pre-built instance. The parent normalises specs (loads
classes, checks `DOES()`, resolves `depends_on`) without constructing
them, so the parent process never opens a logger's file handle or IPC
socket. The child instantiates everything inside `_init_event_sinks`
once it owns the descriptors.

### IPC identities at collector construction

Per §2 and §5.4, every collector carries three IPC identities:

- `ipc_harness` — the canonical harness service bus name. Always
  required; passed down from the service the collector interposes.
- `ipc_run` — the run's bus name (`run_id`) when the collector is
  associated with a run. Unset for the harness's own collector,
  global resource-service collectors, and global-scope preload
  stage collectors.
- `ipc_parent` — the immediate parent service that spawned the
  collector. Always the run service for a test-job collector (even
  when launched via a preload stage — see §10.4); the harness for
  its own interpose collector's top-of-tree case may be undef or
  the command's handle identity.

Additionally, every `Collector` family class requires `ipcm_info` to
be present at construction (an `undef` value is allowed but must be
passed explicitly) so callers cannot silently default away the IPC
connection.

Collectors register on the IPC bus under
`collector:<service_name>` or `collector:<service_name>:<run_id>` —
see §5.4. The identity is self-describing; no separate lookup is
needed to tell which service a given collector belongs to.

### Stream-ordering buffer

The collector's stream-ordering logic applies to every producer that
uses the event-burst protocol — test processes (via `Stream2`) and
services (via `Util::EventEmitter`). Both producers send:

- **stdout**: framed JSON event bursts (atomic) plus any plain
  stdout the process prints itself.
- **stderr**: short JSON sync markers (`{"event_id": "..."}`)
  followed by any plain stderr.

The sync-marker rule is mandatory: every event on STDOUT is paired
with a sync marker on STDERR so the collector can order stderr
text against the events that bracket it. See §6.1 for the on-wire
contract.

The collector buffers each side until both have produced the
matching sync `event_id`, then flushes in order — so stdout/stderr
lines appear interleaved correctly relative to the events that
bracket them. For processes that never emit JSON (plain text
only), the collector flushes eagerly to avoid stalls.

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

## 21. The In-Test Formatter: `Test2::Formatter::Stream2`

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

## 22. Utility Layer

### `Test2::Harness2::Util`

Small bag of shared helpers: `mod2file`, `apply_encoding` (UTF-8-safe
`binmode` wrapper that avoids known thread bugs), `hub_truth` (extract the
canonical hub/trace facet from a facet_data hash), `parse_exit` (decode
`waitpid` status into `{sig, err, dmp, all}`), and `write_file_atomic`
(write-to-tempfile-then-`rename` for any string payload — the base of
the JSON snapshot writer).

### `Test2::Harness2::Util::EventEmitter`

Standalone JSON-event writer that does **not** depend on Test2::API
or Stream2. Used by **every service** in the harness tree
(harness, run services, resource services, preload stage
services) to emit structured events onto its own stdout, using
the same atomic-pipe protocol that `Test2::Formatter::Stream2`
uses from inside test processes. The wire format is identical so
the collector's parser consumes either without caring which
producer wrote the bytes.

Service responsibilities (per §6.2):

- Open STDOUT and STDERR as mixed-mode `Atomic::Pipe`s.
- For each event the service produces, burst the event on STDOUT
  and drop the matching `{"event_id": "..."}` sync marker on
  STDERR.
- Echo every IPC message the service receives into its own
  stdout as an event (facet under `harness` — see §6.3).

UUID generation and `event_id` consistency between the top-level
field and the `harness` facet are guaranteed at emit time. The
emitter does **not** stamp `run_id` / `job_id` / `job_try` — that
provenance comes from the event payload's fields and from the
log-file path when loggers are active.

Test processes do not use `Util::EventEmitter`; they use
`Test2::Formatter::Stream2` (see §21). Stream2 is not used
inside services.

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
via `Util::write_file_atomic` — used by `Logger::JSON` for every
snapshot file it owns), and `json_true` / `json_false` boolean
values.

### `Test2::Harness2::Event`

The single event class everything emits. `Object::HashBase` attributes:
`facet_data`, `stream_id`, `event_id` (required), `stamp`. `as_json`
caches the encoded form; `TO_JSON` deep-copies `facet_data` to avoid
serialisation surprises.

## 23. On-disk wire formats

### Atomic-pipe message format (formatter / EventEmitter → collector)

`Atomic::Pipe` in mixed-data mode interleaves two kinds of payloads on
the same pipe without corruption:

- **Plain text lines** — anything the test or service prints with normal
  `print`/`say`. Read by the collector as `[line => $text]`.
- **JSON message bursts** — written via `write_message`, read by the
  collector as `[message => $decoded]`. Each is a single Test2 event
  hashref.

### Per-test logs (`logs/runs/<run_id>/<job_id>/0.{jsonl,json}`)

Produced when (and only when) the `Logger::JSONL` and `Logger::JSON`
pair is attached to a test-job collector. Those loggers are **not**
installed by default; the artifacts exist only because a caller
(today: the `yath test` early-development default — see §12.2)
configured them.

- `0.jsonl` — one JSON-encoded `Test2::Harness2::Event` per line.
  Every event carries the `harness` facet with `event_id` and
  `stamp`. `run_id` / `job_id` / `job_try` are **not** stamped
  onto events; they come from the file path and from the bracketing
  `test_job_started` / `test_job_completed` service-level events
  (see §7).
- `0.json` — a single JSON document written by `Logger::JSON`. At
  the collector's `startup` it contains the source object's
  `TO_JSON` snapshot (for a per-test collector, the `Run::Job`
  fields). At `shutdown` it is atomically rewritten with those same
  fields plus `exit` (parsed from `child_exit`) and, when an
  auditor is attached, `pass` (0/1). **Not** load-bearing for
  functional state (see §13.0): callers query pass/fail via IPC,
  not by reading this file.

### Per-run snapshot (`logs/runs/<run_id>.json`)

Written by a `Logger::JSON` attached to the run service's own
collector (§19), not by the harness. The run service emits a
`run_mutation` harness event carrying the full `Run->TO_JSON`
payload on every state change (initial broadcast at
`service_on_start`, then each `_handle_test_job_*` transition,
final broadcast at `run_on_cleanup`). The JSON logger consumes
those events (`log_events = 1`), caches the most recent
`run_data` payload, and atomically rewrites the sidecar at
collector shutdown — stamped with the collector's `exit` and the
auditor's `pass` if either is available.

This artifact is **not** load-bearing for functional state
(see §13.0): callers query authoritative run state from the run
service via IPC. The sidecar exists for after-the-fact inspection
and renderer replay.

### Per-run-service logs (`logs/runs/<run_id>/services/<name>/<leaf>.<ext>`)

Same JSONL / JSON shape as per-test logs, but the events are the
run-scoped service's own lifecycle records. Each service gets its
own `services/<name>/` directory; per-logger leaves land inside
(`events.jsonl` from `Logger::JSONL`, `state.json` from
`Logger::JSON`). The directory itself is the run-scoped service
existence signal -- `LogArchive::services($run_id)` walks the
immediate children of `runs/<run>/services/`. Produced when a
`Logger::JSONL` / `Logger::JSON` is attached to the service's
collector (not by default).

### Service logs (`logs/services/<name>/<leaf>.<ext>`)

Same shape; events are the harness-scoped service's own lifecycle
records (§19). They carry the service's `job_id` (set at
construction) and no `run_id` — per-run and per-job IDs ride
inside the event payload's `run_data` / `job_info` fields instead.
Each service has its own `services/<name>/` directory; per-logger
leaves are `events.jsonl` (from `Logger::JSONL`) and `state.json`
(from `Logger::JSON`). The directory itself is the
harness-scoped service existence signal --
`LogArchive::services()` walks the immediate children of
`services/`. Produced only when `Logger::JSONL` / `Logger::JSON`
are attached to the service collector.

### IPC requests

Synchronous request/response over `IPC::Manager`. The Spawn handle
wraps each call as `{ request => $name, ...payload }`. Dispatch on
the service side is `request_handler_<name>`; unknown names return
`{ ok => 0, error => "unknown request '<name>'" }`. Responses are
plain hashrefs returned by the handler.

Important request kinds are defined in Part I:

- `queue_run` / `queue_test_run`, `finish_after_queued`, `status`,
  `run_status`, `get_workdir`, `list_global_artifacts`,
  `list_run_artifacts`, `get_run_status` — see §3, §4, §11.2, §13.1.
- `launch_job` — harness → run service or preload stage, with a
  configurable retry timeout (default 5 s; see §14).

### IPC general messages

Asynchronous fire-and-forget. The canonical list of message kinds,
their payload shape, and their routing is in §7. The ones defined
there are:

- `collector_started` / `collector_exiting` — collector lifecycle
  signals to `ipc_parent` (and `ipc_harness` for the detailed
  exit payload).
- `collector_artifacts` — direct to `ipc_run` if set, else
  `ipc_harness` (see §8).
- `test_job_started` / `test_job_completed` / `launched_job` —
  test-job lifecycle to `ipc_run`.
- `run_started` / `run_complete` — run lifecycle, run service to
  `ipc_harness`.

Every service echoes received IPC into its own collector as a
framed event burst (see §6.3). The facet shape is
`{ harness => { <kind> => { ... } } }` for recognised kinds;
`{ harness => { ipc_received => \%payload } }` for unrecognised.

The previous kinds `job_complete_notify` and `loggers_ready` have
been removed — see `PLAN`'s "Drift 2" correction.

## 24. External Dependencies

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
per the namespace dependency contract in §17; deps used by
`Test2::Harness2`, `Test2::Formatter::Stream2`, or `App::Yath2` may
remain hard requirements.

## 25. Coding Conventions

See `STYLE_GUIDE.md` for code style conventions.

## 26. Test Suite

`t/unit/` (or `t/AI/unit/` for AI-authored tests) holds focused tests
for individual modules (`Collector.t`, `Auditor/Test.t`, parsers,
loggers, run/job, util/IPC, util/JSON, formatters, etc.).
`t/integration/` (or `t/AI/integration/`) holds end-to-end tests that
exercise the service through `start()` or `spawn()`:

- `harness2_start.t` — single-process service start path.
- `harness2_spawn.t` — daemon spawn path with `Spawn` handle.
- `harness2_lifecycle.t` — terminate/finish/detach behaviours, both
  invariants.

Canonical runner is `perl -Ilib scripts/yath test -D -j24 [files...]`.
Verbose runs drop `-j24`.

### Authorship layout

`t/` is partitioned by who originally wrote the test:

- **`t/AI/`** — tests generated entirely by AI live here, in any
  subdirectory layout that mirrors the rest of `t/`.
- **All other `t/` locations** — reserved for tests originally written
  by humans. AI may modify these tests later as long as they remain
  clear and readable.
- Tests copied into `t/` from `reference/old2/` or `reference/legacy/` count as
  human-authored (those trees were originally authored by humans) and
  do **not** need to live under `t/AI/`.

The split lets reviewers know what level of human design went into a
test up front, without changing how the suite is run.

---

## Addendum A — `Atomic::Pipe` mixed_data_mode cross-kind FIFO (GH#389)

*Recorded 2026-04-25. Investigated as part of GH#389.*

### Conclusion: Outcome B — documented non-guarantee

`Atomic::Pipe` in `mixed_data_mode` does **not** guarantee FIFO ordering
between plain-line writes (via `print $fh "...\n"`) and `write_message`
calls on the same pipe fd, even when both come from the same process.

The upstream POD (as of v0.022) says at the top of the `DESCRIPTION`
section:

> "message order is not guaranteed when messages are sent from multiple
> processes or threads. Though all messages from any given thread/process
> should be in order."

This guarantee covers only **message-to-message** ordering from the same
writer. It makes no statement about the relative arrival order of a raw
`print` vs a `write_message` call issued immediately afterward from the
same writer process. Under kernel scheduler pressure on slow CI (observed
on containerized Perl 5.14–5.26 matrix jobs), the `write_message` burst
can land at the reader before the `print` line that was issued first on
the same fd.

This is not a bug in `Atomic::Pipe`; it is a consequence of how `print`
and `write_message` interact with the kernel's pipe buffer: `print` issues
a single unframed write (possibly split across multiple system calls for
large payloads), while `write_message` sends one or more precisely-sized
atomic chunks with framing headers. Under load, the scheduler may interleave
their delivery.

### Impact

The race is visible only on the **STDOUT pipe** — the pipe that carries
both plain text and event bursts from the same child process. The STDERR
pipe carries only sync markers written exclusively via `write_message`, so
it is not affected.

### What the Collector's read loop does (3B-3 finding)

The Collector's `_ingest_item` buffers items per-stream in arrival order
(insertion into `@{$buffer->{$stream}}`). It does **not** re-sort within a
stream; it trusts that `get_line_burst_or_data()` returns items in write
order. The sync-marker system (§6.1) ensures that STDOUT items and STDERR
items are flushed together correctly, but it cannot reorder items already
delivered out of sequence within the STDOUT stream. The `sleep 0.01`
workaround in `t/AI/unit/Collector/burst_sync.t` is therefore the active
mitigation for this race in the test suite.

### Constraints on producers (see also `EventEmitter.pm` POD)

Because the ordering gap is a kernel-level property, producer code must not
assume that a `print` issued immediately before a `write_message` on the
same pipe fd will arrive at the reader in that order. In practice this is
only a problem in testing, where a contrived script interleaves both kinds
in a tight loop. In production, the test formatter (`Stream2`) writes one
`write_message` burst per Test2 event and any surrounding `print` output
is produced by the test itself — not by the harness — so the interleaving
is coarser and the pacing is sufficient.

If a future producer needs strict cross-kind ordering guarantees, the
correct approach is a separate pipe for each kind (one for plain text, one
for event bursts), not a sleep or retry. Do not add sequencing fields to
the JSON payload: that would change the wire format and add overhead to
every event.

---

## Remaining follow-ups

Tracked here so the refactor catches them — not blockers to this
spec:

- **Service event emitter helper library** (§6.2). The on-wire
  frame is shared with Stream2 and the STDOUT / STDERR sync
  contract is the same; the service-side helper library
  implementing that contract still needs to land. Shape: a thin
  wrapper that opens STDOUT / STDERR as mixed-mode
  `Atomic::Pipe`s, accepts structured events, emits an event
  burst on STDOUT, and drops the paired sync record on STDERR.
- **Command-side artifact-to-renderer layer** (§13). Not yet
  implemented. The `OutputManager`, filter classes, and renderer
  base are in place and ready to receive events from whatever
  event source is built here.
- **CLI surfacing of the `launch_job` retry interval** (§14).
  The value lives in run data with a 5 s default today. A
  future CLI flag needs to be added when the options layer
  grows to support it.



## Addendum: zstd-compressed log artifacts (2026-04-25)

This addendum covers the zstd-loggers change. Full spec:
`docs/superpowers/plans/2026-04-25-zstd-loggers-spec.md` (gitignored
local plan); commits on the `zstd-loggers` branch; durable summary at
`AI_DOCS/2026-04-25-zstd-loggers.md`.

### Architectural mandate

Every text file written under `workdir/logs/` is zstd-compressed.
Plaintext text files in the live logdir are not allowed.
Pre-compressed binary content (images, video, audio, etc.) is out of
scope -- producers store it verbatim.

This is enforced by `t/AI/integration/logdir_all_zstd.t`, which walks
`$logdir` post-run and asserts every regular file ends in `.zst` or
sniffs as a known binary content type. Future producers landing new
binary types add to that test's allowlist.

### File extensions and shapes

| Live logdir path                   | On-disk shape                                   |
|------------------------------------|-------------------------------------------------|
| `$logdir/.../*.json.zst`           | One zstd frame per snapshot (whole-file rewrite). |
| `$logdir/.../*.jsonl.zst`          | Multi-frame: one self-contained zstd frame per jsonl line, append-safe. |

The `.jsonl.zst` shape is the load-bearing one for live tail. Each
line is its own frame, so concurrent writers can append safely as
long as a frame fits in `PIPE_BUF` (4 KiB on Linux). Readers tail
new frames as they land via `Test2::Harness2::Util::Zstd`'s
`open_zstd_reader`.

### No custom dictionary

All loggers, readers, and the tar.zidx codec use plain
`Compress::Zstd` calls with the library's default settings.

### Single archive format: `tar.zidx`

The multi-format archive support (`tar`, `tar.gz`, `tar.bz2`, `zip`,
`7z`) was deleted with this spec. `tar.zidx` is the single in-tree
archive format yath produces or reads. Tar manipulation is pure Perl
(hand-rolled ustar packing); zstd is via `Compress::Zstd` (hard
prereq). Normal write / read flow never spawns an external process.

The `tar.zidx` reader and writer live in a single consolidated
module at `lib/App/Yath2/LogArchive/TarZIdx.pm`. Per-entry index
entries gain an `inner` field (`"zstd"` for plaintext sources
wrapped in an inner zstd frame, `"none"` for already-`.zst` source
files stored verbatim).

### Dual-mode reader contract

Live logdirs are uniformly compressed; extracted trees are
plaintext. The file-reader classes split into base (plaintext) and
`::Zstd` subclass (compressed):

* `Test2::Harness2::Util::File::JSON` -- plaintext, used by
  extracted output and tests.
* `Test2::Harness2::Util::File::JSON::Zstd` -- subclass, used by
  the live logger and any consumer reading `.json.zst`.
* `Test2::Harness2::Util::File::JSONL` -- plaintext.
* `Test2::Harness2::Util::File::JSONL::Zstd` -- subclass.

Logger and streamer code picks which to instantiate based on the
file path's `.zst` suffix. The plaintext base classes never see
compressed bytes; the `::Zstd` subclasses never see plaintext.

### `Compress::Zstd` is a hard prereq

Promoted from develop-only to a hard runtime requirement. The
project no longer has a `zstd`/`unzstd` binary fallback for
compress / decompress; compressed log artifacts depend on the
in-process module. The codebase never spawns a zstd process.

### `yath extract` + `--no-decompress`

`yath extract` is two-pass. First, every member of the archive is
written to disk verbatim. Second, every `.zst` file in the extracted
tree is decompressed in-place: the plaintext lands at the
`.zst`-stripped sibling and the original is removed. The result is
a logdir-shaped tree of plaintext files. `--no-decompress` skips
the second pass and preserves the byte-for-byte archive contents
for debugging or training-input pipelines.

## Addendum: full_audit refactor (2026-04-29)

See `AI_DOCS/2026-04-29-full-audit-refactor.md` for the full
record. Headline deviations from the rest of this document:

### `App::Yath2::LogArchive::Format` is gone

Format detection collapses to a `-d` test on the path. The
catalogue indirection only made sense when there were multiple
archive formats; tar.zidx is the only one yath produces. The
`TAR_ZIDX_MAGIC` / `TAR_ZIDX_FOOTER_LEN` constants live in
`LogArchive::TarZIdx`. `viable()` and `default_writer_format()` no
longer exist.

### Loggers identify themselves by class name, not `file_ext`

The `file_ext` requirement on `Test2::Harness2::Role::Collector::Logger`
is dropped. An artifact with extension `.xyz` is produced by
`Test2::Harness2::Collector::Logger::XYZ` (also tried as `Xyz` and
`xyz`). `LogArchive` resolves the class on demand per ext and
caches the result.

### `artifacts.json[.zst]` manifest is dropped

`Test2::Harness2::_write_artifacts_manifest` and the per-run
counterpart in `RunService` are removed. The on-disk manifest is
no longer a thing. `LogArchive::artifacts` and `iter_artifacts`
walk `list_files()` and dispatch by extension. `manifest_drift()`
is gone.

### Existence of runs / jobs / services is keyed on directory
### presence

`runs()`, `jobs()`, and `services()` report every immediate child
directory of `runs/`, `runs/<run>/tests/`, and `services/`
respectively (and the equivalent run-scoped path for services).
The directory itself is the existence signal -- empty
`runs/<id>/`, `runs/<id>/tests/<job>/`, and
`services/<name>/` directories all count. The previous
`spec.json[.zst]` marker check and the `include_empty` option are
gone. `LogArchive` gains a `list_dirs()` backend method; the
Directory backend walks the filesystem, the TarZIdx backend reads
explicit directory entries from the index and additionally derives
parent-of-file paths so older archives still report their
implied shape. The TarZIdx writer records every source directory
as a typeflag-`'5'` index entry so empty directories survive
archive -> extract.

Loggers write to `services/<name>/<leaf>.<ext>` (and the
run-scoped `runs/<run>/services/<name>/<leaf>.<ext>`); the
per-logger leaf is the producer's class basename role
(`Logger::JSONL` -> `events.jsonl`, `Logger::JSON` ->
`state.json`).

### `spec.json` is logger-written

`RunService` no longer calls `_write_run_spec` directly. Instead,
`service_on_start` emits a new harness event:

    kind     => 'run_queued'
    run_data => $run->TO_JSON

`Test2::Harness2::Collector::Logger::JSON` handles the event by
writing `runs/<run_id>/spec.json.zst`, gated on `is_run`.

### `App::Yath2::LogArchive::Role::ChangeWatch` is gone

Replaced by a `static` flag on `FileMonitor` and on the
`LogArchive` base class. `Artifact` no longer carries change-watch
methods; instead it exposes `->watch` returning a fresh
`FileMonitor` with the artifact as the delegate. `LogArchive`
gains `watch_artifact($logical)` as a one-liner shortcut.

### `Test2::Harness2::Util::CwdIndex` is gone

Replaced by `./last_log.yath` (an unconditional symlink the test
command writes after every archive) plus
`App::Yath2::LogArchive->find_latest($settings)` (canonical no-arg
discovery: symlink first, else glob `${TMPDIR}/${project}-${user}-*.yath`
sorted by stamp + hi-res mtime tiebreak; refuses to glob when
project resolves to `__UNKNOWN__`).

### Project name fallback chain

`App::Yath2::Options::Yath` post-processes `--project` when not
explicitly set: rc-file dir basename, then walk up cwd looking for
`.git`/`.svn`/`.cvs`/`lib`/`t` (stops one step before `$HOME` or
`/`), then cwd basename, finally the literal `__UNKNOWN__`.

### IPC info filename / archive filename

Both shapes change from `yath-${type}-...` / `yath-${stamp}-${pid}.yath`
to a project-prefixed form:

    IPC:     ${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json
    archive: ${project}-${user}-${stamp}-${pid}.yath

`publish_ipc_file` takes `command =>` instead of `type =>`;
`find_ipc_files` filters by `command =>`. The `nonce`/`persistent`
type tag is gone from the JSON payload too.

### `Options::Logging` -> `Options::LogArchive`

The user-facing log archive destination options live in
`App::Yath2::Options::LogArchive` (group `log_archive`, category
"Log Archive Options"). `Renderer::Logger`'s separate `logging`
group is unrelated and unaffected.

### `Util::Zstd::Writer->say` embeds the newline in the frame

`Logger::JSONL` writes via `->say`, which compresses
`payload + "\n"` together. Decompressing concatenated frames
yields valid jsonl directly; `yath extract` no longer reinserts
newlines between records. The cached-compressed-frame fast path
on `Logger::JSONL` is dropped (the cache held bare bytes with no
newline).
