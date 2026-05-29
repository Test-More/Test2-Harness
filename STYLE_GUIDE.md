# STYLE_GUIDE.md

Code style conventions for this distribution. This document is the single
source of truth for formatting, naming, and language-feature rules. Both
`CLAUDE.md` and `ARCHITECTURE.md` defer to this file. Architecture/design
rules (process topology, IPC, lifecycle, etc.) live in `ARCHITECTURE.md`,
not here.

## Object orientation

- Use `Object::HashBase` for object attributes.
- Slot ordering in `Object::HashBase` is intentional; additions should
  typically go at the end unless a specific grouping is documented.
- For a read-only attribute, use the `<attr` prefix (reader, no setter),
  **not** `-attr`. Both give a reader and no real writer, but `-attr`
  generates a `set_attr` that exists only to throw "read-only" — a fake
  writer that is never meant to be called. `<attr` generates no setter at
  all, which is what we want. Internal writes via `$self->{+ATTR} = ...`
  work identically under both. Prefer `<attr` for every read-only slot;
  reach for `-attr` only in the rare case where you specifically need the
  throwing `set_attr` to exist (e.g. to give a clearer error than
  "method not found" at a call site you cannot remove). That case should
  be commented.
- Use `Role::Tiny` / `Role::Tiny::With` for roles.
- Use `parent` for inheritance, not `base`.
- `Object::HashBase` and `Role::Tiny` compose. `Object::HashBase` may
  be used inside roles, and may be used by classes that consume roles
  built with `Object::HashBase`. Don't reach for a heavier framework
  to get around a perceived incompatibility — there isn't one.

## Error handling

- Use `Carp qw/croak/` when the problem is in the caller; use `die` when the problem is in the current scope. Rule of thumb:
  - `croak` for interface misuse — bad arguments, missing required parameters, or operations on data the caller provided that turn out to be invalid (e.g. `do_thing_to(file => 'blah')` where the caller's path does not exist or is unreadable).
  - `die` for failures internal to the implementation — a temp file the code itself created cannot be written, an invariant the caller could not have controlled is violated, or an exception is being re-thrown.
  - Examples: `croak "Missing required parameter 'file'"` (caller's fault). `die "Failed to write temp file: $!"` (internal failure). A failed `open` on a path the caller passed in: `croak`. A failed `open` on a path the code constructed itself for its own use: `die`.
- Never suppress or discard exceptions. Always rethrow (`die $@`) or warn (`warn $@`). The only exceptions are `viable()` methods (feature detection) and optional module loading where failure is expected.
- Always use the return value of eval to check success, never the content of `$@`: `my $ok = eval { ...; 1 }`.
- Simple one-way conditional where `$@` is used immediately: any of these short forms is fine.
  - postfix: `warn $@ unless eval { ...; 1 };`
  - block:   `unless (eval { ...; 1 }) { warn $@; exit(1); }`
  - or-form: `eval { ...; 1 } or warn $@;` — acceptable when the eval block is a single statement and the `or`-clause is also a single statement, so nothing can clobber `$@` between the eval close-brace and the use. (For longer blocks or multi-statement handlers, use the three-step form instead.)
  - capture-in-block: `unless (eval { ...; 1 }) { my $err = $@; ...handler using $err... }` — also acceptable. Conditions: the conditional itself must test the return value of `eval` (not `$@`), and if `$@` is referenced anywhere other than the very first statement of the block, it must be assigned to a local variable on that first statement so later code can't clobber it. The whole point of this form is that `eval` success is decided by its return, while `$@` is only used (via the saved local) to format the error.
- If/else branching on eval result: use three-step form. `my $ok = eval { ...; 1 }; my $err = $@; if ($ok) { ... } else { ... }`.
- If the conditional block has statements before `$@` is used (e.g. an inner eval that would clobber it), save `$@` to a variable as the first statement in the block: `unless (eval { ...; 1 }) { my $err = $@; ... }`.
- A multi-line eval block must never appear inside the parens of a conditional. Instead use the three-step form: `my $ok = eval { ...; 1 }; my $err = $@; if/unless ($ok) { ... }`. The postfix/inline/or-form variants are only for eval blocks short enough to fit on a single line.
- Always use `my $pid = fork // die "reason: $!"` to handle fork failure, never a separate conditional afterward. Fork failures are always `die`, not `croak`.

## Whitespace and formatting

- No trailing whitespace. No emojis.
- Use perltidy and the `.perltidyrc` on new or edited code.
- Use perlcritic and the `.perlcriticrc` to catch common mistakes.

## Language-feature defaults

- Prefer `//=` for defaults.
- Use constants over package vars for "is module installed" gating.

## Minimum Perl and subroutine signatures

Minimum supported Perl is **5.38.0** (released 2023-07-02).
Signatures became stable in 5.36; 5.38 added `//=` / `||=` defaults
inside signatures. Every shipped module starts with:

```perl
use v5.38;
```

This single line enables `strict`, `warnings`, and the stable
`signatures` feature. Add `use warnings;` / `use strict;` only when
you also need to override the bundle (very rare).

Use Perl's subroutine signatures for **all** named subs, methods, and
anonymous subs whose argument handling fits within what signatures
support. That includes:

- Methods: `sub method ($self, $arg, $other = undef) { ... }`.
- Class methods: `sub new ($class, %params) { ... }`.
- Functions: `sub helper ($x, $y //= compute_default()) { ... }`.
- Variadic tails: `sub foo ($first, @rest) { ... }` /
  `sub bar (%opts) { ... }`.

Default-value variants follow the same intent rules as `//=` /
`||=` on assignment:

- `$x = $default` — applied only when the argument is **missing**.
  An explicit `undef` is preserved.
- `$x //= $default` — applied when the argument is missing **or** the
  caller passed `undef`. Match this against the same use-cases where
  you would write `$x //= $default;` in the body.
- `$x ||= $default` — applied when the argument is missing or falsy.
  Use sparingly; like the assignment form, it drops legitimate `0`
  / `""` values.

Drop to `@_` only when signatures genuinely cannot express the call
shape. Real cases:

- Re-dispatching arguments unchanged (`goto &other`,
  `$other->(@_)`).
- Argument shapes signatures cannot describe (positional + key/value
  + flag mixes that need custom parsing, prototype-driven DSLs).
- Subs whose first action is to peek at `wantarray` / `caller` and
  then forward.

Aesthetic preference for `my $self = shift;` is **not** a reason to
skip signatures.

Argless declarative-metadata methods (`sub TABLE { 'users' }`,
`sub json_fields { qw{a b c} }`) may keep their empty
parameter list — `sub TABLE { 'users' }` and
`sub TABLE () { 'users' }` are both acceptable. Pick one and be
consistent within a file.

## Sub-second sleeps

Use **`Time::HiRes::sleep($secs)`** for every sub-second sleep —
poll cycles, backoff sleeps, anywhere the busy / idle loop needs
to wait a fraction of a second. `Time::HiRes::sleep` returns early
on signal interruption (`EINTR`), which is the behavior we want:
a `SIGUSR1` wake-up from another process must break the sleep
immediately so the loop can pick up the new work.

Earlier docs claimed `Time::HiRes::sleep` retried internally on
`EINTR` and would silently swallow signals; that was wrong. It
wakes on signal like `sleep`/`usleep` do. There is no need for a
`tinysleep` helper or a 4-arg `select` workaround — just call
`Time::HiRes::sleep` directly.

Do not use 4-arg `select(undef, undef, undef, $secs)` as a sleep
primitive. If you find existing code doing it, replace with
`Time::HiRes::sleep`.

## Conditionals

- Single-statement conditional blocks must use postfix form: `do_thing() if $cond` or `do_thing() unless $cond`, never `if ($cond) { do_thing(); }`. Multi-statement blocks keep the block form.
- Never write a multi-line conditional expression inside the parens of `if`/`unless`/`while`/`until`. A conditional whose test expression spans more than one source line is hard to scan; the eye loses which clauses combine. Refactor by one of:
  - Accumulate the boolean step by step:

        my $ok = defined $arg;
        $ok &&= !ref($arg);
        $ok &&= $arg !~ m{^[0-9]};
        $ok &&= $arg !~ m{^@};
        if ($ok) { ... }

  - Extract a predicate helper that returns true/false:

        sub _is_unknown_kv_arg {
            my ($class, $arg, $has_next) = @_;
            return 0 unless $has_next;
            return 0 unless defined $arg;
            return 0 if ref $arg;
            return 0 if $arg =~ m{^[0-9]};
            return 0 if $arg =~ m{^@};
            return 1;
        }

        if ($class->_is_unknown_kv_arg($arg, $i + 1 < @args)) { ... }

  Either form is acceptable; pick the one that reads best for the surrounding code. Short conditionals that fit on a single source line are still fine.

## Lists and pushes

- When using `push`, separate the target array from the values with `=>` instead of a comma: `push @items => $thing`, `push @{$ref} => $thing`. The fat comma makes the destination visually distinct from the values being pushed.

## Naming and structure

- Named subroutines (ones defined in a package namespace, not anonymous subs or subs assigned to a variable) in a module that defines an object class must be methods, not functions. A class is an object module if it `use`s `Object::HashBase` or composes a `Role::Tiny::With` role (i.e. matches `^use Object::HashBase` or `^with ` at file scope). Imported named subs (e.g. `use Carp qw/croak/`) stay as functions; this rule applies only to subs defined in the module itself.

  Concretely, a named sub in such a module must do at least one of:

  - `my $self  = shift;` (or `my $class = shift;`)
  - `my ($self, ...) = @_;` (or `($class, ...)`)
  - return a literal constant (`sub TABLE { 'users' }`, `sub defaults { {...} }`, `sub json_fields { qw{a b c} }`) — argless declarative-metadata methods are fine because callers invoke them as `$obj->name`.

  Wrong (function inside object module):

  ```perl
  sub _flavor_from_dsn {
      my ($dsn) = @_;
      return undef unless $dsn && $dsn =~ /^dbi:([^:]+):/;
      return $FLAVOR_FROM_DSN_SCHEME{$1};
  }
  # ... called as: $self->{+FLAVOR} //= _flavor_from_dsn($self->{+DSN});
  ```

  Right (method):

  ```perl
  sub _flavor_from_dsn {
      my ($self, $dsn) = @_;
      return undef unless $dsn && $dsn =~ /^dbi:([^:]+):/;
      return $FLAVOR_FROM_DSN_SCHEME{$1};
  }
  # ... called as: $self->{+FLAVOR} //= $self->_flavor_from_dsn($self->{+DSN});
  ```

  An automated scanner lives at `agent_scripts/audit-methods-not-functions` —
  run it before declaring a stage ready for review (it is one of the
  three mandatory pre-review checks in `AGENTS.md`).

## Testing libraries

- Use `Test2::V0` as the test library for everything new under `t/`.
  Avoid `Test::More` and `Test::Simple` in new code; existing `t/`
  imports may stay as they are until touched.
- AI-generated tests live in `t/AI/` and must mirror the main test
  directory's layout.

## UUIDs

- Generate UUIDs in Perl, not in the database. Use
  `Test2::Util::UUID` (which loads `UUID.pm` under the hood).
- These are v7 UUIDs. Do not reorder bits for index locality —
  v7 already orders by time-of-generation.

## Databases

- Hand-written SQL via `DBI` for the harness's row layer.
  `SQL::Abstract` is fine where it helps.
- **Do not use `DBIx::Class`.** Hand-written SQL on `DBI` is the
  whole story for the harness's row layer.
- Default backend is SQLite via `DBD::SQLite`. For non-default
  flavors and ephemeral testing setups, use `DBIx::QuickDB` and
  point it at the installations under `~/dbs/` when available.
- The schema lives at `share/schema/<flavor>.sql`. All flavors move
  together: a DDL change touches every flavor file in the same
  commit.

## File organization

- One Perl namespace per file. A package `Foo::Bar::Baz` lives in
  `lib/Foo/Bar/Baz.pm`, not declared inline inside `lib/Foo/Bar.pm`.
  Helper or inline namespaces that grow complex enough to deserve their
  own package also get their own file at the path that mirrors the
  package name. The exception is throwaway lexical scaffolding (e.g.
  `package main;` blocks inside test scripts, or anonymous-class
  patterns) — those are not "namespaces deserving their own package".
  When in doubt, a `package` declaration that includes any `sub`
  definitions or attributes should be in its own file.

- **POD layout dictates the outer ordering of subs**, and the
  ordering rules below apply **within** each POD section, not
  across the whole file. Subs in the `EXPORTS` POD group come
  before subs in the `PUBLIC METHODS` POD group, which come before
  subs in the `PRIVATE METHODS` POD group (per the POD section
  rules above). Within each of those groups, then apply the rules
  below — 1-line subs near the top of the group, longer subs after,
  optional folds for related logic. Do not reorder across POD
  groups to put a 1-liner first when that breaks the POD layout.

- In general, 1-line methods or functions:

  ```perl
  sub one_line { "1 line" }
  ```

  Should go near the top of the file, after `use` and `BEGIN` statements.
  Exceptions can be made when logic is grouped together because it all
  implements the same role interface or similar; in those cases a fold
  should be introduced and the 1-liner goes to the top of that section:

  ```perl
  # {{{ This is where the doohickey is implemented

  sub one_line { "1 line" }
  sub default  { 1 }
  sub is_smart { 1 }

  sub longer_method {
      my $self = shift;
      ...
      return "That was long";
  }

  sub another {
      ...
  }

  # }}} This is where the doohickey is implemented
  ```

## Module size

- No single `.pm` file should exceed **1000 lines** of code. Lines
  of code includes blank lines and comments but **excludes POD**
  (everything between `=pod` / `=head*` and `=cut`, and everything
  after `__END__`).
- When a module crosses 1000 lines, **flag it for human review**
  rather than silently splitting it. The likely action is to break
  it into multiple modules; the human decides where the seams go.
- Do not work around the rule by stuffing logic into long POD or
  another file via `do`/`require` tricks. The rule exists to keep
  modules comprehensible, not to be gamed.

## Subroutine size

- No subroutine should exceed **75 lines** (sub signature through
  closing brace, inclusive). POD blocks and code comments inside a
  sub do not count toward the limit; the limit applies to executable
  Perl only.
- When a sub crosses 75 lines, break it up into smaller helpers with
  names that describe each step.
- **Narrow exception:** some low-level operations — packed-binary
  encoders, hex / bit-twiddling, table-driven dispatch where every
  branch is a one-liner — read worse when split. If breaking up
  genuinely does more harm than good, keep it and add a short
  comment explaining why. Do not invoke the exception as a default;
  if you're not sure, split.

## Comments

- Default: **no comment.** Code with well-named identifiers
  documents itself; an extra sentence saying what the next line
  already says is noise.
- Add a comment only when it adds **significant** value: a
  non-obvious *why*, a hidden constraint, a subtle invariant, a
  workaround for a specific bug, behavior that would surprise a
  future reader.
- Never write the obvious:

  ```perl
  # BAD — comment restates the code:
  # Return 1
  return 1;
  ```

- Keep comments brief. Multi-paragraph comment blocks are almost
  never warranted; if a topic needs that much explanation it
  probably belongs in POD or `ARCHITECTURE.md`.
- Comments may reference `ARCHITECTURE.md` or `STYLE_GUIDE.md`
  (both tracked, both authoritative). Comments **should not**
  reference `AI_DOCS/*` or other markdown files; if a rule from
  one of those documents matters here, restate the rule in the
  comment instead.

## POD

Every shipped `.pm` file must have POD documentation. Start from
the repository `template.pod` and remove the sections that are not
relevant to the module being documented.

### Section placement

The `template.pod` sections split into three placement groups:

- **Top of file** (before `package`-level code begins to do real
  work, or grouped together at the top after `use` statements):
  - `NAME`
  - `DESCRIPTION`
  - `SYNOPSIS`

- **Inline with code** (POD block immediately above the relevant
  sub / export):
  - `EXPORTS` — POD lives above each exported function.
  - `PUBLIC METHODS` — POD lives above each public method.
  - `PRIVATE METHODS` — POD lives above each private method
    (leading-underscore convention).

  The section names above are still the headings the POD uses —
  the inline blocks are pieces of those sections, ordered by code
  appearance.

- **End of file**, under an `__END__` marker:
  - `SOURCE`
  - `MAINTAINERS`
  - `AUTHORS`
  - `COPYRIGHT`
  - any other tail sections the template carries.

### POD style

- Be brief. POD should describe behavior the reader can't infer
  from the signature in one or two sentences. Avoid retelling the
  whole module in prose.
- Don't repeat yourself. If the same explanation applies to several
  methods, put it in `DESCRIPTION` once and let the per-method POD
  stay short.
- POD **must not** reference any `.md` document — not
  `ARCHITECTURE.md`, not `STYLE_GUIDE.md`, not `AI_DOCS/*`, not
  this file. Users read POD; they cannot read internal docs.
  Restate the relevant rule or behavior in plain prose if it
  matters.
