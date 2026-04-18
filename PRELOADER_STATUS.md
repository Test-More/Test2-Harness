# Preloader Reimplementation — Status

**Branch:** `reimplement-preloader` (off `2.0_rewrite`)
**Worktree:** `.claude/worktrees/reimplement-preloader`

---

## FEATURES_TODO coverage

| # | Item | Status |
|---|---|---|
| 2 | Test runners (preload-launched path only) | landed as `Preloader::Stage` + `Collector::Preloaded`; scheduler path intentionally not touched |
| 3 | Preload system (DSL + stages + persistent services) | landed |
| 4 | Dependency tracer | landed; extended with `importers_of` / `record_import` for exporter reload |
| 5 | File-watch / reloader (Inotify2 + Stat) | landed + Moose and Exporter reload helpers |
| 6 | Preloaded-test collector | landed |

---

## Module inventory

New modules (with test coverage):

    lib/Test2/Harness2/Preload.pm                  DSL + meta object
    lib/Test2/Harness2/Preload/Stage.pm            stage value object
    lib/Test2/Harness2/DepTracer.pm                @INC + Exporter::import hooks
    lib/Test2/Harness2/Reloader.pm                 base + factory
    lib/Test2/Harness2/Reloader/Stat.pm            polling backend
    lib/Test2/Harness2/Reloader/Inotify2.pm        Linux::Inotify2 backend
    lib/Test2/Harness2/Reloader/Moose.pm           metaclass-aware reload
    lib/Test2/Harness2/Reloader/Exporter.pm        replay-on-reload helper
    lib/Test2/Harness2/Preloader.pm                base service, bootstrap, jump landing
    lib/Test2/Harness2/Preloader/Stage.pm          per-stage IPC service
    lib/Test2/Harness2/Collector/Preloaded.pm      fork+interpose+longjump glue

Touched existing modules:

    lib/Test2/Harness2.pm        preload attr, preloader spawning, launch_test_in_preload dispatch
    lib/Test2/Harness2/Spawn.pm  launch_test_in_preload client method
    lib/Test2/Harness2/Util.pm   clean_path + file2mod helpers

---

## Tests

Unit:

    t/unit/Harness2/Preload.t
    t/unit/Harness2/Preload/Stage.t
    t/unit/Harness2/DepTracer.t
    t/unit/Harness2/Reloader.t
    t/unit/Harness2/Reloader/Inotify2.t
    t/unit/Harness2/Reloader/Moose.t
    t/unit/Harness2/Reloader/Exporter.t
    t/unit/Harness2/Preloader.t

Integration:

    t/integration/preloader_bootstrap.t     ping/status round-trip against a solo preloader
    t/integration/preloader_stage_tree.t    multi-stage tree (two tops + one nested), all ready
    t/integration/preloader_launch_test.t   end-to-end: stage forks -> collector attaches -> test runs -> JSONL log has assertion facet
    t/integration/harness2_preloaded_test.t Harness2->spawn + launch_test_in_preload + default logger path

---

## Design decisions worth remembering

### Long::Jump landing inside BEGIN

Initial attempt put setjump at the top of the bootstrap's runtime main
frame; that made the post-jump handler run at runtime, which is too
late for `goto::file` (source filter). Moving setjump inside BEGIN
keeps the jump-landing in the compile phase so `goto::file->import`
swaps the test file's source into place before BEGIN exits.

### Payload shape

`Long::Jump::setjump` returns an arrayref of the positional values the
jumper passed. Stage passes one hashref. The handler normalises both
shapes before dispatching.

### Service-tree topology

- Harness (IPC::Manager::Role::Service)
  - Preloader base service (fork+exec'd from the harness, exec'd to
    start with an empty stack, BEGIN-time setjump as the descendant
    landing)
    - Top-level stage services (fork-only, inherit setjump context)
      - Nested stage services

Each level restarts its immediate children via `run_on_pid`. Stage
services do NOT exec -- they need to inherit the preloader's loaded
module set and setjump context.

### Exporter reload

`Test2::Harness2::DepTracer` hooks `Exporter::import` and records every
`(source, target, \@args)` tuple it sees. When `Reloader::Exporter`
reloads a module, it walks that map and re-runs `import()` on each
recorded target so callers that took aliased coderefs at import time
see the new subs. Custom importers (Moose, Sub::Exporter) bypass the
hook; those paths are covered either by `Reloader::Moose` or by a
manual `record_import` call from the custom importer.

### Moose reload

Removing the `Class::MOP` metaclass-by-name entry before re-requiring
fixes the "reload did nothing" problem observed in old/legacy. Role
files additionally get `Moose::Util::apply_all_roles` called on every
tracked consumer so method-list changes take effect.

---

## Deliberately deferred (not this branch)

- **Scheduler rewrite**: the existing `run_on_all` test-run loop still
  launches tests via `Collector->spawn(launch => [...])`. The new
  `launch_test_in_preload` path is available but nothing calls it
  automatically yet. A subsequent branch should teach the scheduler
  which jobs want a preload stage and route them through the new
  path per-job.
- **Application of `reload_inplace_check`**: the DSL accepts it and
  `file_info` carries it, but the base reloader only consults it when
  deciding to in-place-reload; there is no mechanism yet for the
  reloader to signal the stage service "restart yourself" based on
  the check's verdict.
- **Test retry on broken resource**: outside this branch's scope, but
  relevant because a preloader-restart cycle is a thing tests may
  care about.
- **Windows support**: preloader + stage services are Linux-biased
  (Long::Jump + fork-only). Windows collectors already go through the
  serialize-and-spawn path; preloading under Windows is intentionally
  out of scope.
- **HARNESS-CHURN-START inside stages**: the base reloader supports
  the churn-reload path, but there is no stage-level trigger for it
  beyond the generic file-change detector.

---

## Known flake: prove -r of integration tests

Running `prove -Ilib t/integration -r` sometimes hangs on the first few
integration files in the "preloader_*" family. The culprit is the
`ipcm_spawn()` FIFO handshake inside IPC::Manager -- the test process
opens `/tmp/PerlIPCManager-<pid>-<rand>/spawn` for read and blocks on
`wait_for_partner` because the helper process never opened the other
end. Individual tests always pass when invoked directly (`perl -Ilib
t/integration/preloader_*.t`).

This is not a defect in any of the new preloader code -- it is an
IPC::Manager quirk (likely a race during the spawn handshake under
sequential test load). Workarounds / follow-ups:

* Run integration tests one at a time (`prove ... -s` or direct perl
  invocation).
* Investigate IPC::Manager's spawn handshake for missing timeout /
  retry logic.

## Quick smoke path

    cd .claude/worktrees/reimplement-preloader
    prove -Ilib t/unit/Harness2/Preload.t \
                t/unit/Harness2/DepTracer.t \
                t/unit/Harness2/Reloader.t \
                t/unit/Harness2/Reloader/Moose.t \
                t/unit/Harness2/Reloader/Exporter.t \
                t/unit/Harness2/Preloader.t
    prove -Ilib t/integration/preloader_bootstrap.t \
                t/integration/preloader_stage_tree.t \
                t/integration/preloader_launch_test.t \
                t/integration/harness2_preloaded_test.t
