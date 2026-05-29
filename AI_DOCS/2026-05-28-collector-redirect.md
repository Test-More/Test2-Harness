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
- `Collector::Auditor` — the processor for test jobs. Passes events
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

**Full subtest auditing ported from `reference/old4`.** The auditor reassembles
streaming subtests (buffering child events per nesting level via the hub-truth
`nested` facet, then rolling them into a buffered parent event on close),
recurses into each buffered subtest with a fresh sub-auditor, and runs the
complete TAP validation: plan presence / count-vs-assertions, assertion-number
gaps and duplicates, incomplete subtests, error / bail-out, and exit status.
Pass/fail is the verdict of `fail_error_facet_list`, whose reasons are attached
as error facets to the process-exit event. This is the core test-correctness
logic, kept faithful to old4; it was adapted only to the new shape — the
auditor is a Processor (`process_event`) that emits transitions and the final
state as events rather than calling a recorder's `record_state`, and it has no
`startup`/`shutdown` lifecycle (starting fires on the first event, completed +
final-state on the exit event).

**No `events_file` shortcut; the recorder is optional with no default.**
An earlier iteration let the collector build a default base recorder from an
`events_file` attribute. That was removed on review: the recorder owns its
own outputs (some recorders, e.g. a database recorder, have no files at all),
so callers pass a `recorder` (or none). With no recorder nothing is written —
an in-process `collect` still returns its info summary, but `spawn_collector`
croaks without one, since a forked collector's summary cannot reach the
caller.

**`t2h2_collector` propagates `@INC` via `PERL5LIB`.** Test jobs run with the
stream formatter selected, which lives in this repo's `lib/`. The script
passes its own `@INC` to the child so the formatter loads regardless of how
the script was invoked.

## Legacy audit (parsing / TAP / auditing / transitions)

Audited the current implementation against all reference trees
(`legacy`, `old2`, `old3`, `old4`, `botched`). TAP parsing and the
state-transition set (starting / failing / diagnosing / completed) had no
gaps — the transitions legacy had beyond these are run/scheduler-level
(pending/running/broken/canceled), not per-test. Auditing core matched old4;
the dropped items (rel/abs file, summary_file, retry, closed_by_eid) are
run/job-layer concerns moved upstream. Two real gaps were worked back in:

- **Raw-output encoding** (was in old2, dropped in the rewrite): the
  collector again decodes the child's raw stream lines via an `encoding`
  attribute, with mid-stream switching through a `control.encoding` facet.
  Default off (bytes pass through), so behavior is unchanged unless used.

- **Per-test phase timing** (yath1's `TimeTracker`): ported as
  `Collector::Auditor::TimeTracker`, adapted to read stamps from facets
  (`trace.stamp`, and the exit event's `start_stamp` / `stamp`) rather than
  top-level `event.stamp`/`event_id`, which this architecture does not carry.
  The auditor feeds it and exposes `times` (startup / events / cleanup /
  total) in `final_state`. The renderer-facing bits of the legacy tracker
  (`table` / `summary` / `job_fields`, which need `render_duration` and
  event IDs) were not ported — no renderer consumes them yet.

Dropped by decision: peek/live-preview mode (covered by buffering +
`flush_interval`) and a dedicated skip-all field (the reason already rides in
`final_state.plan.details`).

## Follow-ups not done

- `scripts/t2h2_collector` is not yet wired into `dist.ini` packaging.
