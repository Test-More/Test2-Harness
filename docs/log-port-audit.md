# Test2::Harness2::Log* port audit

This document audits the four `Test2::Harness2::Log*` modules that
`PLAN`'s logging architectural section flagged for "may need to be
re-implemented against the new log structure under `App::Yath2`":

    Test2::Harness2::Log
    Test2::Harness2::Log::CoverageAggregator
    Test2::Harness2::Log::CoverageAggregator::ByRun
    Test2::Harness2::Log::CoverageAggregator::ByTest
    Test2::Harness2::Log::TimeTracker

Stage 10's output is this document. Subsequent stages that need any
of the functionality below reference this audit so nobody accidentally
re-invents pieces that should live together.

## Summary of decisions

| Old module | Decision | Target namespace | When it comes back |
|------------|----------|------------------|--------------------|
| `Test2::Harness2::Log` | **DO NOT port as-is.** Pure POD describing the old single-file `.jsonl` log. The new format is the archive-of-`logs/` described in `PLAN`'s "Logging changes" section. | A fresh POD file under `App::Yath2::LogArchive` documenting the new archive layout, in Stage 11. | Stage 11 introduces `App::Yath2::LogArchive`; its POD replaces this one. |
| `Test2::Harness2::Log::CoverageAggregator` | **Do not port until Stage 15 Cover plugin demands it.** The aggregator is a pure consumer — it reads events out of the old single-file log and rolls them up per coverage strategy. Against the new per-job `0.jsonl` layout the aggregator is effectively a fold-over-artifacts, which the Stage 12 artifact-reading layer already understands. | `App::Yath2::Log::CoverageAggregator` (if needed). | Stage 15, only when `App::Yath2::Plugin::Cover` is ported. |
| `Test2::Harness2::Log::CoverageAggregator::ByRun` | Same as above — strategy subclass. | `App::Yath2::Log::CoverageAggregator::ByRun`. | Stage 15. |
| `Test2::Harness2::Log::CoverageAggregator::ByTest` | Same as above — strategy subclass. | `App::Yath2::Log::CoverageAggregator::ByTest`. | Stage 15. |
| `Test2::Harness2::Log::TimeTracker` | **Do not port unless a consumer returns.** `PLAN`'s scope caveats explicitly defer every log-reading command (`times`, `speedtag`, etc.) — which are the only consumers. Duration-aware scheduling could re-introduce a (different) tracker inside the scheduler, but that's not this module's shape. | `App::Yath2::Log::TimeTracker` if the `times` family returns, else dropped entirely. | **Deferred indefinitely.** Out of plan scope per PLAN's scope caveats. |

## Why the aggregators are deferred rather than ported now

`Test2::Harness2::Log::CoverageAggregator` (and its two strategy
subclasses) consume events via the `process` method:

    $agg->process($facet_data);

The old single-file `events.jsonl.gz` stream was the producer. The
Stage 7+ layout splits per-run and per-job events into separate
files (`logs/runs/<run_id>/<job_id>/0.jsonl` and friends) — the
aggregator's API works fine against that shape too (facet_data is
facet_data), but:

- **No current consumer.** The Coverage plugin (`App::Yath2::Plugin::Cover`)
  hasn't been ported yet (Stage 15). Porting the aggregator without
  its consumer risks baking in shape choices the consumer would
  want to tweak.
- **Cross-job aggregation now cheaper.** Because per-job events
  live in their own files, a Stage 15 Coverage implementation can
  walk `0.jsonl` per job in parallel (or skip jobs that don't
  emit `coverage` facets) without streaming a single unified log.
  The right aggregator for that world might look different from
  the old class hierarchy.
- **Stage 12's artifact-reading layer is the obvious place.** The
  command-side layer between harness and renderer already needs
  to read per-job artifacts and translate them into events for
  the renderer. A Coverage fold is the same pattern; the
  aggregator should probably be a consumer of the same
  artifact-reading primitives, not a parallel implementation.

If Stage 15 lands a minimal Coverage plugin first, the decision
about where the aggregator lives (alongside the plugin under
`App::Yath2::Plugin::Cover::Aggregator`, or as a shared
`App::Yath2::Log::CoverageAggregator` with both ByRun and ByTest
subclasses) becomes a much easier call.

## Why TimeTracker is deferred indefinitely

`PLAN`'s scope caveats:

> Any yath command that operates on a stored yath log (`replay`,
> `times`, `speedtag`, the `db` family, etc.) is **out of scope for
> this plan**.

TimeTracker's only consumers in `old/` are:

- `App::Yath2::Command::times` (log-reading command, out of scope)
- `App::Yath2::Command::speedtag` (log-reading command, out of scope)
- `App::Yath2::Plugin::Cover`'s `claim_file` hook, which uses
  TimeTracker as a second-order input (primary input is
  `duration_data`, tracker is a fallback for unsnapshotted files)

The first two are explicitly deferred. The third is a small
ergonomic improvement that doesn't need TimeTracker to function;
the Coverage plugin ported in Stage 15 can ship without
duration-aware fallback and the `changed_files` hook plus the
per-run `coverage` artifacts are enough. If duration-aware
scheduling ever returns, it will likely live inside the scheduler
and read run metadata directly, not parse logs.

**Net: Test2::Harness2::Log::TimeTracker is not planned to come
back.** If someone disagrees, the right place to revisit is
Stage 19's feature-parity audit.

## What about Test2::Harness2::Log itself?

`Test2::Harness2::Log.pm` is a pure-POD file. Its job was
describing the single-file log format to end users and plugin
authors. The new world replaces that format entirely (see
`PLAN`'s "Logging changes" section and
`IPC_AND_LOGGERS` section 8 for artifact routing /
announcement rules). A single POD file under the old namespace
documenting the old format would actively confuse readers.

Stage 11's `App::Yath2::LogArchive` will ship the new format's
POD as part of its own documentation. That POD is the successor
to `Test2::Harness2::Log.pm`; the old name should stay deleted.

## Files that this audit does NOT cover

`PLAN`'s "Logging changes" section also mentions removing the
following from `Test2::Harness2::*`:

    Test2::Harness2::Util::LogFile
    Test2::Harness2::IPC::Connection
    Test2::Harness2::IPC::Protocol (and family)

Those were absorbed by `IPC::Manager` and the
`Logger::JSONL` / `Logger::JSON` artifact loggers. They are
listed in `PLAN`'s "should NOT come back" section, not in the
audit scope; this document is only about the `Test2::Harness2::Log*`
path.

## Stage 19 cross-reference

When the Stage 19 feature-parity audit walks `old/lib/Test2/Harness2/`,
it should verify this audit's decisions against the final shape of
the ported tree:

- If Stage 15 did land `App::Yath2::Plugin::Cover`, check that
  its aggregator lives in the decided namespace (above).
- If `times` / `speedtag` returned in defiance of PLAN scope (via
  a scope-expansion decision), revisit TimeTracker.
- Confirm `Test2::Harness2::Log.pm` stayed dropped.

## Stage 10 scope confirmation

Per `PLAN`:

> **Stage 10 — `Test2::Harness2::Log` functionality audit.** Audit
> the `Test2::Harness2::Log*` modules listed in the logging
> architectural section and decide, per module, what (if anything)
> needs to come back under `App::Yath2`. Output of this stage is a
> short document (e.g. `docs/log-port-audit.md`) that each
> subsequent stage references.

This document is that output. No new code lands in Stage 10.
