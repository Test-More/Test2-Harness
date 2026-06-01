# yath 2.0 entry point + `yath test` command

## Task

Stand up the `App::Yath2` user-interface namespace far enough to run tests
through the harness via the real `yath` script. Specifically:

- Implement `App::Yath::Script::V2` so the installed `App::Yath::Script`
  (external; provides the `yath` binary) discovers and drives our 2.0 code.
- Implement a `yath test` command that behaves like the `t2h2_run` dev driver
  but parses in-file directives and produces proper run / job objects to hand
  to the harness.

Honoring the directives at run time is explicitly out of scope for now; the
scanned data rides along on each job and a later change will act on it.

## What landed

Producer side (`App::Yath2`, the UI namespace):

- `App::Yath::Script::V2` — minimal delegate. `do_begin` builds an `App::Yath2`
  during BEGIN; `do_runtime` runs it and returns the exit code. The external
  `App::Yath::Script` already does version discovery and calls these.
- `App::Yath2` — lightweight dispatcher. `argv[0]` selects a command from a
  small static table (`test` only, for now). No `Getopt::Yath` framework; the
  heavy option machinery from `reference/old3` was deliberately not ported.
- `App::Yath2::TestFile` — the producer/scanner. Reads the shebang and
  `HARNESS2:` directives (via the ported `Test2::Harness2::Util::Directives`),
  detects binary / non-perl files, and `build_job(%ids)` returns a finished
  `Test2::Harness2::Run::Job`. All filesystem inspection lives here.
- `App::Yath2::Command::test` — mirrors `t2h2_run`'s start/subscribe/queue/
  render loop, but first scans each file into a `Run::Job`, assembles a
  `Test2::Harness2::Run`, serializes the jobs, and queues them as specs.

Harness side:

- `Test2::Harness2::Util::Directives` — copied from `reference/old3` and
  adapted to `use v5.38` + signatures. Pure parser; no file scanning.
- `Test2::Harness2::Scheduler::queue_run` now accepts a `jobs => [\%spec, ...]`
  source in addition to `files => [...]`. Specs are rehydrated into `Run::Job`
  objects; see the contract decision below.
- `Test2::Harness2::Service::Harness` request handler accepts `jobs` or
  `files` (jobs wins when both are present).

## Key decisions

### Client builds objects, harness rehydrates (not "harness builds from specs")

Objects can't cross the unix socket, so something has to serialize. Two models
were considered: (a) the producer emits opaque job-spec hashes and the
scheduler constructs the canonical objects, or (b) the producer builds real
`Run::Job` objects, serializes them via `TO_JSON`, and the scheduler
rehydrates.

Chose (b). The producer (`App::Yath2`) owns the *scan-derived* data and the
job identity it can know (`job_uuid`, `job_ord`, `run_uuid`); the harness stays
authoritative for `run_ord` (queue position) and reassigns it on rehydration,
propagating it to every job. `run_ord` is provisional (`1`) on the client side.
`Scheduler::_add_spec_jobs` overrides `run_uuid` / `run_ord`, honors a spec's
`job_uuid` / `job_ord` (vivifying when absent), and resets lifecycle to a fresh
`pending` / try 1.

This keeps `Run::Job`'s identity fields required (no relaxation) and matches the
earlier principle that the harness owns run lifecycle while other tools own the
scanned state.

### No `TestFile` value-object split on the harness side

Per the prior `Run::Job` decision, the harness has no separate `TestFile`
class — the scan-derived attributes are flat on `Run::Job`. The
`test_files`-history concept is a database / front-end construct and does not
exist in `Test2::Harness2`. The producer is still named `App::Yath2::TestFile`
(it produces from a test file), but it builds a `Run::Job` directly rather than
a `TestFile`.

### Scanner is a directive parser, not a resolver

`App::Yath2::TestFile` stores raw scanned values (category/duration left undef
when unspecified, etc.). It does *not* apply the legacy scanner-aware
resolution (isolation-category, long-duration-when-no-timeout, fork-off for
non-perl) — that is "honoring directives" territory, deferred. `Run::Job`'s
`check_*` helpers still provide the simple `general` / `medium` fallbacks.

Malformed dotted directives (e.g. `feature foo` instead of `feature.foo`) warn
and are skipped rather than crashing the run.

## Discovery / usage

`.yath.rc -> .yath.v2.rc` carries `-D`, and `lib/App/Yath/Script/V2.pm` exists
in the checkout, so running `yath test t/foo.t` from the repo re-execs with
`./lib` on `@INC`, captures version 2 from the rc symlink, and loads our V2.

    yath test t/foo.t t/bar.t
    yath test -v  t/foo.t      # also paint each job's events
    yath test -vv t/foo.t      # also record/show stray events

## Known follow-ups

- The harness does not yet act on any scanned directive (slots, conflicts,
  isolation, timeouts, retry, preload). Jobs carry the data only.
- `Command::test` duplicates `t2h2_run`'s render loop. If a third consumer
  appears, factor the monitor-render loop into a shared helper.
- Scanner-aware classification fallbacks (isolation/long/fork-safety) are not
  ported; revisit when directive honoring is implemented.
