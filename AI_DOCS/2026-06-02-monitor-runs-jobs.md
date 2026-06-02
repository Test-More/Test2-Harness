# Monitor tracks runs + jobs, carries config, reaps on a TTL

## Task

Expand `Test2::Harness2::Collector::Monitor` so it tracks runs and jobs (not just
collectors), propagates that state to subscribed downstream monitors via the
existing transition pipeline, carries the collector's spawn configuration in
state for inspection, and reaps completed entries on a TTL.

Design spec: `docs/superpowers/specs/2026-06-02-monitor-runs-jobs-design.md`
(untracked; `docs/` is gitignored).

## What landed

Three tables in the monitor, keyed independently:

- `runs{run_uuid}` — `queued -> running -> complete`, plus `job_uuids`,
  `job_count`, `completed`, `passed`, `failed`, `pass`, `done_stamp`.
- `jobs{job_uuid}` — Run::Job `spec`, spawn `config`, lifecycle
  (`queued -> running/failing/diagnosing -> complete -> finalized`), `name`,
  `events_file`, `run_uuid`, `final_state`, `done_stamp`.
- `collectors{uuid}` — service / global collectors only.

**Dispatch rule:** a `harness_collector` message whose uuid is a known job folds
into that job; otherwise into a collector. Jobs are announced by the harness
before their collector starts, so a test collector "takes over" its job by shared
uuid and never produces a duplicate collector entry.

New message facets (same `{type:transition, payload:{facet_data}}` envelope):

- `harness_run` — merged into `runs{}` (each emit carries only changed fields).
- `harness_job` — seeds `jobs{}` with the Run::Job spec.
- the collector `starting` message gained `config => {is_test, exec, env,
  processor}`.

Emission and wiring:

- `Monitor::announce(\%facet_data)` builds a transition frame and runs it through
  the existing process -> forward-to-proxies -> retain-for-replay path, so
  harness-originated updates reach proxies and replay like collector frames.
- `Service::Harness` announces a `harness_run` (queued) + one `harness_job` per
  job at queue, a `harness_run` (running) when the scheduler first considers a
  run, progress counts as jobs finalize, and `harness_run` (complete, with
  aggregate `pass`) when all jobs finalize.
- `Scheduler` gained `new_started_runs` / `new_completed_runs` drains (mirroring
  `new_finalized`); it stays Monitor-free, the service does the emitting.
- The base `Recorder` gained `announce_start` (idempotent), and the `Collector`
  calls it for non-test collectors (test collectors get `starting` from the
  auditor). This is what carries config for service/global collectors.

TTL reaping:

- Entities stamp `done_stamp` at their terminal state. `Monitor::sweep($now?)`
  removes entries older than `completed_ttl` (default 300s; 0 disables).
- The harness service sweeps on its tick; downstream monitors sweep in
  `poll_state`. No removal message — each monitor reaps independently
  (eventually-consistent).

## Key decisions

- **Client builds objects, harness rehydrates** (decided in the prior task):
  unchanged here; the monitor work rides the same transition frames.
- **Each monitor sweeps independently** (no `harness_removed` message). Snapshots
  can briefly differ in the completed-but-not-yet-swept tail; in-flight state is
  always identical.
- **Replay-terminal = complete OR finalized** for collectors/jobs (not finalized
  only). A completed collector is no longer "in flight" for replay purposes; this
  also preserves the existing `completed_collectors_not_replayed` behavior.
- **`run` becomes `running` when the scheduler first considers its jobs**, not
  when a job launches — surfaced via `Scheduler::new_started_runs`.
- **`tests()` unions** `jobs{}` with category-`test` collectors, so a raw
  test-collector frame with no prior job announce (standalone / tests) still
  reports as a test.

## Accessor changes (back-compat)

`collector($uuid)` now resolves a test uuid to its job entry, else a collector
entry; the `new_*` drains and `final_state` work across both tables. Added
`runs` / `jobs` / `run($uuid)` / `job($uuid)` / `announce` / `sweep` and the
`completed_ttl` attribute. Existing consumers (`yath test`, `t2h2_run`) are
unchanged.

## Not done (deferred)

- Acting on the spec / config (honoring directives).
- A removal propagation message (explicitly chosen against).
- Run-scoped services and multiple concurrent runs beyond the 1-run/1-job model;
  the started/complete logic is written to extend but exercised single-run.
