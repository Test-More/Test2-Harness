# STYLE_GUIDE_AGENT_CHECKLIST.md

A self-audit checklist for agents. Run every item against every file you
created or modified before declaring work ready for review.

### Sources of truth

This checklist mirrors three authoritative documents:

- **`STYLE_GUIDE.md`** — style, formatting, and language-feature rules.
- **`AGENTS.md`** — workflow, pre-review checks, project conventions.
- **`ARCHITECTURE.md`** — architectural constraints.

When the checklist disagrees with any of those, the source document
wins and this file gets fixed.

## How to use this checklist

1. After you finish a logical chunk of work, list the touched files:
   `git diff --name-only $base...HEAD` (replace `$base` with your
   merge base — usually `origin/master` or `origin/main`).
2. Walk this checklist top to bottom against the **full set of
   touched files**, not just `.pm` / `.t`. A change to `dist.ini`,
   schema SQL, or a script still has to pass the relevant items
   (whitespace, no-emojis, dependency rules, etc.).
3. Items scoped to a specific file type say so explicitly (e.g. "for
   every `.pm` that defines a class or role"). Skip an item only
   when its scope clearly does not match the file.
4. Re-run any automated scanners noted below.
5. Re-run the test suite after fixes.

Do not check items off without verifying — "I usually do this" is not a
verification. Open the file, look, confirm.

---

## 0. Pre-flight (run once per branch)

- [ ] `git diff --name-only origin/main...HEAD` — note the touched file set; this
      is the scope of every check below. (Replace `origin/main` with your base
      branch if different).
- [ ] `perltidy` (with the repository `.perltidyrc`) on every touched
      Perl file (`.pm`, `.pl`, `.t`, executable scripts).
- [ ] `perlcritic` (with the repository `.perlcriticrc`) on every touched
      Perl file.
- [ ] `perl agent_scripts/audit-methods-not-functions lib` — every reported hit
      is a violation of the "named subs in object modules must be methods"
      rule. Resolve all hits.
- [ ] `perl agent_scripts/audit-readonly-attrs lib` — every reported hit is a
      read-only `Object::HashBase` attribute declared with `-` instead of `<`
      (a dead throwing setter). Convert to `<`, or add a `-attr-ok` comment if
      the throwing setter is genuinely intended. Both audits scan the whole
      tree, not just touched files, so a partial edit cannot hide a hit.
- [ ] `perl agent_scripts/find-long-subs` on every touched `.pm`. Resolve hits
      where a sub exceeds 75 lines (excluding comments/POD).
- [ ] `perl agent_scripts/find-large-modules` on every touched `.pm`. Resolve hits
      where a module exceeds 1000 lines (excluding POD).
- [ ] `podchecker` on every touched `.pm`. Resolve every error and warning.
- [ ] No trailing whitespace anywhere in the diff
      (`git diff --check origin/main...HEAD`).
- [ ] No emojis introduced in code, comments, POD, commit messages, or
      diagnostic strings.

---

## 1. Object orientation

For every `.pm` that defines a class or role:

- [ ] Uses `Object::HashBase` for attributes (not `Moo`, `Moose`, manual
      `bless`, etc.).
- [ ] Uses `Role::Tiny` or `Role::Tiny::With` for roles (not `Moo::Role`,
      `Moose::Role`).
- [ ] Uses `parent` for inheritance, never `base`.
- [ ] Does not work around an imagined `Object::HashBase` + `Role::Tiny`
      incompatibility — they compose; use them together as needed.
- [ ] `HashBase` attribute slot ordering is intentional (review the
      constant list — additions go at the end unless the existing order
      has a documented reason).
- [ ] Read-only attributes use the `<attr` prefix, not `-attr`. `-attr`
      generates a throwaway `set_attr` that exists only to throw; `<attr`
      generates no setter. Grep the touched files' HashBase blocks for a
      line matching `^\s*-` and convert each to `<` unless a comment
      explains why the throwing setter is needed.

## 2. Naming and structure — "methods, not functions"

A file is an **object module** if at file scope it matches either:

- `^use Object::HashBase` (any form), or
- `^with ` (consumes a role).

In every object module:

- [ ] Every named sub defined in the package is a method. Concretely, the
      sub does at least one of:
  - `my $self = shift;` / `my $class = shift;`
  - `my ($self, ...) = @_;` / `my ($class, ...) = @_;`
  - returns a literal constant (`sub TABLE { 'users' }`,
    `sub defaults { {...} }`, `sub json_fields { qw{a b c} }`) —
    argless declarative-metadata methods are fine because callers do
    `$obj->name`.
- [ ] No function-style helpers like `sub _foo_from_bar { my ($bar) = @_; ... }`
      called as `_foo_from_bar($x)`. Rewrite as `my ($self, $bar) = @_;` and
      call as `$self->_foo_from_bar($x)`.
- [ ] Imported subs (e.g. `use Carp qw/croak/`, `use List::Util qw/first/`)
      are exempt — the rule applies only to subs *defined* in the module.
- [ ] Anonymous subs and subs assigned to a variable are exempt.
- [ ] `agent_scripts/audit-methods-not-functions lib` reports zero hits for the
      touched files.

## 3. Error handling

Search the diff for `eval`, `die`, `croak`, `$@`, `warn`, `fork`.

### `croak` vs `die`

- [ ] Errors caused by the caller (bad args, missing required params,
      operations on caller-supplied data that turn out invalid) use
      `croak`.
- [ ] Errors internal to the module (temp file the code itself created,
      invariant the caller could not control, rethrows) use `die`.
- [ ] `open` failures: caller-supplied path → `croak`; internally
      constructed path → `die`.

### `eval` patterns

- [ ] Every `eval` checks success via the **return value** of `eval`, not
      via `$@`. The block ends in `; 1 }` and is assigned/tested.
- [ ] No bare `if ($@) { ... }` style. Either `my $ok = eval { ...; 1 };`
      followed by branching on `$ok`, or one of the accepted short forms.
- [ ] Short forms permitted only when the eval block fits on a single
      source line:
  - postfix: `warn $@ unless eval { ...; 1 };`
  - block:   `unless (eval { ...; 1 }) { warn $@; exit(1); }`
  - or-form: `eval { ...; 1 } or warn $@;` — only if the eval is a single
    statement *and* the or-clause is a single statement.
  - capture-in-block:
    `unless (eval { ...; 1 }) { my $err = $@; ... }` — the conditional
    tests the eval return, and if `$@` is referenced anywhere other than
    the first statement of the block, it must be saved to a local on
    that first statement.
- [ ] Multi-line eval blocks use the three-step form:
      `my $ok = eval { ...; 1 }; my $err = $@; if ($ok) { ... } else { ... }`.
- [ ] No multi-line eval block appears inside the parens of `if`/`unless`.
- [ ] If the conditional block has any statement before `$@` is used
      (especially an inner `eval`), `$@` is saved to a local on the
      **first** statement of the block.

### Never swallow exceptions

- [ ] Every caught exception is either rethrown or warned. The string
      used in the rethrow/warn is either `$@` (when used as the very
      first reference inside the handler) or a saved local
      (`my $err = $@; ...; die $err;` / `warn $err`). Multi-step
      handlers always use the saved local so a later inner `eval`
      cannot clobber `$@`.
- [ ] The only exemptions are `viable()`-style feature detection or
      optional module loading where failure is expected — and such
      uses are obvious from context.

### `fork`

- [ ] Every `fork` uses the inline form
      `my $pid = fork // die "reason: $!";`. No separate
      `unless (defined $pid)` block afterward.
- [ ] Fork failures `die`, never `croak`.

## 4. Whitespace and formatting

- [ ] No trailing whitespace.
- [ ] No tab/space mixing introduced by the diff (perltidy will normalize;
      run it).
- [ ] No emojis.
- [ ] File ends with a single trailing newline.

## 5. Language-feature defaults

- [ ] `//=` is used for defaults instead of
      `$x = defined $x ? $x : $default;` or `$x ||= $default;` (the latter
      drops legitimate `0`/`""` values).
- [ ] "Is module installed" gating uses a constant (e.g.
      `use constant HAVE_FOO => eval { require Foo; 1 };`), not a package
      variable.

## 5a. Subroutine signatures (Perl 5.38 floor)

- [ ] Every shipped `.pm` starts with `use v5.38;` (enables `strict`,
      `warnings`, and stable `signatures` in one line). No
      `use feature 'signatures';` + `no warnings 'experimental::signatures';`
      incantations — they are unnecessary at this floor.
- [ ] Every named sub / method / anonymous sub uses a signature
      unless its argument shape genuinely cannot be expressed by
      one. Aesthetic preference for `my $self = shift;` is **not**
      a reason to skip the signature. Methods declare `$self` (or
      `$class`) as the first signature parameter.
- [ ] Default-value form matches intent:
  - `$x = $default` — applied only when the argument is missing
    (explicit `undef` is preserved).
  - `$x //= $default` — applied when the argument is missing or
    `undef`. Use this anywhere the body would otherwise do
    `$x //= $default;`.
  - `$x ||= $default` — applied when the argument is missing or
    falsy. Used sparingly; never where legitimate `0` / `""` values
    must be preserved.
- [ ] Fall back to `@_` only for genuine cases: re-dispatching
      arguments unchanged (`goto &other`, `$other->(@_)`),
      positional/key-value/flag mixes signatures cannot describe, or
      subs that peek at `wantarray` / `caller` before forwarding.
- [ ] Argless declarative-metadata methods (`sub TABLE { 'users' }`)
      may keep the empty parameter list; `sub TABLE ()` is also
      acceptable. Pick one form and stay consistent within the file.

## 6. Sub-second sleeps

- [ ] Every sub-second sleep is `Time::HiRes::sleep($secs)`.
- [ ] No `select(undef, undef, undef, $secs)` calls anywhere. If you find
      one (even outside your direct changes if you touched the file),
      replace it.
- [ ] `sleep $secs` is only used for whole-second waits.
- [ ] No `tinysleep` helper or other custom sleep wrapper.

## 7. Conditionals

- [ ] Single-statement conditional bodies use postfix form:
      `do_thing() if $cond;`, never `if ($cond) { do_thing(); }`.
- [ ] Multi-statement conditionals keep the block form.
- [ ] No conditional test expression spans more than one source line
      inside `if`/`unless`/`while`/`until` parens. If a test would be
      multi-line, refactor by either:
  - accumulating `$ok` with `&&=` / `||=` step by step before the `if`, or
  - extracting a predicate helper that returns true/false.

## 8. Lists and pushes

- [ ] Every `push` separates the target array from the values with `=>`:
  - `push @items => $thing;`
  - `push @{$ref} => @things;`
  - Never `push @items, $thing;`.

## 9. Testing libraries

- [ ] New test files under `t/` use `use Test2::V0;` — not `Test::More`
      or `Test::Simple`.
- [ ] Existing test files using `Test::More` may stay until touched; once
      touched substantively, migrate to `Test2::V0`.
- [ ] AI-generated tests live under `t/AI/` mirroring `t/`'s subdirectory
      layout (e.g. `t/unit/Foo.t` ↔ `t/AI/unit/Foo.t`).

## 10. UUIDs

- [ ] All UUID generation is in Perl, via `Test2::Util::UUID`. No SQL-side
      UUID generation.
- [ ] No bit-reordering of v7 UUIDs for "index locality" — v7 already
      orders by time of generation.

## 11. Databases

- [ ] No `DBIx::Class` usage in harness row code. Hand-written SQL on
      `DBI` only. `SQL::Abstract` is acceptable.
- [ ] Default backend stays SQLite via `DBD::SQLite` directly — *not*
      `DBIx::QuickDB`.
- [ ] `DBIx::QuickDB` only appears in test setup or non-default-flavor
      spin-up; ephemeral DB instances point at `~/dbs/` installations when
      relevant.
- [ ] Any DDL change touches every `share/schema/<flavor>.sql` file in the
      same commit. (Flavors move together.)
- [ ] Non-default DB drivers (`DBD::Pg`, `DBD::mysql`, `DBD::MariaDB`,
      Percona drivers) are Suggests/Recommends in `dist.ini`, never hard
      requires.

## 12. File organization

- [ ] One Perl namespace per file. `package Foo::Bar::Baz;` lives in
      `lib/Foo/Bar/Baz.pm`, not declared inline in `lib/Foo/Bar.pm`.
- [ ] A nested `package` that defines `sub`s or attributes is moved into
      its own file at the path mirroring its name. Exception: throwaway
      `package main;` blocks inside test scripts, or anonymous-class
      patterns.

### Sub ordering within a file

POD layout governs the outer ordering. **Within** each POD group, then:

- [ ] EXPORTS subs precede PUBLIC METHODS subs, which precede PRIVATE
      METHODS subs.
- [ ] Within each group, 1-line subs/methods are near the top of the
      group (after `use` / `BEGIN` blocks at the top of the file).
- [ ] Longer subs follow the 1-liners within the same group.
- [ ] When several subs implement the same role / interface and read
      better together, they are wrapped in a `# {{{ ... # }}}` fold and
      ordered 1-liners-first within the fold.
- [ ] No reordering across POD groups solely to put a 1-liner at the top
      of the file.

## 13. Module size

- [ ] No `.pm` exceeds **1000 lines of code** (blank lines and comments
      count; POD does not — POD = anything between `=pod`/`=head*` and
      `=cut`, plus everything after `__END__`).
- [ ] If a file crossed 1000 lines, **flag for human review**. Do not
      split silently. Do not stuff logic into POD or split via
      `do`/`require` tricks to game the limit.

## 14. Subroutine size

- [ ] No subroutine exceeds **75 lines** (signature through closing brace,
      inclusive). Code comments and POD inside the sub do not count.
- [ ] When a sub crossed 75 lines, it was broken into smaller helpers with
      names describing each step.
- [ ] Narrow exception (packed-binary encoders, hex/bit-twiddling,
      table-driven dispatch where every branch is a one-liner): if kept
      whole, a short comment explains why splitting would do more harm
      than good. Default is to split.

## 15. Comments

- [ ] Default is **no comment**. Every comment present in the diff adds
      significant value: a non-obvious *why*, a hidden constraint, a
      subtle invariant, a workaround for a specific bug, surprising
      behavior.
- [ ] No comment restates what the next line obviously does
      (`# Return 1` above `return 1;`).
- [ ] No multi-paragraph comment blocks. Long explanations belong in POD
      or `ARCHITECTURE.md`.
- [ ] Comments that reference `ARCHITECTURE.md` or `STYLE_GUIDE.md`
      include the **full path plus a specific section identifier**
      (e.g. `# See ARCHITECTURE.md §2.4 "No IPC::Manager"`). Bare
      tokens like `D6` or `step 4+5` are not acceptable.
- [ ] Comments do **not** reference `AI_DOCS/*` or other markdown files
      unless absolutely necessary; when in doubt, restate the rule.
- [ ] No transient change-history comments: task IDs, PR numbers,
      "added for the X flow", "removed Z", "fixes issue #123",
      "TODO before merge", changelog-style notes. Those belong in
      commit messages. Comments that describe a **real, durable**
      external contract or hidden consumer (e.g. "this signature is
      called by `Test2::Formatter::Stream2`") are fine; they document
      an invariant, not a change.

## 16. POD

Every shipped `.pm` must have POD. Start from `template.pod` and trim.

### Section placement

- [ ] Top of file (after `use` statements, before real work):
  - `NAME`
  - `DESCRIPTION`
  - `SYNOPSIS`
  - For HashBase-style classes, an `ATTRIBUTES` section listing slots.
- [ ] Inline POD blocks immediately above the relevant sub:
  - `EXPORTS` heading covers each exported function (POD above each).
  - `PUBLIC METHODS` heading covers each public method (POD above each).
  - `PRIVATE METHODS` heading covers each private method (leading
    underscore convention) — POD above each.
- [ ] End of file, under `__END__`:
  - `SOURCE`
  - `MAINTAINERS`
  - `AUTHORS`
  - `COPYRIGHT`
  - any other tail sections from the template.

### POD style

- [ ] POD is brief — one or two sentences describing behavior the reader
      cannot infer from the signature. No wall-of-text retelling of the
      module.
- [ ] Shared explanations live once in `DESCRIPTION`; per-method POD stays
      short rather than repeating.
- [ ] POD **never** references any `.md` document
      (`ARCHITECTURE.md`, `STYLE_GUIDE.md`,
      `STYLE_GUIDE_AGENT_CHECKLIST.md`, `AI_DOCS/*`, `AGENTS.md`,
      etc.). Restate the rule in plain prose if it matters.
- [ ] `podchecker` reports zero errors and zero warnings on every touched
      `.pm`.

## 17. User-facing strings (POD, help, diagnostics)

This applies to POD, command `description` / `summary` / help output, and
strings passed to `die` / `warn` / `croak` / `print` that a user might see.

- [ ] No user-facing string references any `.md` document. Internal docs
      are invisible to users.
- [ ] If the rule or behavior matters, it is restated in plain prose; if
      it does not, the reference is dropped entirely.

## 18. Dependency rules

- [ ] `Test2::Harness2::*` modules do not `use`/`require` any
      `App::Yath2::*` module statically. Dynamic loading of `App::Yath2*`
      is permitted only when explicitly driven by a user option.
- [ ] Non-default DB drivers (`DBD::Pg`, `DBD::mysql`, `DBD::MariaDB`,
      Percona) appear as Suggests/Recommends in `dist.ini`, not hard
      requires. Loaded lazily only when the DSN demands them.

## 19. Architectural reminders worth re-checking

Foundational architecture rules from `ARCHITECTURE.md` §2 that agents
trip on often enough to surface here:

- [ ] No `IPC::Manager` introduced anywhere. Reference iterations
      used it; the new architecture does not.
- [ ] Reference trees (`reference/legacy/`, `reference/old2/`,
      `reference/old3/`, `reference/old4/`, `reference/botched/`) are
      not modified in place. Borrow by copying out.

---

## Final pass before announcing "ready for review"

- [ ] All three mandatory pre-review checks from `AGENTS.md`
      ("Pre-review checks") ran clean:
  - Style-guide pass (this checklist).
  - POD pass (`podchecker` clean on every touched `.pm`).
  - Util/role/base-class reuse pass: re-scanned touched files for logic
    that already exists in `Test2::Harness2::Util*`,
    `Test2::Harness2::Role::*`, or a relevant base class. Switched to
    the existing helper where applicable. Extracted shared logic when
    the same code appeared in three or more touched files.
- [ ] Test suite re-run after fixups; nothing regressed.
- [ ] Commits are split per logical change (or amended into the recent
      unpushed commit they fix).

## Workflow note (not pure style)

The following items come from `AGENTS.md`, not `STYLE_GUIDE.md`. They
are listed here because they are easy to miss; the source for any
disagreement is `AGENTS.md`:

- `Object::HashBase` slot-ordering convention (§1) — agent workflow
  preference layered on top of the style guide's HashBase rule.
- POD `ATTRIBUTES` section for HashBase-style classes (§16) — agent
  workflow expectation.
- `t/AI/` mirror layout (§9) — agent workflow expectation.
- No emojis in commit messages (§0) — repository agent-hygiene rule;
  not style-guide content, but agents are responsible for it.

If any box above is unchecked, the branch is **not** ready for review.
Fix the violation or document why the exception applies, then re-run the
suite.
