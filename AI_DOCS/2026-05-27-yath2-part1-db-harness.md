# Design: yath 2.0 Part 1 — DB-backed harness

Status: approved design (2026-05-27). Implements the "Part 1" task list in the
repository `next` file.

## Goal

Stand up the first end-to-end slice of the yath 2.0 rewrite: a `yath test`
command that creates a SQLite harness database, starts a runner process,
queues a run, executes its test files one at a time, audits each test's
pass/fail into the database, and reports per-job results before exiting with a
status that reflects whether every job passed.

Deferred (explicitly out of scope for Part 1): argument processing beyond a
bare file list, inline test directives, renderers (we only print test name +
pass/fail), non-SQLite database flavors, runner tagging / shared run queues.

## Known limitations / follow-ups (as built)

These surfaced during implementation review and are deliberately left for a
later pass; the Part 1 happy path is unaffected:

- **No parent-death watchdog on the runner-collector.** The `Collector`
  supports `watch_parent_pid`, but `start_runner` does not yet pass the
  command's pid into the runner-collector. On the normal path the command sets
  the runner to `stop` immediately after queueing, so the runner drains its run
  and self-terminates even if the command later dies. A command killed in the
  brief window before `set_runner_mode(..., 'stop')` would leave a runner in
  `run` mode. Follow-up: wire `watch_parent_pid => <command pid>` into the
  runner-collector.
- **`App::Yath2::Command::test` poll loop has no timeout.** If a runner died
  before stamping `run.stopped`, the command would block forever. Follow-up:
  add a bounded deadline (the runner smoke test already uses one).
- **`collector.exit_code`/`exit_signal` record the collector process's own
  status** (always 0 on a clean pipeline), not the collected child's status —
  the child's exit rides the `harness_process_exit` event.
- **Single-process re-runs against different db_paths** are not supported: the
  QuickORM ORM is a process-global singleton and `connection` only attaches the
  db once per process. Nothing in Part 1 does this (each `yath test` is its own
  process with one db_path); revisit if in-process multi-run is ever needed.

## Foundational constraints (from ARCHITECTURE.md / AGENTS.md)

- `Object::HashBase` for objects, `Role::Tiny` for roles, `parent` for
  inheritance.
- UUIDs are v7, generated in Perl via `Test2::Util::UUID::gen_uuid`, never in
  the database.
- Row layer is `DBIx::QuickORM`; the schema autofills by introspecting the
  live database. `share/schema/<flavor>.sql` is the table-creation source of
  truth; QuickORM never creates tables.
- No `IPC::Manager`. Cross-process state goes through the harness database;
  transient bytes between processes go through `Atomic::Pipe` (already used by
  the collector).
- `use v5.38;` everywhere; signatures mandatory where they fit.
- Reference trees under `reference/` are immutable: copy out, modify the copy.

## Process topology

```
yath  [COMMAND proc]   App::Yath::Script::V2 -> App::Yath2 -> Command::test
 |  create ./<uuid>.sqlite, load share/schema/sqlite.sql into it
 |  Test2::Harness2->new(connect => sub { fresh DBI sqlite handle })
 |  $h->start_runner
 |     \- fork  [RUNNER-COLLECTOR proc]  owns the collector row + runner-events artifact
 |           Collector->run_collector(run_sub => runner loop, is_test => 0)
 |              \- fork  [RUNNER proc]   runner row + service row (shared uuid)
 |                    Role::Service loop: grab a run -> per job -> fork a test collector
 |                       \- fork [TEST-COLLECTOR proc]  collector row + try-events artifact
 |                            Collector->start(is_test => 1,
 |                                exec_command => [$^X, '-Ilib', 't/x.t'],
 |                                processor    => Auditor(try row))
 |  $h->queue_run(@files)  -> txn: insert run + one job per file; set runner mode='stop'
 |  poll until run.stopped is populated (Time::HiRes::sleep)
 |  print each job's last-try pass/fail
 |  $h->finalize_run($run_uuid)  -> delete on-disk events files, null their local_path
 |  exit 0 if every job has a passing try, else non-zero
```

Key decisions baked into the topology:

- The runner is wrapped by a collector, but **only the collector process holds
  the `collector` row**. The collector row is not passed down to the runner.
  The runner process itself gets two rows: the `runner` row and a `service`
  row, which share one UUID (the runner is also a service).
- The auditor runs **in-process** as the test-collector's `processor`
  (`Test2::Harness2::Collector::Role::Processor`), so it sees each event as it
  streams and updates the `try`/`job`/`subtest` rows directly. Events are still
  written to the events file unchanged.
- Every forked process opens its **own** fresh `DBI` handle via the connect
  callback. DBI handles are never shared across a fork.

## Components

### New modules

- `lib/Test2/Harness2.pm` — the primary interface.
  - `new(credentials => ... | connect => ... | ephemeral => $flavor)`.
    `connect` is an alias for `credentials`. `credentials` accepts a coderef
    returning a fresh DBI handle, a hashref, or a `Role::Credentials`
    consumer. `ephemeral` (deferred past Part 1 beyond a stub) would create a
    `DBIx::QuickDB` instance; Part 1 only needs the connect-callback path.
  - `connection` — lazily attaches the connect callback to the `harness` ORM
    and returns a `DBIx::QuickORM::Connection`.
  - `start_runner(...)` — inserts the runner + service rows, forks the
    runner-collector process, returns the runner UUID.
  - `queue_run(@files)` — in one transaction, inserts a `run` row plus one
    `job` row per file (with `runner_uuid` set so this runner picks it up).
    Returns the run UUID.
  - `finalize_run($run_uuid)` — deletes the on-disk events files for the run's
    artifacts and nulls their `local_path` (the `data` blob was already
    populated by the collector at close).

- `lib/Test2/Harness2/Role/Credentials.pm` — role a deployment consumes to
  supply credentials or a `connect` sub for the ORM (encrypted files, secret
  stores, etc.). Part 1 ships the role contract plus the trivial
  connect-callback path.

- `lib/Test2/Harness2/Role/Service.pm` — ported from `reference/old4`'s service
  role: a small `run` loop driving `tick` (returns true when work was done) and
  `should_stop`, with `on_start`/`on_stop` lifecycle hooks, adaptive backoff
  sleep via `Time::HiRes::sleep`, and a USR1 `wake`. No IPC::Manager.

- `lib/Test2/Harness2/Runner.pm` — the runner service (consumes Role::Service).
  Per `tick`: ask the scheduler for the next actionable job in an assigned run;
  if found, create its `try` row and fork a test collector for it; reap
  finished test collectors; when a run's jobs are all resolved, set
  `run.passed` and `run.stopped`. `should_stop` is true when mode is `stop` and
  no work remains, or mode is `kill`.

- `lib/Test2/Harness2/Scheduler.pm` — internal state object (no DB row). Tracks
  which jobs are pending / running and decides retries. Part 1: each job gets a
  single try; another try is created only when the prior try's `should_retry`
  is set (and a retry cap is not exceeded). Default: no retries.

- `lib/Test2/Harness2/Collector/Auditor/Test.pm` and
  `lib/Test2/Harness2/Collector/Role/Auditor.pm` — ported from
  `reference/old4`, converted to `use v5.38;` + signatures and the
  "named subs in object modules are methods" rule. Implements Role::Processor:
  `process_event` delegates to the existing `audit_event` (which tracks
  assertions/plans/subtests/exit and returns events to forward). The auditor
  holds the `try` row; on the `harness_process_exit` event it computes the
  verdict and writes `try.passed` (and `try.should_retry` when a retry event
  was seen), inserts `subtest` rows for top-level subtests, and updates
  `job.passed` when no further try is expected.

### Edited modules

- `lib/Test2/Harness2/Collector.pm` — add two **optional, duck-typed**
  attributes: `collector_row` and `artifact_row`. The launching process (the
  collector parent, which owns a DB connection) creates these rows from the
  schema and passes them in. The Collector itself only calls generic
  `->update` / `->field` / `->save` on them:
  - after the fork, set `collector_row` `child_pid`;
  - at finalize, set `collector_row` `stopped`, `exit_code`, `exit_signal`,
    and read the events file's bytes into `artifact_row.data`.
  Both attributes are optional; when absent the collector behaves exactly as
  today, so the existing collector tests stay green. This keeps QuickORM /
  schema knowledge out of the generic collector.

### UI side (App::Yath2)

- `lib/App/Yath/Script/V2.pm` — the hook `App::Yath::Script` discovers and
  loads. Provides `do_begin(%params)` and `do_runtime()` (returns the exit
  code), wiring the `yath` script to `App::Yath2`.
- `lib/App/Yath2.pm` — discovers and dispatches the requested command.
- `lib/App/Yath2/Role/Command.pm` — Role::Tiny role consumed by every
  command. `requires 'run'`; provides default `name` / `summary` /
  `description` class-method getters. Commands hold their own `argv` slot
  via `Object::HashBase`.
- `lib/App/Yath2/Command/test.pm` — the Part 1 `yath test` command. Takes a
  bare list of test files, drives Test2::Harness2 through the full flow above,
  prints per-job pass/fail, returns the exit code.

## Database schema

`share/schema/sqlite.sql` defines every table listed in `next`, grouped by
category:

- **Local state** (never synced; may reference other categories, never
  referenced by them): `collector`, `socket`.
- **Common** (natural keys, not UUIDs; may be referenced; must not reference
  local-state or logged tables): `account`, `project`, `version`, `test_file`.
- **Logged** (UUID-identified historic record of a run; may reference common
  tables): `runner`, `service`, `run`, `job`, `try`, `subtest`, `artifact`.

Column definitions follow the `next` file exactly, including: `collector`
has exactly one of `runner_uuid` / `try_uuid`; `artifact` has exactly one of
`service_uuid` / `try_uuid` and is indexed on `type`, `name`, and
`type`+`name`; `service` is `unique(name, runner_uuid, run_uuid)`; `try` is
`unique(job_uuid, ord)`; `version` is `unique(project_id, version)`;
`test_file` is `unique(project_id, test_file)` (every test file is scoped to a
project); `account.email` and `project.name` are unique. The original `user`
table was
renamed to `account` and `collector.signal` to `exit_signal` because both
clash with reserved words in PostgreSQL/MySQL/MariaDB; `error_code` was
renamed to `exit_code` to pair with `exit_signal`.

The SQLite file is opened with WAL journaling, a `busy_timeout`, and
`PRAGMA foreign_keys = ON` so the several concurrent writer processes
(command, runner, collectors) coexist.

### Timestamps

Row-level timestamps (`run.started`/`stopped`, `service.started`/`stopped`,
`collector.started`/`stopped`) use the `DATETIME` SQL type, stored as ISO-8601
TEXT, e.g. `"2026-05-28 03:07:11"`. `DBIx::QuickORM`'s DateTime autotype
activates on the `DATETIME` sql_type, wraps reads as a lazy `DateTime` mask,
and formats DateTime objects via the dialect formatter (SQLite uses
`DateTime::Format::SQLite`). The harness writes `DateTime` objects produced
by `Test2::Harness2::Util::now_dt`. Second precision is sufficient at the row
level; sub-second resolution lives only in per-event `harness_process_exit`
stamps, which are captured in the `events.jsonl.zst` artifact (lossless), not
in these row columns.

### UUID storage

UUID columns are stored as `BLOB` (16 bytes) on flavors without a native uuid
type (SQLite, MySQL, MariaDB); PostgreSQL gets its native `uuid` type. v7
UUIDs are still generated in Perl with `Test2::Util::UUID::gen_uuid`;
`DBIx::QuickORM`'s UUID autotype detects binary affinity (sql_type
`BLOB`/`BINARY`/`BYTEA`) and packs the canonical hyphenated string to/from a
16-byte blob, so all application code continues to see the canonical string.

The `run` table additionally carries `run_uuid_string`, a `STORED GENERATED`
column expressing the canonical lowercase form of `run_uuid`. SQLite maintains
it automatically on insert/update; the column is indexed (`run_uuid_string_idx`).
It exists for humans inspecting the database directly (sqlite CLI, ad-hoc
queries) and is the only uuid form they should ever need to type or paste
manually. The ORM can read it (`$run->field('run_uuid_string')`) but writes
are rejected by SQLite (generated columns are read-only by definition), so
the column is safe from accidental application writes regardless.

### Flavor-file deviation (to be recorded as an ARCHITECTURE.md addendum)

AGENTS.md / ARCHITECTURE.md §2.3 require that "all flavors move together" —
every DDL change touches every flavor file. Part 1 ships **only**
`share/schema/sqlite.sql`, per the `next` file's "Only SQLite for now"
instruction. This deliberate deviation will be recorded as an addendum to
`ARCHITECTURE.md` when the schema lands; the remaining flavor files are added
when those flavors are implemented.

## Verdict / data flow

1. The auditor-processor watches the event stream for one test. On
   `harness_process_exit` it derives pass/fail (ported old4 logic: assertions,
   plan, subtests, errors, halt, exit code) and writes `try.passed`. Top-level
   subtests become `subtest` rows.
2. The scheduler, after a try resolves: if `try.should_retry` and the retry cap
   allows, it creates a new try (`ord` + 1); otherwise it sets `job.passed`
   (true if any try passed).
3. When every job in a run has `passed` defined, the runner sets `run.passed`
   (logical AND of the jobs) and `run.stopped`.
4. The command polls `run.stopped`, prints each job's last-try pass/fail,
   calls `finalize_run`, and exits 0 only if every job passed.

`kill` mode (abnormal teardown): the runner sets its child collector rows'
`mode` to `kill`, sends them SIGTERM, and signals child processes. Part 1 wires
this minimally; the normal command path uses `stop`.

## Error handling

- The `my $ok = eval { ...; 1 }; my $err = $@;` pattern throughout; never test
  raw `$@`. `croak` (not `die`) for argument / contract violations in library
  code.
- DB connection failures surface as exceptions from the command and produce a
  non-zero exit with a diagnostic.
- Each process opens its own DBI handle after fork; SQLite WAL + busy_timeout
  absorbs concurrent writes.
- A test collector that fails to fork/exec records the failure on its `try`
  (treated as a non-pass) rather than crashing the runner.

## Testing

Tests live under `t/AI/`, mirroring `t/`'s layout. Helper test scripts under
`t/AI/scripts/`.

- **Unit — Harness2**: `queue_run` inserts a run + jobs atomically; rollback on
  failure; `finalize_run` clears `local_path` and removes files.
- **Unit — Auditor**: feed a recorded event stream (passing and failing) and
  assert the resulting `try` row verdict, `job.passed`, and `subtest` rows.
- **Unit — Role::Service**: a fake consumer; `tick` true/false drives backoff;
  `should_stop` ends the loop; `on_start`/`on_stop` fire.
- **Integration — end-to-end**: run `yath test` against a passing fixture and a
  failing fixture; assert the printed per-job status and the process exit code.

## Alternatives considered

- **Auditor as a separate post-run replay pass** over the events file instead
  of an in-process processor. Rejected: an extra read + replay for no benefit
  here, since the collector already streams every event past the processor.
- **Making the Collector build its own rows** from the schema + UUIDs.
  Rejected in favor of duck-typed rows created by the launcher, to keep the
  generic collector decoupled from QuickORM and the schema and to preserve the
  existing collector tests unchanged.
- **Wrapping the runner without a collector** (plain forked process).
  Rejected: the `next` file calls for a collector around the runner so the
  runner's own output is captured as an artifact; the collector wrapper already
  supports a `run_sub`, so this is cheap.
