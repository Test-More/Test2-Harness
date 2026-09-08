# RULINGS.md

Decisions this project's owner has already made. A recorded ruling stands
until the owner changes it.

Read this file when a decision is in front of you, not for general context.
When new evidence — a bug report, a pull request, a user request, a changed
constraint — suggests a ruling needs revisiting, flag it for the owner rather
than acting against it. See `~/projects/Agents/AGENTS.md` under "Rulings".

Newest first. Each entry gives the date, what was ruled, and enough evidence
for the next reader to judge whether the situation has changed.

Only decisions that could be raised again belong here — contentious calls,
questions likely to recur, and rulings that may need revisiting when
circumstances change. Routine decisions nobody will ever question stay out;
see `~/projects/Agents/AGENTS.md` under "What earns a place in `RULINGS.md`".

---

## 2026-09-08 — `--cover-exclude-dirs` globs, the same as `--cover-dirs`

**Ruling: the exclusion option expands its argument with `glob()` in its
option action, exactly as `--cover-dirs` does. Both halves of a project layout
are then expressible the same way: `--cover-dirs 'cmp/*/lib'` and
`--cover-exclude-dirs 'cmp/*/t'`.**

Coverage and its metrics are meant to cover source files: modules under
`lib/`, per-project libraries under paths like `cmp/*/lib`, and config files
anywhere, but not tests under `t/`, not test libraries under `t/lib` or
`cmp/*/t`, not system libraries, and not other projects linked or checked out
into the working directory. `cmp/*/t` cannot be written as a literal path, and
the matching include side already globs, so a literal-only exclusion option
would leave half the layout inexpressible.

`glob()` runs at option-parse time, so a pattern matching nothing excludes
nothing while the user believes it is configured. That hazard is accepted
rather than solved: the trees this option exists for are checkouts that exist
before the run, the effective exclusion list appears in verbose and debug
output, and the option description says expansion happens when the option is
parsed.

Inherited with `glob()`: a path containing whitespace is split. That is
pre-existing behavior of `--cover-dirs` and is shared deliberately rather than
diverging between the two options.

---

## 2026-09-08 — coverage metrics honor the exclusion list

**Ruling: `Test2::Harness::Log::CoverageAggregator::build_metrics` skips
excluded paths during its directory walk. An excluded file is counted in
neither `files`/`subs` totals nor `untested`.**

Without this, excluding a tree that sits inside a `--cover-dirs` directory made
the reported numbers worse rather than neutral: the file still incremented the
totals, and because it was no longer touched it was pushed onto
`untested.files`, whose paths reach the Test2::Harness::UI database through the
run's coverage field. Excluding a tree lowered the coverage percentage and put
the excluded paths in the database by another route.

`--cover-dirs` keeps its existing meaning as the metrics selector. This does
not make it a file-coverage allowlist; it subtracts an explicit exclusion from
the metrics walk so the two agree.

Metrics and file coverage are not the same set and are not meant to be. Metrics
count typed files under `--cover-dirs`; file coverage records every source and
config file actually touched under the run root. What must agree is the
exclusion rules.

---

## 2026-09-08 — excluding `t/` is configuration, not a default

**Ruling: yath does not exclude `t/`, `t/lib`, or any other test directory from
file coverage by default. A project that wants them out names them in
`--cover-exclude-dirs`, normally in `.yath.rc`.**

The goal that coverage cover only source files does imply tests should not be
recorded, but changing the default changes what every existing `--cover-files`
run records. It also has a concrete cost: coverage-driven test selection maps a
changed file to the tests that touched it, so dropping `t/lib` means a change
to a test library selects nothing.

Revisit as its own piece of work if the recipe proves to be what every project
writes anyway.

---

## 2026-09-08 — coverage requires Test2::Plugin::Cover 0.000029, not just the exclusion option

**Ruling: `App::Yath::Plugin::Cover::post_process` requires version 0.000029
of the coverage class wherever it loads it. The check is not gated on
`--cover-exclude-dirs`. `Test2::Plugin::Cover` stays a `RuntimeSuggests`
prerequisite; only the suggested version moves.**

Do not "optimize" this into a check that fires only when the exclusion option
is set. One version floor for the whole plugin is the point.

Without a check, `--cover-exclude-dirs` against 0.000025 through 0.000028 does
nothing at all and says nothing: the option parses, the `exclude` pairs are
transmitted, the old `import` absorbs them into its parameter hash, the old
`filter` ignores the key, and the dependency tree is recorded while the run
reports success. Silent under-exclusion is the failure this option exists to
prevent, and it would be the state of every machine that has not yet upgraded.

Promoting the prerequisite to `RuntimeRequires` was declined. Coverage is
optional, and this distribution deliberately installs before the rest of the
toolchain is trusted.

Consequence to accept: a `--cover-class` subclass must declare a version of at
least 0.000029, since the check runs against the class actually being loaded.

---

## 2026-09-08 — `--cover-exclude-dirs` rejects paths containing a comma

**Ruling: a `--cover-exclude-dirs` path containing a comma is rejected at
option-parse time with an error naming the reason. The check applies to each
resolved absolute path the option produces, after `glob()` expansion and path
normalization, not to the value as the user typed it. Commas in exclusion
paths are documented as unsupported. Do not add an encoding layer to
`load_import` to make them work.**

The resolved path is what gets transmitted, so it is the only thing worth
checking. This is wider than the typed value in the case that matters — a
comma in an ancestor directory name breaks a value that has none — and
narrower in one harmless case: a comma that `realpath` resolves away, such as
a symlink named `a,b` pointing at `ab`, is deliberately allowed, because
nothing containing a comma is then transmitted. Do not "restore" a check on
the typed value; it would reject paths that work.

Exclusions reach test processes through `run->load_import`, which has two
transports. `Test2::Harness::Runner::Job::cli_options` builds
`-M$mod=` . join(',', @args) for a fresh process, and perl splits that on
commas before calling `import`. `App::Yath::Command::runner::do_loads` calls
`$mod->import(@$args)` directly in the preload/fork path and has no such
limit.

So a path with a comma does not merely fail, it fails differently depending on
whether preload is in use, and it fails wrong rather than loudly:
`-MTest2::Plugin::Cover=exclude,/a/b,c/deps` arrives as
`('exclude', '/a/b', 'c/deps')`, which sets a truncated exclusion and leaves a
stray token in the parameter list. Rejecting up front turns a wrong answer
into a clear one and keeps both transports consistent.

The limit is not new to this option. `App::Yath::Options::Runner` already does
`split(/,/, $settings->runner->cover)` for Devel::Cover arguments, and every
plugin riding `load_import` shares it.

Encoding the arguments so any byte survives was considered and declined. It
would change a mechanism shared by `Devel::Cover`,
`Test2::Plugin::DBIProfile`, and any plugin using `load_import`, and both
transports would have to apply and reverse it — a permanent cost on everything
to serve one option's rare edge case. A separate env-var channel was also
dropped: it needs its own separator, so it solves nothing and adds a second
configuration path.

Revisit if: someone reports a real tree they cannot exclude. Supporting commas
later is backward compatible; withdrawing an encoding after callers rely on it
is not.

---

## 2026-08-20 — minor stall-diagnostics findings considered and accepted as-is

**Ruling: the following were each raised by an independent reviewer, judged
non-blocking, and deliberately left. They are recorded because a later review
will re-derive them, not because they are open work.**

- **The truncated event fragment is cut on a byte boundary**
  (`App::Yath::Command::test`, the EOF fragment report), so it can split a
  multi-byte UTF-8 sequence. The fragment is already a corrupt half-event and
  everything on that pipe is bytes; there is nothing valid to preserve.
- **`Stall::Capture::read_traces` unlinks a trace after reading it.** A handler
  still mid-write keeps writing into the unlinked inode, so its tail can be
  lost. The window is at least a second after the last signal. Closing it means
  having the handler write a temporary file and rename it, which puts more work
  in a signal handler inside a process already believed stuck — against the
  capture ruling's deliberate minimalism there.
- **A trace arriving after `read_traces` has read the directory** is attributed
  to the next report. Delayed, not lost; the per-process round number in the
  filename allows re-attribution.
- **`Stall::Detector::replay` warns without a cap for a direct caller.**
  `check()` gates at `>=` so it is unreachable from the only real caller.
  Cosmetic asymmetry with `poll_stamps`, which kept its guard.
- **`Stall::Capture::usr1_number` is unexercised.** Pinning the signal number
  in the two mask subtests is required — without it the file fails on every
  platform where `SIGUSR1` is not 10 — and that removed its only coverage. A
  reversed name/number map would fall through to `// 10` and stay invisible on
  x86. `%Config` is tied and read-only, so every available test either restates
  the implementation or asserts a platform constant.
- **The `STRONG:0` handler-install path has manual evidence only.** Reverting
  the `runner.pm` fix still passes the whole suite. The seam only bites when
  the last value is zero, which requires the strong tier and therefore nothing
  running, and the integration fixture starts one test first so its tier is
  `loose`. Covering it needs a second fixture.
- **`render_under_alarm` in the renderer unit test has a race**: SIGALRM landing
  between the eval returning and `alarm 0` lets the exception escape the
  helper. It surfaces as a clear test failure rather than a hang, across a
  handful of opcodes against a two or ten second alarm.

Revisit if: any of them is observed rather than reasoned about, or a delivery
path appears that makes the trace-file handling cheap to change.

---

## 2026-08-20 — where the stall bundle goes, and how it is named

**Ruling: the JSON bundle is written to the directory yath was run from, named
`yath-stall-report-<run_id>-<report>.json`, and a copy is also written into the
aux log as one physical line.**

Not the workdir, which is the obvious place and the wrong one. For a plain
`yath test` it is
`tempdir(CLEANUP => !($settings->debug->keep_dirs || $command->always_keep_dir))`
and `App::Yath::Command::test` inherits `always_keep_dir { 0 }`, so a bundle
written there is deleted moments later unless the site also passes
`--keep-dirs` or an explicit `--workdir`.

That matters because the text report is a reduced view. Each process's
`cmdline`, its open file descriptors and what they point at, `sigblk`/`sigign`/
`sigcgt`, `ppid`, thread count, kernel `stack`, `/proc/locks`, memory, load,
the workdir filesystem, the full pending and running task detail with
categories and conflicts, and exact timestamps exist **only** in the bundle.

**Location.** The directory yath was run from — the project root in practice.
`--stall-report-dir` overrides it, for a site whose working directory is not
writable or that collects bundles somewhere durable. Any test that produces a
bundle must pass that option, so running the suite never requires the
distribution directory to be writable; at install time it may not be.

**Name.** The run id keeps bundles from different runs apart, so many can sit
in one directory; the trailing report number keeps a single run's reports (up
to five) from overwriting each other. Both parts are required.

**Also to the log.** A file on the machine that stalled only helps someone who
can reach that machine, and these runs happen where nobody can. The bundle
therefore also goes into `aux_logs/stall-STDERR.log`, which
`Collector::process_runner_output` already forwards, so it reaches the yath UI
with the rest of the run.

**One physical line, and this is the part that is easy to break.** The
collector makes one info facet per *line* of an aux log, so a pretty-printed
bundle would scatter across hundreds of facets. `encode_json` escapes embedded
newlines, which is what keeps a single line true however large the bundle gets
— measured at 46,413 bytes for one report, parsing whole, with `meminfo`,
`/proc/locks`, `strace` output and the stack traces all intact inside it. It
survives rendering too, so it can be decoded straight out of a CI log.

The readable report goes to STDERR and the aux log; the bundle goes to the aux
log and the file, but **not** to STDERR, where it would drown the report it
belongs to.

**Deferred: attaching it as a binary instead.** `Test2::EventFacet::Binary`
exists and carries base64 `data`, `filename`, `details` and `is_image`; the UI
stores it (`Schema::Result::Binary`), serves it at `/binary/:binary_id`, and
`RunProcessor::add_binary` decodes it on ingest. `MAX_ATTACH` is already
defined at 1 MB in `test.pm` and `start.pm` — and consumed nowhere, in either
repository. What is missing is delivery: aux logs carry text lines only, so
nothing can currently move a facet from the runner side into the event stream.
The single-line JSON is sufficient until that path exists; it can be pulled out
of the info facet with one decode.

Revisit if: a site needs the bundle somewhere the option cannot reach, the log
copy proves too large in practice, or someone builds a way for the runner side
to emit a facet rather than a line.

---

## 2026-08-19 — stall diagnostics go to real STDERR and to an aux log

**Ruling: every stall diagnostic is printed to the main process's STDERR *and*
appended to `$workdir/aux_logs/stall-STDERR.log`. Never append to
`error.log`.**

The two channels serve two readers. The main `yath test` process's STDERR is
never redirected by yath — verified: `swap_io(\*STDERR, ...)` fires only when a
`stderr` parameter is passed (`Util/IPC.pm:106`), and neither `start_collector`
nor `start_auditor` passes one; `isolate_stdout` clones STDOUT and leaves
STDERR alone; `Test2::Harness::Plugin::redirect_io` is opt-in. Only the runner
and its descendants (`test.pm:955`) and test jobs (`runner.pm:453`) are
redirected. So STDERR reaches the Jenkins log directly — but nothing forwards
it, so it never reaches the yath UI database.

`aux_logs` closes that gap using a shipped mechanism.
`Collector::process_runner_output` re-`opendir`s `$workdir/aux_logs` on every
poll, picks up files created mid-run, derives a tag from the basename and sets
`debug => 1` for anything matching `*-STDERR.log` (`Collector.pm:228-243`). A
file nobody else writes, opened `>>` by the main process alone, reaches the UI
with no new forwarding code.

**`error.log` is not an option.** It is the runner's redirected STDERR, opened
by `swap_io` with mode `'>'`, not `'>>'` (`Util/IPC.pm:59`). The runner writes
at its own fd offset, so a second process appending at EOF has its bytes
overwritten by the runner's next write and corrupts the runner's output in
turn. Processes that already own `error.log` — runner, scheduler, stages —
writing their own `SIGUSR1` stack dumps to their own STDERR is fine and is not
affected by this.

The full JSON bundle is written separately; see the 2026-08-20 ruling on where
it goes and how it is named.

Limits accepted: `--hide-runner-output` disables the aux-log channel entirely,
and `truncate_runner_output` swallows the first poll batch.

---

## 2026-08-19 — the stall detector reports, it does not kill

**Ruling: detecting a stall produces diagnostics and nothing else. No signal to
terminate, no escalation ladder, no forced exit. Killing is deferred, and the
documentation says so rather than staying silent about it.**

Diagnosis is the goal and termination is secondary: nobody has identified a
root cause, manual means of killing these runs already exist, and Jenkins ends
them on its own after 30 minutes of silence. Killing would change the outcome
by minutes, not hours.

Three reasons beyond that.

**It works against the primary goal.** The reports are output, so each one
resets Jenkins' silence timer and buys more sampling rounds against a live
stalled process. With reproduction cycles measured in weeks, a stalled run left
running is an asset, not a liability.

**The tidy shutdown path is itself a wedge site.** Setting `SIGNAL` to unwind
cleanly routes into `App::Yath::Command::test::stop()`, which does
`delete $state->{no_poll}; $state->poll` (`test.pm:444-449`, not wrapped in
`eval`). That `State` constructs the user's resource classes and its `poll`
runs `release()` on them — the callback most likely to be wedged. Any kill
design has to route around the harness's own cleanup. Not setting `SIGNAL` is
what keeps the detector clear of this.

**Its test is hard to write.** An integration test for a kill path cannot use
an unbounded wedge: `App::Yath::Tester` sends TERM at 120s (`Tester.pm:126`),
and that TERM lands in the same `stop()` → `poll` → `release()` trap, hanging
the test process itself.

Also unspecified and deliberately not solved: nothing currently makes an
aborted run exit non-zero. `run()` returns `$pass ? 0 : 1` from `FINAL_DATA`
(`test.pm:224-239`), which is absent on this path, so the run dies "Final data
never received from auditor!".

This supersedes `STALL_FIX_BRIEF.md`'s acceptance criterion that a stalled run
must end itself non-zero, which was written before the owner set diagnosis
above termination.

Revisit if: a site needs the executor back sooner than Jenkins reclaims it, or
a capture proves complete enough that keeping the specimen alive no longer has
value. Adding a kill later is additive and leaves the diagnostic path
unchanged; the starting points are the `stop()` trap and the exit-code path
named above.

---

## 2026-08-19 — stall capture: external data in the sender, only the Perl stack in the signal handler

**Ruling: the detector collects everything obtainable from outside the stalled
process. The `SIGUSR1` handler produces only the Perl call stack, which cannot
be obtained any other way. Capture broadly — verbosity is cheap, a missing
field costs a reproduction cycle measured in weeks.**

### Division of labour

Collected by the **detector** (the main `yath test` process): per-process
`/proc/*/{status,stat,wchan,syscall,stack,cmdline,fd,fdinfo}`; `strace -p`,
short and bounded, best effort; `/proc/locks` (every flock holder on the box
with pid and inode); `/proc/loadavg`; `/proc/meminfo`; the workdir's filesystem
type and free space; the full process tree under the runner; the observer
`State` dump; and a verbatim lock-free tail of `dispatch.jsonl` and the other
workdir state files.

Collected by the **handler** in each signalled process: `caller($i)` frames
(package, file, line, sub name), `$0`, pid, ppid, `$!`, `$@`. Nothing else. No
harness object traversal — a wedged process is the wrong place to walk state,
and forking `strace` or opening files from a handler there is a bad bet.

**This split is required, not stylistic. The handler may never run.** A
process in an uninterruptible syscall, or one Perl auto-restarts, never reaches
an opcode boundary, so `SIGUSR1` is never delivered — and that is exactly the
case most in need of description. If `/proc` and `strace` lived in the handler
we would get nothing precisely when we need everything.

Consequently the detector **must not block waiting for a stack**. It records
"no stack obtained" and treats the absence as evidence: no stack plus
`State: D` in `/proc/*/status` is itself a diagnosis.

### Where the handler is installed, and the safety rule

Installed in **all harness processes**: runner, scheduler, stages, collector
and auditor. The main process needs no signal; it dumps its own stack directly.

**Not installed in test job processes, and they must never be signalled.** They
shed the handler when `longjump` fires the `Scope::Guard` restoring
`%orig_sig` (`runner.pm:130-142`), so `SIGUSR1` there takes its default action
and **terminates the test**. Therefore:

- Signal a positive whitelist of known pids only.
- **Never signal a process group.** `IPC::killall` signals groups
  (`IPC.pm:109-114`); the detector must not use it.

Install the handler inside `generate_run_sub` after the `%orig_sig = %SIG`
snapshot, so the scheduler and stage forks inherit it and job processes shed it
with no per-job cleanup code.

### Output shape

The handler writes to its own STDERR (which for runner/scheduler/stages is
`error.log`, already forwarded by the collector) **and** to
`$workdir/stall/stack-<pid>-<round>.txt`. The detector reads those after a
short timeout and folds them into one JSON bundle, so an analysis agent gets a
single artifact rather than interleaved stderr; the stderr copy survives if the
detector itself dies.

The report is emitted as human-readable text plus a structured JSON payload
between explicit begin/end markers, so it can be extracted from a Jenkins log
by pattern rather than by parsing prose, and written to
`$workdir/stall-report-N.json`.

The whole per-process set is sampled **3 rounds a few seconds apart**. Frames
and `syscall` moving between rounds is mechanism 2 (looping); identical is
mechanism 1 (wedged). That distinction is the first question any analysis asks
and is nearly free.

### Related

`strace` usually fails on default-hardened Linux and that is accepted rather
than worked around. Yama gates the **tracer** on being an ancestor of the
target; `strace` is a freshly exec'd process and is never an ancestor of the
scheduler. Measured on Arch at `ptrace_scope=1`: an ancestor's read of a
grandchild's `/proc/PID/syscall` succeeds, while `strace -p` against its own
direct child returns `ptrace(PTRACE_SEIZE): Operation not permitted`. It is
kept as best-effort because some CI containers run at `ptrace_scope=0` or with
`CAP_SYS_PTRACE`, and `/proc/PID/syscall` plus `wchan`, sampled repeatedly,
covers the same question when it is denied. `PR_SET_PTRACER` was considered to
force it to work and rejected as arch-specific `syscall()` code in a
perl-5.10-floor maintenance line.

Installing a `USR1` handler makes a blocking `flock` return `EINTR`.
`Runner.pm:322` is `flock($lock, LOCK_EX) or die ...`, unguarded, and that die
counts toward the 5-error scheduler abort. An `EINTR` retry matching
`Util::lock_file` ships with this.

Revisit if: a capture arrives and an analysis agent still cannot identify a
cause — the gap it names is the next thing to add.

---

## 2026-08-19 — stall reporting is opt-in, `yath test` only, thresholds 600:1200

**Ruling: the stall detector is off by default and enabled per-site by
`--stall-report=STRONG:LOOSE`, defaulting to `600:1200` seconds when switched
on. It runs under `yath test` (and `projects`, which inherits it); `yath run`
and `yath start` paths are unsupported for now.**

Off by default because only a few sites hit this at all, and rarely; the owner
wants it turned on where it matters rather than shipped into every run of a
maintenance line.

The thresholds come from the affected site's measured shape: most tests finish
in under a minute; longer ones self-timeout at 15 minutes; about ten
grandfathered tests run ~1 hour, the longest 1.5 hours; concurrency between
`-j40:6` and `-j80:6`; runs last ~3 hours; the stall appears 1-2 hours in;
Jenkins kills after 30 minutes of silence.

- **Loose tier 1200s.** The binding legitimate case is all slots busy with
  15-minute tests, so the floor is just above 15 minutes. The ten hour-long
  tests cannot fill 40+ slots, so they do not raise it. Firing at stall+20min
  beats the earliest possible Jenkins kill: the stall blocks new launches, not
  running tests, so output continues until the last running test ends and the
  kill lands no earlier than stall+30min.
- **Strong tier 600s.** Above the site's ~5 minute application preload. The
  currently-ready-stage gate (below) covers preload directly, but a site
  preloading *several* stages can have a small stage ready while the big one is
  still loading, and the detector cannot tell — see the stage-attribution limit
  below. 600s is the safeguard. Detection at 10 minutes rather than 2 costs
  nothing against the 30-minute Jenkins floor.

**Two suppressions are part of this ruling.**

1. **Gate on a stage being *currently* ready** — not on a `stage_ready` record
   having ever appeared. The replay tracks `stage_readiness` (`stage_ready`
   sets, `stage_down` clears), so this is exact. It suppresses the initial
   preload window, during which the queue is already populated and nothing has
   started.
2. **Suppress when every pending task is `isolation` while something runs, or
   the pending set is entirely conflict-blocked.** These are the scheduler
   waiting correctly and can last as long as the longest running test — up to
   1.5 hours at this site, which would otherwise force an unusably large loose
   threshold. Category comes straight off the task (`State::task_fields:595-601`)
   with no preloader involvement, so this is reliable. **This is not the
   refuted `_next` blame seam**; it reads the pending set from a replay we
   already perform, rather than instrumenting the dispatch decision.

**Known limit, deliberately not fixed: per-stage suppression.**
`State::task_stage` (`:565-576`) returns `$task->{stage} // 'DEFAULT'` when
there is no preloader, and the observer `State` has none; the scheduler
resolves the real stage via `preloader->task_stage($file, $wants)`. So the
detector's per-task stage attribution can disagree with the scheduler's, and
"all pending work belongs to a stage that is not ready" cannot be computed
honestly. The strong-tier threshold is the safeguard instead.

Reload and runner respawn were considered and set aside: the affected site uses
no persistent runner and does not reload, so a mid-run restage is not a case
this needs to handle.

Implementation shape for the command scoping: one overridable predicate,
default on, overridden off in `App::Yath::Command::run`. `projects.pm`
subclasses `test` and owns its own runner, so it inherits a working detector;
excluding it would cost more code than leaving it.

Revisit if: a site enables this against a persistent runner, uses several
preload stages and finds the strong tier noisy, or reports a stall the loose
tier misses.

---

## 2026-08-19 — the stall detector replays `State`, with a resource list that cannot reach user code

**Ruling: the stall detector builds its own observer
`Test2::Harness::Runner::State` with an explicit in-tree `resources` list and
calls `poll` on it, rather than hand-writing a reducer over
`dispatch.jsonl`.**

```perl
Test2::Harness::Runner::State->new(
    workdir   => $workdir,
    job_count => $job_count,
    resources => [Test2::Harness::Runner::Resource::JobCount->new(...)],
)->poll;
```

The synthetic `resources` list is the point, and it is why this looks odd
enough to be "cleaned up" by someone who does not know. `State::init`
constructs the user's resource classes **only when `resources` is empty**
(`State.pm:72-79`). A non-empty in-tree list means no user class is ever built,
so `_stop_task`'s `$_->release($job_id)` (`State.pm:454`) reaches only
`JobCount`. Passing `job_count` also avoids loading `settings.json`.

Without that, `State::poll` in the main process runs the user's `release()` —
the callback most likely to be wedged, and the reason
`App::Yath::Command::test::stop()` can hang after a stall
(`test.pm:444-449`). **Do not remove the `resources` argument.**

Reading the file by hand was considered and rejected. Pending counts are not
arithmetic over records: `_retry_task` calls `_stop_task` then `_queue_task`
in-process without emitting a `queue_task` record (`State.pm:465-483`), both
return early when the run is halted, and `_halt_run` prunes a run's whole
pending subtree. A hand-written reducer duplicates five `State` handlers in a
maintenance line and goes wrong the first time an action is added.

`App::Yath::Command::status` (`status.pm:34-141`) already performs this replay
and already renders the dump — pending per run, stage table with pids, running
tests with job pids. Note it does *not* pass `resources`, so `yath status`
itself does construct user resource classes; that is pre-existing and out of
scope here.

Costs accepted: `State`'s handlers `die` on inconsistency ("Run stack
mismatch", "Could not find task to start") and were not written for read-only
replay in a foreign process, so the replay is wrapped in `eval`. The detector
must never be able to end a healthy run.

Two related constraints, recorded here because they are easy to violate:

- **Do not read through `$state->dispatch_file`.** `Queue`'s reader is
  stateful, and the main process's `State` keeps its dispatch file untouched so
  `stop()` can replay the whole file on Ctrl-C (`test.pm:444-449`, not wrapped
  in `eval`). Sharing the reader starts that replay mid-file and dies.
- **The trigger still needs a raw `Queue` read** for the last `start_task`
  stamp. `State` exposes no stamps, and `LAST_JOB_ACTIVITY` updates on stop as
  well as start (`State.pm:425`, `457`).

Revisit if: `State` grows a documented read-only observer mode, or the replay's
`die`-on-inconsistency behavior proves too noisy in practice.

---

## 2026-08-19 — the stall detector runs in the main process, not a watcher process

**Ruling: the `yath test` main process polls the scheduler's heartbeat file
from the render loop it already runs. No separate watcher process and no new
internal command.**

Bounding a wedged scheduler needs something outside that process to notice a
heartbeat stop advancing and act on it. A dedicated `App::Yath::Command::watcher`
was proposed and rejected; the detection logic, `/proc` collection, `SIGUSR1`
stack dump, escalation ladder, option, and unit tests are identical either way,
so only the polling site was ever at issue.

Two of the three arguments for a separate process were measured false:

- The scheduler's STDERR is `error.log`, but that is not a dead-end channel.
  `Test2::Harness::Collector::process_runner_output` tails `output.log` and
  `error.log` and forwards both through the event pipeline whenever
  `show_runner_output` is on, which is the default. In the reported incident it
  was silent because nothing wrote to it.
- A watcher process would be the scheduler's *sibling*. Verified on Arch with
  `kernel.yama.ptrace_scope=1`: a sibling reading `/proc/PID/syscall` gets
  `EPERM`. The main process is the scheduler's ancestor and can read it.
  (`/proc/PID/wchan` is `PTRACE_MODE_READ` and works either way.)

The third — a watcher still reports when the main process itself wedges — is
real but covers a failure nobody has reported. The one incident's main process
hung only in `render()`, which the EOF fix addresses directly.

Against that, a watcher costs a new long-lived process in every `yath test` run
of a maintenance line, plus a lifecycle that has no natural end: `stop()` calls
`$ipc->wait(all => 1)` and `killall` never fires on a clean run, so the
watcher's own exit condition becomes the only thing ending a normal run, and
its poll interval is added to every clean shutdown. It is also inherited by
`App::Yath::Command::run` and `::projects` through `start()`, where it would
watch a *shared persistent* scheduler.

The render loop iterates every 0.02s for the life of the run and is made
reliable by the EOF fix that ships alongside this.

Revisit if: evidence shows the main process wedging for a reason the EOF fix
does not cover, or `yath start` needs a watched scheduler. A separate watcher
is the documented escalation; adding it later is additive, while removing a
shipped internal command is not.

---

## 2026-08-17 — `find_yath()` does not look for `./scripts/yath`

**Ruling: `find_yath()` returns `$App::Yath::Script::SCRIPT` when it is set,
then searches `YATH_SCRIPT`, a `blib/script` beside any `blib/lib` or
`blib/arch` in `@INC`, the `Config` paths, a `bin` beside any `lib/perl5` in
`@INC`, and `PATH`. It does not check a `scripts/` directory in the current
directory.**

The check was there because this distribution once shipped the script as
`scripts/yath`. It stopped shipping it in 1.000171, when `b5134b33c` moved the
script logic into `App::Yath::Script::V1` and the script itself into the
App-Yath-Script distribution; no top-level `scripts/` directory has existed
here since. The one tracked path that still ends in `scripts/yath` is the
`t/yath_script/nested` fixture, which `t/yath_script.t` chdirs into: it is an
empty, non-executable file, so neither the removed check nor `find_alt_script`
ever matched it.

The behavior it provided did not go away, it moved up a layer.
`App::Yath::Script::do_begin` calls `find_alt_script()`, which swaps to an
executable `./scripts/yath` when the current directory has one and re-execs it.
That script sets `$ENV{YATH_SCRIPT}` to itself, and `find_yath()` checks
`YATH_SCRIPT` first, so a checkout's own script still wins — through the layer
that owns the behavior.

Keeping the check meant a second, cwd-relative source that outranked the
authoritative one and whose answer changed under a `chdir`. Five integration
tests (`t/integration/includes.t`, `init.t`, `inc_hook.t`, `projects.t`,
`speedtag.t`) call `find_yath()` early with `# cache result before we chdir`.
Those calls still matter: a relative `@INC` entry or `PATH` element keeps the
remaining search cwd-dependent.

Revisit if: something needs `find_yath()` to prefer a checkout's script in a
process that yath did not start — plain `prove` or `perl` in a tree that has
`scripts/yath`. No such caller is known; App-Yath-Script's own suite does not
use `find_yath()`.

---

## 2026-08-15 — `@INC` hooks are not propagated to test jobs

**Ruling: yath filters `@INC` hook refs out of every snapshot it takes and does
not carry them into runner or forked job processes. Forked jobs consequently
lose hooks that exec'd jobs keep; that asymmetry is known and accepted.**

`@INC` may hold coderefs, arrayrefs, or blessed objects (`perlvar "@INC"`).
Carmel injects one via `PERL5OPT=-MCarmel::Setup`. Yath snapshots `@INC` in
`App::Yath::Script::V1::do_begin` (into `settings->harness->orig_inc`) and in
`Test2::Harness::Util::process_includes(include_current => 1)`; both assume
plain path strings. Unfiltered, a blessed hook aborts the run when
`write_settings_to` JSON-encodes the settings, and coderef/arrayref hooks are
stringified by `clean_path` into bogus `/cwd/CODE(0x...)` entries that reach
child `-I` flags. Filtering fixes both, and is all this ruling requires.

Scope of what remains broken, measured with a hook that serves a module
reachable no other way: yath never touches `PERL5OPT` — it manages `PERL5LIB`
only (`Test2::Harness::Runner::Job` `set_env`) — so an exec'd job re-runs
whatever `-M` injection the parent had and recovers its hook unaided.
`yath test --no-fork` therefore already works with the filter alone. Only the
default fork path fails, because the job inherits the runner's `@INC` after
`Test2::Harness::Runner::process` has replaced it.

Propagating hooks was measured and works: preserve refs across the
`@INC = process_includes(...)` assignments in `Test2::Harness::Runner::process`
**and** `App::Yath::Command::runner::build_init_state`. Neither site alone is
enough — `Runner::process` wipes the hook before the fork so `build_init_state`
has nothing left to preserve, and preserving only in `build_init_state` wipes
it again first.

It is rejected for now on one ground, and it is not doubt about the mechanism:
the change puts hooks at the **front** of `@INC` in every runner and job
process, giving them first refusal on every `require` including the harness's
own preloads. Yath has never done that, it affects every user rather than only
hook users, and it is far easier to add later than to withdraw once a workflow
depends on it. Demand is one report (#277), self-closed by the reporter,
against `2.0` where these files no longer exist in this form.

Revisit if: a concrete Carmel or `PAR` workflow needs working forked test jobs
rather than merely a run that does not abort. The two-site change above is the
starting point; it wants its own commit, a functional-hook fixture, and a
decision about where in `@INC` the preserved hooks belong.
