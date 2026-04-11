# Schema DBIC Unification — Resume State

**Last updated:** 2026-04-11 (after Phase 5 completion)
**Branch:** `2.0`
**Last commit:** `4d5ffd2e6 chore(schema): delete legacy per-backend schema trees and tests`
**Working tree:** clean

## Where to resume

**Phase 6 (test infrastructure) is next.** Phase 5 is complete and the legacy per-backend trees and tests have been deleted in the same sweep. No subagent is currently mid-task — start a fresh subagent for Phase 6 Task 23 per the plan.

Read `docs/superpowers/plans/2026-04-11-schema-dbic-unification.md` for the original plan. **Phases 2, 3, and 4 are OBSOLETE** (they described the generator approach — see pivot note). **Phases 5, 6, 7 are still the source of truth for what's left**, but Phase 5 actually ended up interleaved with the "Delete old trees" step (see below).

## Critical pivot

The user rejected the auto-generator approach mid-Phase 2. Instead of using `regen_schema.pl` + parser/merger/emitter helpers, Result classes are hand-maintained. `author_tools/regen_schema.pl` and `author_tools/lib/Yath/Regen/DBIC/*` were deleted in commit `1a70dd29e`. The unified Result files have NO `# >>> BEGIN/END GENERATED <<<` markers — they are normal hand-maintained Perl modules.

## What is done

### Phase 1 (Foundation)
- `lib/App/Yath/Schema/DBIC.pm` — schema class with exportable helpers (`is_sqlite`, `is_postgresql`, `is_mysql`, `is_mariadb`, `is_percona`, `can_store_null_character`, `format_uuid_for_db`, `format_uuid_for_app`). Method-form works too. `load_namespaces` is guarded on `$LOADED` so the module is importable at compile time without a backend loaded (fixes standalone `perl -c` on every Result class).
- `lib/App/Yath/Schema/DBIC/ResultBase.pm` — hand-maintained unified base.
- `lib/App/Yath/Schema/DBIC/ResultSet.pm` — hand-maintained unified resultset.
- `t/unit/App/Yath/Schema/DBIC.t` — 19 tests, passing.

### Phase 2 (hand-migration)
All 29 unified Result classes written at `lib/App/Yath/Schema/DBIC/Result/<Name>.pm`:
ApiKey, Binary, Config, Coverage, CoverageManager, Email, EmailVerificationCode, Event, Host, Job, JobTry, JobTryField, LogFile, Permission, PrimaryEmail, Project, Reporting, Resource, ResourceType, Run, RunField, Session, SessionHost, SourceFile, SourceSub, Sweep, TestFile, User, Version.

Five connection modules:
- `lib/App/Yath/Schema/DBIC/SQLite.pm`, `PostgreSQL.pm`, `MySQL.pm`, `MariaDB.pm`, `Percona.pm`

Smoke test (still passes; re-run to re-verify):
```
for driver in SQLite PostgreSQL MySQL MariaDB Percona; do
  perl -Ilib -e 'use App::Yath::Schema::DBIC::'$driver'; my @s = sort App::Yath::Schema::DBIC->sources; print "Driver='$driver' sources=", scalar(@s), "\n"'
done
```
Expected: each line prints `sources=29`.

### Phase 5 (consumer updates) — DONE

All consumers rewritten to reference the unified DBIC namespace:

- **Task 17** (`a26f43ccd`) — schema-adjacent modules: 4 of 9 files touched (Util, RunProcessor, Config, DateTimeFormat). Sync, Sweeper, Importer, ImportModes, Queries had no applicable references.
- **Task 18** (`2a8e39205`) — server/renderer/plugin layer: only 1 line in `Server.pm` changed (dynamic require of backend connection module). The 22 controllers and all plugin/renderer/options files were already clean.
- **Task 19** — command layer: NO CHANGES NEEDED. Every reference in `Command/db*.pm`, `recent.pm`, `server.pm` was to exempted sub-namespaces (`::Util`, `::Sync`, `::Sweeper`, etc.). No commit was made.
- **Task 20** (`ceb1e745b`) — unit tests: 33 files updated (29 `Result/*.t` + `Schema.t`, `ResultBase.t`, `ResultSet.t`, plus one stray).
- **Task 21** (`66585a765`) — ancillary tests: only `t/0-load_all.t` needed changes (4 lines: dynamic require path, SQLite pre-load guard regex, $LOADED reference). `t/database/test.pl` and `t/integration/coverage-*.t` had nothing to update.
- **Task 22 (validation)** — ran into a fundamental issue: the plan expected the legacy and unified trees to coexist at load time, but each backend's connection module `confess`es if its sibling's `$LOADED` is already set. The pragmatic fix was to **delete the legacy trees in the same pass**, collapsing the "Delete old trees" step into Phase 5.

### Legacy tree deletion — DONE (`4d5ffd2e6`)

366 files removed in a single commit:

**Deleted library trees:**
- `lib/App/Yath/Schema.pm`
- `lib/App/Yath/Schema/ResultBase.pm`, `ResultSet.pm`
- `lib/App/Yath/Schema/{SQLite,PostgreSQL,MySQL,MariaDB,Percona}.pm` (5 connection modules)
- `lib/App/Yath/Schema/{SQLite,PostgreSQL,MySQL,MariaDB,Percona}/*.pm` (5 × 29 per-backend Result classes)
- `lib/App/Yath/Schema/Overlay/*.pm` (29 overlay stubs)
- `lib/App/Yath/Schema/Result/*.pm` (29 cross-backend Result base classes)

**Deleted tests:**
- `t/unit/App/Yath/Schema/{SQLite,PostgreSQL,MySQL,MariaDB,Percona}/*.t` (legacy per-table tests)
- `t/unit/App/Yath/Schema/{SQLite,MariaDB,Percona}.t` (top-level backend tests)
- `t/UI/{MySQL,PostgreSQL}.t`

**Validation after deletion:**
- `t/0-load_all.t` passes: **220 tests, all green** against SQLite.
- Syntax sweep clean across `lib/App/Yath/`, `t/unit/App/Yath/`, `t/integration/coverage-*.t`, `t/database/`.
- Phase 1 `t/unit/App/Yath/Schema/DBIC.t` still passes (19 tests).
- Smoke test all five drivers still reports `sources=29`.

**Note:** `lib/App/Yath/Schema/Table/` does not exist in this repo — the earlier memory note about leaving it alone was a false positive. Nothing there to worry about.

### Key commits (most recent first)
- `4d5ffd2e6` — delete legacy per-backend schema trees and tests (Phase 5 cleanup)
- `675f645aa` — fix: guard DBIC.pm `load_namespaces` on `$LOADED` so standalone `perl -c` works on all Result classes
- `66585a765` — refactor(tests): update ancillary tests (Task 21)
- `ceb1e745b` — refactor(tests): update unit tests (Task 20)
- `2a8e39205` — refactor(schema): update server/renderer/plugin (Task 18)
- `a26f43ccd` — refactor(schema): update schema-adjacent modules (Task 17)
- `85f1685aa` — docs: prior resume state
- `188adbeaa` — DBIC connection modules + load_namespaces
- (older Phase 1 / Phase 2 commits — see prior resume state)

## What is NOT done

### Phase 6 — Test infrastructure
Per the original plan:
- **Task 23** — `t/lib/App/Yath/Test/DBIC/Database.pm` — ephemeral DB helper wrapping `App::Yath::Server->start_ephemeral_db`
- **Task 24** — `t/lib/App/Yath/Test/DBIC/Schema.pm` — reusable schema smoke tests
- **Task 25** — `t/lib/App/Yath/Test/DBIC/Coverage.pm` — reusable body extracted from current `coverage-*.t`
- **Task 26** — 10 shim `.t` files under `t/integration/` named `dbic-{schema,coverage}-<driver>.t`
- **Task 27** — Delete the old per-db unit tests and `t/UI/{PostgreSQL,MySQL}.t` and old `t/integration/coverage-*.t`. **Partial overlap with Phase 5 deletion:** the per-backend unit tests under `t/unit/App/Yath/Schema/{SQLite,...}/` and `t/UI/{MySQL,PostgreSQL}.t` have ALREADY been deleted. `t/integration/coverage-*.t` is still present (Task 21 only made them compile-clean; Task 27 will delete them once replaced by Task 26 shims).

### Phase 7 — Validation
- **Task 28** — Run the full test suite against each available backend
- **Task 29** — Idempotency check (obsolete — no generator)
- **Task 30** — Final sweep and summary commit. Tag `post-dbic-migration`.

## Known issues still flagged (unchanged)

1. **Event.nested preserved verbatim as `smallintegernot`** (SQLite only, bug in original loader output). File: `lib/App/Yath/Schema/DBIC/Result/Event.pm`. Needs a follow-up SQL schema/migration fix.

2. **Percona UUID inflate_column inconsistency.** The new unified Result files preserve the existing inconsistency — Binary and tables that had an inflate get a `if (is_percona()) { __PACKAGE__->inflate_column(...) }` block; the ones that didn't get nothing. Latent bug that only manifests when querying those tables on Percona.

3. **`Run.pm coverage_data` iterator bug** (pre-existing in the overlay): `$run_id` is compared but never set. Preserved verbatim.

4. **`Job.pm` `*job_tries = *jobs_tries` glob alias** produces a harmless "used only once" warning at compile time. Pre-existing behavior preserved.

## Style conventions established during Phase 2 (unchanged)

See the prior revision of this file for the full style guide — unchanged. Highlights:

- File structure: package → pragmas → `our $VERSION` → `use parent 'App::Yath::Schema::DBIC::ResultBase'` → `use App::Yath::Schema::DBIC qw/.../` → `load_components` → `table` → `add_columns` → `set_primary_key` → `add_unique_constraint` → relationships → conditional Percona `inflate_column` → unconditional JSON `inflate_column` → custom methods → `1;`. No POD at bottom.
- 3-way / 4-way `do {}` branching patterns for PK/UUID/Boolean/Enum/Datetime/JSON columns (using `is_sqlite()`, `is_postgresql()`, `is_percona()`, `is_mysql()`, `is_mariadb()`).
- Relationship targets: always `App::Yath::Schema::DBIC::Result::Foo`.
- `belongs_to` attrs: uniform `is_deferrable => 0, on_update => "NO ACTION"`.

## How to pick up from here

1. Verify working tree is clean: `git status`
2. Verify smoke test still passes (command above)
3. Verify `t/0-load_all.t` still passes: `YATH_SCHEMA_DRIVER=SQLite prove -Ilib t/0-load_all.t`
4. Read this file and the plan (`docs/superpowers/plans/2026-04-11-schema-dbic-unification.md`) — Phase 6 sections
5. Dispatch subagent for Phase 6 Task 23 (`App::Yath::Test::DBIC::Database` helper).
