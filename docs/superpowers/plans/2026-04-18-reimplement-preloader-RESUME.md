# Reimplement Preloader — Resume Notes

**Session dates:** 2026-04-17 → 2026-04-18
**Branch:** `reimplement-preloader` (off `2.0_rewrite` @ `18df142f3`)
**Worktree:** `/home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-preloader`

This document is the single source of truth for picking this work back
up. `PRELOADER_BRIEF.md` is the original design; `PRELOADER_STATUS.md`
is the landed-vs-deferred snapshot; this file is oriented around "what
to do when you next sit down at the keyboard."

---

## Quick orientation (2 min)

    cd /home/exodist/projects/Test2/Test2-Harness/.claude/worktrees/reimplement-preloader
    git log --oneline 2.0_rewrite..HEAD
    # 12 commits, linear, all green when tested individually.

    cat PRELOADER_STATUS.md           # what is done / what was deferred
    cat PRELOADER_BRIEF.md            # original design intent

    prove -Ilib t/unit -r             # expect: 268 tests, clean PASS
    perl -Ilib t/integration/preloader_bootstrap.t     # expect: 10 OK
    perl -Ilib t/integration/preloader_stage_tree.t    # expect: 12 OK
    perl -Ilib t/integration/preloader_launch_test.t   # expect:  8 OK
    perl -Ilib t/integration/harness2_preloaded_test.t # expect:  9 OK

If any of those integration tests hangs in `wait_for_partner` on the
IPC::Manager FIFO -- that's the known flake described below, not a
code regression. Clean `/tmp/PerlIPCManager-*` dirs that belong to
dead pids and retry.

---

## What scope this branch covered

FEATURES_TODO items #2, #3, #4, #5, #6:

| # | Feature | Primary files |
|---|---|---|
| 2 | Test runner (preload-launched path) | `lib/Test2/Harness2/Preloader/Stage.pm`, `lib/Test2/Harness2/Collector/Preloaded.pm` |
| 3 | Preload system (DSL + stage service tree) | `Preload.pm`, `Preload/Stage.pm`, `Preloader.pm`, `Preloader/Stage.pm` |
| 4 | Dependency tracer (+ new importer map) | `DepTracer.pm` |
| 5 | File-watch / reloader (all backends + helpers) | `Reloader.pm`, `Reloader/{Stat,Inotify2,Moose,Exporter}.pm` |
| 6 | Preloaded-test collector | `Collector/Preloaded.pm` |

Harness-side integration (new): `preload` constructor attr,
`launch_test_in_preload` request handler on `Test2::Harness2`, and
matching client method on `Test2::Harness2::Spawn`.

**NOT in scope:** scheduler rewrite, any change to `run_on_all`'s
current fork+exec test-launch path, any Settings plumbing
(App::Yath2's territory), Windows preloading.

---

## Known flake

`$handle->ready` occasionally hangs in `wait_for_partner` (blocking
read on an `ipcm_spawn`-created FIFO) when several integration tests
run back-to-back under `prove -r`. The preloader subprocess itself is
fine -- it boots and stays alive. The hang is on the IPC::Manager
client side.

**Two reproducible observations:**

1. Running any integration test in isolation: always passes.
2. Running them sequentially: the 2nd or 3rd one sometimes hangs.

**Working diagnoses:**

- Stale `/tmp/PerlIPCManager-<pid>-<rand>/` directories left by
  crashed/killed earlier runs can include `preloader.pid` /
  `<uuid>.pid` entries for dead PIDs. IPC::Manager's readiness check
  may be confused by those.
- Possible race between IPC::Manager's FIFO `open(..., O_RDONLY)` in
  the parent and the helper's matching `open(..., O_WRONLY)` -- if
  the helper exits before opening, the parent blocks forever.

**Candidate fixes (pick one, ranked):**

1. **Isolate the bus dir per test.** Have `ipcm_spawn(workdir => ...)`
   (if supported) or set the relevant IPC env var to force the bus
   directory under the test's tempdir. Guarantees no cross-test
   residue.
2. **Ready-with-timeout in `Spawn->handle->ready`.** Wrap the
   blocking `ready` in a `SIGALRM`-bounded loop (e.g. 10 s), and on
   timeout tear down the handle and rebuild it once. Fixes the
   symptom from our side without touching IPC::Manager.
3. **Fix in IPC::Manager.** Have the spawn helper write a single
   byte to a pipe once it has opened its side of the FIFO, and have
   `ipcm_spawn` read that byte before returning. Best fix but
   requires upstream changes.

---

## Remaining follow-up work

None of these block the current branch; they are the natural next
steps.

### A. Wire `Reloader::check_reload` into the stage-service loop

Currently `Reloader::check_reload` returns an arrayref of modules
that could not be reloaded in place, which is meant to signal the
stage "you must restart me." Nothing consumes that signal yet. Fix:

- Add `run_on_interval` to `Test2::Harness2::Preloader::Stage` that
  polls its own `Reloader::ACTIVE` (constructed at `_run_as_service`
  time if `in_place` is enabled).
- On non-empty return, call `$self->terminate(0)`. Parent preloader's
  existing `run_on_pid` restart logic takes over.
- Consider a ping to the base preloader to note the restart as a
  lifecycle event (optional).

### B. End-to-end test for `reload_inplace_check`

DSL supports it, `Reloader::can_reload_file` consults it, but no
integration test exercises a stage that uses
`reload_inplace_check sub { ... }` to steer the reload decision.
Add a 20-line test that writes a module whose reload check returns
false, touches the file, and asserts the reloader reports the module
as "cannot reload."

### C. Moose custom-importer tracking

`Reloader::Moose` handles the metaclass and role consumers, but
packages that used `Moose::Exporter`-backed sugar (`has`, `with`,
`extends`) are not in the DepTracer import map because Moose's
import bypasses `Exporter::import`. Two options:

1. Accept the limitation and document it explicitly in
   `Reloader::Moose` POD.
2. Add a small helper that monkey-patches `Moose::Exporter::init_meta`
   (or an equivalent stable hook) to call
   `Test2::Harness2::DepTracer->ACTIVE->record_import(...)`. Ensures
   callers get reload notifications.

Option 1 is the pragmatic choice; option 2 is strictly better if a
user reports reload problems with Moose sugar.

### D. `HARNESS-CHURN-START` at stage level

`Reloader` supports churn-block reload (it parses and re-evals the
marked sections). There's no stage-level trigger yet -- the user's
DSL cannot say "use churn mode for this stage." Add either a DSL
knob (`churn_only => 1`) or a per-module watch callback that wraps
`_reload_churn`. Low priority; the existing generic path covers most
use cases.

### E. Harder test around `Long::Jump` payload shape

`Test2::Harness2::Preloader::_post_jump_launch` assumes the raw
arrayref Long::Jump returns has exactly one hashref inside. Today
the only caller is `Collector::Preloaded::launch`, which passes a
single hashref -- so the assumption holds. Add either:

- An assertion: `die "unexpected longjump payload shape" if @$raw != 1`.
- Or document the contract with a pointer to
  `Collector::Preloaded::launch` as the canonical jumper.

---

## Design decisions worth remembering (from the session)

### Setjump lives in BEGIN, not runtime

Early attempt put `setjump` at the top-level runtime of the exec'd
`-e` script. That was wrong: by the time the post-jump handler ran,
Perl was in runtime and `goto::file` (a source filter) no longer
had anything to filter. Moving the whole landing into BEGIN keeps
the jump inside the compile phase so `goto::file->import` swaps the
test source in before BEGIN unwinds.

### `Long::Jump::setjump(label, sub { ... })`

Long::Jump's API requires a sub to be protected, not a bare call.
The service loop runs inside that sub; a `longjump` from any
descendant process returns control to the line *after* the
setjump call, with `$payload` (an arrayref of the jumper's args)
as its value.

### Stages don't exec, the base preloader does

The base preloader `exec`s to start with an empty stack. Stage
services are plain forks of the base -- they inherit the loaded
modules AND the jump context. When a test longjumps, it unwinds
to the landing in the BASE preloader's frame (inherited via fork).

### Parent-restarts-child via `run_on_pid`

Both the base preloader (watching stage pids) and each stage
service (watching nested stage pids) keep a `child_stage_pids` or
`started_stage_pids` map and re-spawn on unexpected exit. Kept
entirely within `IPC::Manager::Role::Service` conventions; no
separate supervisor.

### Exporter reload via DepTracer's importer map

`Reloader::Exporter->reload` walks the DepTracer's recorded
`(source_pkg, target_pkg, \@args)` tuples and re-runs `->import`
from each target, appending `; 1;` so a falsey import return is
not mistaken for a failure.

---

## Commit list

    a54943cde Preload DSL: port stage builder and stage value object
    bb1ee54e6 DepTracer: port with new importer-tracking for exporter reload
    0f4a133fa Reloader: port base + Stat + Inotify2 backends from old/
    20ad46fdc Reloader: add Moose and Exporter reload helpers
    e9703b58f Preloader: base service tree with exec+BEGIN+Long::Jump
    92059a578 Preloader: route launch_test through a collector + goto::file
    cd829dbb6 Harness2: accept preload config and launch tests via the preloader
    3f8af7bb7 docs: status file for the reimplement-preloader branch
    a694f5c6c POD: replace L</item> with C<> for unresolvable internal links
    01cdaabbd tests: give the bootstrap syntax-check a real config file
    39cc2a0b9 tests: drop the perl -c compile check for the bootstrap script
    fbda326e2 docs: note the prove-r ipcm_spawn flake and link the status file

Each commit is self-contained; any individual one can be reverted
without breaking the rest of the suite.

---

## Resume checklist

When you sit back down:

- [ ] Pull: `git fetch` and compare `2.0_rewrite` to the base this branch was cut from (`18df142f3`); rebase if the base has moved.
- [ ] Run the unit suite: `prove -Ilib t/unit -r`.
- [ ] Spot-check the four integration tests individually.
- [ ] Read the **Known flake** section above and decide whether to take it on now (candidate fix #2 is a one-file change) or defer.
- [ ] Pick one of items A–E under **Remaining follow-up work**, or move on to the scheduler rewrite that was the deliberate-deferred headline of this branch.

Scheduler rewrite is the natural next branch. Its hook into this work is:

- On each job about to launch, decide whether to go through the
  existing `Collector->spawn(launch => [...])` path (current behavior)
  or through the new `launch_test_in_preload` path.
- For the new path it needs: stage name for the job (from TestFile
  metadata or a DSL-claimed file-stage plugin), run_id, job_id, and
  a logger spec it can serialize to the stage service.

Both paths co-exist happily on this branch; the scheduler just needs
to choose per-job.
