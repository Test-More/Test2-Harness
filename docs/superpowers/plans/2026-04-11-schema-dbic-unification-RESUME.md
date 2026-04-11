# Schema DBIC Unification — Resume State

**Last updated:** 2026-04-11 (mid-session save)
**Branch:** `2.0`
**Last commit before save:** `188adbeaa feat(schema): add DBIC connection modules and wire up load_namespaces`
**Working tree:** clean

## Where to resume

Phase 5 (consumer updates) is next. About to dispatch a subagent for Task 17 (schema-adjacent modules: Util, Sync, Sweeper, RunProcessor, Importer, ImportModes, Queries, Config, DateTimeFormat).

Read `docs/superpowers/plans/2026-04-11-schema-dbic-unification.md` for the original plan. **The plan is OBSOLETE for Phases 2, 3, and 4** — see pivot note below. **The plan is still the source of truth for Phases 5, 6, and 7.**

## Critical pivot

The user rejected the auto-generator approach mid-Phase 2. Instead of using `regen_schema.pl` + the parser/merger/emitter helpers to generate Result classes, they are hand-maintained. `author_tools/regen_schema.pl` and the `author_tools/lib/Yath/Regen/DBIC/*` helpers have been deleted (commit `1a70dd29e`). The unified Result files also have NO `# >>> BEGIN/END GENERATED <<<` markers — they are normal hand-maintained Perl modules.

## What is done

### Phase 1 (Foundation)
- `lib/App/Yath/Schema/DBIC.pm` — schema class with exportable helpers (`is_sqlite`, `is_postgresql`, `is_mysql`, `is_mariadb`, `is_percona`, `can_store_null_character`, `format_uuid_for_db`, `format_uuid_for_app`). Method-form works too. Wired up with `load_namespaces` and the `$LOADED` guard.
- `lib/App/Yath/Schema/DBIC/ResultBase.pm` — verbatim copy of the old ResultBase under new namespace.
- `lib/App/Yath/Schema/DBIC/ResultSet.pm` — verbatim copy with internals updated. Imports `format_uuid_for_db` directly from `App::Yath::Schema::DBIC`.
- `t/unit/App/Yath/Schema/DBIC.t` — 19 tests, all passing.

### Phase 2 (hand-migration)
All 29 unified Result classes written at `lib/App/Yath/Schema/DBIC/Result/<Name>.pm`:
ApiKey, Binary, Config, Coverage, CoverageManager, Email, EmailVerificationCode, Event, Host, Job, JobTry, JobTryField, LogFile, Permission, PrimaryEmail, Project, Reporting, Resource, ResourceType, Run, RunField, Session, SessionHost, SourceFile, SourceSub, Sweep, TestFile, User, Version.

Five connection modules:
- `lib/App/Yath/Schema/DBIC/SQLite.pm`, `PostgreSQL.pm`, `MySQL.pm`, `MariaDB.pm`, `Percona.pm`

**End-to-end smoke test passed:** each of the 5 connection modules, when loaded, successfully triggers `load_namespaces` and registers all 29 sources. Run this to re-verify:
```
for driver in SQLite PostgreSQL MySQL MariaDB Percona; do
  perl -Ilib -e 'use App::Yath::Schema::DBIC::'$driver'; my @s = sort App::Yath::Schema::DBIC->sources; print "Driver='$driver' sources=", scalar(@s), "\n"'
done
```
Expected: each line prints `sources=29`.

### Key commits (most recent first)
- `188adbeaa` — DBIC connection modules + load_namespaces
- `b83f219f6` — Result classes for Coverage, CoverageManager, Resource, ResourceType, Reporting, SourceFile, SourceSub (Batch E)
- `8aec092ce` — Result classes for Job, JobTry, JobTryField, Event, LogFile (Batch D)
- `639a7a5e5` — Result classes for Run, RunField, Sweep, Version, TestFile (Batch C)
- `191bd7795` — Result classes for Host, Permission, Project, Session, SessionHost (Batch B)
- `b59002576` — Result classes for ApiKey, Binary, Email, EmailVerificationCode, PrimaryEmail (Batch A)
- `70fe19d5b` — Config.pm and User.pm (pattern reference)
- `1a70dd29e` — **THE PIVOT:** remove regen_schema.pl and pivot to hand-maintained Result classes
- `d1d973d63` — DBIC::ResultBase and DBIC::ResultSet
- `bfdebb500` — method-form helpers
- `f9c4ff2e9` — initial DBIC.pm with exportable helpers
- `eaa418f52` — implementation plan
- `ab3052d96` — design spec

## What is NOT done

### Phase 5 — Consumer updates (next)
Every file outside `lib/App/Yath/Schema/DBIC/` that references the old schema namespace needs its references rewritten. Four substitution categories:
1. `App::Yath::Schema::Result::` → `App::Yath::Schema::DBIC::Result::`
2. `App::Yath::Schema::ResultBase` → `App::Yath::Schema::DBIC::ResultBase`
3. `App::Yath::Schema::ResultSet` → `App::Yath::Schema::DBIC::ResultSet`
4. `App::Yath::Schema::(SQLite|PostgreSQL|MySQL|MariaDB|Percona)` → `App::Yath::Schema::DBIC::$1`
5. `$App::Yath::Schema::LOADED` → `$App::Yath::Schema::DBIC::LOADED`
6. Bare `use App::Yath::Schema;` / `use base 'App::Yath::Schema';` → `App::Yath::Schema::DBIC` **but NOT** `App::Yath::Schema::Util`, `::Sync`, `::Sweeper`, `::RunProcessor`, `::Importer`, `::ImportModes`, `::Queries`, `::Config`, `::DateTimeFormat` — those keep their current names.

**Task 17** — Schema-adjacent modules that keep their names but have internals rewritten:
- `lib/App/Yath/Schema/Util.pm`, `Sync.pm`, `Sweeper.pm`, `RunProcessor.pm`, `Importer.pm`, `ImportModes.pm`, `Queries.pm`, `Config.pm`, `DateTimeFormat.pm`

**Task 18** — Server / renderer / plugin layer:
- `lib/App/Yath/Server.pm`, `Server/Request.pm`, `Server/Controller/*.pm` (9 files), `Renderer/Server.pm`, `Renderer/DB.pm`, `Plugin/DB.pm`, `Options/DB.pm`

**Task 19** — Command layer:
- `lib/App/Yath/Command/db.pm`, `db/sync.pm`, `db/sweeper.pm`, `db/publish.pm`, `db/importer.pm`, `recent.pm`, `server.pm`

**Task 20** — Unit tests referencing Result classes:
- `t/unit/App/Yath/Schema/Result/*.t`, `t/unit/App/Yath/Schema.t`, `t/unit/App/Yath/Schema/*.t`

**Task 21** — Ancillary tests:
- `t/database/test.pl`, `t/0-load_all.t`, existing `t/integration/coverage-*.t`

**Task 22** — Full syntax sweep and load test per backend.

### Delete old trees (after Phase 5 is done)
Only safe after consumers stop referencing them. Delete:
- `lib/App/Yath/Schema.pm`
- `lib/App/Yath/Schema/ResultBase.pm`
- `lib/App/Yath/Schema/ResultSet.pm`
- `lib/App/Yath/Schema/SQLite.pm`, `PostgreSQL.pm`, `MySQL.pm`, `MariaDB.pm`, `Percona.pm`
- `lib/App/Yath/Schema/SQLite/`, `PostgreSQL/`, `MySQL/`, `MariaDB/`, `Percona/`, `Overlay/`, `Result/` (all directories and their contents)

Leave `lib/App/Yath/Schema/Table/` alone — user said to ignore it.

### Phase 6 — Test infrastructure
Per the original plan:
- `t/lib/App/Yath/Test/DBIC/Database.pm` — ephemeral DB helper wrapping `App::Yath::Server->start_ephemeral_db`
- `t/lib/App/Yath/Test/DBIC/Schema.pm` — reusable schema smoke tests
- `t/lib/App/Yath/Test/DBIC/Coverage.pm` — reusable body extracted from current coverage-*.t
- 10 shim `.t` files under `t/integration/` named `dbic-{schema,coverage}-<driver>.t`
- Delete old per-db unit tests (`t/unit/App/Yath/Schema/{SQLite,MariaDB}/*.t`), `t/UI/{PostgreSQL,MySQL}.t`, and old `t/integration/coverage-*.t`.

### Phase 7 — Validation
- Run the full test suite against each available backend
- Final grep sweep to confirm no stale references remain
- Tag `post-dbic-migration`

## Known issues flagged during Phase 2

1. **Event.nested is preserved verbatim as `smallintegernot`** (SQLite only). This is a bug in the original SQLite loader output — all other backends use `smallint`. The subagent preserved the buggy behavior to avoid making semantic changes during a structural refactor. Needs a follow-up SQL schema/migration fix; flagged in Batch D commit message area. File: `lib/App/Yath/Schema/DBIC/Result/Event.pm`.

2. **Percona UUID inflate_column inconsistency.** The old `Percona/Binary.pm` had `inflate_column` on `event_uuid`, but `Percona/ApiKey.pm`, `Percona/EmailVerificationCode.pm`, and possibly others did NOT have it for their own UUID columns. The new unified files preserve that existing inconsistency — Binary and tables that had an inflate get a conditional `if (is_percona()) { __PACKAGE__->inflate_column(...) }` block; the ones that didn't get nothing. This is likely a latent bug that only manifests when you actually query those tables on Percona. Fix: apply uniform inflate to all Percona UUID columns in a follow-up.

3. **`Run.pm coverage_data` iterator bug** (pre-existing in the overlay): a `$run_id` variable is compared but never set. Subagent preserved verbatim.

4. **`Job.pm` has a `*job_tries = *jobs_tries` glob alias** that generates a harmless "used only once" warning at compile time. Not a bug; pre-existing overlay behavior preserved.

## Style conventions established during Phase 2

For future maintenance of the unified Result classes:

- **File structure:** package → use pragmas → `our $VERSION` → `use parent 'App::Yath::Schema::DBIC::ResultBase'` → `use App::Yath::Schema::DBIC qw/.../` (only helpers actually used) → any overlay-derived `use` lines and constants → `load_components` → `table` → `add_columns` → `set_primary_key` → `add_unique_constraint` → relationships → conditional `if (is_percona()) { inflate_column(...) }` blocks if applicable → unconditional `inflate_column` for JSON columns if applicable → custom methods → trailing `1;`. No POD at bottom.
- **Branching patterns:**
  - PK: `is_sqlite() ? "integer" : "bigint"` + `(is_postgresql() ? (sequence => "<table>_<col>_seq") : ())`
  - UUID: 3-way `do {}` block — `is_percona` binary(16), `is_postgresql` uuid size=16, else uuid
  - Boolean: 3-way `do {}` — SQLite bool+`\"FALSE"`, PG boolean+`\"false"`, MySQL family tinyint+0
  - Enum: 3-way `do {}` — SQLite text + plain default, PG enum + `custom_type_name`, MySQL family enum + list
  - 4-way datetime: `do {}` — SQLite (`datetime`/`\"now"`/size 6), PG (`timestamp with time zone`/`\"current_timestamp"`), Percona (`datetime`/`CURRENT_TIMESTAMP`), MySQL/MariaDB (`timestamp`/`current_timestamp(6)`)
  - JSON column: 4-way — SQLite (json + null default), PG (jsonb), Percona (json), MySQL/MariaDB (longtext)
  - numeric vs decimal: `is_mysql() ? "decimal" : "numeric"`
  - citext: `is_postgresql() ? "citext" : "varchar"` + conditional size
- **Relationship targets:** always use `App::Yath::Schema::DBIC::Result::Foo`.
- **belongs_to attrs:** uniform `is_deferrable => 0, on_update => "NO ACTION"`. The MySQL family's `is_deferrable => 1, on_update => "RESTRICT"` values in the old files were deploy-time metadata only, ignored by runtime DBIC.
- **Unique constraint names:** SQLite's names are used as canonical — DBIC constraint names are just Perl-level identifiers, no external code references them.

## How to pick up from here

1. Verify working tree is clean: `git status`
2. Verify the five smoke-test loadables still pass (command above)
3. Read this file and the plan (`docs/superpowers/plans/2026-04-11-schema-dbic-unification.md`)
4. Dispatch subagent for Phase 5 Task 17 (schema-adjacent modules) per the plan.
