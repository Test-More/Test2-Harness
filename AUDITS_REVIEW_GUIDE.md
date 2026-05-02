# AUDITS Review Guide — `full_audit` branch

28 commits over `2.0` (style commit `e5cdb3753`). Branch is local-only,
never pushed. `git log --oneline fff992a6d..full_audit` shows the chain.

Read commits **bottom-up** — the order matches dependency / merge order.
Each section below mirrors a commit, with what changed, why it
matters, and the most useful angle to review from. Diff sizes are
aggregate (insertions+deletions) so you can budget time.

Summary: 28 commits, ~13.6k loc churn (+ 9.4k / − 4.6k). The big
ones are the structural pieces: LogArchive reshape (1.6k), zstd-dict
removal (1.4k cleanup, mostly deletions), Run/State split (1.1k),
collector cleanup (1.6k), TestFile split (1k).

---

## Foundational utility (Phase 1)

### `5d4cdf613 util: add Test2::Harness2::Util::FileMonitor`

+490 / −0. New module + tests. Pure addition, no consumers yet.

What to look for:
- Linux::Inotify2 vs hi-res-stat fallback paths.
- `changed` / `peek_changed` / `await_change` semantics, especially
  the "first call always reports change" contract and the delegate
  return.
- `tinysleep` is the mandatory polling primitive (see STYLE_GUIDE).

### `59031f1f3 util/file: strip change-detection; consumers use FileMonitor`

+472 / −643 (net deletion). Util/File classes lose their internal
change tracking; callers wrap them in FileMonitor.

What to look for:
- File / File::JSON / File::JSONL / File::Value / File::Stream all
  shrink — the change-detection state is gone.
- Consumers (Collector loggers, RunService) now construct a
  FileMonitor wrapping the file object as delegate.
- Test renames: `File_changed.t` / `JSON_stream.t` removed; the
  semantics moved into `FileMonitor.t`.

### `93b063e33 util/file: drop Stream + JSONL::Zstd; rework JSONL as whole-file`

+139 / −310. Two whole modules deleted; JSONL gets a new shape.

What to look for:
- `Util::File::Stream` and `Util::File::JSONL::Zstd` gone — their
  jobs collapse into JSONL + zstd-Reader.
- New `Util::JSONL::Reader.pm` is the only "stream JSONL records"
  class now.
- `Util::File::JSONL` reparents onto `Util::File::JSON` and assumes
  whole-file semantics; `read_line` decodes one line.

### `9d7dfb65c zstd: drop the shipped dictionary and explicit level=3 callsites`

+171 / −1246 (mostly deletion). Big sweep. Squashed with the
Phase 1.5 `xt/author/zstd-dict.t` cleanup.

What to look for:
- `share/other/zstd.dict` (32 KB binary) gone.
- `author/train_zstd_dict` gone.
- `App/Yath2/Options/LogArchive.pm` (no production consumer) gone.
- `IPC_DEFAULT_ZSTD_LEVEL` retired; per-instance bless removed; a
  bunch of "if dict, use_dict" branches collapse.
- The dictionary benchmark threshold was 35% improvement; measured
  18.34% → not worth the complexity.

---

## TestFile refactor (Phase 3)

### `b1b413bde TestFile: Role becomes pure contract (Phase 3.1)`

+179 / −52 in one file. `Role::TestFile` is purely a contract now:
no `$self->scan` from `check_*` lookups, no implicit I/O.

What to look for:
- Per-attribute defaults centralize on `defaults()`; each accessor
  reads from there so a consumer can override every default in one
  place.
- POD note on each role accessor: HashBase consumers shadow it.
- Static `%FEATURE_DEFAULTS` and `%RANK` lift out of the role.
- New `meta_get($key)` helper (because `meta($key)` collides with
  HashBase's slot reader, which silently ignores method args).

### `1f9de73d2 TestFile: split static value object from yath-side scanner (Phase 3.2 + 3.3)`

+768 / −249. Big split.

What to look for:
- `Test2::Harness2::TestFile` becomes a static value object: no
  scanning, no I/O, takes pre-built data via constructor.
- New `App::Yath2::TestFile` (yath-side) does shebang +
  `HARNESS-*` header reads, applies CLI overrides, produces the
  queue payload.
- HashBase slot prefixes:
  - `+` (constant only) for slots whose accessor is overridden.
  - `<` (slot + reader) for plain slots.

### `ca1b7e632 TestFile: migrate producers and tests to App::Yath2::TestFile (Phase 3.4)`

+107 / −82 across 14 files. Mechanical wiring.

What to look for:
- Every producer that was scanning now calls `App::Yath2::TestFile`.
- "THIS IS A GENERATED YATH RUNNER TEST" short-circuit moves into
  the scanner — harness no longer sees those files.

---

## Run/State split + log layout (Phase 4)

### `6717e1374 Run/State split: spec stays immutable, runtime state moves to Run::State`

+842 / −261. Per-field decision-heavy.

What to look for:
- `Test2::Harness2::Run` is now an immutable spec.
- New `Test2::Harness2::Run::State` carries mutable runtime state.
- Per-field placement: `created_at` is the only field intentionally
  duplicated (canonical = Spec, State copy keeps state.json
  self-readable). `start_time`, `finish_time`, `completed`,
  `exit_summary`, `resources_started`, `resources_torn_down` →
  State. `loggers`, `extend_loggers`, `test_loggers`,
  `extend_test_loggers`, `launch_job_timeout`, `resources` → Spec.
- Identity split (Q4a option b): `requested_harness_uuid` (Spec,
  nullable) vs `running_harness_uuid` / `collector_uuid` /
  `bus_address` / `running_session_uuid` (State).

### `fb4eff7e0 log layout: split runs/<id> into spec/state/events + reject pre-Phase-4`

+256 / −42. Combined the two layout steps.

What to look for:
- New on-disk shape: `runs/<run>/spec.json` (frozen) +
  `runs/<run>/state.json` (mutable) + `runs/<run>/events.jsonl`.
- `LogArchive::_assert_run_layout_phase4` croaks on pre-Phase-4
  layouts with an explicit message — no back-compat.
- Test fixtures re-baked: archive replay `.yath` files updated.

---

## LogArchive cleanup (Phase 4.5)

### `bbb638198 log layout: introduce LogLayout module + per-try test basename + logger role file_ext/update_type`

+567 / −62 across 18 files. Foundational for the next two commits.

What to look for:
- New `Test2::Harness2::LogLayout` — single canonical source of
  relative-path templates inside the yath log tree.
- Per-try test log layout: `runs/<run>/tests/<job>/<try>.<ext>`
  (per-job dir, per-try file). Old layout
  `runs/<run>/tests/<job>.<ext>` clobbered prior tries on retry; the
  new layout preserves history.
- Logger role contract gains `file_ext` (`'json'`, `'jsonl'`) +
  `update_type` (`'replace'` / `'append'`) required methods.
  LogArchive uses these to map physical paths to logger classes.

### `d21734764 LogArchive: add Artifact handle + ChangeWatch role`

+722 / −0 in 3 new files. Pure addition; no callers yet.

What to look for:
- `App::Yath2::LogArchive::Role::ChangeWatch` mirrors FileMonitor's
  surface (`changed` / `peek_changed` / `await_change` /
  `delegate`).
- `App::Yath2::LogArchive::Artifact`:
  - Live (Directory backend) wraps a FileMonitor.
  - Static (TarZIdx, extracted Directory) short-circuits to
    first-truthy / rest-zero.
  - `->data` for single-object artifacts (`json`); `->next` for
    multi-object (`jsonl`).

### `3dafa4f2a LogArchive: factory open() + Directory/TarZIdx HashBase + iter_artifacts API`

+1240 / −326 across 18 files. Structural reshape; the biggest commit
in the chain.

What to look for:
- `App::Yath2::LogArchive` no longer overrides Object::HashBase's
  `new`. Drops the `($class eq __PACKAGE__)` factory-in-constructor
  branch entirely — that branch caused infinite recursion when a
  subclass tried to call its own `->new`.
- New factory: `LogArchive->open(file|dir|path => ...)`.
  `App::Yath2::LogArchive->new(...)` is gone; backends use HashBase
  directly.
- `artifacts($run_id?, $job_id?)` returns `{append, replace}` keyed
  by logical name; per-job keyed by try number.
- `iter_artifacts($run_id?, $job_id?)` flat (rel => class) helper
  for streamer-style consumers (Streamer::Static).
- `manifest_drift($run_id?)` exposes any drift between manifest +
  on-disk files.
- Removed `App::Yath2::LogArchive::Role::{Source,Writer}` stubs;
  the dual-backend split lives on the concrete subclasses.
- Migrated every `LogArchive->new(path => ...)` callsite to
  `->open(...)`: extract / failed / replay / speedtag / times
  commands plus `Streamer::Static` and tests.

---

## Collector + auditor cleanup (Phase 5)

### `ce3009bd2 collector: split into Collector::Util + Collector::Win32; drop trivial subclasses`

+980 / −602 across 13 files. Three coordinated steps in one commit
(5.1.1 + 5.1.2 + 5.1.3).

What to look for:
- `Collector::Service::Run` and `::Service::Harness` deleted; both
  were thin subclasses doing nothing more than flagging
  `is_run` / `is_harness_collector`. Replaced with kwargs on the
  base.
- New `Collector::Win32` (~340 lines): all Win32-only spawn /
  launch / kill / quote / DESTROY paths. Base delegates when
  `$^O eq 'MSWin32'`.
- New `Collector::Util` with the pure helpers Collector.pm grew:
  `spec_class`, `validate_spec`, `make_warn_handler`, `kill_child`,
  `win32_quote_arg`, `Util::FileLineReader`.
- `Collector.pm` itself: 1947 → 1621 lines (target ~1000 NOT
  reached; Step 5.2 cross-cutting roles are deferred).

### `3b3dcbcb8 auditor: split oversized _audit and _subtest_process methods (5.4)`

+248 / −160 in one file. Pure refactor, no behavior change.

What to look for:
- `_audit` 132 → 45 lines.
- `_subtest_process` 119 → 34 lines.
- Six new helpers: `_audit_subtest_start`,
  `_audit_orphan_subtest_end_recovery`,
  `_audit_close_deeper_subtests`, `_subtest_process_parent`,
  `_subtest_tally_facets`, `_subtest_process_exit`.

### `488718baf RunService: tidy general-message dispatch + spawn return (5.5)`

+21 / −32. Hygiene rename pass.

What to look for:
- `_handle_test_job_*` → `_handle_gen_msg_test_job_*`.
- `_handle_collector_artifacts` → `_handle_gen_msg_collector_artifacts`.
- Dynamic `require` of File::Spec replaced with top-of-file `use`
  (matches `request_handler_launch_job` from Phase 4).

---

## Hash seed (Phase 7)

### `88871a56c hash-seed: --set-hash-seed option + per-run env injection (Phase 7.1)`

+116 / −11 across 6 files.

What to look for:
- `--set-hash-seed` added to existing `App::Yath2::Options::Tests`.
  Absent → leave `PERL_HASH_SEED` untouched. No value → today's
  date as `YYYYMMDD` (matches App-Yath-Script shim format).
  Explicit value → verbatim.
- Spawn-env injection in `Test2::Harness2._launch_job` (around
  line 1862, after `T2_HARNESS_INCLUDES`).

### `a4a4a29c6 hash-seed: harness-level slot + reject-on-mismatch + AI_DOC`

+341 / −20. Combines Phase 7.2 + Phase 7's AI_DOC.

What to look for:
- New `hash_seed` slot on `Test2::Harness2`.
- `request_handler_queue_test_run` rejects on explicit-vs-explicit
  mismatch with a clear error (preload reuse safety).
- Status-asymmetry path (one side set, other unset) is accepted
  with a TODO for `Resource::Preload`.
- `yath start` and `yath run` are PR #390 stubs that `die`; both
  have TODO comments at the top describing the wire-up plan.
- AI_DOC `AI_DOCS/2026-04-28-phase-7-hash-seed.md` covers the full
  design + the cross-distribution coordination plan with
  App-Yath-Script.

---

## Move artifacts out of CWD (Phase 8)

### `3f763c056 Phase 8.1: stop dropping artifacts in cwd by default`

+64 / −21 across 6 files. Default-destination flip.

What to look for:
- `yath test` archive path: `<cwd>/<stamp>.yath` →
  `<sys_tmp>/yath-<stamp>-<uuid>.yath`. Survives workdir cleanup.
- `yath archive` default path: `<cwd>/<stamp>.yath` →
  `<sys_tmp>/yath-<stamp>-<pid>.yath`.
- IPC info-file `dir_order` default:
  `[user_rc, project_rc, cwd, tempdir]` →
  `[tempdir, user_rc, project_rc]`. cwd dropped entirely.

### `23589743f Phase 8.2: --local-artifact-links flag (symlinks into cwd)`

+309 / −14 across 8 files.

What to look for:
- New `--local-artifact-links` Bool option in
  `App::Yath2::Options::Workspace`.
- Symlink-only (Q8a option a). On failure, single warn message +
  skip remaining links.
- cwd-side names: `yath-latest-archive.yath`, `yath-latest-ipc`,
  `yath-latest-logs` (only with `--keep-dirs`),
  `yath-latest-workdir` (only with `--keep-dirs`).

### `d8fa68c27 Phase 8.3: per-cwd index for the latest run (Util::CwdIndex)`

+701 / −11 across 14 files.

What to look for:
- New `Test2::Harness2::Util::CwdIndex`.
  - Storage: `$XDG_RUNTIME_DIR/yath/cwd-index.json` if available,
    else `<sys_tmp>/yath-cwd-index-$USER.json`. Mode 0600.
  - Schema: `{ sha1_hex(abs_cwd) => { latest_archive,
    latest_workdir, last_run_uuid, updated_at } }`.
  - `flock(LOCK_EX)` on a sibling `.lock` file during
    read-modify-write; rewrite via `write_file_atomic_mode($path,
    0600, ...)`.
- Producer: `App::Yath2::Command::test` calls `gc()` then
  `record(getcwd, ...)` after archive write, eval-wrapped so a
  record failure cannot fail the run.
- Consumers: `replay`, `extract`, `failed`, `times`, `speedtag`
  fall back to `lookup(getcwd)` when no positional LOG given.
- Test isolation: `archive_extract.t` sets `$ENV{XDG_RUNTIME_DIR}`
  to a tempdir at file scope so a stale entry from a prior real
  yath run can't poison the no-arg-extract subtest.

---

## Synthetic rename (Phase 2)

### `a52dcace8 naming: rename resource-side 'synthetic' -> 'unavailable_action'`

+119 / −79 across 7 files.

What to look for:
- `_launch_synthetic_job` → `_launch_unavailable_action_job` on
  `Test2::Harness2`.
- Auditor-side "synthetic" stays — it's a different concept (event
  fabrication, see ARCHITECTURE §20).
- Watchdog completion-message synthesis
  (`PENDING_SYNTH_COMPLETIONS`) intentionally kept under
  "synthetic" — fabricated message, not launched job.

---

## Resource model overhaul (Phase 6)

### `067f49643 Phase 6.1: drop is_job_limiter from harness mandate`

+57 / −53 across 7 files. Tight, mostly contract change.

What to look for:
- `is_job_limiter` removed from `Role::Resource`,
  `Resource::JobCount`, `Resource::SharedJobs`. Harness no longer
  asserts a limiter exists.
- `Test2::Harness2.pm` job-launch grep predicate:
  `needed && !is_permanent_broken` (replaces the
  `is_job_limiter && needed` filter).
- Unavailable-action launch path drops the `is_job_limiter` filter
  too — consults every resource that reports
  `needed(job => $job)` and is not permanent_broken.

### `64e2cdcd9 Phase 6.2: yath test becomes the JobCount limiter source`

+112 / −16 across 2 files.

What to look for:
- `App::Yath2::Options::Resource::jobs_post_process` injects
  JobCount only when neither `--resource` nor `--no-resource` was
  supplied.
- New `_build_resources` helper in `App::Yath2::Command::test`:
  consumes `$resource->classes` (when settings expose a real
  resource group), constructs a JobCount with slots/max_per_job
  from `-j N:M` for the no-args case, falls back to a direct
  JobCount instance for unit-test mock settings.

### `c41fd8a4b Phase 6.3: add --utilize / -U option stub`

+120 / −3. Option lands; gating is not implemented yet.

What to look for:
- Scalar option `0 < x < 100` (exclusive), validated.
- Plumbed through to resources but no resource consults it yet.
- POD documents the eventual spawn-throttle window (2-second
  sliding window of `(spawned − exited)` deltas) — also not
  implemented yet.

### `231a751fc Phase 6.4: define Resource::Utilizer role and apply it to existing stubs`

+411 / −0 across 5 files. Pure addition; methods are stubbed.

What to look for:
- New `Test2::Harness2::Role::Resource::Utilizer` (per Exodist's
  naming convention — roles go under `Roles::*`, multi-level OK).
- Memory / PipeLimits / UnixLimits apply Utilizer with stub method
  bodies. Memory carries a Phase 6.6 history-aware TODO comment.

### `ee6d327c6 Phase 6.5: stub TempSpace and CPU resources`

+244 / −0 in 2 new files.

What to look for:
- `Resource::TempSpace` (subclass of Disk, auto-set to
  `File::Spec->tmpdir`).
- `Resource::CPU` (aggregate CPU usage).
- Both apply Utilizer; both `croak "not implemented yet"` from
  every method body.

---

## Phase 9 documentation pass

### `c7e5b7fc7 ARCHITECTURE: refresh §14.1 for Phase 6.1 resource model`

+6 / −5 in `ARCHITECTURE.md`.

What to look for:
- §14.1 wording was "shares the run's job-limiter pool". Phase 6.1
  removed that semantic. New text: "consults every resource that
  reports `needed(job => $job)` and is not `is_permanent_broken`,
  requesting `need=1` from each".

---

## Style commit (Phase 0 follow-up, already on `2.0`)

### `e5cdb3753 style: document tinysleep / Time::HiRes::sleep / no-direct-select rule`

+24 / −0 in `STYLE_GUIDE.md`. Already on `2.0`; included here as the
chain base.

What to look for:
- Nothing structural. `tinysleep` is the mandatory primitive for
  busy-loop polling so signals (SIGCHLD / SIGTERM) interrupt the
  wait. `Time::HiRes::sleep` retries on EINTR and silently swallows
  signals. Direct 4-arg `select()` is also banned.

---

## Things deliberately deferred

These are not bugs to flag during review — they are noted-and-known
follow-ups planted as TODO comments or in AI_DOCs:

- **Phase 5.2** (cross-cutting roles `HasLoop`, `HasIPC`,
  `HasObserverChain`, `HasAuditor`) deferred until `Collector.pm`
  is small enough to make the role boundaries obvious.
- **Phase 6 stubs**: every Utilizer / TempSpace / CPU /
  Disk / Memory / PipeLimits / UnixLimits method `croak`s "not
  implemented yet". `--utilize` percentage is parsed and
  propagated; no resource consults it. The `(spawned − exited)`
  spawn-throttle window is documented in POD but not implemented.
- **Phase 7 status-asymmetry**: hash-seed mismatch only fires when
  both sides have explicit seeds. Strict asymmetry rejection
  should land when a real `Resource::Preload` exists.
- **Phase 7 yath start / yath run**: PR #390 stubs that `die`. TODO
  comments at the top of each describe the `--set-hash-seed`
  wire-up.
- **App-Yath-Script coordination**: harness now sets
  `PERL_HASH_SEED`; the shim still does the same in its re-exec
  path. Behavior is duplicative until App-Yath-Script ships a
  release with the seed-setting `exec` removed and the cpanfile
  pin moves forward. AI_DOC has the full plan.

---

## Recommended review order

1. **Foundational utility (Phase 1)** — bottom-up: FileMonitor,
   then change-detection strip, then JSONL/Stream rework, then
   zstd-dict removal. Each later commit assumes earlier ones.
2. **TestFile (Phase 3)** — Role first, then split, then producer
   migration.
3. **Run/State + log layout (Phase 4)** — Run/State split first.
4. **LogArchive (Phase 4.5)** — LogLayout module first, then
   Artifact handle, then the structural reshape.
5. **Collector / auditor / RunService (Phase 5)** — independent of
   each other; review in any order.
6. **Hash seed (Phase 7)** — option first, then harness-side check.
7. **CWD artifacts (Phase 8)** — defaults flip, then links flag,
   then index.
8. **Synthetic rename (Phase 2)** — independent.
9. **Resource overhaul (Phase 6)** — 6.1 first (the contract
   change), then 6.2 (yath-test integration), then the option +
   role + stubs in any order.
10. **Phase 9 doc** — last.

---

## Useful invocations

```bash
# Diff vs base (everything in this branch)
git diff fff992a6d..full_audit

# Single commit, with prefix-trimmed paths
git show <sha> --stat

# Files touched by a phase
git log --name-only fff992a6d..full_audit -- lib/Test2/Harness2/Util/

# Word-by-word inside a long commit
git log -p -G'<symbol>' -- <path>

# Re-run the full test suite (mind ulimits — see CLAUDE.md)
ulimit -v 16000000 -u 4096 && AUTHOR_TESTING=1 prove -j4 -Ilib -It/lib -r t
```

---

(end of guide)
