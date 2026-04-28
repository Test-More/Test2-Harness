# AUDITS — Final report

Generated 2026-04-28. All implementation phases (0–8) complete. Phase 9
(documentation reconciliation + planning-artifact deletion) skipped per
user direction.

---

## Branch chain

All branches local only — none pushed to origin.

```
2.0
 └── audits-phase-0  (07e602404)                              STYLE_GUIDE
      ├── audits-phase-1  (082b8f1da → 92a57607f)            File IO + FileMonitor
      │    └── audits-phase-3  (7ff81db9d → 44043153a)       TestFile split
      │         └── audits-phase-4  (e460d6456 → 1dd9a9273)  Run/State + log layout
      │              ├── audits-phase-5  (d7dc71840 → 31a6e0feb)  Collector cleanup
      │              ├── audits-phase-7  (89e0b709f → 1d797450a)  Hash seed
      │              └── audits-phase-8  (b68c2dbe0 → 2a85ccd81)  CWD artifacts
      ├── audits-phase-2  (15ee7d48e)                         Synthetic rename
      └── audits-phase-6  (6808277f6 → 11ff7c160)            Resource overhaul
```

Phase 2 and Phase 6 branched directly from Phase 0 — neither depended on
the 1/3/4 chain. They will conflict-merge cleanly into the main chain at
merge time but were not chained because the dependency graph in
`AUDITS.md` placed them off-trunk.

## Per-phase summary

### Phase 0 — STYLE_GUIDE.md extraction
- Commit `07e602404` on `audits-phase-0`.
- New `STYLE_GUIDE.md` at repo root.
- `CLAUDE.md` `## Style` and `ARCHITECTURE.md` `## 25. Coding Conventions`
  sections collapsed to one-line pointers.
- Added one-liner-at-top rule (AUDITS:194-228) verbatim with the example.
- `Commits` (process) and `Dependency Rules` (architectural contract)
  intentionally left in `CLAUDE.md`, not migrated.
- Named-subs rule kept in shorter form.

### Phase 1 — File/IO utility cleanup + FileMonitor
- Commits `082b8f1da → 92a57607f` (4 commits) on `audits-phase-1`.
- New `lib/Test2/Harness2/Util/FileMonitor.pm` + tests. Hi-res mtime,
  Linux::Inotify2 when present.
- New `lib/Test2/Harness2/Util/JSONL/Reader.pm` (extension beyond brief —
  supports the existing "ready peeks / fetch consumes" pattern via
  `peek_changed()` on `FileMonitor`).
- Deleted `Util/File/Stream.pm`, `Util/File/JSONL/Zstd.pm`,
  `App/Yath2/Options/LogArchive.pm` (no production consumer),
  `share/other/zstd.dict`, `author/train_zstd_dict`, 5 obsolete tests.
- `Util/File/JSONL.pm` reparented onto `Util/File/JSON`; assumes complete
  files; `read_line` decodes one line; `write` / `rewrite` take lists.
- Zstd dictionary benchmark: 18.34% improvement, below the user's 35%
  threshold → **dictionary deleted**. `IPC_DEFAULT_ZSTD_LEVEL` retired;
  per-instance bless removed; `JSON::Zstd` used as a class string.
- 934 tests pass (`AUTHOR_TESTING=1 prove -j16 -Ilib -It/lib -r t/`).
- Cleanup miss: `xt/author/zstd-dict.t` left orphaned; deleted by
  Phase 4 commit `1dd9a9273`.

### Phase 2 — Synthetic rename
- Commit `15ee7d48e` on `audits-phase-2`.
- Resource-side "synthetic" → `unavailable_action`. Auditor-side
  "synthetic" left as-is.
- `_launch_synthetic_job` → `_launch_unavailable_action_job`. Internal
  method only — no external callers.
- Test files updated. ARCHITECTURE.md gained §14.1 "Unavailable-action
  launches".
- Watchdog completion-message synthesis (`PENDING_SYNTH_COMPLETIONS`)
  intentionally kept under "synthetic" (matches meaning #2 — fabricated
  message, not launched job).
- 148 files PASSED, no regressions.

### Phase 3 — TestFile refactor
- Commits `7ff81db9d → 44043153a` (4 commits) on `audits-phase-3`.
- `Test2::Harness2::Role::TestFile` → pure contract. `check_*` are pure
  lookups, no implicit `$self->scan`.
- `Test2::Harness2::TestFile` → static value object. No mutators, no
  scanning, no I/O. Constructor takes pre-built data.
- `App::Yath2::TestFile` (new) → scanner. Reads shebangs / `HARNESS-*`
  headers, applies CLI overrides, produces queue payload.
- HashBase shadowing: kept Q3b option (a). Role accessors carry an
  explicit POD note that consumers typically shadow them.
- `max_slots` default = `undef` (Q3.4 option c). Each resource
  interprets.
- "THIS IS A GENERATED YATH RUNNER TEST" short-circuit moved into the
  scanner — harness no longer sees it.
- All 15 pitfalls from `TEST_FILE_AUDIT.md` §4 resolved; results
  appended as TEST_FILE_AUDIT.md §5.
- In-place decisions:
  - `comparable` method skipped (doesn't exist anywhere in
    references).
  - `meta($key)` from audit conflicted with HashBase shadowing (sub
    arg silently ignored). Added `meta_get($key)` as distinct helper.
    `meta()` stays as bare hashref accessor.
  - HashBase slot prefix `+` (constant only) used for slots with
    auto-scanning accessor overrides; `<` (slot + reader) for plain
    slots.
  - Strict `-f $file` validation restored on init per "port the exact
    idiom".
- 143/143 tests pass on `t/`.

### Phase 4 — Run/State split + log layout
- Commits `e460d6456 → 1dd9a9273` (4 commits) on `audits-phase-4`.
- `Test2::Harness2::Run` → immutable spec. `Test2::Harness2::Run::State`
  → mutable runtime state.
- New layout: `runs/<UUID>/spec.json`, `runs/<UUID>/state.json`,
  `runs/<UUID>/events.jsonl`. Compressed variants `.zst`.
- Q4a option (b) — split queue-time vs runtime identities:
  - Spec: `requested_harness_uuid` (nullable).
  - State: `running_harness_uuid`, `collector_uuid`, `bus_address`,
    `running_session_uuid`. None existed pre-Phase 4 — added per the
    decision.
- Q4b — old layout rejected with `croak`:
  ```
  runs/<run_id>/ missing spec.json -- log layout pre-Phase-4 is no
  longer supported
  ```
  emitted from `App::Yath2::LogArchive::_assert_run_layout_phase4`.
- Per-field decisions for ambiguous fields:
  - `created_at` — duplicated on both (canonical = Spec). State carries
    a copy so state.json read alone is self-contained.
  - `start_time` / `finish_time` / `completed` — State.
  - `exit_summary` — State.
  - `loggers` / `extend_loggers` / `test_loggers` /
    `extend_test_loggers` / `launch_job_timeout` — Spec (caller intent
    frozen).
  - `resources` — Spec (live Perl objects passed at queue).
  - `resources_started` / `resources_torn_down` — State (idempotency
    flags).
- Phase 5.5 partially folded: `request_handler_launch_job` uses
  `File::Spec->file_name_is_absolute`; dynamic `require` replaced with
  top-of-file `use`.
- 952/952 tests pass.

### Phase 5 — Collector cleanup
- Commits `d7dc71840 → 31a6e0feb` (5 commits) on `audits-phase-5`.
- New `Test2::Harness2::Collector::Util` (helpers: `spec_class`,
  `validate_spec`, `make_warn_handler`, `kill_child`, `win32_quote_arg`,
  `Util::FileLineReader`).
- New `Test2::Harness2::Collector::Win32` (Win32-only spawn / launch /
  kill / quote / DESTROY methods, ~340 lines).
- Deleted `Collector::Service::Run`, `Collector::Service::Harness` (both
  trivial subclasses); replaced with kwargs (`is_run`,
  `is_harness_collector`) on the base.
- Auditor split: `_audit` 132 → 45 lines; `_subtest_process` 119 → 34.
  New helpers: `_audit_subtest_start`, `_audit_orphan_subtest_end_recovery`,
  `_audit_close_deeper_subtests`, `_subtest_process_parent`,
  `_subtest_tally_facets`, `_subtest_process_exit`.
- RunService 5.5 hygiene: dispatch handlers renamed
  `_handle_test_job_*` → `_handle_gen_msg_test_job_*`,
  `_handle_collector_artifacts` → `_handle_gen_msg_collector_artifacts`.
- `Collector.pm` line count: 1947 → 1621 (-326). Target ~1000 NOT
  reached. Step 5.2 (cross-cutting roles) deferred — file still too
  large for the "small follow-on" threshold the plan called out.
- Step 5.3 (Process-Collector extraction) closed per Q5a — no TODO
  opened, no document append.
- 971 tests pass.

### Phase 6 — Resource model overhaul
- Commits `6808277f6 → 11ff7c160` (5 commits) on `audits-phase-6`.
- Dropped `is_job_limiter` from `Role::Resource`, `Resource::JobCount`,
  `Resource::SharedJobs`. Harness no longer mandates a limiter.
- `Test2::Harness2.pm:1654` job-launch grep predicate:
  `needed && !is_permanent_broken` (subagent's chosen replacement —
  not a TODO).
- `App::Yath2::Options::Resource.pm` `jobs_post_process` rewritten:
  - User passes any `--resource` → no auto-injection.
  - User passes `--no-resource` (auto-generated clear form on the
    `classes` map option) → no auto-injection.
  - Otherwise inject `Test2::Harness2::Resource::JobCount` with
    empty args (slots/max_per_job come from `-j` defaults).
- `--utilize` / `-U` Scalar option: `0 < x < 100` (exclusive),
  validated, propagates to resources, no actual gating yet (stub per
  plan).
- New role `Test2::Harness2::Role::Resource::Utilizer` (per Exodist's
  naming convention).
- Applied Utilizer to `Memory.pm`, `PipeLimits.pm`, `UnixLimits.pm`
  with stub methods + Phase 6.6 history-aware TODO comment on Memory.
- New stubs: `Resource::TempSpace` (subclass of Disk, auto-set to
  `File::Spec->tmpdir`), `Resource::CPU` (aggregate CPU usage). Both
  apply Utilizer; both `croak` in unimplemented methods.
- 975 tests pass.

### Phase 7 — Hash seed
- Commits `89e0b709f → 1d797450a` (3 commits) on `audits-phase-7`.
- `--set-hash-seed` added to existing `App::Yath2::Options::Tests`
  group. No new options module.
- Behavior:
  - Absent → `PERL_HASH_SEED` left untouched on test children.
  - No value → today's date as `YYYYMMDD` (matches App-Yath-Script
    shim format).
  - `--set-hash-seed=N` → verbatim `N`.
- Spawn-env injection: `lib/Test2/Harness2.pm` `_launch_job` (around
  line 1862, after `T2_HARNESS_INCLUDES`).
- Reject-on-mismatch in `request_handler_queue_test_run`:
  ```
  --set-hash-seed=$run_seed on the run does not match
  --set-hash-seed=$harness_seed on the harness; preload was started
  with seed $harness_seed and cannot be reused
  ```
  Currently fires only when both sides have explicit seeds and they
  differ. Status asymmetry (set vs unset) deferred until a real
  `Resource::Preload` lands — TODO planted at the queue handler.
- `yath start` / `yath run` are PR #390 stubs that `die`. TODO
  comments added at top of each describing the wire-up plan.
- AI_DOC: `AI_DOCS/2026-04-28-phase-7-hash-seed.md`.
- 964 tests pass.

### Phase 8 — Move artifacts out of CWD
- Commits `b68c2dbe0 → 2a85ccd81` (3 commits) on `audits-phase-8`.
- Per user's stronger-than-D stance: cwd is **never** the default
  destination. Artifacts land in tempdir / workdir; cwd only when
  explicitly requested.
- Default-destination changes:
  - `yath test` archive: `<cwd>/<stamp>.yath` →
    `<sys_tmp>/yath-<stamp>-<uuid>.yath` (sibling of the workdir,
    survives workdir cleanup).
  - `yath archive` default path: `<cwd>/<stamp>.yath` →
    `<sys_tmp>/yath-<stamp>-<pid>.yath`.
  - IPC info file `dir_order` default:
    `[user_rc, project_rc, cwd, tempdir]` →
    `[tempdir, user_rc, project_rc]`. cwd dropped entirely.
- New `--local-artifact-links` Bool option (in
  `App::Yath2::Options::Workspace`). Symlink-only. On failure, single
  warn message + skip remaining links (Q8a option a). cwd-side names:
  - `yath-latest-archive.yath`
  - `yath-latest-ipc`
  - `yath-latest-logs` (only with `--keep-dirs`)
  - `yath-latest-workdir` (only with `--keep-dirs`)
- New `Test2::Harness2::Util::CwdIndex` module:
  - Path: `$XDG_RUNTIME_DIR/yath/cwd-index.json` if available, else
    `<sys_tmp>/yath-cwd-index-$USER.json`. Mode 0600.
  - Schema: `{ sha1_hex(abs_cwd) => { latest_archive, latest_workdir,
    last_run_uuid, updated_at } }`.
  - Sibling `.lock` file for `flock(LOCK_EX)` during read-modify-write;
    rewrite via `write_file_atomic_mode($path, 0600, ...)`.
- Producer: `App::Yath2::Command::test` calls `gc()` then
  `record(getcwd, ...)` after archive write, eval-wrapped so a record
  failure cannot fail the run.
- Consumers: `replay`, `extract`, `failed`, `times`, `speedtag` fall
  back to `lookup(getcwd)` when no positional LOG given.
- Left as-is per design: `yath init` writes `test.pl` (project seed),
  `yath speedtag` rewrites tests in place + `durations.json`,
  `yath extract` defaults to `./logs` (user-driven extract).
- 884 tests pass.

---

## Things you need to know

### App-Yath-Script coordination (Phase 7)

The harness now sets `PERL_HASH_SEED` from `--set-hash-seed`. The
`App-Yath-Script` shim still does the same in its re-exec path. The
behavior is duplicative until `App-Yath-Script` ships a release with
the seed-setting `exec` removed.

Plan (recorded in `AI_DOCS/2026-04-28-phase-7-hash-seed.md`):

1. Cut a release of `App-Yath-Script` with the seed-setting `exec`
   removed.
2. Bump the cpanfile pin in this distribution to require that release.
3. Until then, wrapper and harness duplicate the work; behavior is
   correct but the wrapper's `--no-exec`/`--exec`-or-equivalent should
   be considered overlapping.

### Hash seed feature gaps

- `yath start` / `yath run` are PR #390 stubs that `die`. Both have
  TODO comments at the top describing the `--set-hash-seed` wire-up
  for the day they're reimplemented.
- Status-asymmetry rejection (run sets a seed but harness has none, or
  vice versa) is currently accepted with a TODO. The strict check
  should land when a real `Resource::Preload` exists.

### Phase 5 incomplete

- Step 5.1 dropped `Collector.pm` from 1947 → 1621 lines. The plan
  envisioned ~1000. Remaining 600 lines are the loop, the IPC outbox
  drain, the parser/auditor/logger wiring, and the harness-collector
  special-case logic.
- Step 5.2 (cross-cutting roles: `HasLoop`, `HasIPC`,
  `HasObserverChain`, `HasAuditor`) was deferred per the plan's "do
  5.1 first; defer until file is small enough to read" guidance.
  Current size argues for picking it up later.

### Phase 6 stubs

- `Resource::TempSpace`, `Resource::CPU`, `Resource::Disk`,
  `Resource::Memory`, `Resource::PipeLimits`, `Resource::UnixLimits`
  are all stubs. Their `available` / `assign` / `release` methods
  `croak` "not implemented yet".
- `--utilize` percentage is parsed and propagated but no resource
  actually consults it yet. The Utilizer role is defined; methods are
  stubbed.
- The spawn-throttle window described in the plan (2-second sliding
  window of `(spawned - exited)` deltas) is documented in the
  `--utilize` POD but not implemented.

### Phase 3 leak: `xt/author/zstd-dict.t`

- Phase 1 deleted the zstd dictionary but left this test orphaned.
- Phase 4 commit `1dd9a9273` removed it. xt suite green after that.

### Per-field assignment for Run / Run::State

If a future field needs assignment, follow the rule the Phase 4
subagent used: "anything mutated post-queue → State; anything frozen
at submission → Spec". `created_at` is the only field intentionally
duplicated on both sides (canonical = Spec; State copy exists so
state.json read alone is self-contained).

### `meta()` vs `meta_get($key)` on TestFile

Phase 3 added `meta_get($key)` as a distinct helper because
`meta($key)` would collide with HashBase's slot reader (HashBase
ignores method args). `meta()` returns the bare hashref; `meta_get($k)`
returns a single key's value. Document this if any external code is
expected to use it.

### Branches not pushed

All 9 branches are local. Merge strategy is up to you.

Suggested merge order (least conflict first):

```
2.0
 ←── audits-phase-0
2.0+phase-0
 ←── audits-phase-2  (resource-side rename, low blast)
 ←── audits-phase-6  (resource overhaul, low blast)
 ←── audits-phase-1  (file IO + FileMonitor)
 ←── audits-phase-3  (TestFile, depends on 1)
 ←── audits-phase-4  (Run/State + log layout, depends on 1+3)
 ←── audits-phase-5  (Collector cleanup, depends on 1+4)
 ←── audits-phase-7  (Hash seed, depends on 4)
 ←── audits-phase-8  (CWD artifacts, depends on 4)
```

Phases 5, 7, 8 all branched from 4 and may conflict with each other on
files like `lib/Test2/Harness2/RunService.pm` (Phase 5 hygiene) and
`lib/App/Yath2/Command/test.pm` (Phases 7 + 8 both wired into the test
command).

### Phase 9 (skipped per direction)

Outstanding items to sweep when you do the docs pass:

- Re-read `ARCHITECTURE.md`. Confirm the addenda already added by
  Phase 2 (§14.1) and any others made by per-phase subagents are
  consistent with each other after the merge.
- Re-read `PLAN`. Trim done items, add follow-ups for things deferred
  here (Phase 5.2, Phase 6 stubs, Phase 7 status-asymmetry, Phase 7
  start/run command stubs).
- Confirm `STYLE_GUIDE.md` is the only place style rules live (it
  should be — Phases 0–8 obeyed it).
- Delete the planning artifacts:
  - `AUDITS` (the freeform note)
  - `IPC_AND_LOGGERS.bak.20260420-072104`
  - `AUDITS_PENDING_QUESTIONS.md`
  - `AUDITS_FINAL_REPORT.md` (this file — keep until you've absorbed
    its content)
  - `COLLECTOR_CLEANUP.md`, `CWD_FILES.md`, `TEST_FILE_AUDIT.md`,
    `test_command_options_audit.md` (companion audits — keep if you
    want a record, delete otherwise)
- The inline `# ...` review comments left in modified files were
  honored by the per-phase subagents but the comments themselves were
  not bulk-removed across the working tree. Sweep for any remaining
  ones (`grep -rn "# Remove\|# REMOVE\|# TODO: AUDITS\|# AUDIT" lib/`).

---

## Decisions log (for reference)

| Q | Phase | Decision |
|---|---|---|
| Setup | — | Worktrees chained off prior dependent step's branch. Per-phase worktree. Commit + local branch; do not push. |
| 0 ambiguity #1 (Commits section) | 0 | Process rule, not style. Kept in CLAUDE.md, dropped from STYLE_GUIDE.md. |
| 0 ambiguity #2 (named-subs wording) | 0 | Shorter CLAUDE.md wording kept. |
| 0 ambiguity #3 (Dependency Rules) | 0 | Kept in CLAUDE.md as architectural contract. |
| 1.5 zstd dict threshold | 1 | 35% improvement threshold. Measured 18.34% → deleted. |
| 2.1 synthetic rename | 2 | Resource side renamed. Auditor side kept. |
| 2.1 rename target | 2 | `unavailable_action`. |
| 3.4 max_slots default | 3 | (c) keep `undef`; each resource interprets. |
| 3a net-new accessors | 3 | Keep all. |
| 3b HashBase shadowing | 3 | (a) keep current pattern, role accessors get explanatory POD. |
| 4a Spec/State per field | 4 | User-pinned per field; `created_at` on both. |
| 4a identity fields | 4 | (b) split queue-time vs runtime; `requested_X` / `running_X`. |
| 4b old log layout | 4 | No back-compat. Reject with clear error. |
| 5.3 Process-Collector | 5 | (b) close the question. |
| 6.4 Utilizer role name | 6 | `Test2::Harness2::Role::Resource::Utilizer`. |
| 7.1 default seed format | 7 | `YYYYMMDD` (matches App-Yath-Script shim). |
| 8.2 flag name | 8 | `--local-artifact-links`. |
| 8a Win32 fallback | 8 | (a) try `symlink()`; on failure warn + skip. |
| 8b cwd→run association | 8 | Stronger than D: cwd is never the default destination; index in tempdir, no cwd dotfile. |

---

(end of report)
