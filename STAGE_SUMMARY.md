# Stage 10 — Test2::Harness2::Log* functionality audit

## Branch

- `plan-stage-10-log-audit`
- Base: `plan-stage-09-preload-reload` (32c26dc70)

## What landed (one commit)

1. **`docs/log-port-audit.md`** — the audit PLAN Stage 10 asked
   for. Decides, per `Test2::Harness2::Log*` module, whether it
   should come back under `App::Yath2`, when, and where:

   | Old module | Decision |
   |------------|----------|
   | `Test2::Harness2::Log` | Do not port. Stage 11's `App::Yath2::LogArchive` POD replaces it. |
   | `Test2::Harness2::Log::CoverageAggregator` (+ `ByRun` / `ByTest`) | Deferred to Stage 15 when the `Cover` plugin returns. |
   | `Test2::Harness2::Log::TimeTracker` | Deferred indefinitely -- log-reading commands are out of plan scope. |

   The audit also cross-references Stage 12's artifact-reading
   layer (a CoverageAggregator port might layer on top of it
   rather than reinvent artifact reading) and Stage 19's
   feature-parity audit.

## Test results

`prove` is unchanged -- Stage 10 ships no code.

## Flip-back notes

- **Stage 11** should open the `App::Yath2::LogArchive` POD and
  treat it as the successor to the deleted
  `Test2::Harness2::Log.pm` POD.
- **Stage 15 (Cover plugin)** should reference this audit when
  deciding where the ported aggregator lives.
- **Stage 19 feature-parity audit** should verify the audit's
  decisions against the final shape of the ported tree.
