# Stage 15 -- Port specific plugins

Branch: `plan-stage-15-plugins`
Base:   `plan-stage-14-daemon` (tip `70fda6fa3`)
HEAD:   `c049c57cc`
Commits: 8

Ports the stage-15 plugin set on top of the Stage 7 plugin
infrastructure, plus the minimum harness-side wiring to dispatch
`run_queued` and stamp plugin-supplied fields onto a run.

Plugins ported:

- `App::Yath2::Plugin::SysInfo`
- `App::Yath2::Plugin::Git`
- `App::Yath2::Plugin::Cover` (minimal slice, aggregator deferred)
- `Test2::Plugin::Immiscible`
- `Test2::Plugin::IsolateTemp`

`App::Yath2::Plugin::DB` is intentionally **not** ported (out of
scope per PLAN and CLAUDE.md dependency rules).

## Commits

### 1. `323381c9a` Harness2: dispatch run_queued plugin hook + Run run-fields slot

Foundation for the plugin set. Adds a `fields` arrayref to
`Test2::Harness2::Run` plus an `add_fields(@fields)` helper, and
wires `run_queued` dispatch into `request_handler_queue_test_run`:
every plugin on the harness gets its `run_queued($run)` called,
and returned hashref fields are stamped onto the run before the
`run_queued` service event fires. A broken plugin warns and is
skipped; other plugins and the queue operation are unaffected.

This is the first real dispatch of a harness-side plugin hook
(Stage 7 summary: "Plugins are stored on the harness but not yet
dispatched... call sites land when the consuming subsystem needs
them"). Further hook call sites (`tick`, `run_complete`, etc.)
follow the same pattern when their consumers arrive.

### 2. `496909761` App::Yath2::Plugin::SysInfo

Ports `old/lib/App/Yath2/Plugin/SysInfo.pm`. Stamps a single `sys`
run field containing env, fork/thread capability bits, hostname +
short form, and a handful of `@Config` keys. Uses
`Role::Tiny::With` on `App::Yath2::Role::Plugin` and
`Object::HashBase` directly (no Test2::Harness2::Util::HashBase).
`run_queued` returns `run_fields`; the harness stamps it onto the
run via `add_fields`.

### 3. `133883055` App::Yath2::Plugin::Git

Ports `old/lib/App/Yath2/Plugin/Git.pm`. Stamps a `git` run field
when the cwd is a git checkout or `GIT_LONG_SHA` is set. Also ships
the `changed_diff` / `_changed_diff` / `_diff_from` helpers used by
downstream plugins (Cover) for change-narrowing.

Difference from old/: `IPC::Cmd` and `Capture::Tiny` are now
optional, gated by `HAS_IPC_CMD` / `HAS_CAPTURE_TINY` constants.
Missing either -> no git field; no error. Per-probe errors run
inside a per-command eval so one failed git call doesn't abort the
whole `run_fields`.

### 4. `6d8249093` App::Yath2::Plugin::Cover (minimal)

Ports the Cover plugin on the narrow scope the Stage 10 log-port
audit (`docs/log-port-audit.md`) laid out. **Option group and
plugin class land now**, option parses, `-pCover` loads cleanly;
aggregator (`App::Yath2::Log::CoverageAggregator` + `ByRun` +
`ByTest`) + `annotate_event` wiring + run_queued coverage-field
emission are **deferred to Stage 18 / a successor plan** with
inline TODO markers.

Rationale (from the audit): the aggregator is a pure consumer of
events; porting it without its consumer (`annotate_event`
dispatched from the renderer / artifact-reader layer) risks baking
in shape choices the consumer would want to tweak. The Stage 12
artifact-reading layer is the right place for it, not a standalone
port.

`post_process` is guarded with `can()` checks so the two Stage 6
options it writes into (`tests->load_import` and
`runner->preload_early`) are skipped cleanly while they're still
commented out upstream. `HAS_TEST2_PLUGIN_COVER` constant gates the
optional runtime dep. `client_finalize` summary print is present
but no-ops when no aggregator is wired.

### 5. `0127edc34` Test2::Plugin::Immiscible

Ports `old/lib/Test2/Plugin/Immiscible.pm` verbatim into `lib/`. No
behavioural changes.

**Distribution-split decision**: leaving inside Test2-Harness2.
The module is harness-adjacent (yath's concurrency model is its
only interesting consumer), and the one reviewer-facing alternative
(hoisting to a standalone distribution) would just add CPAN
release overhead without clear benefit. Hoisting remains easy if a
reviewer prefers it -- the module has no dependencies on the rest
of the harness.

### 6. `980b5b316` Test2::Plugin::IsolateTemp + Util::chmod_tmp

Ports `old/lib/Test2/Plugin/IsolateTemp.pm` verbatim. Also adds the
`chmod_tmp($path)` helper it needs to `Test2::Harness2::Util`
(ported from old/). `chmod_tmp` sets the sticky+1777 mode and is
exported from `Test2::Harness2::Util`.

Same distribution-split decision as Immiscible.

### 7. `ed69feb6b` yath run: load plugins and dispatch client_* hooks

Minor extension to `App::Yath2::Command::run`: `--plugin` / `-p`
now wired to plugin loading + client_setup / client_teardown /
client_finalize dispatch, matching what `yath test` has done since
Stage 7. Previously those args were silently ignored at the
command layer.

Note: the harness-side plugin hooks (`run_queued`, etc.) still
fire on the daemon, against whatever plugins the daemon was
started with. `yath run`'s plugin list only affects the command
process itself (client_*). If a user wants run_queued-side
stamping from `yath run`, they need to pass the same plugin to
`yath start -pSysInfo` as well. This matches the command-set
shipped in Stage 14 -- it's a deliberate separation, not a gap.

### 8. `c049c57cc` integration test for run_queued hook dispatch + field stamping

End-to-end coverage of the Stage 15 foundation. Starts
`Test2::Harness2` with an inline plugin returning two stamped
fields, runs one trivial test, and reads the harness service log
to confirm the `run_queued` service event carries both fields
through `run_data.fields`, round-tripping through `TO_JSON` + JSONL
serialization.

## Old integration tests: NOT ported

`old/t/Yath/integration/plugin.t` is the obvious candidate but
requires:

- `App::Yath2::Tester` (shared driver module; not yet ported to V2
  -- also deferred by Stage 14).
- `--ext`, `-A`, `--durations-threshold`, `--no-plugins`,
  `--changes-plugin`, `-v` option wiring (most still commented out
  in Stage 6).
- A test fixture (`old/t/Yath/integration/plugin/`) that tests
  hook surfaces (inject_run_data, handle_event, setup, teardown)
  flagged as "deprecated" in old/ and not present on the V2 role
  at all.

Porting it now would require a >50% rewrite. Per the stage rule,
AI-authored equivalents land under `t/AI/` (the integration test
above; the per-plugin unit tests below). A future stage that
brings `App::Yath2::Tester` across can pick `plugin.t` up cleanly.

Similarly, `old/t/Yath/integration/coverage*.t` (five files) all
require the aggregator port to produce coverage artifacts.
Deferred with the aggregator port to Stage 18 / a successor plan.

## Tests shipped

New AI-authored tests under `t/AI/`:

- `t/AI/unit/App/Yath2/Plugin/SysInfo.t` -- role composition,
  `run_fields` shape, hostname capture, `host_short_pattern`, env
  filter, `run_queued` dispatch. (6 subtests)
- `t/AI/unit/App/Yath2/Plugin/Git.t` -- role composition, env-driven
  `run_fields`, no-branch fallback, no-long-sha empty return,
  `run_queued` dispatch, `HAS_*` constants. (6 subtests)
- `t/AI/unit/App/Yath2/Plugin/Cover.t` -- role composition,
  `HAS_TEST2_PLUGIN_COVER` constant, `run_queued` no-op (stage-15
  deferral), `annotate_event` short-circuit, `client_finalize`
  silent no-op, `_percentages` helper. (6 subtests)
- `t/AI/unit/Test2/Plugin/Immiscible.t` -- three import paths
  (skip callback, lock-acquired success, not-writable SKIP) via a
  fork+capture helper. (3 subtests)
- `t/AI/unit/Test2/Plugin/IsolateTemp.t` -- active mutation path
  (tempdir allocated, env set, sticky mode) + TEST2_HARNESS_ACTIVE
  no-op. Runs plugin in a child so the outer test's %ENV isn't
  touched. (2 subtests)
- `t/AI/integration/plugin_run_queued.t` -- end-to-end run_queued
  dispatch + field stamping through a running harness. (8 subtests)

## Final test suite

    prove -I lib -I t/lib -r -j16 t/
    Files=62, Tests=548, 60 wallclock secs. Result: PASS

Starting point (Stage 14 tip): 56 files / 517 tests. This stage
adds 6 test files and 31 subtests.

End-to-end CLI smoke (not part of the prove suite):

    perl -Ilib scripts/yath test -pSysInfo /tmp/trivial-pass.t
    perl -Ilib scripts/yath test -pGit     /tmp/trivial-pass.t
    perl -Ilib scripts/yath test -pCover   /tmp/trivial-pass.t

All three exit 0 with "RESULT: PASSED".

## Points of interest / decisions to revisit

- **Cover aggregator deferred to Stage 18 / successor plan.** The
  Stage 10 audit argued for deferral; Stage 15 took the argument.
  A minimum slice to get `yath test -pCover --cover-files
  --cover-write=coverage.jsonl` producing a real file would need:
  (a) `App::Yath2::Log::CoverageAggregator` + `ByRun` + `ByTest`
  ported from `old/lib/Test2/Harness2/Log/CoverageAggregator*.pm`,
  (b) dispatch from the artifact-reading layer (Stage 12) into
  plugin `annotate_event`, and (c) `load_import` / `preload_early`
  options re-activated in Stage 6. All three belong to a single
  follow-up work item. If a reviewer wants the aggregator sooner,
  pick (a) + a minimal plumbing for (b); (c) is independent.

- **`run_queued` dispatch is currently the only harness-side hook
  site.** Stage 7 summary: "call sites land when the consuming
  subsystem needs them". Stage 15 added the `run_queued` site only
  because SysInfo + Git need it. `tick`, `run_complete`,
  `run_halted`, `instance_*`, `changed_*`, `duration_data`,
  `coverage_data`, `munge_*`, `claim_file` remain defined on the
  role but never dispatched from the harness. Next stage / review
  should decide whether to grow the dispatch surface per-consumer
  (current policy) or in one sweep.

- **`run_fields` stamped onto Run vs emitted as a separate
  event.** Old/ emitted `harness_run_fields` as a per-run facet_data
  event over IPC (Run.pm's `send_event`). New/ stamps onto the Run
  object itself and lets `run_queued` event's `run_data` carry the
  fields. Rationale: the Stage 7 notes call out that `send_event`
  depended on Collector::Child / IPC::Util, neither of which exist
  in the new rewrite yet. Stamping onto Run is the lowest-friction
  alternative and keeps all run metadata travelling together
  through TO_JSON / JSONL serialization. If a future consumer wants
  a standalone `harness_run_fields` event again, the harness can
  emit one from the same dispatch site.

- **Distribution-split decision on `Test2::Plugin::*`.** Both
  `Immiscible` and `IsolateTemp` stay in this distribution. Neither
  depends on the harness (Immiscible doesn't at all; IsolateTemp
  uses one small `Test2::Harness2::Util` helper). Hoisting out
  stays easy if a reviewer disagrees; the code is self-contained.

- **`yath run` plugin loading is symmetric with `yath test` on
  client_* hooks, but NOT on run_queued.** The daemon decides
  which plugins stamp run metadata because the run executes there.
  `yath run -pSysInfo` only affects the command process's
  client_setup / client_teardown / client_finalize. This is the
  Stage 14-era separation and matches the command-set shape
  already in tree; flagged here so the reviewer knows it's
  intentional.

- **Cover's `post_process` is a write-through to two options still
  commented out in Stage 6.** Guarded with `can()` checks so the
  plugin is usable today; the guard disappears when Stage 18
  activates `tests->load_import` and `runner->preload_early`.

- **`Git` plugin treats a nonzero `git` exit inside
  `run_fields` as expected (not a hard error).** Old/ dies on
  non-zero git exit. We eval each per-command call separately so
  "cwd is not a git repo" and "branch unknown" produce quiet empty
  returns rather than aborting the whole `run_fields` output.

## Deviations from IPC_AND_LOGGERS

None. The run_queued hook dispatch and field-stamping are both
downstream of the service's own `emit_service_event(kind =>
'run_queued')` call (section 7) and use the existing `run_data`
payload shape. Adding `fields` as one more key on the Run's
TO_JSON snapshot is the same pattern other Run attributes already
use.

## Points for the next stage / user reviewer

- **Stage 16 (resources port)**: `App::Yath2::Resource::SharedJobSlots`
  is the one concrete item to bring across. This stage did not
  touch resources, so the Stage 14 surface is unchanged.
- **Cover aggregator follow-up** (Stage 18 / successor): see the
  first bullet under "Points of interest". Inline TODOs inside
  `lib/App/Yath2/Plugin/Cover.pm` point at the exact slots that
  re-enable when the aggregator lands.
- **If the stage-chain decides to stop deferring `yath run`
  run-side plugins**: the cleanest path is probably threading the
  command-side plugin list into `queue_test_run`'s payload as a
  new `plugins` field; the daemon would then union it with its own
  plugin set for that one run. Not started in this stage.
