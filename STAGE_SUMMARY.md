# Stage 2 — Move AI-generated tests under `t/AI/`

## Branch

- `plan-stage-02-ai-tests`
- Base: `reimplement-resource-classes` (HEAD `9e31630c0`)
- No merge of `reimplement-resource-classes` into `2.0_rewrite` was performed,
  per the instruction to base the chain directly on that branch.

## What landed

- Every existing test file under `t/integration/` and `t/unit/` moved under
  `t/AI/integration/` and `t/AI/unit/` via `git mv` (rename, 100% similarity
  preserved).
- `t/lib/` (test-support library, not itself a test) stayed put.
- `CLAUDE.md` got a new bullet under **Testing** documenting the `t/AI/`
  rule, mirroring what `ARCHITECTURE.md` section 13 ("Authorship layout")
  already describes.

## Commit

1. `Move existing AI-generated tests under t/AI/`

## Tests

- `prove -I lib -I t/lib -r t/AI/unit` — 25 files, 331 tests, all pass.
- `prove -I lib -I t/lib -r t/AI/integration` — 6 files, 23 tests, all pass.
  The `Collector IPC send failed (kind 'collector_exiting')` warnings on
  STDERR are pre-existing; they predate this stage and are not caused by
  the move.
- The existing `use lib 't/lib'` lines in the moved tests still resolve
  correctly because `yath`/`prove` runs them from the repo root.

## Points of interest / decisions you may want to revisit

1. **`t/lib/Test2/Harness2/TestFile.pm` stays at `t/lib/`.** It is a Perl
   test-support module, not a test file itself, so the `t/AI/` rule does
   not strictly apply. If you want test-support modules split by authorship
   too, move it to `t/AI/lib/` and update `use lib 't/lib'` call sites.

2. **`CLAUDE.md` is gitignored** on this branch (line 64 of `.gitignore`:
   `/CLAUDE.md`). That means the edit I made to `CLAUDE.md` is a **user-
   level change**, not a branch change, and will not show up when this
   branch is rebased or merged. Your worktrees all share the same
   symlinked `CLAUDE.md`, so the edit applies everywhere.

   If you want the rule to live with the branch, `ARCHITECTURE.md`
   section 13 already has it (committed). If you want a third, committed
   location specifically aimed at contributors, consider either:
     - Un-gitignoring `CLAUDE.md` (revert `18df142f3`), or
     - Creating a new committed `docs/authorship.md` and linking it from
       `ARCHITECTURE.md`.

3. **No change to `.claude/settings.local.json`.** The PLAN allowed
   updating CLAUDE.md "and/or claude settings"; the rule does not need
   tool-level enforcement (it is an editorial rule), so I left the
   settings file untouched. If you want a lint hook that blocks new
   `.t` files outside `t/AI/` unless they pass some authorship check,
   that would be a settings-level addition worth a follow-up.

4. **`.gitignore` line 56 (`t/integration/test-broken-symlinks/...`)**
   references the old test path. It was stale already (no such path exists
   in this tree) and remains untouched; if the acceptance-test port in
   Stage 17 brings `test-broken-symlinks` into `t/`, that line may need
   updating to `t/integration/...` or `t/AI/integration/...` depending
   on authorship.

5. **Exit criteria.** The PLAN also asks for `CLAUDE.md` /
   `.claude/` settings to reflect the rule. Since CLAUDE.md is gitignored,
   the committed artefact of this stage is only the file moves. The rule
   itself is carried by `ARCHITECTURE.md` (already present) and by the
   per-user `CLAUDE.md` (updated but not committed).

## Post-refactor rebase (2026-04-20)

Rebased onto the updated `reimplement-resource-classes` base
(`0c46805cf`), which now carries the IPC_AND_LOGGERS-alignment
refactor:

- IPC message-kind renames: `job_complete` → `test_job_completed`,
  `loggers_ready` → `collector_artifacts`.
- Collector artifact routing now targets `ipc_run` (preferred) or
  `ipc_harness`, not `ipc_parent`.
- Collector bus name convention: `collector:<service>[:<run_id>]`.
- Per-run `launch_job_timeout` slot on `Test2::Harness2::Run` with
  a 5-second default.

Stage-02's own commits (the `t/AI/` move) replayed cleanly — no
conflicts during cascade. (Live branch tip recorded in
`PLAN_RESUME.md` on the primary repo, not pinned here.) Full
`prove -j16 -I lib -I t/lib -r t` run green downstream.
