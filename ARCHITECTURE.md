# ARCHITECTURE.md

Authoritative architectural spec for the `Test2::Harness2` rewrite.

This document is **grown as work lands**. It only describes architecture
that has been decided and committed. Speculative future sections do not
belong here — when in doubt, leave the section out until the work that
forces the decision arrives.

Style and formatting rules live in `STYLE_GUIDE.md`. Per-agent /
contributor preferences live in `AGENTS.md`. This file owns process
topology, module boundaries, contracts between subsystems, on-wire
formats, and any other decisions that constrain how the code fits
together.

## Conventions for this document

- **Add sections only for committed architecture.** A subsystem belongs
  here once its shape is stable enough that other code is built against
  it. Work-in-progress designs live in `AI_DOCS/<date>-<slug>.md` (or in
  agent / human notes) until the design lands.
- **Section numbering may be reserved.** When a major subsystem is
  known to be coming but not yet designed, a numbered stub with a
  one-line "TBD" placeholder is acceptable so cross-references stay
  stable. Do not pre-fill speculative content.
- **Deviations are recorded in-place.** If something ships that
  contradicts an existing section here, append an addendum section to
  this document explaining and justifying the deviation. The
  authoritative spec stays in one place.
- **User-facing strings never reference this file.** POD, command
  help, and diagnostic strings restate the relevant rule in plain
  prose instead of pointing at internal docs. `STYLE_GUIDE.md`
  ("POD style") and `AGENTS.md` ("Referencing AI docs from code")
  cover this in detail.
- **Regular code comments may cite this file**, with a specific section
  identifier (e.g. `# See ARCHITECTURE.md §2 "Foundational rules"`).
  Bare tokens like `D6` or `step 4+5` are not acceptable.

## 1. Project scope

This is the in-progress 2.0 rewrite of yath. Everything ships in a
single distribution (`Test2-Harness2`), split across two namespaces
by concern:

- **`Test2::Harness2`** owns **producing results**: running tests,
  driving the collector pipeline, schedulers, launchers, recorders,
  preloads, and the harness database (results recorded to disk and
  to the DB).
- **`App::Yath2`** owns **the user interface**: parsing user input,
  feeding tests-to-run into `Test2::Harness2`, and formatting /
  displaying results (live render, archived render, querying past
  runs against the harness database).

Both namespaces live under `lib/` in this repository and ship as
parts of the same distribution. The split is a code-level
separation of concerns; it is not a distribution boundary and not a
process boundary. `App::Yath2` consumes `Test2::Harness2` through
its public API; `Test2::Harness2` knows nothing about `App::Yath2`.

The `yath` command itself is provided by `App::Yath::Script` (an
external module that discovers and loads our `App::Yath2`
implementation). This distribution does not ship its own `yath`
binary.

The harness database owned by `Test2::Harness2` *is* the archive.
There is no separate log-archive layer or pluggable DB-backend layer
beneath the schema; persistence is the schema, and tooling (every
read path in `App::Yath2`) reads it directly.

## 2. Foundational rules

These are non-negotiable. New code must follow them; any future
exception must be recorded as an addendum to this document.

### 2.1 Object orientation

- Objects use `Object::HashBase`.
- Roles use `Role::Tiny` / `Role::Tiny::With`.
- Inheritance uses `parent`, not `base`.
- `Object::HashBase` and `Role::Tiny` compose freely — `Object::HashBase`
  may be used inside roles and by classes that consume roles. Do not
  reach for a heavier framework around an imagined incompatibility.

Style rules tied to object orientation (slot ordering, "named subs in
object modules must be methods, not functions", and the rest) are in
`STYLE_GUIDE.md`.

### 2.2 UUIDs

UUIDs are generated in Perl, using `Test2::Util::UUID`, never in the
database. They are v7; do not re-pack bits for index locality — v7 is
already time-ordered.

### 2.3 Databases

- The row layer is **`DBIx::QuickORM`**. The schema is a QuickORM `orm`
  that builds itself from the live database via `autofill` (introspection);
  `autotype` inflates/deflates JSON, UUID, and DateTime columns
  automatically, and `autorow` generates a row class per table under
  `Test2::Harness2::Schema::Row::` (a hand-written
  `Test2::Harness2::Schema::Row::<Table>` is loaded if present).
  `DBIx::Class` is **not** used.
- The default backend is SQLite via `DBD::SQLite`.
- Non-default flavors (Postgres, MySQL, MariaDB, Percona) are
  driver-loaded on demand; their `DBD::*` modules are Suggests /
  Recommends in `dist.ini`, never hard requires.
- The schema module (`Test2::Harness2::Schema`) bakes in **no credentials**
  and no database. The caller attaches a database with a `connect`
  callback at runtime, then asks for the connection; autofill runs lazily
  on first connect. UUID values are still generated in Perl
  (`Test2::Util::UUID`, v7 — see §2.2); the QuickORM UUID type only
  converts stored values to and from their canonical form.
- Table creation lives at `share/schema/<flavor>.sql`. All flavors move
  together: every DDL change touches every flavor file in the same
  commit. Autofill introspects the database **after** that DDL has been
  applied; QuickORM never creates tables.
- `DBIx::QuickDB` is used for ephemeral test databases and for spinning
  up non-default flavors on the fly. It is **not** used for the default
  SQLite path.

### 2.4 No `IPC::Manager`

Earlier rewrite attempts (`reference/old3` in particular) routed
cross-process coordination through `IPC::Manager`. That layer turned
out to be too bulky for the shape of work the harness does. The new
architecture **does not use `IPC::Manager`**.

If a reference doc, a design note, or a snippet of `reference/` code
calls for `IPC::Manager`, treat that as outdated and follow this
document instead. The positive replacement (which transport carries
what) will be specified in the relevant §4 subsystem section once
the design lands.

### 2.5 Minimum Perl version

The harness targets **Perl 5.38.0** (released 2023-07-02) as its
floor. Every shipped module starts with `use v5.38;`, which enables
`strict`, `warnings`, and the stable `signatures` feature in one
line.

Capabilities the codebase may rely on at this floor:

- Subroutine signatures became stable in Perl 5.36 (2022-05-28).
  5.36 dropped the `experimental::signatures` warning, so no
  `no warnings 'experimental::signatures'` incantation is needed.
- 5.38 added `//=` and `||=` default-value operators inside
  signatures. `sub foo ($x //= compute())` applies the default when
  the argument is missing **or** undef; `||=` applies it when the
  argument is missing or falsy. Plain `=` continues to apply the
  default only when the argument is missing.

`STYLE_GUIDE.md` ("Minimum Perl and subroutine signatures") owns the
usage rule: signatures are mandatory for every named sub, method,
and anonymous sub whose argument handling fits within what
signatures support; fall back to `@_` only when signatures cannot
express the call shape.

### 2.6 Reference trees are immutable

`reference/` holds prior iterations (`legacy/`, `old2/`, `old3/`,
`old4/`, `botched/`) for reading. Nothing under `reference/` is
edited in place. When borrowing, copy out and modify the copy.
`reference/old3` and `reference/old4` are the most recent and usually
the right starting point for "how did this used to work" questions;
when their answer conflicts with this document, this document wins
and the conflict gets flagged.

## 3. Repository layout

Top-level layout that architecture depends on:

- `lib/Test2/Harness2/` — harness library code.
- `lib/Test2/Harness2/Util/` — leaf utility modules.
- `lib/Test2/Harness2/Role/` — `Role::Tiny` roles consumed by harness
  code.
- `share/schema/<flavor>.sql` — schema definitions, one file per DB
  flavor. All flavors move together.
- `t/` — human-authored tests.
- `t/AI/` — AI-generated tests, mirroring `t/`'s subdirectory layout.
- `reference/` — historical iterations; immutable, see §2.5.
- `AI_DOCS/<YYYY-MM-DD>-<slug>.md` — durable context for non-trivial
  decisions that the code and commit history cannot carry alone.

## 4. Subsystems

Subsystem sections land here as their architecture is decided. Each
section should describe:

1. The subsystem's responsibility and where it lives in `lib/`.
2. The contract it exposes to the rest of the harness (constructor
   arguments, public methods, events, schema rows, on-wire bytes —
   whichever apply).
3. Invariants the subsystem promises to its callers, and invariants it
   relies on from its inputs.
4. Failure modes and how they surface (return codes, recorded events,
   thrown exceptions).

Subsections will be numbered `4.1`, `4.2`, … in the order they are
designed. Numbering is stable once assigned; if a subsystem is
removed, its number is retired, not reused.

### 4.1 Harness control and runner (Part 1)

**Responsibility / location.** `Test2::Harness2` (`lib/Test2/Harness2.pm`)
is the public entry point for producing results: it bootstraps the SQLite
database from `share/schema/sqlite.sql`, hands out a `DBIx::QuickORM`
connection, starts runners, queues runs, and cleans up. `Test2::Harness2::Runner`
(`lib/Test2/Harness2/Runner.pm`) is the long-lived process that executes a
run's jobs; it consumes `Test2::Harness2::Role::Service`
(`lib/Test2/Harness2/Role/Service.pm`) for its tick loop and uses
`Test2::Harness2::Scheduler` (`lib/Test2/Harness2/Scheduler.pm`) to pick the
next job and decide retries. The `App::Yath2` side
(`lib/App/Yath2.pm`, `lib/App/Yath2/Command/test.pm`,
`lib/App/Yath/Script/V2.pm`) is the user interface that drives this API.

**Contract.** `Test2::Harness2->new(db_path => ... | connect => ...)` then
`->initialize` (load DDL), `->connection`, `->start_runner(%opt)` →
`runner_uuid`, `->queue_run(runner_uuid => ..., files => [...])` → `run_uuid`,
`->set_runner_mode($runner_uuid, 'run'|'stop'|'kill')`, and
`->finalize_run($run_uuid)`. Cross-process state lives entirely in the harness
database; there is no socket/IPC layer (see §2.4). The runner is wrapped by a
`Test2::Harness2::Collector`: only the collector process holds the `collector`
row, while the runner process owns its `runner` + `service` rows (sharing one
UUID). Each test job runs under its own collector with
`Test2::Harness2::Collector::Auditor::Test` wired in as the collector's
`processor`; the auditor writes the `try` verdict, the scheduler resolves
`job.passed`, and the runner sets `run.passed` / `run.stopped`.

**Invariants.** Tests run one at a time per runner in Part 1
(fork + exec + waitpid). Every forked process opens its **own** DBI handle —
handles are never shared across a fork (`Test2::Harness2::connection` is
pid-aware and reconnects when it detects a fork). The runner observes its
`service.mode` each tick: `stop` drains outstanding work then exits, `kill`
terminates running collectors then exits.

**Failure modes.** A test that dies, times out, or whose collector fails
becomes a non-zero collector exit; the runner reaps it and the scheduler
resolves the job from its try rows (an unset verdict counts as not-passed),
rather than hanging the runner. Forked children are eval-guarded so they
always terminate via `POSIX::_exit` rather than unwinding into the parent.

*(Later subsystems — preloads, resource scheduling, renderers, non-default DB
flavors — will be numbered 4.2, 4.3, … as they are designed.)*

## 5. Cross-cutting concerns

Reserved for things that cut across multiple subsystems once more than
one exists — wire formats shared between processes, error / event
taxonomies, shutdown ordering, schema migration policy, and similar.

*(Empty until the first cross-cutting concern lands.)*

## 6. Open questions

Reserved for architectural questions that have been raised but not yet
resolved. Each entry should name the question, link to the work
forcing the decision, and note who is expected to answer it. Resolved
entries move into the relevant numbered section above and are removed
from this list.

*(Empty.)*

## 7. Addenda

In-place record of decisions that superseded earlier committed
architecture. The numbered sections above are kept current; these entries
preserve what changed and why.

### 7.1 Row layer: `DBIx::QuickORM` supersedes hand-written SQL (2026-05-26)

§2.3 originally specified the row layer as **hand-written SQL on `DBI`**
(optionally aided by `SQL::Abstract`), with an explicit "`DBIx::Class` is
not used" rule and hand-maintained row code. That has been superseded:
the row layer is now **`DBIx::QuickORM`**, and §2.3 has been rewritten to
match.

Reasoning:

- A single declarative source handles inflate/deflate for JSON, UUID, and
  DateTime (`autotype`) instead of repeating that logic across
  hand-written row classes.
- `autofill` introspects the live database, so there are no hand-written
  row classes to keep in sync with the DDL. `share/schema/<flavor>.sql`
  remains the table-creation source of truth; QuickORM only reads what it
  produced.
- The schema carries no credentials: a `connect` callback is attached at
  runtime, matching how the harness builds its own database handles.
- `DBIx::QuickORM` is maintained in-house, so the harness's needs can
  drive it directly.

Unchanged by this decision: §2.2 (UUIDs generated in Perl with
`Test2::Util::UUID`, v7), the SQLite-via-`DBD::SQLite` default, non-default
`DBD::*` drivers as Suggests / Recommends, and `DBIx::QuickDB` for
ephemeral test databases only.

### 7.2 Part 1 ships SQLite DDL only (2026-05-27)

§2.3 requires that all flavors move together: every DDL change touches every
flavor file in the same commit. Part 1 of the rewrite ships **only**
`share/schema/sqlite.sql`; the PostgreSQL / MySQL / MariaDB / Percona flavor
files are deliberately deferred, matching the Part 1 scope of "only SQLite for
now."

Reasoning: Part 1 exercises only the default SQLite path end to end. Writing
and maintaining four additional DDL files before any code drives them would be
speculative. When a non-default flavor is implemented, its
`share/schema/<flavor>.sql` file is added and the "move together" rule applies
from that point forward.

Reserved-word audit (done up front to keep the SQLite DDL portable):
- `user` table renamed to `account` (USER is reserved in PostgreSQL, MySQL,
  MariaDB, and the SQL standard).
- `collector.signal` renamed to `exit_signal` (SIGNAL is reserved in
  MySQL/MariaDB as the SIGNAL statement).
- `collector.error_code` renamed to `exit_code` for naming consistency with
  `exit_signal`.

When a new table or column is added in any flavor file, audit the name against
the reserved-word lists for every supported flavor and prefer an unreserved
alternative over a quoted-identifier workaround.
