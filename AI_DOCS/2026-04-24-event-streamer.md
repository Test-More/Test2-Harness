# Event streamer and harness subscribe API

## Task

Implement an `App::Yath2::Streamer` family that produces a unified
event stream from either a running harness (live) or a completed log
archive (static), plus the harness-side subscription infrastructure
needed to feed the live mode. Integrate the live class into
`App::Yath2::Command::test` so that the command emits lifecycle events
to stdout as JSON lines (replacing the stop-gap `run_results`-polling
loop). The static class is reused by `App::Yath2::Command::replay`.

Triggered by: `eventfeeder`, `eventfeeder2`, `eventfeeder3`, `eventfeeder4`
design notes in the worktree root. These specified the required
Logger class-method interface, the subscribe/unsubscribe API shape,
and the per-job timing fields the streamer needs for ordering.

## Scope

- `Test2::Harness2::Role::Collector::Logger` gained a streamer
  interface: `update_style`, `log_reader`, `ready`, `fetch_events`,
  `fetch_state`, `records_state`, `records_general_events`.
  Loggers that do not participate in streaming leave the default
  `croak` bodies alone so mis-registered loggers fail loudly.
- `Logger::JSONL` (`update_style='append'`, general events) reuses
  the existing `Util::File::JSONL` streaming reader.
- `Logger::JSON` (`update_style='replace'`, state snapshots) uses
  an opaque reader hash carrying a `Util::File::JSON` plus an mtime
  so `ready()` can detect atomic-swap updates.
- `RunService` seeds `$run->results` entries for every job at init
  time with queue-time metadata (`queued_at`, job_try, file paths)
  and fills in `started_at` / `completed_at` as the collector
  reports them. Completed-job handler now merges instead of
  replacing so queue and start stamps survive.
- `Test2::Harness2` gained a subscriber registry plus `subscribe`
  and `unsubscribe` request handlers. Fan-out happens from
  `_handle_run_state_update` (state) and the artifact merge sites
  (both global and run-scoped). A send failure queues a retry; a
  second failure unsubscribes the peer with a warning.
  `run_on_peer_delta` reaps dropped peers, distinguishing
  "suspended" from "gone for good" via `peer_exists()`.
- `RunService._handle_collector_artifacts` now forwards its artifact
  table to the harness as `run_artifacts_update` so the harness can
  feed run-scope subscribers without scraping disk.
- `Spawn` gained thin `subscribe` / `unsubscribe` wrappers.
- `Role::Service::handle_request` now passes `$msg` through to
  handlers so `request_handler_subscribe` can read `$msg->from` for
  the peer name.
- The streamer is a small role-based class hierarchy:
  - `App::Yath2::Streamer::Base` -- abstract parent. Owns the event
    queue, the state-diff + facet-synthesis code, the event-reader
    drain loop, and the public API (`stream`, `next`,
    `request_exit`). Subclasses override `_bootstrap` (runs at the
    tail of `init`) and `_tick` (runs when the queue drains dry).
  - `App::Yath2::Streamer::Live` -- subscribes to a running harness
    via a Spawn handle. `_tick` polls the IPC handle, applies
    state/artifact messages, opens append-style general-event readers
    on newly-advertised artifacts, and drains those readers each pass.
    Synthesises `harness_run`, `harness_job_queued`,
    `harness_job_start`, `harness_job_end`, `harness_job_exit`, and
    `harness_run_end` facets on `Test2::Harness2::Event` objects.
  - `App::Yath2::Streamer::Static` -- consumes either a log
    directory or a `.yath` archive via `App::Yath2::LogArchive`.
    `_bootstrap` validates requested run ids, collects per-run
    state snapshots (cross-logger agreement check), and sets up
    general-event readers; `_tick` drains them. Archives are
    extracted lazily on first artifact access via `File::Temp`,
    so files the streamer never reads stay inside the archive.
- `App::Yath2::Command::test` drives a `Streamer::Live` instead of
  polling `run_results` from a tight loop. The stream's own
  `harness_run_end` is the authoritative "run is over" signal.

## Decisions

### Where does the Streamer live?

`App::Yath2::Streamer::*` rather than `Test2::Harness2::Streamer`.
Per the CLAUDE.md dependency rule, `Test2::Harness2` must not load
`App::Yath2` modules directly; the streamer is a yath-layer
consumer of the harness (yath may consume harness). The harness
side carries the subscribe/unsubscribe primitives; the streamer
sits above them.

### Three classes, not one mode-branching facade

Live and static consume very different inputs: live sits on an IPC
subscription and ticks when messages arrive; static walks a
manifest and drains per-artifact readers to exhaustion. A single
class with a `MODE` slot would branch on it in enough places --
bootstrap, `_tick`, artifact handling, teardown -- that every
method became a case analysis. Splitting into
`Streamer::Base` + `Streamer::Live` + `Streamer::Static` keeps each
subclass focused on one input shape. The common machinery (event
queue, state-diff, facet synthesis, reader drain) lives in `Base`.
Subclasses only need to implement `_bootstrap` and `_tick`.

### Event shape

Events match the reference/old2 harness facet shapes (`harness_run`,
`harness_job_queued`, `harness_job_start`, `harness_job_end`,
`harness_job_exit`). A new `harness_run_end` facet carries the
aggregate pass / pass_count / fail_count / stamp for the end of a
run; the old reference did not have a dedicated run-end facet but
we need one so renderers can close out a run. A paired `harness_run`
with the terminal state goes in the same event so renderers that
already consume `harness_run` still get the final snapshot.

### Subscribe model: directed sends, not firehose

Before this change the harness had no broadcast channel to
arbitrary clients. `RunService` emits a single directed
`run_state_update` to the harness; the harness processed it
internally. The subscribe API introduces a proper per-peer
registry: subscribers are added by name, matched on type
(state/artifacts) and scope (global/run), and fed via directed
`send_message` from the harness's own client. This keeps the work
purely additive -- no existing path changed semantics.

### Initial snapshots are sent at subscribe time, artifacts first

The subscribe handler sends any in-scope artifact snapshots first
and state snapshots second so the consumer has the artifact map
before it sees state that references entries in it. Even with that
ordering the stream is inherently racy (a state update for a new
run might arrive before its artifact entry in a sufficiently
hostile interleaving), so the streamer tracks a
`pending_actions` slot keyed by artifact scope and resolves
blocked actions when the late artifact arrives. First-iteration
actions list is empty because the streamer does not yet synthesize
events from artifact messages alone; the hook exists for forward
use.

### Per-job timing fields in `$run->results`

Added to the same hash that already carries the job verdict, rather
than introducing a parallel `job_info` slot. Bootstrapping in
`RunService::init` means every Run the run service receives has
per-job `queued_at` + file paths in one place. The harness's copy
receives the enriched structure through the usual
`run_state_update` broadcast. `_snapshot_run_results` now ignores
entries without `completed_at` so skipped / never-started jobs
still do not fail the aggregate pass (matching prior semantics).

### Multi-state-logger agreement

Only enforced in static-archive mode. In live mode the harness is
the source of truth and records_state loggers are ignored. Static
mode currently only checks the shallow cared-about keys
(`run_id`, `created_at`, `pending`, `running`, `done`) plus
per-job `queued_at`, `started_at`, `completed_at`, `pass`, `exit`,
and file paths. Extra fields are tolerated silently. `Test2::Compare`
was considered but the custom walker is small enough to be
inlined.

### Peer-drop handling uses `peer_exists`, not `peer_active`

`peer_exists` returns true if the peer is still registered on the
bus (even if suspended pending reconnection). `peer_active` returns
true only if the peer has a live fd. The spec asks for the former
so a merely-suspended subscriber is not warned about. `run_on_peer_delta`
drops the registration in both cases (so the retry queue stops
accumulating) but only warns when `peer_exists` returns false.

### DESTROY does not unsubscribe

Unsubscribe is a sync_request. If the harness has already exited
(Command::test's usual flow: stream -> unsubscribe -> finish ->
wait -> end-of-scope), a sync_request against the dead peer can
raise SIGPIPE at the transport layer before the exception
propagates. The DESTROY documents this and relies on the harness's
peer-delta path to clean up stale registrations. Callers that
care unsubscribe explicitly while the peer is still alive.

### Archive mode: lazy extraction via LogArchive

`Streamer::Static` accepts both a bare `logs/` directory and a
`.yath` archive file. Both flow through `App::Yath2::LogArchive`:
the directory backend handles unpacked logs; the tar / zip / 7z
backends handle archives. Files are extracted lazily --
`_resolve_path($rel)` pulls one entry out of the archive on first
access, caches the resulting tempdir path, and returns it on
later calls. Files the streamer never reads (e.g. harness JSONL
when only the state snapshot is needed) stay inside the archive.
The tempdir is cleaned up on streamer destruction via
`File::Temp`. `App::Yath2::LogArchive` is `require`d lazily so
`Streamer::Live` does not pay for archive backend modules.

### General-event tailing in both subclasses

Both `Live` and `Static` open append-style readers on every
general-event artifact and drain them on each tick. In `Live` the
reader set grows as the harness advertises new artifacts via IPC;
in `Static` the readers are seeded at bootstrap from the
manifest. Same `_drain_event_readers` helper in `Base` services
both. Synthesised lifecycle facets and pass-through general events
arrive on the same callback in arrival order.

## Architectural changes

- New harness contract: subscribers are named peers that opt into
  `state` and/or `artifacts` messages scoped to specific runs or
  the harness. The harness owns the registry; `RunService`
  continues to publish upstream only, unchanged in topology.
- `RunService` now forwards its artifact table to the harness on
  every merge (`run_artifacts_update`), giving the harness an
  in-memory view for subscriber fan-out. The authoritative
  per-run manifest on disk is still written by the run service.
- `$run->results` is now continuously populated from queue time
  onward, not just at completion. The Run snapshot sent to the
  harness is a richer lifecycle view than it used to be.

No deviation from `ARCHITECTURE.md`: the document already
describes the harness service as the IPC hub and the logger
interface as the artifact map. The streamer interface and
subscribe API extend that model rather than changing it. No
addendum is necessary; future renderer plumbing work can
reference this doc for the event shapes it should consume.

## Test coverage

- `t/AI/unit/Collector/Logger/JSONL_streamer.t`: JSONL logger
  class-method interface, including incremental appends.
- `t/AI/unit/Collector/Logger/JSON_streamer.t`: JSON logger
  class-method interface, including mtime-driven re-read.
- `t/AI/unit/Streamer/static_mode.t`: end-to-end synthesis from
  a synthetic log directory with one completed job and one
  queued-but-never-started job.
- `t/AI/unit/Streamer/archive_mode.t`: same scenario packaged as
  a `.yath` archive; asserts the state artifact is extracted on
  demand while unrelated harness logs stay inside the archive.
- `t/AI/unit/Streamer/general_events.t`: state snapshot plus a
  JSONL of pre-recorded general events; verifies both
  synthesised lifecycle facets and pass-through general events
  arrive in order.
- `t/AI/unit/Util/File_changed.t`: change-detection primitives
  (`changed()`, `_record_state()`, `read_if_changed`) including
  inode-based detection of atomic-rename-in-place when mtime
  collapses both writes into the same one-second bucket.
- `t/AI/integration/test_command_loggers.t`: existing integration
  test; still passes with the streamer-backed command. Exercises
  the full live flow (spawn harness, subscribe, drive a real
  test file, archive the logs).

Pre-existing failing tests (`t/AI/unit/Collector.t`,
`t/AI/unit/Collector/burst_sync.t`,
`t/AI/unit/Harness2/Role/Collector/Observer.t`,
3 subtests in `t/AI/unit/Harness2.t`) were failing before this
work and are unchanged by it.

## Caller picks the class that matches the input

    # Test command, live harness
    my $s = App::Yath2::Streamer::Live->new(
        handle => $spawn,
        run    => $run_id,
        log    => "$workdir/logs",
    );

    # Replay from an archive (or from a logs/ directory)
    my $s = App::Yath2::Streamer::Static->new(
        log => '/path/to/run.yath',
        run => $run_id,
    );
