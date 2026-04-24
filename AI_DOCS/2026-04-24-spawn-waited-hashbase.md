# Spawn: declare `_waited` via Object::HashBase

**Date:** 2026-04-24
**Issue:** https://github.com/Test-More/Test2-Harness/issues/397
**Trigger:** Automated audit flagged an undeclared hash slot used as a guard flag.

## What was done

The `wait()` method in `lib/Test2/Harness2/Spawn.pm` used `$self->{_waited}` as a
one-shot idempotency guard, but `_waited` was never declared in the
`Object::HashBase` specification. It was set as a raw hash key relying on
implicit `undef`-as-false semantics.

The fix:

1. Added `+_waited` to the `Object::HashBase` attribute list.
2. Initialized it to `0` in `init()` with `$self->{+_WAITED} //= 0`.
3. Replaced the raw string key access in `wait()` with the generated `+_WAITED`
   constant.

## Decisions

- **`+` sigil (read-only constant accessor) vs `<` (read + reader method):** Used `+`
  because `_waited` is internal state, not a public attribute that callers should read
  via an accessor method. The `+` form declares the constant key name without generating
  a reader, keeping the public API surface minimal.

- **Initialize to `0` not `undef`:** The guard is conceptually a boolean. Initializing
  to `0` makes the intent explicit and matches the `//=` default pattern already used
  for `terminate_on_destroy`.

## Tests added

`t/AI/unit/Harness2/Spawn.t` — two new subtests:

- `_waited is declared in Object::HashBase`: checks `can('_WAITED')` and that the
  initialized value is `0`.
- `wait is idempotent via _waited guard`: pre-sets `_waited` to `1` via the constant
  key, calls `wait()`, and verifies it returns without invoking `waitpid` on a
  non-existent PID.

## No architectural changes

This is a pure style/discipline fix. The runtime behavior of `wait()` is unchanged.
