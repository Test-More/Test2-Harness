# Stage 5 — Minimal `test` command

## Branch

- `plan-stage-05-test-command`
- Base: `plan-stage-04-yath-script`

## Post-rebase note (architectural realignment)

PLAN gained a new "State and control flow: IPC, not on-disk
artifacts" section after these commits first landed: no file
written by a logger can be functionally load-bearing, and the
`test` command's pass/fail verdict must come from a direct IPC
query to the harness service, not from reading `0.json`. Commit
#6 below is the correction -- it replaces the original Stage-5
file-tally path with IPC-driven polling + tally.

## What landed

Six commits (commits #5 and #6 are post-Stage-5 cleanups committed
here rather than opened as separate stages):

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
   `lib/App/Yath2/Command/test.pm`. The original Stage-5 command:
   finder -> spawn harness -> wait -> tally per-job `0.json`
   sidecars -> exit 0 / 1 / 2. Superseded by commit #6 once PLAN
   forbade file-based tally; the original commit is preserved in
   history for review clarity.

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

6. **`Command::test: tally pass/fail via IPC, scoped to the
   queued run`** — PLAN's "State and control flow: IPC, not
   on-disk artifacts" section forbids any logger-written file
   from being functionally load-bearing, and the tally must be
   scoped to the specific run the command queued (today
   Command::test; tomorrow Command::run against a multi-run
   daemonized harness). This commit:
   - Threads a pass flag into Run's `mark_done`; Run gains
     `pass_count` / `fail_count` slots.
   - Adds a `completed_runs` snapshot map on Harness2 keyed by
     run_id, populated when a run is pruned from the queue.
   - Adds `request_handler_run_status` (+ `Spawn::run_status`):
     given a run_id, returns the run's live queue state or, if
     the run has already completed, its captured snapshot.
   - Rewrites Command::test to drop `test_run` at spawn, queue
     the run over IPC via `Spawn->queue_test_run` (capturing the
     returned `run_id`), poll `run_status($run_id)` for drain,
     read the per-run `pass_count` / `fail_count` from the
     response, then send `finish` and wait. The `0.json` walk
     is gone.

## Tests

- `prove -j16 -I lib -I t/lib -r t` — 31 files, 343 tests, all
  pass (~60s wall clock).
- End-to-end `yath test` smokes (single-file, post commit #6):
  `passing.t` -> pass=1 fail=0 exit=0; `failing.t` -> pass=0
  fail=1 exit=1; mixed -> pass=1 fail=1 exit=1.
- Two-run isolation smoke (ad-hoc): queue a pass-only run and a
  fail-only run against the same harness; `run_status` reports
  pass=1/fail=0 for the first id and pass=0/fail=1 for the
  second. Per-run scoping confirmed.

## Historical: pre-existing harness infrastructure issue (now resolved)

**Resolved by the logger overhaul now landed on
`reimplement-resource-classes` + commit #6 above.** The notes
below describe the state before that overhaul; leaving them in
place for the commit-review narrative.

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
