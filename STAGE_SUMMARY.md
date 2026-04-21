# Stage 14 — Daemon-mode commands

Branch: `plan-stage-14-daemon`
Base:   `plan-stage-12-renderers` (tip `0847c7d6d`)
HEAD:   `d4d76ee36`
Commits: 5

Ports the 12 daemon-mode yath commands:

    start  stop   status  ping    kill    ps
    run    spawn  abort   watch   reload  resources

plus the shared `App::Yath2::Daemon` pointer/attach helper and the
new harness IPC request handlers the commands drive.

## Commits

### 1. `b069001e2` Harness2: daemon-client IPC request handlers

Adds five request handlers on the Test2::Harness2 service:

- `get_workdir` -- canonical workdir + logdir per IPC_AND_LOGGERS
  section 11.2.
- `list_processes` -- enumerate harness, run services, resource
  services, running test collectors.
- `list_resources` -- report global and per-run resources with their
  usability/broken-state flags.
- `abort_runs` -- mark every pending job across every queued run
  (or a single run when `run_id` is given) skipped; in-flight tests
  continue normally.
- `reload_preloads` -- forward a reload trigger to every Preload
  resource. Calls the resource's `request_reload` hook when present
  (Stage 9 scaffolding).

Plus a generic `request_handler_ping` on
`Test2::Harness2::Role::Service` so any service consumer can be
probed for liveness without growing its own handler, and matching
thin wrapper methods on `Test2::Harness2::Spawn`: `get_workdir`,
`list_processes`, `list_resources`, `abort_runs`, `reload_preloads`,
`ping`.

### 2. `750f29b0e` App::Yath2::Daemon: pointer I/O + attach helper

Shared module the daemon commands use to discover and connect to a
running daemon. Two responsibilities:

- **Pointer I/O.** `write_pointer` drops a small JSON file at
  `$workdir/daemon.json` plus an optional `.yath-daemon.json` hint
  in the cwd. `remove_pointers` cleans both up (guarding the cwd
  pointer so a second daemon started in the same directory isn't
  accidentally unlinked). `read_pointer` decodes and sanity-checks
  a pointer file.
- **Attach helper.** `discover_pointer` honours the
  IPC_AND_LOGGERS section 11.2 discovery order: explicit
  `--daemon-workdir` / env var / cwd hint. `attach` returns a
  `Test2::Harness2::Spawn` wired to the existing daemon's bus with
  `terminate_on_destroy => 0`, so attached commands can't
  accidentally tear the daemon down when their handle falls out of
  scope.

### 3. `e5fb01f31` yath start / spawn / stop daemon commands

- **`start`** -- classic double-fork daemonizer that spawns
  `Test2::Harness2`, writes the pointer file, and prints a
  human-readable banner (`pid`, `name`, `workdir`) before exiting.
  Accepts `--name=NAME`, `--logdir=DIR`, and `-f` / `--foreground`
  to block until the daemon exits.
- **`spawn`** -- machine-parseable cousin of `start`. Prints a
  single `pid=... workdir=...` line and detaches. Suitable for
  scripted launches.
- **`stop`** -- attaches, sends `finish`, polls for the daemon's
  process to actually exit, then cleans up pointer files. Supports
  `--timeout N` (default 60s).

The **double-fork** is load-bearing: if `Test2::Harness2->spawn`
were called from the command process directly, the daemon child
would inherit the command's stdio, holding any parent-side pipe
(e.g. `yath start | tee` or a test's `open -|`) open forever. The
intermediary closes stdio to `/dev/null` before forking the
harness; the original command process never shares fds with the
eventual daemon.

The registry on `App::Yath2.pm` flips all twelve daemon-mode
entries from stub (value `1`) to real class names in the same
commit, since the daemon class names are stable even while the
commands were being written.

### 4. `923865efe` attached daemon-client commands

Seven short attached commands that each discover the daemon and
dispatch a single IPC request:

- **`status`** -- prints service info, queue, running jobs, resources.
- **`ping`** -- single round-trip to `request_handler_ping` with
  `--count N` / `-n N` for repeats.
- **`kill`** -- signal escalator (`TERM`/`INT` -> `KILL`) keyed off
  the daemon pointer's pid; cleans up pointer files after.
- **`ps`** -- tabular output: PID, type, role, name per process
  from `list_processes`.
- **`resources`** -- per-resource scope + state flags + status
  dump from `list_resources`.
- **`abort`** -- `abort_runs`; supports `--run-id=ID`.
- **`reload`** -- forwards `reload_preloads` (Stage 9+ will fill in
  the concrete reload behaviour; today the command is a clean
  no-op against a daemon without preloads).

All seven accept `--daemon-workdir=PATH`; otherwise they follow the
standard discovery order.

### 5. `d4d76ee36` yath run + yath watch

Artifact-reader-driven commands:

- **`run`** -- attaches to the daemon, discovers tests via
  `App::Yath2::Finder::Simple`, submits them via `queue_test_run`,
  and follows the run to completion via
  `App::Yath2::ArtifactReader` (when any renderer is configured) or
  a simple `run_status` poll. Exits 0 on all-pass, 1 on failure,
  2 on usage/attach error.
- **`watch`** -- same reader layer, but pointed at an existing run.
  Picks the single queued run automatically, or takes an explicit
  `--run-id=ID`. Installs the Default renderer if none were
  configured so there's always visible output.

## Tests shipped

Four new AI-authored integration tests under `t/AI/integration/`:

- `harness2_daemon_requests.t` -- unit-style round trips for each
  of the five new IPC request handlers + `ping`.
- `daemon_start_stop.t` -- end-to-end `start` -> `stop` covering
  pointer-file creation, banner output, and clean daemon exit.
- `daemon_attached_commands.t` -- one daemon, then `status`,
  `ping`, `ps`, `resources`, `abort`, `reload`, `kill` against it.
- `daemon_run.t` -- `start` + `run <pass.t>` + `run <fail.t>` +
  `kill`, asserting the exit-code contract of `yath run`.

Plus `t/AI/unit/App/Yath2/Daemon.t` -- pure-Perl coverage of
`write_pointer`, `read_pointer`, the three `discover_pointer`
paths, and `remove_pointers`'s cwd-pointer guard.

## Old integration tests: deferred to Stage 17

None of the old `old/t/Yath/integration/` integration tests
(`persist.t`, `concurrency.t`, `reload.t`, etc.) are ported in this
stage. They depend on:

- `App::Yath2::Tester` (the driver module the old tests share; not
  yet ported to V2),
- `--ext=tx` and related option surfaces (not yet wired in Stage 6),
- The 1.0 log format (persist.t in particular inspects JSONL
  shape),
- End-to-end `yath run` output formatted by the old Default
  renderer (pattern-matched in the tests).

Each of those would trigger a >50% rewrite to fit the V2
architecture. Per the stage rule (tests requiring >50% rewrite
move to `t/AI/`), I wrote the AI-authored equivalents above
instead. Stage 17 (acceptance-test sweep) can port the old tests
once `App::Yath2::Tester`, `--ext`, and the matching-renderer
output surfaces all land.

## Final test suite

Full suite on this branch's HEAD:

    prove -I lib -I t/lib -r -j16 t/
    Files=56, Tests=517, 60 wallclock secs. Result: PASS

Starting point (Stage 12 tip): 51 files / 467 tests. This stage
adds 5 test files and 50 subtests.

## Daemon discovery -- decision recorded here for Stage 15

Pointer-file semantics used by Stage 14, recorded so Stage 15
(plugins) and the future CLI-options rewrite can keep the shape
consistent or override it deliberately:

- Canonical pointer is at `$workdir/daemon.json`. Workdir is a
  `File::Temp::tempdir('yath2-$$-XXXXXX', TMPDIR => 1)` (per
  IPC_AND_LOGGERS section 11.1).
- Convenience pointer at `./.yath-daemon.json` (in the cwd the
  `start` / `spawn` command ran in). Discovery-only hint;
  authoritative location is the workdir pointer.
- Discovery order: `--daemon-workdir=PATH`, then
  `$ENV{YATH_DAEMON_WORKDIR}`, then `./.yath-daemon.json`.
- Pointer contents:
  `{ pid, workdir, ipcm_info, name, started_at }`. `name` is the
  daemon's IPC bus identity (default `harness`; overridable via
  `yath start --name=NAME`).
- `.yath-daemon.json` added to `.gitignore`.

Open for revision: when `yath init` grows project-level config
(Stage 13's `init` is currently a stub), the project convention
may want to pin the daemon workdir explicitly under the project
rather than rely on a per-cwd pointer. That's a Stage 17/18 call.

## Points of interest for a reviewer

- **Double-fork daemonization.** `start` / `spawn` run
  `_detach_stdio()` in an intermediary child, not in the command
  process itself, so the command's STDOUT/STDERR stay open for
  the banner. This is documented in the commit message and a
  block comment in each file. Pipelines (`yath start | foo`)
  would hang on EOF without this.
- **`request_handler_ping` on Role::Service.** Placed on the role
  so every service consumer gets it by default. `PreloadService`
  already defines its own `request_handler_ping` (Stage 8) which
  takes precedence there; the role-supplied version covers
  `Test2::Harness2` and future services.
- **`reload_preloads` hook is scaffolded.** The harness iterates
  its preload resources and calls `request_reload` via `can()`.
  Until Stage 9's preload reload integration lands, no preload
  resource defines that method and the handler returns an empty
  `reloaded` list. The command still exits cleanly.
- **`abort_runs` semantic.** Pending jobs become `mark_skipped`;
  running jobs finish normally. The daemon stays up. To drop
  in-flight tests as well, follow with `yath kill` (or `yath
  stop` for a clean drain).
- **Stage 8 `run_bus_name` workaround** is unaffected. Nothing
  in Stage 14 touches `RunService`'s bus-name convention.

## Deviations from IPC_AND_LOGGERS / carry-forward notes

None that conflict with the spec.

- `reload_preloads`'s in-harness dispatch to
  `$res->request_reload` is the minimum surface a Stage 9 reload
  integration can grow against. The command contract
  (`{ ok, reloaded }`) matches section 7-adjacent patterns (list
  of affected resources) rather than introducing a new shape.
- `yath watch` currently treats `list_global_artifacts` /
  `list_run_artifacts` the same way `yath run` does -- via
  `ArtifactReader`. If a future watch mode needs to replay from
  an extracted archive (IPC_AND_LOGGERS section 13.2, post-run
  playback), that falls under Stage 17/18.
- `yath ps` leans on `list_processes` as the single source of
  truth. The old `yath ps` read a filesystem-stored state file;
  the new shape consults the live harness and is therefore
  accurate across collector crashes.

## Next stage pointers

- **Stage 15** (plugins): the plugin loader used by `yath test`
  (via `App::Yath2::Plugins`) is reusable; `yath run` doesn't
  currently load plugins. Add a plugin-load step in `yath run`
  when plugins grow their own per-command hooks.
- **Stage 17** (acceptance sweep): the old `persist.t`,
  `kill.t`-equivalent, `concurrency.t`, and `reload.t` tests can
  all reuse Stage 14's fork-and-capture test pattern.
  `App::Yath2::Tester` (if revived) should mirror the
  `yath_run('start')` helper shape used throughout this stage's
  tests.
- **PLAN_RESUME** for a future session: this stage closes out all
  twelve daemon-mode commands; no stubs remain in the registry.
