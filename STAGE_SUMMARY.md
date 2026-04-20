# Stage 5 — Minimal `test` command

## Branch

- `plan-stage-05-test-command`
- Base: `plan-stage-04-yath-script`

## What landed

Five commits (the fifth is a post-Stage-5 cleanup committed here rather
than opened as a separate stage):

1. **`App::Yath2::TestFile: a plain TestFile value object`** —
   `lib/App/Yath2/TestFile.pm`. Role-consuming
   (`Test2::Harness2::Role::TestFile`) `Object::HashBase` object with
   the defaults that `Run::from_files` expects. `Test2::Harness2`
   itself never touches a concrete TestFile class; it only looks at
   the role.

2. **`App::Yath2::Finder::Simple: minimal test-file discovery`** —
   `lib/App/Yath2/Finder/Simple.pm`. Expands positional args: files
   pass through as-is; directories get a recursive `*.t` scan.
   Dedup on absolute path. Croaks on missing paths.

3. **`App::Yath2::Command::test: minimal test command`** —
   `lib/App/Yath2/Command/test.pm`. The Stage-5 command: finder ->
   spawn harness -> wait -> tally per-job `0.json` sidecars -> exit
   0 / 1 / 2.

4. **`App::Yath2: dispatch 'test' command to App::Yath2::Command::test`** —
   flip the registry entry from the stub sentinel to the real class
   name and add `_dispatch()` which `require`s + `new`s + runs.

5. **`Drop Test2::Harness2::TestFile fixture; use App::Yath2::TestFile`** —
   delete `t/lib/Test2/Harness2/TestFile.pm` (a near-duplicate of the
   Stage-5 concrete class). Retarget every Harness2 test that needed
   a concrete TestFile object at `App::Yath2::TestFile`. The
   dedicated round-trip test moves from
   `t/AI/unit/Harness2/TestFile.t` to
   `t/AI/unit/App/Yath2/TestFile.t`. The role unit tests
   (`t/AI/unit/Harness2/Role/TestFile.t`) continue to use inline
   consumer packages and do not depend on any concrete class.

## Tests

- `prove -I lib -I t/lib -r t` — 32 files, 355 tests, all pass (~72s).
- Manual smoke via `perl -Ilib scripts/yath test <path>` — command
  wiring works end-to-end: options parsed, finder runs, harness
  service spawned, logs written, per-run JSON sidecar produced.

**However:** the test jobs themselves do not actually run to
completion under the current base branch (see "Pre-existing
harness infrastructure issue" below). Manual smokes therefore
exit with the fail path, because the harness emits
`job_completed {err => 255}` on every job launch and no per-job
`0.json` sidecar is ever written.

Per Chad's direction on 2026-04-19, Stages 6+ proceed on top of
this chain and accept that `yath test` is not end-to-end
verifiable until the base regression is addressed separately.
Stage 6 work will be verified via the `prove -I lib -I t/lib -r t`
path only.

## Pre-existing harness infrastructure issue (NOT Stage 5 scope)

When invoking a test through either

    Test2::Harness2->spawn(workdir => $dir,
                           test_run => {files => [$tf]},
                           finish_after_initial_run => 1)

or the drain-then-finish pattern used by
`t/AI/integration/harness2_run_service.t`:

    my $spawn = Test2::Harness2->spawn(workdir => $dir);
    $spawn->queue_test_run(files => [...]);
    wait_until(queue empty && running empty);
    $spawn->finish;
    $spawn->wait;

the harness logs:

1. `run_queued`, `job_queued`
2. `service_started`, `run_started`
3. `job_started`
4. `job_loggers` (only records the **harness's own** loggers — the
   `jsonl_file` points at `logs/services/harness.jsonl`, not at the
   per-job `logs/runs/<run_id>/<job_id>/0.jsonl`)
5. `job_completed` with `{exit => {err => 255}, pass => 0}`
6. `run_ended`, `service_stopped`

The per-job directory IS created under
`logs/runs/<run_id>/<job_id>/` — empty, no `0.jsonl`, no `0.json`.

`err => 255` is the documented "collector itself failed" exit path
(ARCHITECTURE.md section 7, "Exit code mirroring", point 1). The
collector forks inside the `RunService::request_handler_launch_job`
spawn but exits before any logger calls `startup`.

The existing integration tests
(`t/AI/integration/harness2_run_service.t`,
`harness2_start.t`, `harness2_spawn.t`) pass because they only
assert on service-level artefacts (service jsonl exists,
`service_started`/`service_stopped` events present, run dir exists)
and never on per-job completion. The bug is latent and pre-dates
Stage 5.

Prior triage pointed at three likely culprits (in
`Test2::Harness2::Collector::spawn` as called from
`RunService::request_handler_launch_job`):

- An `ipcm_info` passed to the collector child that doesn't match
  what the child needs to reach the bus.
- `new_pgroup => 1` on the collector combined with the run service
  already being in a nested pgroup killing the collector early.
- Hard-coded `-Ilib` in the collector launch argv
  (`RunService.pm:155`) failing outside the repo root.

None of these are Stage 5 blockers — they are Stage 1 (or earlier)
base-branch bugs that the existing integration tests happen not to
catch.

## Points of interest / decisions you may want to revisit

1. **`App::Yath2::TestFile` vs `Test2::Harness2::TestFile` duplication** —
   **RESOLVED** (2026-04-19). The fifth commit above dropped the
   `t/lib` fixture. Per Chad: `App::Yath2::TestFile` is where the
   test-file processing logic lives; `Test2::Harness2` only ships
   the role (`Test2::Harness2::Role::TestFile`) describing what
   consumers must provide.

2. **`App::Yath2::Finder::Simple` is a pure class method, not a
   role consumer.** Stage 7 (plugins) will introduce hooks that want
   to interpose on finder results. When that lands, expect this
   module to either grow a plugin-aware subclass or be replaced.

3. **The command tallies from per-job `0.json` sidecars.** That
   matches the ARCHITECTURE-doc layout (section 7, per-test logs).
   It also means "no sidecar" counts as a failure — so if the
   collector dies before `Logger::JSON`'s `shutdown` fires (which
   is exactly what's happening above), every job counts as a fail.
   Once the launch regression is fixed, this behaves correctly.

4. **`argv` hash-key trick repeated.** `App::Yath2::Command::test`
   carries the same explicit `sub argv { $_[0]->{argv} }` accessor
   that `App::Yath2` does, for the same reason (the `ARGV` bareword
   reservation). If we end up building many command classes with
   the same shape, it's worth extracting a tiny
   `App::Yath2::Role::Command` that does this once.

5. **`local $?` around `$spawn->wait`.** `Spawn::wait` calls
   `waitpid` and thus leaves `$?` set to the service's exit status.
   Perl's END/DESTROY cleanup propagates `$?` after `exit()`, which
   silently overrode the explicit `exit 1` I was trying to return.
   The fix is a `local $?` block; the commit message calls this out
   so the trap stays documented.

6. **`--help` / `--version` inside `yath test` not wired.** The
   Stage-5 scope is "positional args only, no options." Once Stage
   6 ports the option libraries, `Command::test` will start
   consuming them. Right now any `-flag` argument to `yath test`
   would be passed straight through to the finder, which will
   then fail the `-e $path` check.

7. **No dedicated unit tests for `Command::test`.** Per PLAN Stage 5
   ("Only ship narrowly-scoped unit/smoke coverage"), the intended
   coverage is "invokes with a single passing test and exits 0" and
   "invokes with a single failing test and exits non-zero." Those
   tests would be green *if the harness launch regression weren't
   in the base* — blocked on that. The underlying `Finder::Simple`
   and `TestFile` classes do have trivial sanity in the smoke runs
   I did while writing the code.

8. **The PLAN's Stage-5 language "Only ship narrowly-scoped
   unit/smoke coverage" deliberately avoids porting
   `old/t/Yath/integration/test.t`.** Integration coverage comes in
   later stages as options/plugins/preloads/renderers land.
