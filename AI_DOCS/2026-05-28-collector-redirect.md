# 2026-05-28 Collector redirect

## Task and trigger

The `redirect` file at the repo root changed direction: the harness is no
longer database-driven (a database becomes a deferred, log-storage-only
concern, schema via `DBIx::QuickORM`), and the collector is to be polished
into a functional interface with a pluggable recorder, an auditor processor,
a test-aware recorder, and a `t2h2_collector` script. This work implemented
that on the `collector-redirect` branch and recorded the direction change in
`ARCHITECTURE.md` (§1, §2.3, §2.4, §4.1).

## What landed

- `Collector::Role::Recorder` + base `Collector::Recorder` — the pipeline
  sink. Writes every event to one `jsonl.zst` file; `finalize` closes and
  touches an optional `touchfile`.
- `Collector::Auditor::Test` — the processor for test jobs. Passes events
  through, tracks the verdict, injects `harness_state_transition` events
  (starting / failing / diagnosing / completed) and a `harness_final_state`
  event on the process-exit event.
- `Collector::Recorder::Test` — routes transition events to a transitions
  file and the final-state event to a state file; touches the touchfile on
  each transition.
- `Test2::Harness2::Collector` gained the exported `collect` /
  `spawn_collector` functions and a recorder sink in place of the hard-coded
  events-file writer.
- `scripts/t2h2_collector` — runs one test file, exits 0/1 by verdict.

## Decisions and alternatives

**Collector stays the engine; functions are added to it.** The redirect
shows `use Test2::Harness2::Collector qw/collect spawn_collector/`, implying
the functions live in that package. The alternative — splitting the ~1200
line OO engine into a separate internal class and making `Collector.pm` a
pure functional façade — was rejected: it would churn every existing
`->new` / `->start` caller and test for no behavioral gain. Instead the
functions delegate to methods (`collect` builds the object; `spawn_collector`
calls a `$class->_run_spawned` method), so they legitimately reference an
invokant and pass `audit-methods-not-functions`.

**Auditor is a Processor that emits events, not a recorder with a
`record_state` API.** `reference/old4` had the auditor call
`$recorder->record_state(...)` directly. The redirect unifies everything on
the event stream: the auditor emits transition / final-state *events*, and
the recorder routes them by facet (`harness_state_transition`,
`harness_final_state`). This keeps the Processor contract a single
`process_event` method and lets a plain recorder record transitions like any
other event.

**Exit event flows through the pipeline after output drains.** The collector
dispatches the synthetic `harness_process_exit` event through
parser→processor→recorder in `_finalize`, after both pipes are drained. The
auditor recognizes it, emits `completed` + `harness_final_state`, and only
then is the recorder finalized — guaranteeing the exit/verdict land after all
of the child's output.

**`$info.exit` is `parse_exit`'s output.** Per direction, `$info.exit` is the
exact hash `Test2::Harness2::Util::IPC::parse_exit` returns — `sig` (signal),
`err` (decoded exit code), `dmp` (core-dump flag), `all` (raw wait status) —
so callers share one decoding of the wait status with the
`harness_process_exit` facet.

**`env` attribute stored as `child_env`.** `Object::HashBase` will not create
an `ENV` constant (it collides with the `%ENV` superglobal), so the slot is
`child_env` (constant `CHILD_ENV`). The functional interface accepts `env` as
an alias (alongside `exec`/`run` for `exec_command`/`run_sub`).

**Verdict counts only nesting-depth-zero assertions/plans.** Buffered subtest
children would otherwise be double-counted against the parent's summary
assertion. Streamed (nested) child assertions are skipped; the parent
`Subtest:` summary assertion carries the subtest's pass/fail.

**`events_file` kept as a convenience.** When no `recorder` is supplied the
collector builds a base recorder from `events_file`, so existing
`events_file` callers and integration tests keep working while `recorder`
becomes the canonical sink.

**`t2h2_collector` propagates `@INC` via `PERL5LIB`.** Test jobs run with the
stream formatter selected, which lives in this repo's `lib/`. The script
passes its own `@INC` to the child so the formatter loads regardless of how
the script was invoked.

## Follow-ups not done

- Deep nested-subtest diagnostic trees (old4's `subtest_fail_error_facet_list`
  recursion) were not ported; the verdict is correct via the parent summary
  assertion, but per-subtest failure detail is not yet synthesized.
- `scripts/t2h2_collector` is not yet wired into `dist.ini` packaging.
