# AGENTS.md

This project is a ground-up rewrite of yath 2.0. Everything ships in a
single distribution (`Test2-Harness2`), with a separation of concerns
expressed through two namespaces:

- **`Test2::Harness2`** owns **producing results**. Running tests,
  driving the collector pipeline, schedulers, launchers, recorders,
  preloads, and the harness database. Perl API only; no user
  interface lives here.
- **`App::Yath2`** owns **the user interface**: parsing user input
  and feeding tests-to-run into `Test2::Harness2`, plus formatting
  and displaying results (live render, archived render, querying
  past runs).

Both namespaces live under `lib/` in this repository and ship in the
same CPAN distribution. The split is a code-level separation of
concerns, not a distribution boundary.

The `yath` script itself comes from `App::Yath::Script` (an external
module that discovers and loads our `App::Yath2` implementation).
This distribution does not ship its own `yath` binary.

## How work happens

The project is **driven by the user, not by an AI plan**. There is no
multi-stage staged backlog; agents do not pick what to do next.
Instead, the flow is:

- The user writes stubs / comments / pseudo-code and asks an agent to
  flesh out a specific piece.
- The user asks an agent to grab a specific component from a previous
  iteration under `reference/` and adapt it.
- The user asks targeted questions, requests reviews, or requests
  follow-up edits.

Agents respond to those specific asks and stop. Do not invent
follow-up work, do not expand scope, do not draft staged plans. When
an ask is ambiguous, ask back before guessing.

You are an expert Perl developer. Write code following the patterns
and styles of "Exodist" (Chad Granum) as seen throughout this
codebase.

## Reference trees

- `reference/legacy/` — yath 1.0. Reference only.
- `reference/old2/` — earlier 2.0 attempt. Reference only. The
  collector implementation here is simpler than `old3`'s.
- `reference/old3/` — `IPC::Manager`-based attempt. Reference only.
  Most utility code (parsers, auditor, resources, directives,
  JSON / Zstd / EventEmitter helpers, TestFile, schema SQL) was
  originally intended to be copied (or copied-and-adapted) from here.
- `reference/old4/` — most recent attempt prior to this restart.
- `reference/botched/` — failed refactor attempt. Reference only.

**Never modify anything under `reference/`.** Copy out, modify the
copy. The reference trees are immutable history we read against.

When borrowing, `reference/old3` and `reference/old4` are usually the
right starting points. If a reference's behavior conflicts with
`ARCHITECTURE.md` or `STYLE_GUIDE.md`, the current docs win — flag
the conflict if it is non-trivial.

## Canonical sources of truth

1. **`ARCHITECTURE.md`** — Authoritative spec for the rewrite. Grown
   incrementally as architecture is decided.
2. **`STYLE_GUIDE.md`** — Style, formatting, and language-feature
   rules for code in this repository.
3. **`STYLE_GUIDE_AGENT_CHECKLIST.md`** — Self-audit checklist agents
   walk through every touched file before handing changes back to
   the user. Mirrors `STYLE_GUIDE.md` and the pre-review checks
   below.
4. **This file (`AGENTS.md`)** — Per-repository agent / contributor
   workflow, pre-review checks, and project conventions that are
   not pure style.

If you are about to implement something that seems to conflict with
`ARCHITECTURE.md`, stop and verify. The most common cause is that
the other document is stale — follow `ARCHITECTURE.md` and flag the
inconsistency.

## Pre-review checks

Before handing changes back to the user for review, run the following
passes against every file the branch touched (typically
`git diff --name-only $base...HEAD`, where `$base` is your merge
base — `origin/master`, `origin/main`, or whatever branch you cut
from). Resolve anything they turn up, then re-run the test suite.

1. **Style-guide pass.** Walk
   `STYLE_GUIDE_AGENT_CHECKLIST.md` against every touched file.
   Common slips: `eval` patterns (always check the return value,
   never raw `$@`), `croak` vs `die`, `//=` for defaults,
   `Time::HiRes::sleep` for sub-second waits, `Object::HashBase`
   slot ordering, read-only attributes using `<attr` not `-attr`, no
   trailing whitespace, and the "named subs in object modules must be
   methods, not functions" rule (see `STYLE_GUIDE.md` "Naming and
   structure"). Run `perl agent_scripts/audit-methods-not-functions lib`
   and `perl agent_scripts/audit-readonly-attrs lib` and resolve every
   reported hit. These automated gates are mandatory because the
   equivalent manual checklist items get skipped under pressure -- a hit
   from either script is a hard stop, not a judgment call.

2. **POD pass.** Verify the file follows the POD layout in
   `STYLE_GUIDE.md` ("POD" section): `NAME` / `DESCRIPTION` /
   `SYNOPSIS` (plus `ATTRIBUTES` for HashBase-style classes) at the
   top of the file, `EXPORTS` / `PUBLIC METHODS` / `PRIVATE METHODS`
   inline above each sub, `SOURCE` / `MAINTAINERS` / `AUTHORS` /
   `COPYRIGHT` under `__END__`. Run `podchecker` on every `.pm`
   touched; resolve every error and warning.

3. **Util / role / base-class reuse pass.** Re-scan touched files
   for logic that already exists as a utility. The relevant homes
   are `Test2::Harness2::Util`, `Test2::Harness2::Util::*`,
   `Test2::Harness2::Role::*`, and the matching DB row classes. If
   the file open-codes something a util / role / base class
   already provides, switch to using it. If you see the same logic
   appearing in three or more places across the touched files,
   extract it to a util / role / base class instead of leaving the
   duplication.

These three passes are mandatory, not optional. Land their fixups
either as cleanup commits or by amending the relevant feature
commits. Only after they pass should you announce the work as
ready for review.

## AI task documentation

`AI_DOCS/` is for durable context that the code and commit history
cannot carry on their own. Default: **do not** write one. Only write
an AI_DOC when the task falls into one of these categories:

- A significant new feature.
- An architectural change (process topology, schema layout, service
  lifecycle, collector contract, recorder contract, preload
  mechanism, etc.).
- A non-trivial refactor that changes module boundaries, public
  interfaces, or coding patterns across multiple files.

Do **not** write an AI_DOC for:

- Bug fixes. If the fix directly contradicts or extends what an
  existing AI_DOC or `ARCHITECTURE.md` section already says, update
  that document in place. Otherwise the commit message is the only
  record.
- Test-only work (adding tests, fixing flakes, test refactors).
  Commit messages only.
- Trivial cleanups (typos, whitespace, perltidy passes, comment
  tweaks).

When an AI_DOC is warranted, it should describe:

- What the task was and what triggered it.
- Decisions made, including alternatives considered and why they
  were rejected.
- Any architectural changes introduced.

Filename convention: `AI_DOCS/<YYYY-MM-DD>-<short-slug>.md`.

Any decision to deviate from `ARCHITECTURE.md` must **also** be
recorded as an addendum section appended to `ARCHITECTURE.md`
itself, explaining and justifying the deviation. `ARCHITECTURE.md`
remains the authoritative spec; addenda exist so anyone reading it
sees the deviation and its reasoning in one place. This rule applies
regardless of whether an AI_DOC is also written.

### Referencing AI docs from code

User-facing text — POD, command `description` / `summary` / help
output, `die` / `warn` / `croak` / `print` strings, and any other
diagnostic shown to users — must **never** reference any `.md`
document (including `ARCHITECTURE.md`, `STYLE_GUIDE.md`,
`STYLE_GUIDE_AGENT_CHECKLIST.md`, `AI_DOCS/*`, this file, etc.). If
the rule or behavior matters to the user, restate it in plain prose;
if it does not, drop the reference. Users cannot read internal
documentation and should not be pointed at it. POD is user-facing —
see `STYLE_GUIDE.md` "POD style".

Regular `#` comments in code may reference `ARCHITECTURE.md` or
`STYLE_GUIDE.md` (both tracked, both authoritative). References to
`AI_DOCS/*` or other markdown files are **discouraged** and should
only appear when the comment cannot stand on its own without one.
When a reference is included, it must be specific: full path plus
a section identifier. A bare token like `D6` or `M2 step 4+5` is
not acceptable.

When in doubt, restate the rule itself in the comment and skip the
reference.

## Testing

While the harness is being rebuilt and is not yet self-hosting, tests
run via:

```
prove -Ilib -j16 -r t/
```

Eventually yath will be self-hosting and the runner moves to:

```
yath test -D -j24 [files...]
```

The `yath` script comes from `App::Yath::Script` (see top of file);
this distribution does not ship its own `yath` binary.

Test layout:

- `t/` — human-authored tests.
- `t/scripts/` — helper scripts invoked by human-authored tests.
- `t/AI/` — AI-generated tests. Mirror whatever subdirectory layout
  `t/` uses (e.g. `t/unit/Collector.t` ↔ `t/AI/unit/Collector.t`).
- `t/AI/scripts/` — helper scripts invoked by AI-generated tests.
- Tests copied from `reference/` count as human-authored even when
  the copy is done by AI.

It is OK to add throwaway scripts under `agent_scripts/` to verify
in-progress functionality. Anything an agent (human- or AI-driven)
needs as standalone tooling — auditors, finders, stage verification
helpers — lives in `agent_scripts/`. These scripts are not part of
the shipped distribution.

## Style

See `STYLE_GUIDE.md`. Pay particular attention to the `eval`
patterns — agents frequently get them wrong. The checklist at
`STYLE_GUIDE_AGENT_CHECKLIST.md` is the self-audit form of the
guide; walk it before declaring work ready for review.

## Dependency rules

- `Test2::Harness2` must not load `App::Yath2*` modules directly.
  Dynamic loading is acceptable only when driven by user-provided
  options that explicitly request `App::Yath2*` functionality.
- Hard-required CPAN deps for `Test2::Harness2` /
  `Test2::Formatter::Stream2` are fine. Non-default database
  drivers (Postgres, MySQL, MariaDB, Percona) are loaded only when
  the caller points the harness at a matching DSN, so their
  `DBD::*` modules must be Suggests / Recommends in `dist.ini`,
  not hard requirements.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has
  not yet been pushed to origin, amend that commit instead of
  creating a new one.

## Worktrees

- Significant work requires a worktree. Place worktrees in
  `worktrees/`.
- Documentation-only work (editing `ARCHITECTURE.md`, `STYLE_GUIDE.md`,
  this file, etc.) does not require a worktree.
- Always integrate a worktree's branch with a merge commit
  (`git merge --no-ff`), never a fast-forward. The merge commit is the
  record that a discrete piece of work landed; preserve it even when the
  target branch has not advanced.

## Architecture quick-reference

The full spec lives in `ARCHITECTURE.md`. Foundational rules an agent
must internalise before writing any code (all are documented in
`ARCHITECTURE.md` §2):

- **`Object::HashBase` for objects; `Role::Tiny` for roles.** They
  compose — `Object::HashBase` may be used inside roles and used by
  consumers of roles that use it.
- **`parent` for inheritance, not `base`.**
- **`Test2::Util::UUID` for UUIDs** (v7; generated in Perl, not in
  the database).
- **No `DBIx::Class`** for the harness's row layer. SQL via DBI
  (optionally aided by `SQL::Abstract`).
- **`DBD::SQLite` directly for the default backend.** `DBIx::QuickDB`
  is for ephemeral test setups and non-default flavors; never for
  the default SQLite path.
- **No `IPC::Manager`.** Earlier iterations relied on it; the new
  architecture does not. Cross-process state goes through the
  harness database; transient bytes between processes go through
  `Atomic::Pipe`. If a reference doc or piece of `reference/` code
  calls for `IPC::Manager`, treat that as outdated.
- **Reference trees are immutable.** Copy out, modify the copy.
