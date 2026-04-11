# Schema DBIC Unification — Resume State

**Last updated:** 2026-04-11 (Phase 6 + Phase 7 complete)
**Branch:** `2.0`
**Last commit:** `1778809f7 refactor(tests): delete stale Overlay/* unit test stubs`
**Tag:** `post-dbic-migration`
**Working tree:** clean

## Status: DONE

All phases of the schema DBIC unification refactor are complete. The branch is
ready for review, merge, or further work. No subagent is mid-task.

## Summary of what landed

### Phase 6 — Test infrastructure (2026-04-11)

- `186ab65cb` Task 23 — `t/lib/App/Yath/Test/DBIC/Database.pm` (ephemeral_server helper)
- `c55eed0c0` Task 24 — `t/lib/App/Yath/Test/DBIC/Schema.pm` (run_schema_tests: load + 29 source + User password subtests)
- `511ae04da` Task 25 — `t/lib/App/Yath/Test/DBIC/Coverage.pm` (run_coverage_tests; body lifted from coverage-sqlite.t lines 40-352; `$dir` hardcoded to `t/integration/coverage` because the plan's caller-derived regex would have yielded the nonexistent `t/integration/dbic-coverage`)
- `658113321` Task 26 — 10 shim `.t` files: `dbic-{schema,coverage}-{sqlite,postgresql,mysql,mariadb,percona}.t`
- `05bd7b0fb` Task 27 — deleted the 5 legacy `t/integration/coverage-*.t` files. The other files Task 27 listed (per-backend unit test dirs, `t/UI/{PostgreSQL,MySQL}.t`) had already been removed in Phase 5's `4d5ffd2e6`.

### Phase 5 follow-up fixes discovered during Phase 6

- `c45ffb88f` **Latent Phase 5 gap** — the legacy `App::Yath::Schema` defined runtime methods `config()` and `vague_run_search()` that were never ported to the new unified `App::Yath::Schema::DBIC`. Eight consumers call them (`Server.pm`, `Plack.pm`, `Controller/{User,Recent,ReRun,Files}.pm`, `Plugin/DB.pm`, `Command/recent.pm`). The Phase 5 validation only exercised compile-time loading via `t/0-load_all.t`, so the gap went unnoticed until the new `ephemeral_server` helper hit a runtime failure in `Server.pm` line 162. Both methods copied verbatim from the pre-deletion `Schema.pm`.

### Phase 7 — Validation & sweep

- `5f5fef7ef` **POD convention fix** — `t/1-pod_name.t` was failing on all 36 files in the unified DBIC tree because the Phase 2 style guide removed POD. The user elected to keep the convention check unchanged and instead add minimal `=head1 NAME` POD stubs to every file in the tree (DBIC.pm, 5 connection modules, ResultBase.pm, ResultSet.pm, 29 Result classes). Phase 2 style rule "no POD at bottom" has been amended: the Result classes DO carry a minimal `=head1 NAME` block.
- `1778809f7` **Stale overlay stubs deleted** — Task 30's stale-reference sweep surfaced 30 dead placeholder `.t` files under `t/unit/App/Yath/Schema/Overlay/` that all `skip_all "write me"` against the deleted `App::Yath::Schema::Overlay::*` namespace. Equivalent stubs under `t/unit/App/Yath/Schema/Result/*.t` already target the DBIC-resolved namespace, so the Overlay copies were dead duplicates. Deleted.
- **Tag** — `post-dbic-migration` applied to `1778809f7`.

### Full-suite validation

Run via: `perl -Ilib scripts/yath test -D -j24`

Result: 298 files, 3013 assertions, 65s, all green. All 5 backends are available on this host except Percona (skips cleanly). Both schema shims and coverage shims exercise PostgreSQL, MySQL, MariaDB, and SQLite end-to-end.

## Obsolete plan tasks (Phases 2, 3, 4, 29 — generator rewrite approach)

The original plan's Phase 2/3/4 described an auto-generator (`regen_schema.pl` + Parser/Merger/Emitter/Splicer/Writer helpers). The user rejected that mid-Phase 2 in favor of hand-maintained unified files; the generator was deleted in commit `1a70dd29e`. Task 29 (idempotency check) and Task 30 Step 3 (author_tools regen tests) are therefore obsolete and were skipped.

## Pivots that amended the plan

1. **Generator approach killed** — hand-maintained Result classes, no `>>> GENERATED <<<` markers. (Phase 2, pre-existing context.)
2. **Phase 5 and "delete legacy trees" were interleaved** — the plan expected the old and new trees to coexist during Phase 5 validation, but each backend's connection module `confess`es if its sibling's `$LOADED` is set. Task 22 handled this by deleting the legacy trees in the same pass.
3. **Task 25 `$dir` hardcoded** — plan proposed deriving from caller, but the new shim filenames (`dbic-coverage-*`) don't match the fixture directory (`t/integration/coverage/`). Fixed in the implementation.
4. **Task 27 scope reduced** — the per-backend unit test dirs and `t/UI/{PostgreSQL,MySQL}.t` were already deleted in Phase 5, so Task 27 ended up being just the 5 `t/integration/coverage-*.t` files.
5. **Phase 2 "no POD at bottom" amended** — `t/1-pod_name.t` required POD; rather than exempt the tree, minimal `=head1 NAME` stubs were added.
6. **Overlay unit-test stubs cleaned up** — not strictly in scope of any task, but caught by Task 30 Step 2's grep sweep.

## Known issues still flagged (unchanged — not blockers)

1. **`Event.nested` preserved as `smallintegernot`** (SQLite only, bug in original loader output). Needs a follow-up SQL schema/migration fix.
2. **Percona UUID inflate_column inconsistency** — preserved from the old overlay.
3. **`Run.pm coverage_data` iterator bug** (`$run_id` compared but never set) — preserved verbatim.
4. **`Job.pm` `*job_tries = *jobs_tries` glob alias** — "used only once" compile-time warning, preserved.

## How to resume (should the work be reopened)

1. `git status` — verify clean tree.
2. `perl -Ilib scripts/yath test -D -j24` — full suite (~65s on this host). Expect 298 files pass, Percona shims skip if not installed.
3. `git tag -l post-dbic-migration` — should list the tag.

Beyond that, the refactor is done. The 4 known latent issues above are the only follow-ups, and they're scoped to individual columns/methods — not structural.
