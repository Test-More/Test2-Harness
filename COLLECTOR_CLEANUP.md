# Collector Cleanup Analysis

Analysis-only. No code changes proposed; this document describes the
current shape, the friction points it produces, and a set of options
ordered from "safe in-tree refactor" to "extract a generic
Process-Collector distribution."

All path:line cites are current as of branch `2.0` working tree.

---

## 1. Current class graph

### 1.1 Inheritance tree

```
Test2::Harness2::Collector                       (lib/Test2/Harness2/Collector.pm:1, 1947 lines)
|
|-- Test2::Harness2::Collector::Test             (lib/Test2/Harness2/Collector/Test.pm:1, 155 lines)
|       carries auditor; defaults TestObserver; bus_id from job_id
|
\-- Test2::Harness2::Collector::Service          (lib/Test2/Harness2/Collector/Service.pm:1, 70 lines)
        |   bus_id from ipc_parent; no auditor
        |
        |-- Test2::Harness2::Collector::Service::Run        (Collector/Service/Run.pm:1, 59 lines)
        |       defaults is_run => 1 so logger paths land at runs/<run_id>
        |
        \-- Test2::Harness2::Collector::Service::Harness    (Collector/Service/Harness.pm:1, 74 lines)
                is_harness_collector => 1 (suppresses self-addressed sends)
```

The base class is itself instantiable; the four subclasses only differ
in (a) auditor presence, (b) `_build_collector_bus_id`, (c) one default
observer list, and (d) one `is_run` default.

### 1.2 Plug-in axes consumed by the collector

```
Collector
   parser     -> Test2::Harness2::Collector::Parser::IOParser            (default)
                 + Parser::IOParser::Stream  (TAP-aware variant)
                 + Parser::TapParser          (helper used by ::Stream)

   auditor    -> any class doing role Test2::Harness2::Role::Auditor
                 (only consumer in tree: Collector::Auditor::Test)

   observers  -> classes doing role Test2::Harness2::Role::Collector::Observer
                 (only in-tree: Collector::Observer::TestObserver, defaulted by ::Test)

   loggers    -> classes doing role Test2::Harness2::Role::Collector::Logger
                 (in-tree: Collector::Logger::JSONL, Collector::Logger::JSON)
```

### 1.3 Helper classes

```
Collector::Handle           parent-side stub returned to spawner    (Collector/Handle.pm:1, 141 lines)
Collector::FileLineReader   wraps non-pipe file handles            (Collector/FileLineReader.pm:1, 82 lines)
Util::IPC                   pid_is_running, swap_io,
                            list_direct_children,
                            atomic_pipe_compression_args, ...      (Util/IPC.pm:1, 422 lines)
```

### 1.4 Who calls whom

External callers of the collector class hierarchy (lib + scripts):

| Call site                                                 | Method     | Class used                                |
|-----------------------------------------------------------|-----------|-------------------------------------------|
| `Test2::Harness2.pm:289-302`                              | interpose | `Collector::Service::Harness`             |
| `Test2::Harness2::RunService.pm:230-247`                  | spawn     | `Collector::Test`                         |
| `Test2::Harness2::RunService.pm:869-883`                  | interpose | `Collector::Service::Run`                 |

Internal entry points on the base class:

| Method                      | Line                                              | Notes |
|-----------------------------|---------------------------------------------------|-------|
| `spawn`                     | Collector.pm:413                                  | new + start; replaces `$_[0]` with a Handle |
| `start`                     | Collector.pm:424                                  | "                                           |
| `_spawn_collector`          | Collector.pm:445                                  | unix fork path                              |
| `_spawn_collector_win32`    | Collector.pm:469                                  | serialize + system 1, @cmd                  |
| `collect_from_file`         | Collector.pm:557                                  | win32 child trampoline                      |
| `interpose`                 | Collector.pm:1828                                 | unix-only; parent becomes collector         |
| `_run_collector`            | Collector.pm:584                                  | the actual loop scaffolding                 |

### 1.5 Sub categories inside `Collector.pm`

The 1947-line file's `^sub` list groups naturally:

```
spec / validation / instantiation   _spec_class .. _add_logger              ~lines 176-411
spawn / start / win32 trampoline    spawn .. collect_from_file              ~lines 413-582
collector loop scaffolding          _run_collector .. _finalize_collection  ~lines 584-1202
ipc helpers                         _ipc_client .. _send_logger_metadata    ~lines 733-926
warn handler                        _make_warn_handler                      ~lines 935-957
child launching (unix + win32)      _launch_child .. _win32_quote_arg       ~lines 1231-1452
DESTROY (win32 job cleanup)         DESTROY                                 ~lines 1454-1462
io plumbing                         _wrap_handle .. _flush_buffer           ~lines 1464-1627
event dispatch                      _emit_collector_error .. _process_event ~lines 1629-1712
exit + kill                         _exit_mirroring_child, _kill_child      ~lines 1730-1809
interpose                           interpose .. _interpose_child           ~lines 1828-1945
```

That layout is roughly the natural module-decomposition the file is
asking for; see §3.

---

## 2. Pain points

Concrete things in the current code that are hard to follow.

### 2.1 One file at 1947 lines covering ten concerns

The list in §1.5 makes it explicit: the base class is doing
spec-validation, lazy spec-instantiation, fork spawning, win32
re-exec, child-process launching (two platforms), pipe wrapping,
atomic-pipe message demux + reorder buffering, observer/auditor/logger
pipeline, IPC sending, exit-status mirroring, kill escalation, and
the `interpose` flow. Every reader has to skim past nine of them to
reach the one they care about.

### 2.2 Auditor is wired into the base class as "no-op"

`Collector.pm:74-81` defines `auditor`, `_auditor_spec`,
`_normalize_auditor`, `_instantiate_auditor` as default no-ops on the
base class, then `Collector::Test` (Test.pm:18-23, 47-101) shadows the
HashBase slot and replaces the four methods with working versions.
The base class therefore has type-shape that pretends an auditor
might exist; the only working consumer is the test subclass. All
observer / logger code threads `auditor` through (`Collector.pm:267,
275, 283, 368, 378, 387, 686-688, 1181-1183, 1689-1693`) even though
service collectors will always see undef. The "auditor is a Test
concept" fact is invisible from the base class's surface.

### 2.3 Win32 path forks the file in two

Every major operation in `Collector.pm` is "unix path then win32 path":

- `_spawn_collector` (445) vs `_spawn_collector_win32` (469) +
  `collect_from_file` (557).
- `_launch_child_unix` (1271) vs `_launch_child_win32` (1345) +
  `_launch_child_win32_job` (1393) + `_check_new_pgroup_supported_on_win32`
  (1330) + `_win32_quote_arg` (1446) + `_win32_spawn` (1320).
- `_kill_child` (1778) branches at line 1785.
- `interpose` croaks on win32 at 1832.
- `DESTROY` (1454) only exists for win32 cleanup.

Of the file's 1947 lines, ~340 (lines 469-582 and 1320-1452 and a
handful elsewhere) are win32-specific. Anyone tracing the unix path
has to skim past blocks that are dead code on their platform.

### 2.4 Init / lifecycle ordering is implicit but load-bearing

`init` (Collector.pm:95) dictates an order that the rest of the file
depends on:

1. Spec normalization runs in init in the parent process.
2. Real constructors for auditor/observers/loggers run later in
   `_init_event_sinks` (Collector.pm:667) inside the collector
   *child*, with very deliberate ordering between auditor startup
   events, observer startup events, and the logger replay
   (Collector.pm:678-705).
3. Shutdown mirrors that ordering (Collector.pm:1175-1199).

The reason for the split (don't open files in the parent that the
fork would then duplicate) is in a comment block at lines 290-295 and
324-326, but the staged behavior is spread across four methods. There
is no single "lifecycle" view; you have to read all of `_normalize_*`,
`_instantiate_*`, `_init_event_sinks`, `_finalize_collection`, and the
two `_pipe_through_observers` calls to assemble the picture.

### 2.5 Bus-id derivation by subclass override

`_build_collector_bus_id` (Collector.pm:796) returns a base-class
fallback; `Collector::Test` (Test.pm:36-43) overrides to use job_id;
`Collector::Service` (Service.pm:17-24) overrides to use ipc_parent;
`Collector::Service::Harness` (Service/Harness.pm:15) sets
`is_harness_collector` so two unrelated send sites
(Collector.pm:898 in `_send_logger_metadata`, and the comment at
Collector.pm:84-91) silently no-op. That is four classes coordinating
on one identity decision via three different mechanisms (override,
override, flag).

### 2.6 The "harness collector" special-case is shouted three places

- Subclass `Collector::Service::Harness` exists solely to flip a flag.
- `is_harness_collector` is read at `Collector.pm:898`.
- The base class's `init` croaks if `ipc_harness` is undef
  (Collector.pm:108-109), and the only legitimate caller that has no
  parent service still passes `ipc_harness` (`Test2::Harness2.pm:294`),
  so the special case is not actually about missing harness — it's
  about send-to-self.

### 2.7 Compression / Atomic-Pipe knowledge leaks across modules

The collector reads compressed bytes via Atomic::Pipe's keep_compressed
mode (`Collector.pm:1503-1521`), threads the bytes as a third tuple
element through `_ingest_item` (1531-1582), passes them as the
`compressed` kwarg to `parser->parse_io` (1598-1606), the
`IOParser::parse_io` then stashes `$event->{compressed_form}`
(`Parser/IOParser.pm:47-54`), and the JSONL zstd logger consumes that
on the other side. Three modules and the Event class know about a
single pass-through optimisation.

### 2.8 `Collector::Service::Run` exists only to default a flag

`Collector/Service/Run.pm:15-19` overrides `init` solely to set
`IS_RUN //= 1`. That is a one-line `init` override running through a
separate subclass file with its own POD. A configuration option on
the parent class would do the same job.

### 2.9 `interpose()` mixes class-method dispatch and `_OWNS_CHILD`

`interpose` (1828) is a class method that forks, builds an instance
in the parent, and runs the loop. It uses an underscored-constant
HashBase slot via `$params->{_OWNS_CHILD()} = 1` (1910) — the only
caller of that constant — and remaps `out_r/err_r` -> `stdout/stderr`
(1908-1909) to feed `init`. It is also the only entry point that
needs `Long::Jump` and `jump_payload`. None of that fits the
"collector class" mental model — it is a separate use-case (turn
this process into a collector) crammed into the same file.

---

## 3. In-tree simplification options

Each option is independent unless noted. None of them changes the
external API surface (`spawn`, `interpose`, `Collector::Test->spawn`,
`Collector::Service::*->interpose`).

### 3.1 Move the auditor wiring out of the base class onto a role

What: Define `Test2::Harness2::Role::Collector::HasAuditor`
that adds the four methods (`auditor`, `_auditor_spec`,
`_normalize_auditor`, `_instantiate_auditor`) and the HashBase slot.
`Collector::Test` consumes the role. The base class drops the four
no-op stubs and the calls in `_init_event_sinks`,
`_instantiate_loggers`, `_instantiate_observers`, `_finalize_collection`,
and `_process_event` learn to `can` or call through a single helper.

Pros: removes the "pretend an auditor might exist" smell from the
base class; makes the test-only nature of auditing explicit; reduces
the per-call `defined $self->auditor ? ...` clutter in three
instantiate methods (Collector.pm:275, 283, 368, 378, 387).

Cons: roles in `Role::Tiny` cannot share HashBase slots cleanly with
the consumer's own slots, so the auditor slot probably has to stay on
the consumer class — the role only lifts the methods and the
auditor-aware code paths in Collector.pm. Net win is moderate, not
large.

Scope: ~1 new role module (~80 lines), ~30 lines deleted from
Collector.pm, ~40 lines moved to Collector::Test.

### 3.2 Split Collector.pm by concern

What: Break `Collector.pm` into co-located helper modules without
changing the public class:

- `Collector/Util.pm` — public kit: spec helpers (`_spec_class`,
  `_validate_spec`), Win32 quoting (`_win32_quote_arg`), select-fh /
  read-handle / wrap-handle helpers, the warn-handler factory.
- `Collector/Loop.pm` (or a role) — `_run_collection_loop`,
  `_ingest_item`, `_flush_buffer` and the ordering buffer.
- `Collector/Launcher.pm` (or a role) — `_launch_child`,
  `_launch_child_unix`, `_launch_child_win32`, `_launch_child_win32_job`,
  `_win32_spawn`, `_check_new_pgroup_supported_on_win32`,
  `_kill_child`, `DESTROY`. Possibly factored as Win32 vs Posix
  subclasses (see §3.4).
- `Collector/IPC.pm` (or a role) — `_ipc_client`,
  `_wait_for_ipc_target`, `_send_to`, `send_ipc`,
  `_send_logger_metadata`.
- `Collector/Pipeline.pm` (or a role) — `_init_event_sinks`,
  `_finalize_collection`, `_pipe_through_observers`, `_process_event`,
  `_emit_collector_error`.
- `Collector/Interpose.pm` — `interpose`, `_interpose_parent`,
  `_interpose_child`.

Pros: each file is 100–300 lines instead of 1947; each tells one
story; the base class file becomes a top-level orchestrator that
delegates. Maps directly onto §1.5.

Cons: roles touch the same hash, so wrong cuts produce attribute
collisions; `local $SIG{...}` stuff in `_run_collector` (606-624)
must remain in whatever module owns the loop because `local` in a
helper unwinds when the helper returns, not when the loop ends — so
the signal-handler installation can't migrate freely. The same is
true for the `Scope::Guard` patterns in `_spawn_collector` and
`collect_from_file`. Roles also obscure callgraphs unless each role
sticks to a tight sub-vocabulary.

Scope: largest of the in-tree options. Pure code motion + some
attribute-leakage discipline. No behavior change.

### 3.3 Replace `Collector::Service::Run` and `Collector::Service::Harness` with attributes

What: Drop both subclasses. Move `is_run` to a constructor knob
already present (it is) and move the harness `is_harness_collector`
flag to a constructor knob; let the call sites pass the flag
explicitly.

Pros: removes two classes whose entire body is one method or one
default; brings the four-class hierarchy down to two classes
(`Collector` + `Collector::Test` + `Collector::Service`, where
`Service` is also pretty thin). The "what subclass do I want?"
decision shrinks to one binary (do I have an auditor?), which is the
real distinction.

Cons: the harness-interpose call site
(Test2::Harness2.pm:289-302) is currently typed by class — the
explicit `Collector::Service::Harness->interpose(...)` is a
self-documenting hint at the call site that reads "this is the
top-of-tree variant." Replacing it with
`Collector::Service->interpose(..., is_harness_collector => 1)`
shifts that doc burden onto the kwarg. Two existing CPAN-side
subclassers (none found in tree, but possible externally) would
break.

Scope: small — ~150 lines of subclasses deleted, two call sites
updated, `Collector::Service::Run`'s `is_run //= 1` default moved
to either `Collector::Service::init` or
`Test2::Harness2::RunService::start` directly.

### 3.4 Win32 split: subclass vs separate dispatcher

What: Three sub-options, ordered from cheapest to deepest.

(a) Push the Win32 paths into a sibling module that the base class
loads only when `IS_WIN32`. `Collector.pm` keeps the unix path
inline; `Collector::Win32` defines `_spawn_collector_win32`,
`_launch_child_win32`, `_launch_child_win32_job`, `_win32_spawn`,
`_check_new_pgroup_supported_on_win32`, `_win32_quote_arg`, the
win32 branch of `_kill_child`, and `DESTROY`. Loaded via
`require Collector::Win32 if IS_WIN32` in Collector.pm.

(b) Same as (a) but as a Role::Tiny role mixed in only when
`IS_WIN32`. Same effect, more idiomatic.

(c) Two top-level classes: `Collector` (posix) and `Collector::Win32`
that share a small base or role with the platform-neutral parts. The
public callers pick at construct time:
`my $class = IS_WIN32 ? 'Collector::Win32' : 'Collector'; $class->spawn(...)`.

Pros: option (a) is the smallest possible behavior-equivalent change
with the largest readability win — the unix file shrinks by ~340
lines and the IS_WIN32 branches collapse to one dispatch site each.
Option (c) is the cleanest but pushes a class-pick onto callers.

Cons: option (a) and (b) leave a few `IS_WIN32 ? this : that`
dispatch sites in the base file (the `interpose` "not supported"
croak, the `_spawn_collector` first line). Option (c) requires an
external API change because callers currently say
`Test2::Harness2::Collector::Test->spawn(...)`; that test-job class
has no platform variant, so the split would need a factory pattern
to pick the platform underneath the test/service axis. It's the
biggest change for a feature (Win32) that sees the least testing.

Scope: (a) ~200-line module-extraction; (b) similar; (c) much larger
because the inheritance axis multiplies (test x posix, test x win32,
service x posix, service x win32 -> roles required to keep the matrix
sane).

### 3.5 Roles to consider

Distinct from §3.2's split-into-modules, these are role candidates
even if the file stays whole:

- `Role::Collector::Loop` — `_run_collection_loop` + helpers, factored
  so the loop is reusable for non-test contexts (matches a chunk of
  the Process-Collector goal in §4).
- `Role::Collector::HasAuditor` — see §3.1.
- `Role::Collector::IPC` — `send_ipc`, `_send_to`,
  `_wait_for_ipc_target`, `_send_logger_metadata`. Separates the
  harness-IPC concern from the generic collector concern; valuable
  in particular if §4 happens.
- `Role::Collector::ObserverChain` — `_pipe_through_observers`,
  `_process_event`, `_emit_collector_error`. Useful even without
  extraction.

Pros: the second and fourth roles correspond directly to "harness
features" vs "process-supervision features" — a clean split point
for §4. Distinguishing the two via roles inside the same dist is the
low-risk preview of "what if we extracted Process-Collector?"

Cons: piling roles onto a HashBase class is fine in this codebase
but does cost discoverability — three roles, a HashBase slot list,
and an inheritance chain together can be harder to follow than one
big file. Each role earns its keep only if the boundary it draws
matches a real call-graph cut.

Scope: medium per role, ~150-300 lines moved each.

### 3.6 Util module candidates

What: A `Test2::Harness2::Collector::Util` (or extend
`Test2::Harness2::Util::IPC`) absorbs the standalone helpers:

- `_spec_class`, `_validate_spec` — currently class methods that take
  no instance state (Collector.pm:176-216). Both are pure functions
  that fit a `Util::Spec` perfectly.
- `_win32_quote_arg` (1446) — pure function.
- `_make_warn_handler` (935) — only depends on the collector for
  `_process_event`; could become `make_warn_handler($cb)`.
- `_kill_child` (1778) — only depends on `KILL_TIMEOUT`; would be
  `kill_child($pid, %opts)` in a util.
- `swap_io`, `pid_is_running`, `set_procname`, the IPC defaults — all
  already in `Util/IPC.pm:1`. Extending that module is the natural
  home.

Pros: pulls 200+ lines of pure helpers out of the class, leaves the
class file with class-shaped code only. Most candidates here are
also exactly what Process-Collector would want as utilities (§4).

Cons: a few of them (`_make_warn_handler`) are named with a leading
underscore precisely because they were intended to be private; if
they move to a util module they should drop the underscore, which
makes the rename slightly visible.

Scope: small. ~150 lines moved, no behavior change.

---

## 4. Process-Collector extraction analysis

The user has classified each capability as generic or harness-specific.
Mapping that onto current code:

### 4.1 Generic capability -> current code site

| Capability                                        | Currently lives at                                                     |
|---------------------------------------------------|------------------------------------------------------------------------|
| Atomic::Pipe for stdout/stderr                    | Collector.pm:1237-1238 (pair), 1464-1485 (wrap), 1499-1529 (read)      |
| Atomic-pipe zstd compression                      | Util/IPC.pm:108-140 + Collector.pm:1237, 1479                          |
| Message-burst protocol (decode JSON-frames)       | Collector.pm:1499-1583 (`_read_handle`, `_ingest_item`, `_flush_buffer`)|
| Get child exit code                               | Collector.pm:1086-1100, 1117-1124, 1140-1144                           |
| Watched-process action loop                       | Collector.pm:959-1128 (`_run_collection_loop`)                         |
| Optional merged stdout/stderr                     | Collector.pm:976-977 + flush_buffer ordering                           |
| Spawning the child                                | Collector.pm:1231-1318 (unix), 1345-1441 (win32 + job)                 |
| Spawn collector then child                        | Collector.pm:413-466, 469-582 (spawn + win32 trampoline)               |
| Become collector + fork child (interpose)         | Collector.pm:1828-1945                                                 |
| Retain clones of STDOUT/STDERR in collector       | Collector.pm:1242-1255, 1313-1316, 1851-1852, 1900-1905                |
| Optional redirect of collector's STDOUT/STDERR    | Currently always restored; configurable point not yet exposed         |
| Cross-platform                                    | Collector.pm + Util/IPC.pm:17 (HAS_PARSEABLE_PROC), and the Win32 forks|
| Use exec() in child post-fork                     | Collector.pm:1309 (exec @$cmd)                                         |
| Specify a sub to run as the child                 | Today only `interpose` provides "child runs caller's code"; no exec-vs-coderef matrix on the spawn path |
| Long::Jump integration                            | Collector.pm:1842-1846, 1875-1880                                      |
| Zstd on Atomic::Pipe messages, not on raw bytes   | Util/IPC.pm:93-140, atomic_pipe_compression_args + apply_*             |

Each of these is implemented in a way that does not depend on
`IPC::Manager`, `Test2::Harness2::Event`, or any `Test2::*` concept.
The only Test2 dependency in the launching/looping/exit-mirroring
code is `Test2::Util::IS_WIN32` at Collector.pm:93, which is trivial
to vendor or replace with a `$^O` check.

### 4.2 Stays in Test2::Harness2

| Concern                                                    | Currently lives at                                              |
|------------------------------------------------------------|-----------------------------------------------------------------|
| Auditor (parser -> auditor -> logger flow)                 | Collector.pm:1679-1712, plus all of Collector::Auditor::Test    |
| Logger contract (role + JSONL/JSON in-tree implementations)| Role/Collector/Logger.pm, Collector/Logger/*                    |
| Observer chain                                             | Role/Collector/Observer.pm, Collector::Observer::TestObserver   |
| Parser contract (IOParser/IOParser::Stream/TapParser)      | Collector::Parser::*                                            |
| IPC::Manager send + bus-id management                      | Collector.pm:733-926                                            |
| ipc_parent / ipc_run / ipc_harness identity                | Collector.pm:54-57, all the `_send_to` / bus-id code            |
| `is_harness_collector` self-send suppression               | Collector.pm:91, 898; Service/Harness.pm:15                     |
| `_send_logger_metadata` (collector_artifacts message)      | Collector.pm:893-926                                            |
| `_emit_collector_error` (synthesizes Test2::Harness2::Event)| Collector.pm:1629-1653                                          |
| harness_process_exit facet construction                    | Collector.pm:1140-1173                                          |
| Logger / observer / auditor attribute threading            | Collector.pm:249-411 (instantiate_*)                            |
| Test2::Harness2::Event itself                              | Event.pm                                                        |

These are all Harness-2-specific.

### 4.3 Mapping to a clean cut

The cut largely lines up with §3.2 + §3.5. The "process supervision"
core that would move to a `Process::Collector` distribution is:

```
Process::Collector  (new dist)
   spawn / start / interpose                   from Collector.pm:413-582, 1828-1945
   _run_collector loop scaffolding             from Collector.pm:584-661
   _run_collection_loop                        from Collector.pm:959-1128
   _setup_child_handles                        from Collector.pm:640-661
   child launch on unix + win32                from Collector.pm:1231-1452
   _kill_child                                 from Collector.pm:1778-1809
   _exit_mirroring_child                       from Collector.pm:1730-1776 (minus IPC drain)
   _wrap_handle / _select_fh / _read_handle    from Collector.pm:1464-1529
   _ingest_item / _flush_buffer (ordering buf) from Collector.pm:1531-1627
   atomic-pipe compression helpers             from Util/IPC.pm:93-140
   FileLineReader                              from Collector/FileLineReader.pm
   Collector::Handle                           from Collector/Handle.pm
   set_procname / swap_io / pid_is_running     from Util/IPC.pm:142-197
   _make_warn_handler                          from Collector.pm:935 (genericized: takes a callback)
   Long::Jump integration                      from Collector.pm:1842-1880
```

Test2::Harness2 would then have a thin subclass/role that adds:

```
Test2::Harness2::Collector  isa  Process::Collector
   _ipc_client / _send_to / _wait_for_ipc_target / send_ipc
   _send_logger_metadata
   parser/auditor/observer/logger spec validation + instantiation
   _process_event / _pipe_through_observers / _emit_collector_error
                       (these synthesize Test2::Harness2::Event)
   harness_process_exit facet construction in _finalize_collection
   ipc_parent / ipc_run / ipc_harness / bus_id attributes
   is_harness_collector flag and its send-suppression site
```

### 4.4 Riskiest entanglement points

These are the spots where the generic / specific boundary is currently
blurred and would need real care:

1. **`_run_collector` signal handlers + `_ipc_client` drain inside the
   loop.** `_run_collection_loop` (Collector.pm:1004-1035) does
   `client->drain_pending` and `client->writable_handles` inline. The
   loop is generic; the IPC client is harness-specific. The clean
   split is "loop accepts an optional outbox-drain callback," but
   today the collector hard-codes the IPC client lookup. Touching
   this is the single biggest mechanical rewrite for an extraction.

2. **`_exit_mirroring_child` does an IPC drain** (Collector.pm:1740-1752)
   before exiting. That drain is harness-specific (it is flushing
   IPC::Manager queues). Generic process-collectors should not know
   about IPC outboxes. Same pattern as (1): provide a hook the
   subclass plugs into.

3. **`_emit_collector_error`** (Collector.pm:1629-1653) builds a
   `Test2::Harness2::Event` with a specific facet shape. Generic
   collectors need a "tell me about a collector failure" callback;
   the harness subclass turns that into a Test2 event. The two
   kill-paths in `_run_collection_loop` (Collector.pm:1108-1112) and
   `_spawn_collector` (Collector.pm:463) call this directly.

4. **`_finalize_collection` builds a `harness_process_exit` facet**
   (Collector.pm:1140-1173). The exit-status math (parse_exit, child
   wall, child cpu) is generic; the facet shape is harness-specific.
   Generic should expose a "child finished, here is the
   exit/timing struct" hook; harness wraps that into the facet.

5. **`_init_event_sinks`** (Collector.pm:667-725) is the most heavily
   harness-specific scaffolding: auditor + observer + logger startup
   ordering, replay through observer chain, `_send_logger_metadata`.
   None of it belongs in a generic dist. But the loop calls into
   `_process_event` which calls into the auditor + observers + loggers
   chain (Collector.pm:1679-1712), so the loop has to call something —
   the cleanest cut is "the generic loop hands every parsed item to a
   single user-supplied callback; the harness subclass installs that
   callback to be `_process_event`."

6. **Spec/instantiate machinery** (Collector.pm:189-411). It validates
   that a spec implements a Role::Tiny role, instantiates lazily in
   the child, and threads `ipcm_info`, `auditor`, `loggers_lookup`
   into constructors. The spec mechanism is generic in shape but
   every concrete role name (Auditor, Logger, Observer) is
   harness-specific. A generic `Process::Collector` could expose a
   "register spec category with role name and identity-injector"
   API, but doing so risks over-generalizing for one consumer.

7. **`interpose`'s `_OWNS_CHILD` and stdin/stdout remap**
   (Collector.pm:1908-1910). This is generic in spirit. The harness
   uses `interpose` for service-process collection; nothing about
   that pattern is harness-specific.

8. **HashBase slots are shared by base + subclasses.** `ipcm_info`,
   `ipc_parent`, `ipc_run`, `ipc_harness`, `bus_id` (Collector.pm:54-58)
   are HashBase slots on the base class. If `Process::Collector`
   becomes the base, those slots have to move to the harness
   subclass (HashBase happily allows that). It's mechanical but each
   call site in the base class that reads them today
   (`_build_collector_bus_id`, `_send_to`, `_send_logger_metadata`)
   has to move with the slots.

### 4.5 Things the user listed that aren't in the code today

- "Optionally redirect collector STDERR/STDOUT, or keep them" — today
  the collector always restores its own STDOUT/STDERR after launching
  the child (Collector.pm:1313-1315, 1382-1383, 1900-1905). There is
  no knob exposed to keep them swapped. Adding it is independent of
  extraction and small.
- "Ability to specify a sub to run as the child" via the spawn path —
  today only `interpose` runs caller code as the child; the spawn
  path always `exec`s. A `command => $arrayref` vs `code => $sub`
  selector on the spawn API would need to be added; trivial under
  unix (replace exec with calling the sub then `_exit`), still
  trivial under win32-fork-emulation but not really viable under
  win32 system(1, @cmd).

Both of those are small additions to the generic core regardless of
whether extraction happens.

### 4.6 What the extraction is actually buying

- **Reuse value:** the supervision core (atomic-pipe demux, ordered
  flush buffer, exit mirroring, signal/parent-pid/timeout handling,
  win32 job-object cleanup) is the kind of thing other Perl
  programs would happily depend on — there is no equivalent on CPAN
  that combines all of it.
- **Cognitive value for the harness:** the Harness2 collector code
  shrinks to "the harness-specific event-pipeline glue that drives
  Process::Collector" — a much smaller mental model.
- **Test value:** Process::Collector can be tested in a vacuum
  (no IPC bus, no Test2 events, no auditor) — currently every
  collector test has to set up `ipcm_info` and at least a stub
  parser.

Costs:
- Two repos to keep in sync during the rewrite.
- A new published distribution; the harness becomes another
  consumer of an upstream we control. Version pinning + bug-fix
  release latency become real concerns.
- The riskiest entanglements (4.4 #1, #2, #3) are exactly the ones
  that determine the API the harness will live with.

---

## 5. Recommendation

**Do §3.3, §3.4(a), and §3.6 first, in tree, no extraction.**

That is:

1. Replace `Collector::Service::Run` and `Collector::Service::Harness`
   with constructor flags (§3.3). Saves two classes for two flags.
2. Push the Win32 paths into `Collector::Win32` loaded only on win32
   (§3.4 option a). Removes ~340 lines of platform-dead code from
   the unix-side reader's view.
3. Move the pure helpers (`_spec_class`, `_validate_spec`,
   `_win32_quote_arg`, `_kill_child`, `_make_warn_handler`,
   `FileLineReader`) into `Test2::Harness2::Collector::Util`
   (§3.6). Drops another ~200 lines from `Collector.pm`.

After those three, `Collector.pm` is roughly 1000 lines instead of
1947 and the reader's mental model is "init -> spawn -> loop ->
finalize" without the Win32 fork and without the trivial-subclass
noise.

**Defer Process-Collector extraction (§4) until at least #1 and #2 of
the riskiest entanglements (§4.4) have been resolved internally.**
Specifically: introduce the "loop drains an optional outbox callback"
hook and the "exit hands an exit-status struct to a callback" hook
inside Test2::Harness2::Collector first. Once those hooks exist and
the harness uses them, the subsequent mechanical extraction into
Process::Collector becomes a near-rename. Trying to design those
hooks at the same time as the extraction is the failure mode that
leads to a generic API that is shaped exactly by one consumer's
needs and then has to be widened later.

**Strongest argument against this recommendation:**
extraction-first is the only way to know the abstraction is right.
Every "first I'll factor it cleanly internally, then I'll lift the
boundary" plan in this codebase's history has produced a boundary
that turns out wrong when the second consumer arrives. If
Process::Collector is going to happen, the user (Chad) is the
likeliest second consumer, and he already knows what he wants from
it (the bullet list in the prompt). Putting the dist on CPAN now,
even with rough edges, gets feedback from the real second consumer
(non-harness uses) before the API is set.

Counter-counter: of the eight risky entanglement points, six are
already isolated to specific methods — the file is structured well
enough that the boundary is mostly visible. The genuinely uncertain
parts are #1 (loop / outbox drain) and #5 (event-sink scaffolding).
Doing the in-tree refactor first does not lock anything in; it just
makes the remaining surface easier to extract cleanly later.

So the recommendation stands, with the caveat that if the user has a
near-term second consumer in mind, the calculus flips and §4 becomes
worth doing now even at the cost of one or two API revisions later.
