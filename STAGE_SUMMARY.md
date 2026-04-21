# Stage 12 -- Renderers + command-side artifact-reading layer

## Branch

- `plan-stage-12-renderers`
- Base: `plan-stage-13-commands` (`37ec8bf57`)
- Stage 12 was deferred during session 2 (see `PLAN_RESUME_2026-04-20_session2.md`)
  and is landing on top of Stage 13 rather than between 11 and 13 per
  the user's instruction to preserve the chain even though the number
  is out of sequence.

## What landed (seven commits)

1. **`Harness2: artifact-enumeration IPC handlers`** -- `da10f437a`
   - `Test2::Harness2` grows two artifact buckets (`GLOBAL_ARTIFACTS`
     and `RUN_ARTIFACTS`) populated from incoming `collector_artifacts`
     messages. Successive announcements merge additively per
     `IPC_AND_LOGGERS §8.2`.
   - New request handlers: `list_global_artifacts`,
     `list_run_artifacts(run_id => ...)`, `get_run_status(run_id => ...)`
     (alias for `run_status`).
   - `RunService` gains `run_on_general_message` so it stores its own
     `collector_artifacts` arrivals and forwards the same payload to
     the harness. The run service also exposes its own
     `list_run_artifacts` request handler for direct queries.
   - `Spawn` client: new helpers `list_global_artifacts`,
     `list_run_artifacts`, `get_run_status`.
   - Unit tests: `t/AI/unit/Harness2/Artifacts.t`. Covers empty
     buckets, global vs run separation, additive merging, defensive
     copying, and the `get_run_status` alias.

2. **`App::Yath2::Role::Renderer: passive event-consumer role`** -- `e5b38e572`
   - `lib/App/Yath2/Role/Renderer.pm` -- the single-entry-point
     renderer contract from `IPC_AND_LOGGERS §13`. Required:
     `event_in($event)`. Optional: `start_of_run`, `end_of_run`,
     `shutdown` with no-op defaults.
   - Unit test: role composition check, required-method enforcement,
     default no-op dispatch, ordered call sequence.

3. **`App::Yath2::Renderer::Theme::Composer: port facet composer`** -- `453e875ed`
   - Port of `old/lib/App/Yath2/Renderer/Default/Composer.pm` into
     `lib/App/Yath2/Renderer/Theme/Composer.pm`. Same public
     interface: `render_one_line`, `render_verbose`, `render_brief`,
     plus per-facet helpers. Emits `[facet, tag, text]` triples so
     any text renderer can share it.
   - Unit test: every dispatch path, SKIP variants, amnesty dedup,
     debug fallback, error tag inference, super_verbose encoding.

4. **`Renderer::Default, Renderer::Summary, Renderer::Formatter`** -- `5d742c386`
   - Three minimal renderers, each consuming the role. Not a
     bug-for-bug port of `old/` -- the Stage 12 contract is passive
     consumption, so the old file-reading TUI was rewritten rather
     than ported.
   - `Renderer::Default`: one line per event (LAUNCH/PASSED/FAILED/RUN
     headers for lifecycle events, render_brief for everything else).
   - `Renderer::Summary`: end-of-run block with counts, optional
     wall time, list of failing files, and a PASSED/FAILED verdict.
   - `Renderer::Formatter`: verbose `-v` line-by-line formatter
     that routes pass/info to STDOUT, fail/error/DIAG to STDERR.
   - One unit test per renderer (Default, Summary, Formatter).

5. **`App::Yath2::ArtifactReader: command-side artifact-reading layer`** -- `9c0be9cbe`
   - `lib/App/Yath2/ArtifactReader.pm` -- the only component in the
     command that reads artifacts or queries the harness, per
     `IPC_AND_LOGGERS §13`.
   - Modes: quiet, qvf, verbose, default (§13.2). Mode selection
     filters what the layer emits to renderers.
   - Live path (`run`): polls `run_status` + `list_run_artifacts`
     until drain; replays `0.jsonl` in verbose / qvf-fail mode.
   - Replay path (`replay_from_logs`): walks an extracted logs/
     tree and feeds the same event stream -- no IPC. Intended
     for post-run playback from `App::Yath2::LogArchive` extracts.
   - Fallback: when the primary `run_status` call returns anything
     other than a hashref, falls back to `get_run_status`; verdicts
     synthesised from per-job completion state when artifacts are
     missing.
   - Unit test: quiet / default / verbose / qvf mode selection;
     verbose replay from a staged `0.jsonl`; qvf replay only on
     failure; `replay_from_logs` against a synthesised logs tree;
     constructor validation (bad mode, missing run_id).

6. **`Command::test: wire --renderer / -r through ArtifactReader`** -- `222ca8245`
   - Activate the renderer Map option in `Options::Renderer`
     (default set: `Default` + `Summary`), plus `--quiet` and
     `--qvf`. Bare names prefix with `App::Yath2::Renderer::`;
     `+Fully::Qualified` pass through. `no_require` at parse time;
     the command loads classes via `Util::load_module`.
   - `Command::test`: new helpers `_resolve_mode` (qvf > quiet >
     verbose > default) and `_load_renderers`. When at least one
     renderer is configured the command routes events through
     `ArtifactReader`; when none are configured it falls back to
     the Stage 5 IPC tally path.
   - Tests cover mode resolution, default-set composition, and
     adding a renderer via `-rFormatter`.

7. **`ArtifactReader: read from jsonl_file metadata key; Command::test attaches a per-job JSONL logger`** -- `bfa41ccac`
   - Fix for end-to-end replay: the in-tree `Logger::JSONL` reports
     its artefact as `jsonl_file` (not the generic `output_file`).
     Teach `ArtifactReader` and `Renderer::Default` to check
     `jsonl_file` / `output_file` / `json_file`.
   - `Command::test` now attaches a JSONL logger to each test-job
     collector whenever a renderer is configured, so there's a
     `0.jsonl` to replay. Without renderers the harness still
     installs no loggers by default (§12.1).
   - Verified end to end: `yath test -v -rFormatter file.t` now
     replays every NOTE / PASS / PLAN line from the test's 0.jsonl.

## Test results

- `prove -I lib -I t/lib -r -j16 t` -- **51 files / 467 tests,
  all passing** on this branch. Final line:

      Files=51, Tests=467, 61 wallclock secs ( 0.12 usr  0.02 sys +  4.20 cusr  3.54 csys =  7.88 CPU)
      Result: PASS

- CLI smoke (verbose replay):

      $ perl -Ilib scripts/yath test -v -rFormatter /tmp/passing.t
      [PLAN    ] Expected assertions: 2
      [PASS    ] foo
      [NOTE    ] a note
      [PASS    ] bar
      ...
      yath test: pass=1 fail=0

- CLI smoke (qvf replay-on-fail):

      $ perl -Ilib scripts/yath test --qvf /tmp/failing.t
      [FAIL    ] -: this fails
      [DIAG    ] -: Failed test 'this fails' at line 2.
      ...
      RESULT: FAILED
      yath test: pass=0 fail=1

## Points of interest / decisions worth revisiting

### 1. Per-job verdict inference is greedy-fail

`ArtifactReader::_verdict_for_job` infers a per-job pass/fail from
the harness's `pass_count` / `fail_count` aggregates because the
current `run_status` response does not carry per-job verdicts
directly. The inference is greedy-fail: a newcomer is assumed
passing unless the total `fail_count` exceeds what we've already
recorded, in which case the newcomer is marked as the failing
one.

This works for concurrent runs where the order of completion
matches the order of fail_count increment (typical single-slot
case and most multi-slot cases since the completion that bumped
fail_count is the one we just observed), but it's structurally
fragile: if two jobs complete between polls and one fails, we
can't always tell which one was the failing one.

**Follow-up:** have the harness's `run_status` response include
per-job verdicts, or have the run service push a per-completion
message the layer can subscribe to. Once that lands, delete
`_verdict_for_job` and read verdicts directly.

### 2. The layer polls; it does not subscribe to the IPC bus

Section 13.0 says "renderers do not subscribe to the bus." The
*layer* could in principle subscribe, but the Stage 12
implementation polls `run_status` + `list_run_artifacts` instead.
Reason: simpler to reason about in the face of a replay-from-
archive mode that has no bus. A push-based variant is feasible
once the command-side IPC story stabilises.

### 3. `Renderer::Default` is terse

The plan says "a clean minimal implementation is fine; it just
needs to feel like a live test run display." `Renderer::Default`
is deliberately minimal: one LAUNCH / PASSED / FAILED line per
job plus a brief tag-column line per interesting facet. It is
**not** a TUI -- no carriage-return overwrites, no active-job
display, no colour theming. If a richer live display is wanted,
it can be added as an output-side refinement without touching
the role or the artifact-reader (per §13.0 "Output is free").

### 4. Mode precedence is qvf > quiet > verbose > default

`Command::test::_resolve_mode` picks `qvf` first if set; else
`quiet` if set and not also verbose; else `verbose` if any `-v`
level; else `default`. `quiet + verbose` together was treated
as "be verbose but use the quiet default colourway" in `old/` --
since the Stage 12 layer doesn't do theming yet, that
combination flows through as plain verbose. Worth revisiting
once theming lands.

### 5. `--renderer` option uses `no_require` at parse time

The renderer Map option's `normalize` callback is
`fqmod($_[0], 'App::Yath2::Renderer', no_require => 1)`. Class
loading is deferred to `_load_renderers`, which calls
`load_module` and surfaces any load error with a clear
"renderer class '...' failed to load: ..." message. Parse time
stays fast; errors arrive when the user can still see them.

### 6. `Renderer::Default`'s `job_file_map` is informational only

`Renderer::Default::_render_harness_event` populates
`job_file_map` from incoming `job_loggers` events but the
Default renderer itself does not replay from those files (that
is the artifact-reader's job). The map is kept in case a
future renderer-side refinement wants to surface per-job file
paths for debugging. Not load-bearing.

### 7. No integration test exercising `ArtifactReader` against a real spawned harness

Unit tests use a `FakeSpawn` mock. `PLAN_RESUME.md` notes a
known `yath test -j16 t/` flakiness when running the full suite
through the real harness (the many-collectors IPC path); until
that's resolved, adding an integration test that spawns a real
harness and drives a run through `ArtifactReader` risked
introducing flake. The two manual CLI smokes above exercise
the path end to end; a committed integration test is a
follow-up worth adding once the IPC flakiness is addressed.

### 8. Artifact key lookup is permissive (`jsonl_file`, `output_file`, `json_file`)

The canonical in-tree `Logger::JSONL` reports `jsonl_file` in its
metadata (matching `Logger::JSON`'s `json_file`), while the spec
in §8.1 names `output_file` as the generic field. Stage 12 reads
all three so the layer can handle both today's loggers and any
future ones that adopt the unified key. If the project decides
to settle on one name, the two fallback keys can be removed in a
one-line edit each in `ArtifactReader::_job_log_from_artifacts`
and `Renderer::Default::_extract_log_files`.

## Deviations from `IPC_AND_LOGGERS`

None that require a follow-up commit. Two points worth flagging
even though they're intentional:

- **`Spawn` exposes both `run_status` and `get_run_status`.** The
  spec's §13.1 names `get_run_status` / `list_run_final_state`; the
  harness already had `run_status` from Stage 5 so Stage 12 added
  `get_run_status` as an explicit alias rather than renaming.
  Either one is fine per the spec; the alias keeps the two forms
  in sync.
- **Artifact forwarding: run service always forwards to harness**,
  not just at run end. The spec (§8.3) allows either per-message
  forwarding or end-of-run aggregation; per-message is simpler and
  keeps the harness's response to `list_run_artifacts` current
  while the run is live. The extra IPC cost is one forward per
  `collector_artifacts` announcement, which is already rare (once
  per collector, not per event).

## Flip-back notes for the next stage

- **Stage 13's `Command::failed` stub** can now be implemented.
  `ArtifactReader` offers the artifact-discovery path it was
  waiting on; use `Spawn->list_run_artifacts` (or a static
  workdir snapshot) to find the last run's failing-job log
  files and feed those back into `Command::test`.
- **Preload-stage / run-scoped artifacts** flow through the same
  route: the preload service's collector would also send
  `collector_artifacts`. When the preload service's interpose
  collector lands (flagged in Stage 8's summary), its
  announcements join the harness's global bucket automatically --
  no ArtifactReader changes needed.
- **Richer per-job verdict wire shape.** Whenever the harness or
  run service response grows per-job verdicts natively, delete
  `ArtifactReader::_verdict_for_job` and read them directly. The
  greedy-fail heuristic is adequate for Stage 12 but is the
  single biggest source of latent ambiguity in the layer.
- **Color / theming.** `Options::Renderer` still has TODO-gated
  `--theme`, `--wrap`, `--show-times`, etc. Stage 12 does not
  need them; the next renderer-facing stage (likely Stage 17 /
  18's cleanup sweep, or whenever ResetTerm / QVF need theming)
  should activate them.
