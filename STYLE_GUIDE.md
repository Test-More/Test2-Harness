# STYLE_GUIDE.md

Code style conventions for this distribution. This document is the single
source of truth for formatting, naming, and language-feature rules. Both
`CLAUDE.md` and `ARCHITECTURE.md` defer to this file. Architecture/design
rules (process topology, IPC, lifecycle, etc.) live in `ARCHITECTURE.md`,
not here.

## Object orientation

- Use `Object::HashBase` for object attributes.
- Use `Role::Tiny` / `Role::Tiny::With` for roles.
- Use `parent` for inheritance, not `base`.

## Error handling

- Use `Carp qw/croak/` when the problem is in the caller; use `die` when the problem is in the current scope. Rule of thumb:
  - `croak` for interface misuse — bad arguments, missing required parameters, or operations on data the caller provided that turn out to be invalid (e.g. `do_thing_to(file => 'blah')` where the caller's path does not exist or is unreadable).
  - `die` for failures internal to the implementation — a temp file the code itself created cannot be written, an invariant the caller could not have controlled is violated, or an exception is being re-thrown.
  - Examples: `croak "Missing required parameter 'file'"` (caller's fault). `die "Failed to write temp file: $!"` (internal failure). A failed `open` on a path the caller passed in: `croak`. A failed `open` on a path the code constructed itself for its own use: `die`.
- Never suppress or discard exceptions. Always rethrow (`die $@`) or warn (`warn $@`). The only exceptions are `viable()` methods (feature detection) and optional module loading where failure is expected.
- Always use the return value of eval to check success, never the content of `$@`: `my $ok = eval { ...; 1 }`.
- Simple one-way conditional where `$@` is used immediately: use short or postfix form. E.g. `warn $@ unless eval { ...; 1 };` or `unless (eval { ...; 1 }) { warn $@; exit(1); }`.
- If/else branching on eval result: use three-step form. `my $ok = eval { ...; 1 }; my $err = $@; if ($ok) { ... } else { ... }`.
- If the conditional block has statements before `$@` is used (e.g. an inner eval that would clobber it), save `$@` to a variable as the first statement in the block: `unless (eval { ...; 1 }) { my $err = $@; ... }`.
- A multi-line eval block must never appear inside the parens of a conditional. Instead use the three-step form: `my $ok = eval { ...; 1 }; my $err = $@; if/unless ($ok) { ... }`. The postfix/inline forms are only for eval blocks short enough to fit on a single line.
- Always use `my $pid = fork // die "reason: $!"` to handle fork failure, never a separate conditional afterward. Fork failures are always `die`, not `croak`.

## Whitespace and formatting

- No trailing whitespace. No emojis.
- Use perltidy and the `.perltidyrc` on new or edited code.

## Language-feature defaults

- Prefer `//=` for defaults.
- Use constants over package vars for "is module installed" gating.

## Sub-second sleeps

Three primitives, picked by purpose. Never use 4-arg `select` directly.

- **`Test2::Harness2::Util::tinysleep($secs)`** — default for busy loops,
  poll cycles, and any sleep where the caller expects to react promptly
  to a signal. `tinysleep` is implemented over 4-arg `select(undef, undef,
  undef, $secs)`, which returns early on `EINTR` and does **not** resume
  the remaining sleep. That is the desired behavior for code that
  cooperates with signal-driven shutdown / SIGCHLD reaping / wakeups.
  Almost every sleep in this codebase should be `tinysleep`.

- **`Time::HiRes::sleep($secs)`** — only when the code genuinely needs
  to guarantee a minimum elapsed wall-clock duration. `Time::HiRes::sleep`
  retries internally on `EINTR` and so will silently swallow signals to
  meet the requested duration. Use this for timing-sensitive paths
  (rate limiters, "wait at least N seconds before retrying a backoff",
  etc.) where signal interruption would produce a wrong result. Document
  the reason at the call site.

- **4-arg `select(undef, undef, undef, $secs)`** — never use directly.
  If you need its semantics, use `tinysleep`. Existing direct uses are
  bugs to fix during cleanup passes.

## Conditionals

- Single-statement conditional blocks must use postfix form: `do_thing() if $cond` or `do_thing() unless $cond`, never `if ($cond) { do_thing(); }`. Multi-statement blocks keep the block form.

## Lists and pushes

- When using `push`, separate the target array from the values with `=>` instead of a comma: `push @items => $thing`, `push @{$ref} => $thing`. The fat comma makes the destination visually distinct from the values being pushed.

## Naming and structure

- Named subroutines (ones defined in a package namespace, not anonymous subs or subs assigned to a variable) in a module that defines an object class must be methods, not functions. Named subroutines are only allowed to be functions when the module is not an object class — e.g. a utility/export module or a plain `.pl` script. Imported named subs (e.g. from `use Carp qw/croak/`) stay as functions; this rule applies only to subs defined in the module itself.

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
