# TestFile: Stage A — scan() scaffolding

## What and why

GitHub issue [#375](https://github.com/Test-More/Test2-Harness/issues/375)
(label `TestFile`, milestone `PTS26`) asked for the foundation of the
`Test2::Harness2::TestFile` directive parser: expand the HashBase slot
list and add `scan()` / `_scan()` with every stop condition in place, but
no per-directive dispatch yet. Subsequent stages (B — shebang, C —
binary detection, D–G — each `HARNESS-*` directive, H — `check_*`
helpers) each add one concern in isolation.

The gap was not theoretical: `App::Yath2::Finder::exclude_file` already
calls `$test->check_feature(run => 1)` and `$test->check_duration`, so
finder filtering depended on machinery that did not exist.

## What changed

- `lib/Test2/Harness2/TestFile.pm`
  - Expanded the `Object::HashBase` slot list to cover every attribute
    the role (`Test2::Harness2::Role::TestFile`) documents a default
    for, plus two scan-internal slots `_scanned` and `_shbang`.
  - Added `scan()` (public, returns nothing) and `_scan()` (idempotent
    internal workhorse) with the line-by-line read loop and every stop
    condition wired — blank-line skip, placeholder for Stage B shebang,
    non-HARNESS comment skip, leading `use/require/BEGIN/package` skip,
    `last` on the first non-HARNESS line. No directive dispatch.
  - Extended `init()` to seed each slot from `$self->defaults` (see
    deviation below).

- `t/AI/unit/Harness2/TestFile/scan_scaffold.t` (new)
  - Idempotency via local-override of the imported `open_file` symbol.
  - Halt-at-first-code-line.
  - Empty file.
  - Missing file.
  - Non-`#` comment character (`//`).
  - Role-default preservation after a directive-free scan.

## Decisions

### Deviation from the plan: init() is updated

The issue's Acceptance criteria said `init()` should remain unchanged.
But the role's default methods (`category`, `duration`, `min_slots`,
etc.) are shadowed by the HashBase reader accessors once the slot list
expands; the HashBase reader returns `undef` when the slot is unset.
That contradicts the plan's other criterion — "role defaults return
their role-defined defaults".

Resolution: `init()` now calls `$self->defaults` once and seeds each
missing slot with the role's default. This is the same pattern already
used by the test-suite stand-in at
`t/lib/Test2/Harness2/TestFile.pm`, expressed more compactly by reading
the role's canonical defaults hash rather than hand-enumerating the
fields. The change is one short loop with a comment explaining why.

### Binary detection stays out

Kept deliberately in Stage C (per the issue). Moving it into `init()`
now would break rehydrated TestFiles for files that no longer exist,
e.g. when reviewing logs on another host.

### `_SCANNED` post-increment

`return if $self->{+_SCANNED}++;` — idiomatic one-shot flag. First call
sees 0, proceeds, sets flag to 1; subsequent calls see 1 and
short-circuit. Matches `reference/legacy` and `reference/old2` exactly.

### Idempotency test via namespace-local override

`open_file` is imported into `Test2::Harness2::TestFile`, so
`local *Test2::Harness2::TestFile::open_file = sub {...}` is the
correct target. Using `Test2::Mock` on `Test2::Harness2::Util` would
not intercept the already-imported copy.

## Alternatives considered

- **Port old2's `_scan` verbatim** (all directives at once). Rejected:
  defeats the staged review plan.
- **Add slots only, defer the loop to the first directive stage**.
  Rejected: every directive stage would then mix loop plumbing with
  directive logic.
- **Make the scaffold test use `use lib 't/lib'`** so the test-suite
  stand-in's init-seeded defaults hide the problem. Rejected: the
  scan() method lives in `lib/`, so the test must exercise the real
  class; otherwise we're not testing Stage A at all.

## Verification

- `perl -Ilib t/AI/unit/Harness2/TestFile/scan_scaffold.t` — passes.
- `perl -Ilib t/AI/unit/Harness2/TestFile.t` — passes (regression).
- `perl -Ilib t/AI/unit/Harness2/Role/TestFile.t` — passes (regression).
- Pre-existing failures in `t/AI/unit/Collector.t`,
  `t/AI/unit/Collector/burst_sync.t`, `t/AI/unit/Harness2.t`, and
  `t/AI/unit/Harness2/Role/Collector/Observer.t` confirmed unrelated
  to this change (present on `git stash` baseline).
- `perltidy` applied against `.perltidyrc`.

## Out of scope (later stages)

- B — shebang parsing, `non_perl` set from shebang.
- C — binary detection, generated-runner sentinel.
- D–G — directives: `no`, `smoke`, `retry`, `yes`/`use`, `stage`,
  `meta`, `duration`, `category`, `conflicts`, `timeout`, `job`.
- H — `check_feature`, `check_duration`, `check_*` helpers.
