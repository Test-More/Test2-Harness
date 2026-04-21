# Stage 18 -- TODO cleanup sweep

## Branch

- `plan-stage-18-todos`
- Base: `plan-stage-17-acceptance` (tip `773e493c8`)
- Final HEAD (before this summary): `1e8e7d0fb`
- Commit count: 8 code + this summary

## Scope

Walk the tree for `TODO` markers left by earlier stages. Resolve
each one where tractable; re-document the rest, in place, with
clear pointers at the successor work that will resolve them.
Intentional design markers left by earlier stages (the commented-
out option libraries under `lib/App/Yath2/Options/*.pm`) stay
untouched -- the PLAN's Stage 6 section calls for exactly that
shape, and each such TODO already carries a "when X lands" note.

## TODO inventory (pre-Stage 18)

A sweep of `lib/ t/ scripts/ docs/` at start of stage yielded
roughly 170 `TODO`-flagged entries. Ignoring TAP-language hits
(TAP parser / TAP test fixtures with legitimate `# TODO` directives),
the real markers broke down as:

- ~155 in `lib/App/Yath2/Options/*.pm`: commented-out option
  blocks waiting for their consumer stage to activate them.
  These are the designed-deferred Stage 6 state and stay as-is.
- 5 in `lib/App/Yath2/Plugin/Cover.pm`: coverage-aggregator /
  load-import / preload-early wiring gaps. Reclassified as
  successor-plan deferrals.
- 1 in `lib/App/Yath2/ArtifactReader.pm`: per-job verdict
  fallback via future `list_run_final_state` query.
  Reclassified as a Stage 19 follow-up note.
- 13 in `t/integration/*.t`: per-test `TODO Stage 18` headers on
  skip_all'd ports from Stage 17. Reclassified as
  successor-plan deferrals with explicit resolved-by pointers.
- 1 in `scripts/yath`: @INC handling regression vs. old/scripts/yath.
  **Resolved in place.**
- 1 renderer synthetic-event gap (filename label column on
  `[PASSED  ] <label>`). **Resolved in place.**

## Disposition table

| Category | Count | Disposition |
|----------|-------|-------------|
| `scripts/yath` @INC regression | 1 | Resolved |
| `--extension` option activated + wired to Finder::Simple | 1 | Resolved |
| Harness `run_status` jobs map + ArtifactReader filename | 1 | Resolved |
| `Plugin::Cover` deferred wiring (load_import, preload_early, annotate_event, aggregator port) | 4 | Re-documented (successor plan) |
| `ArtifactReader` per-job verdict inference | 1 | Re-documented (Stage 19) |
| `t/integration/init.t` skip_all header | 1 | Re-documented (Stage 19 audit) |
| `t/integration/help.t` skip_all header | 1 | Re-documented (post-parity help rewrite) |
| `t/integration/*.t` other skip_all headers | 11 | Re-documented (per-test resolved-by) |
| `lib/App/Yath2/Options/*.pm` option TODOs (Stage 6 designed-deferred) | ~155 | Untouched (already correctly deferred) |

## `skip_all` lifts

- **`t/integration/nested_includes.t`**: one lift. The combination
  of the `scripts/yath` @INC fix and the new `T2_HARNESS_INCLUDES`
  -> launch-`-I` plumbing in `App::Yath2::Command::test` lets the
  test run to completion. Verified green with
  `perl -Ilib -It/lib t/integration/nested_includes.t`.

No other Stage 17 skip_all tests were lifted: each of the remaining
twelve blocks on work substantially bigger than this stage (renderer
Formatter redesign, --log / Tester plumbing, extra plugin hooks,
daemon output-shape rebuild, retry-mechanism port, etc.).

## Per-commit notes

| SHA | Subject |
|-----|---------|
| `5e8c462f3` | `scripts/yath: restore append-style T2_HARNESS_INCLUDES handling` -- one-block fix matching old/scripts/yath exactly. |
| `4ee915672` | `Finder: activate --ext/--extension option and wire it through` -- uncomments the --ext / --extension / --extensions option on `App::Yath2::Options::Finder`, teaches `App::Yath2::Finder::Simple` an `extensions` named arg, threads it through `Command::test`, and folds `T2_HARNESS_INCLUDES` into the launch-side `-I` list (mirrors old/TestSettings::includes). |
| `c53521c2f` | `t/integration: lift skip_all on nested_includes.t` -- replaces the skip with the real test body. |
| `33838e41f` | `Harness: surface per-job test_file via run_status; ArtifactReader uses it` -- adds a `jobs` map (job_id => { test_file, test_file_abs }) to `request_handler_run_status` + the completed-run snapshot, then threads `file` into the synthetic `test_job_started` / `test_job_completed` events so `Renderer::Default::_job_label` gets to use its already-existing `$h->{file}` lookup branch. Renderer lines read `[PASSED  ] Event.t: ...` instead of the opaque UUID Stage 17 documented. |
| `fdd31e285` | `Plugin::Cover: reclassify Stage 18 TODOs as successor-plan deferrals` -- rewrites four TODO markers as explicit 'Deferred: resolved-by <successor plan>' notes. |
| `24f43be97` | `ArtifactReader: reclassify per-job verdict TODO as successor-plan note` -- similar reclassification. |
| `0f94e7cd1` | `t/integration: reclassify init.t and help.t TODOs as post-parity follow-ups` -- these two tests are effectively obsolete-by-design or wait on a dedicated help rewrite; both are now explicitly deferred. |
| `1e8e7d0fb` | `t/integration: reclassify skip_all TODO headers as successor-plan deferrals` -- bulk rewrite of eleven skip_all'd tests so their headers now name their blocking dependency verbatim rather than reading as Stage-18 leftovers. |

## Tests

Final:

```
prove -I lib -I t/lib -r -j16 t
Files=84, Tests=591, 60 wallclock secs
Result: PASS
```

Stage 17 baseline was 84 files / 590 tests. The +1 test is the
`nested_includes.t` skip_all that now runs a real yath invocation.

## Points of interest / decisions for Stage 19

### 1. Renderer Formatter column gap is a real follow-up

Stage 17 flagged that the new `Renderer::Formatter` drops the old
"job N" column, the depth indentation, and the tree-corner markers.
`encoding.t` and `tapsubtest.t` still skip_all on that.

Stage 18 did not attempt it. The decision tree is:
(a) restore the old shape verbatim to let both tests port cleanly,
(b) redesign the verbose output and move both tests under `t/AI/`
    since > 50% of the body would change,
(c) leave the skip_all markers in place indefinitely.

This is a renderer-design call; Stage 19 audit should decide.

### 2. Auditor strictness vs. `old/`

Stage 17 noted that `lib/Test2/Harness2/Collector/Auditor/Test.pm`
rejects five raw-TAP shapes old/ tolerated in its
`FAILURE_DO_PASS=1` branch (badplan.tx, dupnums.tx, missingnums.tx,
buffered_subtest_abrupt_end.tx, buffered_subtest_abrupt_end_nested.tx).

Stage 18 did not touch the Auditor. Whether the stricter contract
is a conscious improvement or a regression is a post-parity policy
decision; Stage 19 audit is the right place.

### 3. `--log` / Tester `log => 1` plumbing is the single biggest skip_all multiplier

Four skip_all'd tests (`concurrency.t`, `resource.t`, `smoke.t`,
`stamps.t`) block primarily on the Tester `log => 1` knob and a
CLI `--log` / `-L` / `--log-dir` that feeds an explicit JSONL
logger into the workdir. The per-job JSONL logger already wires
in for renderer consumption -- the user-facing top-level log is
the gap. Activating the existing `--log` option block in
`App::Yath2::Options::Run.pm` and a small Tester follow-up would
unblock all four in one pass. Not in scope for Stage 18; flagged.

### 4. `init.t` is likely obsolete-by-design

`Command::init` writes `.yath.rc`, not `test.pl`. The assertion
surface in `old/t/Yath/integration/init.t` is hardcoded to the old
`test.pl` scaffold. Stage 19 audit should either delete the test
body outright (it no longer maps to new behaviour) or rewrite it
against `.yath.rc` (which almost certainly pushes it under
`t/AI/` since >50% of the body would change).

### 5. `help.t` needs a dedicated help-rewrite stage

`App::Yath2` intercepts `help` at the top level; `Command::help`
is a Stage 13 stub. The old-style layout the test asserts
(`^Usage:`, per-command summary rows, group-header sections) is
tied to Getopt::Yath's help generator. A dedicated help-rewrite
stage is a reasonable successor plan item; Stage 18 does not
attempt it.

### 6. `lib/App/Yath2/Options/*.pm` option TODOs stay intentionally

~155 option-level TODOs in `lib/App/Yath2/Options/*.pm` are the
designed-deferred Stage 6 state (PLAN Stage 6: "Any option that a
stage does not need yet stays wrapped in a clear TODO block...
When a later stage activates one, the commenting is removed and
the TODO marker deleted."). Each one names the stage that will
activate it. They are the correct end-state for Stage 18, not
outstanding work.

### 7. Per-run JSON sidecar -- already done

The PLAN's Stage 18 bullet about `Test2::Harness2` writing the
per-run JSON directly needing to migrate to a per-run service
owning its own snapshot is already satisfied:
`Test2::Harness2::RunService::_write_snapshot` owns the atomic
write to `$logdir/runs/<run_id>.json`, and `Test2::Harness2` itself
no longer writes any run-scoped JSON. No work needed for this bullet.

## Safety

- Did not merge `reimplement-resource-classes`.
- Did not push any branch.
- Did not rebase any `plan-stage-*` branch.
- Did not modify `PLAN` / `ARCHITECTURE.md` / `IPC_AND_LOGGERS`.
- Did not modify or delete other worktrees.
- No `--no-verify`, `--no-gpg-sign`, `--amend`, force-push, or hook bypass.
- No AI / Claude / skill mentions in commit messages.
- Did not delete any tests; the one skip_all lift landed as a
  proper test body port (nested_includes.t).
