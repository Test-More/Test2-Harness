# Stage 20 -- `yath test` runner + top-level help regressions

## Branch

- `plan-stage-20-yath-test-help`
- Base: `plan-stage-19-audit` (new tip `99f2083aa` after the chain
  rebase this stage triggered)
- Final HEAD: see `git log -1 --oneline`

## What this stage fixes

1. **`.yath.rc` filename-based version detection.** The plain file
   was defaulting to V1 and the installed V1 `App::Yath` choked on
   the `# V2` marker comment. Renamed the file to `.yath.v2.rc` at
   Stage 17 (where acceptance tests first spawn `scripts/yath` as a
   subprocess) so the rename is available to every stage from 17
   onward. Stage 20's own rename commit was dropped during rebase
   because its patch was already upstream.

2. **Top-level `-D`, `--help`, `--help=GROUP`, `--version`.** The
   Stage 4 `App::Yath2->run` stub rejected any argv token starting
   with `-`. Replaced it (Stage 4 sub-agent) with a real top-level
   dispatcher driven by `Getopt::Yath`, which consumes yath-level
   options before dispatch and renders group-scoped help via
   `Getopt::Yath::Instance::docs`. Stage 6 sub-agent uncommented
   the `dev_libs`, `help`, `version`, and `dev_libs_verbose` TODO
   blocks in `App::Yath2::Options::Yath` so the real option
   definitions back the dispatcher.

3. **`yath test --help` / `yath test --help=GROUP`.** Stage 4's
   dispatcher stops at the first non-option, so anything after the
   bare command name goes to the command's own parser. Extended
   `App::Yath2::Command::test::run` to honour a post-parse
   `$settings->yath->help` value by building a
   `Getopt::Yath::Instance` with the command's full
   `include_options` chain and calling `docs('cli', ...)`.

4. **Harness service env hygiene (the real fix for "yath test fails
   under yath").** `Test2::Harness2::start` now clears a narrow set
   of leaked env vars at service entry --
   `T2_FORMATTER`, `T2_HARNESS2_PIPE_COUNT`, `T2_HARNESS_FORKED`,
   `T2_HARNESS_JOB_IS_TRY`, `T2_HARNESS_JOB_NAME`, `T2_STREAM_DIR`,
   `T2_STREAM_FILE`, `T2_STREAM_JOB_ID`, `TEST2_JOB_DIR`,
   `TEST2_RUN_DIR`, plus `TEST2_ACTIVE` / `TEST_ACTIVE` /
   `TEST2_HARNESS_ACTIVE` if `Test2/API.pm` is not loaded.
   Deliberately does NOT clear `HARNESS_IS_VERBOSE` /
   `T2_HARNESS_IS_VERBOSE` / `T2_HARNESS_PRELOAD` because those
   are user-option-settable and have already been re-applied by
   the time `start()` runs.

5. **Launch -I paths are now absolute.**
   `App::Yath2::Command::test::_build_launch_args` and
   `Test2::Harness2::RunService`'s fallback `launch_cmd` default
   now absolutize every path before turning it into an `-I`
   switch. Fixes tests that chdir after `use Test2::V0` but
   before the first event emit: `Test2::API::test2_formatter`
   lazily `require`s `Test2::Formatter::Stream2` at that first
   emit, and without absolute `@INC` the child loses the repo's
   `lib/` when it moves cwd.

6. **Test-level isolation for qx{} grandchildren.**
   `t/AI/unit/Test2/Plugin/Immiscible.t` and
   `t/AI/unit/Test2/Plugin/IsolateTemp.t` fork a fresh perl via
   `qx{}` and expect plain TAP on STDOUT. Under yath the outer
   collector exports `T2_FORMATTER=Stream2`, so the grandchild
   was loading Stream2 and emitting JSON event frames instead of
   TAP. Added `local %ENV = %ENV; delete $ENV{T2_FORMATTER};
   delete $ENV{T2_HARNESS2_PIPE_COUNT};` in each `run_child`,
   plus an `$ABS_LIB = Cwd::abs_path('lib')` passed as `-I` so
   the grandchild finds its modules after its own cwd moves.

## Dispatched work (other stage worktrees)

- **Stage 4** (`plan-stage-04-yath-script`): real
  `App::Yath2->run` dispatcher + minimal `Options::Yath`. Two
  commits (`d0ccb71ad`, `afeb56c25`), both rebased into the
  chain.
- **Stage 6** (`plan-stage-06-options`): activated
  `dev_libs` / `help` / `version` / `dev_libs_verbose`. One
  activation commit (`51737e72f`, now rebased as `5f5c2304b`),
  plus a Stage-20-driven guard commit on `dev_libs`'s trigger so
  it doesn't fire a re-exec when the yath group has no `script`
  / `orig_argv` option yet (pre-full-dispatcher stages).

## Stage 5 / Stage 13 follow-up commits during rebase

- **Stage 5**: added a test fixup
  (`t/AI/unit/App/Yath2.t: match Stage 5's real 'test' dispatch`)
  because the Stage 4 sub-agent's new dispatcher test assumed
  every command in `%COMMANDS` emitted the "not been ported" stub
  banner. Stage 5 flips `test` to a real class, so the test's two
  `test`-using subtests had to assert the real banner.

- **Stage 13**: trivial conflict resolution on
  `lib/App/Yath2.pm`'s stub-banner copy (`$cmd` vs `$first`).

## Not resolved in Stage 20 (deferred to Stage 21)

- Single-test-per-run verdict misattribution under 16-way
  parallelism. `App::Yath2::ArtifactReader::_verdict_for_job`
  infers per-job pass/fail from running totals in `run_status`
  because the IPC layer does not carry an authoritative per-job
  verdict. Under load the totals can cross one job's ordering
  with another's and flip the wrong test to FAILED. Specific
  code pointer in PLAN section "Stage 21 -- Authoritative
  per-job verdicts".

## Chain rebase

The following branches were rebased onto the updated Stage 4 /
Stage 6 chain, in order. Each rebased cleanly except where noted:

```
plan-stage-05-test-command     conflict on lib/App/Yath2.pm (resolved)
plan-stage-06-options          add/add on Options/Yath.pm (took Stage 6's)
plan-stage-07-plugins          clean
plan-stage-08-preload          clean
plan-stage-09-preload-reload   clean
plan-stage-10-log-audit        clean
plan-stage-11-log-archive      clean
plan-stage-13-commands         trivial conflict on lib/App/Yath2.pm
plan-stage-12-renderers        clean (built on 13)
plan-stage-14-daemon           clean
plan-stage-15-plugins          clean
plan-stage-16-resources        clean
plan-stage-17-acceptance       clean (plus Stage-17-side rename commit)
plan-stage-18-todos            clean
plan-stage-19-audit            clean (local working-tree workaround stashed)
plan-stage-20-yath-test-help   clean (Stage 20 rename dropped as upstream)
```

`reimplement-resource-classes` was not touched. A note file,
`STAGE_20_NOTES_FOR_RESOURCE_REWORK.md`, was dropped into that
worktree (untracked) describing what the env-clear contract
implies for any resource logic landing there.

## Tests

`perl -Ilib scripts/yath test -j16 t/` runs the full tree and
exits 1 with 85 passed / 1 failed. The failing test is
non-deterministic -- rerunning picks a different single victim
each time -- and is the verdict-attribution race documented in
PLAN Stage 21.

`prove -Ilib -It/lib -j16 -r t` still passes every file.

`yath --help`, `yath --help=yath`, `yath test --help`, and
`yath test --help=yath` all render the expected option docs.

## Safety

- Did not merge `reimplement-resource-classes`.
- Did not push any branch.
- Did not modify or delete worktrees.
- Did not edit `reimplement-resource-classes`' committed content
  (only added an untracked note file).
- No `--no-verify`, `--no-gpg-sign`, or force-push.
