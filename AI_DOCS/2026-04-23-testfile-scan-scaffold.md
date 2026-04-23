# TestFile: Stage A — scan() scaffolding

## What triggered this task

GitHub issue #375 requested the scan() scaffold for `Test2::Harness2::TestFile` as the
first stage of a multi-stage build-out of directive parsing. Finder filtering already
calls `check_feature` and `check_duration` on each TestFile object, so the missing scan
machinery was a live gap.

## What was implemented

### HashBase slot expansion

`lib/Test2/Harness2/TestFile.pm` previously declared only three HashBase slots:
`file`, `absolute`, `relative`. The full attribute set (`category`, `duration`,
`features`, `switches`, `conflicts`, `min_slots`, `max_slots`, `retry`,
`retry_isolated`, `non_perl`, `is_binary`, `event_timeout`, `post_exit_timeout`,
`meta`, `comment`, `_scanned`, `_shbang`) was added to give `_scan()` direct hash
slots to write into as directives are processed in later stages.

### Default initialization in init()

Because Object::HashBase-generated accessors read directly from hash slots, leaving a
slot undef causes the accessor to return undef rather than delegating to the role's
`defaults()` method. Per-instance defaults are now filled in `init()`, mirroring the
`t/lib` reference implementation that existed before this task. This preserves the
documented defaults for callers that do not go through `scan()`.

### scan() / _scan() methods

`scan()` is the public stable entry point; `_scan()` is the idempotent workhorse.
Separation lets callers invoke `scan()` freely without guarding against double-execution.

`_scan()` logic:
- `return if $self->{+_SCANNED}++` — first call proceeds and sets flag to 1; subsequent
  calls short-circuit. The file is not re-opened.
- `return unless -e $self->{+ABSOLUTE}` — silently skips missing files; flag is not set
  so a later call after the file appears will retry (intentional).
- `return if $self->{+IS_BINARY}` — early exit for binary files.
- Loop reads lines; skips blank lines; on line 1, a shebang parsing placeholder is
  reserved for Stage B.
- Non-HARNESS comment lines (`^\s*\Q$comment\E` without `HARNESS-.+`) are skipped.
- `use`/`require`/`BEGIN`/`package` lines are skipped.
- Any other non-comment line triggers `last` (halt).
- HARNESS-* comment lines reach the dispatch placeholder (Stages D–G).

Both the skip-non-HARNESS regex and the terminal `last` regex use `\Q$comment\E` so
files with non-`#` comment characters (e.g. `//` for non-Perl stubs) are handled
correctly. The comment value is read directly from the hash slot (`// '#'`) rather
than via the accessor, because the accessor itself may not yet be populated at scan
time (defensive against future changes to init order).

### Test

`t/AI/unit/Harness2/TestFile/scan_scaffold.t` covers:

1. **Idempotency** — spy on `open_file` via local symbol override; confirms file opened
   exactly once across two `scan()` calls.
2. **Halt at code line** — file with blank lines, plain comment, `use strict`, then
   `my $x = 1;`; verifies scan completes without directive dispatch.
3. **Empty file** — no crash; `_SCANNED` set.
4. **Missing file** — no crash; object remains usable.
5. **Non-`#` comment char** — `comment => '//'`; no crash; scan halts correctly.
6. **Role defaults** — after no-directive scan, all accessor-facing defaults (`category`,
   `duration`, `features`, etc.) return their expected values.

## Design decisions

### Why initialize defaults in init() rather than leaving slots undef

Alternative: rely on the role's `defaults()` method via method dispatch. This breaks
because Object::HashBase generates `sub category { $_[0]->{+CATEGORY} }` which
shadows the role's `sub category { $_[0]->defaults->{category} }`. An undef slot
returns undef, not the role default. The `t/lib` reference implementation already
handled this correctly; this task brings the production module into alignment.

### Why scan() delegates to _scan() rather than containing the logic directly

`scan()` is the stable public API; making it a thin wrapper lets subclasses override
`_scan()` without touching the public contract, and lets tests mock or intercept `_scan`
independently.

### Why \Q$comment\E rather than hardcoded `#`

`TestFile` objects can represent non-Perl files (e.g., shell stubs, C stubs) where
the comment character differs. Using `\Q$comment\E` in both regexes ensures consistent
behaviour and avoids a silent regression when a non-`#` comment char is configured.
