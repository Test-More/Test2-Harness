# DBIx::QuickORM schema layer

Date: 2026-05-26
Branch: `dbix_quickorm`

## Task and trigger

The rewrite needed its database/row layer decided. The user directed that
`Test2::Harness2` will use `DBIx::QuickORM` going forward, with a
`Test2::Harness2::Schema` module that is "super simple, no database
credentials built-in, everything automatic, automatic types for JSON,
UUID, and DateTime." This reverses the earlier `ARCHITECTURE.md` §2.3
decision (hand-written SQL on `DBI`, no `DBIx::Class`).

## Decision

Adopt `DBIx::QuickORM` as the row layer. `Test2::Harness2::Schema` defines
a QuickORM `orm` named `harness` with **no database**. The schema is built
by `autofill` (live-database introspection), which runs lazily the first
time a connection is made. `autotype 'JSON'`, `autotype 'UUID'`, and
`autotype 'DateTime'` apply the built-in inflate/deflate types
automatically; `autorow 'Test2::Harness2::Schema::Row'` generates a row
class per table (loading a hand-written
`Test2::Harness2::Schema::Row::<Table>` if one exists).

No credentials live in the module. Following QuickORM's "schema with no
database, add a connect callback later" recipe, the caller attaches a `db`
with a `connect` callback (and `dialect` / `db_name`) at runtime, then asks
for `->connection`.

`share/schema/<flavor>.sql` remains the table-creation source of truth (all
flavors move together); autofill only reads what that DDL produced and
never creates tables. UUID values the harness inserts are still generated
in Perl with `Test2::Util::UUID` (v7); QuickORM's UUID type only converts
stored values to/from canonical form (§2.2 unchanged).

## Alternatives considered

- **Hand-written SQL on `DBI`** (the original §2.3). Rejected: it spreads
  inflate/deflate logic across hand-maintained row classes that must be
  kept in sync with the DDL by hand.
- **Manual QuickORM schema** (define every table/column in the DSL, let
  QuickORM emit DDL). Rejected for now: `share/schema/<flavor>.sql` stays
  the DDL source of truth, so tables are never hand-defined in QuickORM;
  autofill against the applied DDL avoids a second schema definition.
- **`quick()` wrapper** (QuickORM's zero-definition live-introspection
  entry point). Rejected: it leaves no named `orm`/schema entity to grow
  onto, and the user chose the connect-callback recipe, which wants a
  defined `orm` with a deferred `db`.

## Topology

```
share/schema/<flavor>.sql   -- DDL, creates tables (all flavors together)
            |
            v  (applied to the database out of band)
Test2::Harness2::Schema      -- orm 'harness', no db, autofill { autotype...; autorow }
            |
   caller attaches db(connect => sub { fresh dbh }, dialect, db_name)
            |
            v
   $orm->connection            -- autofill introspects the live db here
            |
   Test2::Harness2::Schema::Row::<Table>  -- generated row classes
```

## Documentation changes

- `ARCHITECTURE.md` §2.3 rewritten; deviation recorded as addendum §7.1.
- `AGENTS.md` architecture quick-reference bullet updated.
- `dist.ini` added with `DBIx::QuickORM` as a hard requirement and
  non-default `DBD::*` drivers as RuntimeRecommends.

## Implementation notes (gotchas)

- Consumers get a `qorm()` accessor (QuickORM's default export name), not
  `orm()`. Fetch the ORM with `qorm(orm => 'harness')`.
- The builders imported via `use DBIx::QuickORM only => [...]` carry no
  `(&)` prototype, so the `db { ... }` block sugar does not parse; use the
  explicit `db(sub { ... })` form.
- SQLite connections require `db_name` (the database file path) on the
  `db`, even when a `connect` callback supplies the handle.
