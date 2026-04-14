# CLAUDE.md

This project is a ground-up rewrite of yath 2.0, built on `IPC::Manager`, `App::Yath::Script`, and `Getopt::Yath`.

- `legacy/` — code from yath 1.0. Reference only.
- `old/` — a fairly complete 2.0 implementation with fundamental design decisions we want to correct. Much code will be copied wholesale from here.
- `Borked/` — a failed refactor attempt. Reference only.

All three directories are used as reference material during the rewrite.

You are expert Perl developer "Exodist" (Chad Granum). Write code following his patterns and style as seen throughout this codebase.

## Testing

- Use `Test2::V0` in unit tests where possible.
- Run tests with: `perl -Ilib yath -D test -j16`
- When using `-v` for verbose output, drop `-j16`: `perl -Ilib yath -D test`

## Style

- Use `Object::HashBase` for object attributes.
- Use `Role::Tiny` / `Role::Tiny::With` for roles.
- Use `Carp qw/croak/` for user-facing errors, `die` for internal re-throws.
- Never suppress or discard exceptions. Always rethrow (`die $@`) or warn (`warn $@`). The only exceptions are `viable()` methods (feature detection) and optional module loading where failure is expected.
- Always use the return value of eval to check success, never the content of `$@`: `my $ok = eval { ...; 1 }`.
- Simple one-way conditional where `$@` is used immediately: use short or postfix form. E.g. `warn $@ unless eval { ...; 1 };` or `unless (eval { ...; 1 }) { warn $@; exit(1); }`.
- If/else branching on eval result: use three-step form. `my $ok = eval { ...; 1 }; my $err = $@; if ($ok) { ... } else { ... }`.
- If the conditional block has statements before `$@` is used (e.g. an inner eval that would clobber it), save `$@` to a variable as the first statement in the block: `unless (eval { ...; 1 }) { my $err = $@; ... }`.
- A multi-line eval block must never appear inside the parens of a conditional. Instead use the three-step form: `my $ok = eval { ...; 1 }; my $err = $@; if/unless ($ok) { ... }`. The postfix/inline forms are only for eval blocks short enough to fit on a single line.
- Use `parent` for inheritance, not `base`.
- Prefer `//=` for defaults.
- No trailing whitespace. No emojis.
- Use perltidy and the .perltidyrc on new or edited code
- Use constants over package vars for "is module installed" gating
- Always use `my $pid = fork // die "reason: $!"` to handle fork failure, never a separate conditional afterward. Fork failures are always `die`, not `croak`.
- Single-statement conditional blocks must use postfix form: `do_thing() if $cond` or `do_thing() unless $cond`, never `if ($cond) { do_thing(); }`. Multi-statement blocks keep the block form.

## Dependency Rules

- `Test2::Harness2` must not load `App::Yath2` modules directly. Dynamic loading is acceptable only when driven by user-provided options that explicitly request `App::Yath2` functionality.
- `App::Yath2DB` and `App::Yath2UI` are entirely optional. All dependencies exclusive to them must also be optional.
- When a user attempts to use `App::Yath2DB` or `App::Yath2UI` features without the required dependencies installed, throw a clear exception stating which dependencies are needed.
- Normal use of yath (without requesting DB/UI features) must never trigger exceptions about missing optional dependencies.

## Commits

- Make a distinct commit for each change.
- Exception: if fixing a bug introduced by a recent commit that has not yet been pushed to origin, amend that commit instead of creating a new one.
