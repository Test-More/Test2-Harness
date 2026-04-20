# Stage 3 — Port the utility classes listed in "These need to be ported in"

## Branch

- `plan-stage-03-utility-classes`
- Base: `plan-stage-02-ai-tests`

## What landed

Four commits, each one mechanical-ish but separately reviewable:

1. **`Util: add file-IO helpers (open_file/read_file/write_file/lock_file/...)`**
   — port the file-IO helpers from `old/Test2::Harness2::Util` into the
   current focused `Util.pm`. New exports: `open_file`, `maybe_open_file`,
   `close_file`, `read_file`, `maybe_read_file`, `write_file`, `lock_file`,
   `unlock_file`. `write_file_atomic` is rewritten to route its pending
   write through `write_file` (same behaviour; simpler code).
   `open_file` keeps the old transparent `.gz` / `.bz2` decompression on
   read.

2. **`Util::File: port the base file class`** — port
   `Test2::Harness2::Util::File` from `old/`, swapping
   `Test2::Harness2::Util::HashBase` (in the "do not bring back" list)
   for `Object::HashBase` directly. Public API identical:
     - Attributes: `name`, `done`, `skip_bad_decode`.
     - Methods: `read`, `maybe_read`, `write`, `rewrite`, `read_line`,
       `reset`, `open_file`, `exists`, `fh`, `decode`, `encode`.
   While porting I reformatted `read_line`'s eval into the project's
   three-step form (`my $ok = eval { ... }; my $err = $@; ...`) per
   `CLAUDE.md`.

3. **`Util::File::{Stream,Value,JSON,JSONL}: port the File subclasses`**
   — port all four subclasses with the same `Util::HashBase` →
   `Object::HashBase` swap. `Value.pm` now calls `SUPER::init()` before
   setting `DONE`; the old version skipped `SUPER::init()`, which also
   skipped the `'name' is a required attribute` check and the
   `_INIT_FH` handoff. That alignment is a deliberate behavioural
   change called out in the commit message — see "Points of interest"
   below.

4. **`Util::JSON: merge stream_json_l* and decode_json_no_null from old`**
   — merge the `old/` `Util::JSON` helpers that were missing from the
   current thin `Cpanel::JSON::XS` wrapper:
     - `decode_json_no_null` — replacing the old's
       `print-and-exit(1)` error path with a normal `die`.
     - `stream_json_l`, `stream_json_l_file`, `stream_json_l_url` —
       iterate a local file or http(s) URL of JSON / JSONL records.
   Also port the `decode_json_no_null` subtest from
   `old/t/Harness/Util/JSON.t` to `t/unit/Util/JSON_no_null.t`.
   Tests copied from `old/t/` count as human-authored so it sits
   under `t/unit/`, not `t/AI/`.

## Tests

- `prove -I lib -I t/lib -r t` — 32 files, 355 tests, all pass (72s
  wall-clock). Previously-noisy `Collector IPC send failed` warnings
  on STDERR are pre-existing and unrelated to this stage.

## Points of interest / decisions you may want to revisit

1. **`Util::File::Value` now calls `SUPER::init()`.** The old version
   skipped it. This is likely a latent bug in `old/` (no `name`
   check, `_INIT_FH` ignored), but fixing it is a behavioural change.
   If you want to preserve the old behaviour verbatim, drop the
   `$self->SUPER::init();` call in
   `lib/Test2/Harness2/Util/File/Value.pm`. No test in this tree
   exercises the constructor error path for Value, so nothing breaks
   either way today.

2. **`open_file` compression support is a no-op for writes.** Old
   behaviour (write modes ignore the `.gz` / `.bz2` extension) is
   preserved. When the log archive stage lands (Stage 11), we may want
   to add write-side compression so `Util::File::Value` and friends
   can transparently write a `.log.gz`. Flagging this as a
   forward-looking decision rather than something to do now.

3. **`Util.pm` now carries 8 new exports.** The PLAN classes
   `Test2::Harness2::Util` as "copy functionality as needed". I ported
   exactly the surface the Util::File family needs. The other old
   helpers (`find_libraries`, `file2mod`, `fqmod`, `chmod_tmp`,
   `hash_purge`, `is_same_file`, `render_status_data`, `clean_path`,
   `find_in_updir`, `looks_like_uuid`) are **not** ported in this
   stage. They will come in later stages that need them (plugin
   discovery, config-file conversion, the render layer, etc.).

4. **`decode_json_no_null`'s error path changed.** `old/` hard-exited
   the whole process on failure (`exit(1)`) after printing the two
   versions of the JSON. The port raises a `die`, which is what every
   other decode helper in this file does. If you specifically wanted
   the "crash-loudly" behaviour for this one function, I can put a
   `confess` wrapper back. I judged the normal `die` more consistent
   with the surrounding code.

5. **`stream_json_l_url` is untested.** The old code wasn't tested
   either, and bringing in a live HTTP test is out of scope. It's
   paper-ported only; the first time it sees real usage (log-server
   fetches, much later in the plan) it may need adjustment.

6. **No AI-generated unit tests were added for File.pm / Stream.pm /
   JSON.pm / JSONL.pm / Value.pm** in this stage. The smoke tests I
   ran inline (see commit messages) exercise the happy paths. If you
   want explicit `t/AI/unit/Util/File*.t` coverage, that's an easy
   follow-on; I intentionally skipped it to keep this stage focused.

7. **POD is present on every new module.** I followed the existing
   house style (name, description, synopsis, attributes, methods,
   source/maintainers/authors/copyright). `old/` had "POD NEEDS AUDIT"
   markers at the end of many files; I did not port those markers —
   the POD in these ports has been audited (by me, just now) against
   the code.

## Note for Stages 8-9 (preloader)

Independent of this stage, the `reimplement-preloader` worktree on
disk at `.claude/worktrees/reimplement-preloader/` already has the
preloader work committed (DSL port, DepTracer, Reloader base + Stat +
Inotify2, Moose/Exporter reload helpers, exec+BEGIN+Long::Jump
bootstrap, collector routing, harness acceptance). When Stages 8-9
come around, those commits should be cherry-picked / rebased onto
the stage chain rather than implemented from scratch.

## Post-refactor rebase (2026-04-20)

Rebased onto the updated `reimplement-resource-classes` base
(`0c46805cf`), which now carries the IPC_AND_LOGGERS-alignment
refactor (message-kind renames `job_complete` → `test_job_completed`
and `loggers_ready` → `collector_artifacts`, direct artifact
routing to `ipc_run`/`ipc_harness`, collector bus-name convention
`collector:<service>[:<run_id>]`, configurable per-run
`launch_job_timeout` defaulting to 5s).

Stage-03's own commits (utility classes port) replayed cleanly —
no conflicts during cascade. (Live branch tip recorded in
`PLAN_RESUME.md` on the primary repo, not pinned here.) Full
`prove -j16 -I lib -I t/lib -r t` run green downstream.
