# TestFile Audit: current vs reference implementations

Compares:

- **Current Role** — `lib/Test2/Harness2/Role/TestFile.pm`
- **Current Class** — `lib/Test2/Harness2/TestFile.pm`
- **Legacy** — `reference/legacy/lib/Test2/Harness/TestFile.pm` (1.x)
- **Old2** — `reference/old2/lib/Test2/Harness2/TestFile.pm` (failed 2.0)

Future split (per AUDITS guidance):

- **Role** — `Test2::Harness2::Role::TestFile` (interface, helpers, defaults, predicates).
- **Harness2** — `Test2::Harness2::TestFile` (static-data only; no scanning/reading; no mutation; consumes already-formed data).
- **Yath2** — `App::Yath2::TestFile` (UX side: scans headers, applies CLI overrides, serializes for queueing).

## 1. Summary table

| Feature / method                                | Legacy | Old2 | Current | Future home                |
|-------------------------------------------------|:------:|:----:|:-------:|----------------------------|
| `file` attribute (required)                     |   Y    |  Y   |    Y    | Role (req) / Harness2 / Yath2 |
| `absolute` derived path                         |   -    |  -   |    Y    | Role / Harness2            |
| `relative` derived path                         |   Y    |  Y   |    Y    | Role / Harness2            |
| `is_binary` detection (`-B`)                    |   Y    |  Y   |    Y (scan) | Yath2 (sets data)      |
| `is_binary` "binary must be executable" guard   |   Y    |  Y   |    -    | Yath2                      |
| `non_perl` shebang detection                    |   Y    |  Y   |    Y    | Yath2                      |
| `clean_path` of file at construction            |   Y    |  Y   |    -    | Yath2                      |
| `-f $file` existence assertion at init          |   Y    |  Y   |    -    | Yath2                      |
| Shebang parsing / `_parse_shbang`               |   Y    |  Y   |    Y    | Yath2                      |
| `shbang()` accessor (raw shebang hash)          |   Y    |  Y   |    -    | Yath2 / Role (nice to have)|
| `switches()` derived from shebang               |   Y    |  Y   |    Y (slot) | Yath2 / Role           |
| `headers()` accessor                            |   Y    |  Y   |    -    | Yath2 (internal)           |
| HARNESS-NO-* / HARNESS-YES-* / HARNESS-USE-*    |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-NO-RETRY                                |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-RETRY (+N, +ISO, default 1)             |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-SMOKE                                   |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-STAGE                                   |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-DURATION / HARNESS-DUR                  |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-CATEGORY / HARNESS-CAT (+ duration alias) |  Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-CONFLICTS (multi-line, lc, uniq)        |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-TIMEOUT EVENT/POSTEXIT (+POST EXIT)     |   Y    |  Y   |    Y    | Yath2 (parser)             |
| HARNESS-JOB-SLOTS N [M]                         |   Y    |  Y (M defaults to -1) | Y (first wins) | Yath2 (parser) |
| HARNESS-META key val                            |   Y    |  Y   |    Y    | Yath2 (parser)             |
| `THIS IS A GENERATED YATH RUNNER TEST` -> run=0 |   Y    |  Y   |    Y    | Yath2 (parser)             |
| `comment` configurable comment char             |   Y    |  Y   |    Y    | Role (default `#`) / Yath2 |
| `chomp` of each line during scan                |   Y    |  Y   |    -    | Yath2                      |
| `meta($key)` accessor returning list            |   Y    |  Y   |    -    | Role / Harness2            |
| `feature($name)` accessor                       |   -    |  -   |    Y (Role) | Role                  |
| `check_feature` w/ DEFAULTS table               |   Y    |  Y   |    Y    | Role (defaults) / Harness2 (override) |
| `check_feature` fork/preload safety override    |   -    |  Y (in test_settings) | Y | Harness2 / Role |
| `check_feature` `io_events` default             |   Y    |  -   |    Y    | Role (defaults)            |
| `check_duration` w/ timeout fallback            |   Y    |  Y   |    Y    | Role / Harness2            |
| `check_category` w/ isolation fallback          |   Y    |  Y   |    Y    | Role / Harness2            |
| `check_stage`                                   |   Y    |  Y   |    Y    | Role / Harness2            |
| `check_min_slots` / `check_max_slots`           |   Y    |  Y   |    Y    | Role / Harness2            |
| `event_timeout`, `post_exit_timeout`            |   Y    |  Y   |    Y    | Role / Harness2            |
| `conflicts_list` (returns arrayref OR list)     |   Y (ref) | Y (ref) | Y (list) | Role / Harness2     |
| `has_conflicts` predicate                       |   -    |  -   |    Y (Role) | Role                  |
| `is_executable`                                 |   Y    |  Y   |    Y (Role) | Role / Harness2       |
| `rank()` (smoke / category / duration table)    |   Y    |  Y   |    Y (Role) | Role                  |
| `set_duration` / `set_category` (lc-normalized) |   Y    |  Y   |    -    | Yath2                      |
| `set_stage` / `set_min_slots` / `set_max_slots` |   Y    |  Y   |    -    | Yath2                      |
| `set_retry` / `set_retry_isolated`              |   Y    |  Y   |    -    | Yath2                      |
| `set_smoke`                                     |   Y    |  Y   |    -    | Yath2                      |
| `queue_args` arrayref (extra k/v injected)      |   Y    |  -   |    -    | Yath2                      |
| `queue_item($job_name,$run_id,%inject)`         |   Y    |  -   |    -    | Yath2                      |
| `test_settings()` (Old2 successor to queue_item)|   -    |  Y   |    -    | Yath2                      |
| `input` attr                                    |   Y    |  -   |    -    | Yath2                      |
| `env_vars` attr                                 |   Y    |  -   |    -    | Yath2                      |
| `test_args` attr                                |   Y    |  -   |    -    | Yath2                      |
| `job_class` attr                                |   Y    |  -   |    -    | Yath2                      |
| `ch_dir` attr                                   |   -    |  Y   |    Y (Role default) | Role / Harness2 / Yath2 |
| `gen_uuid()` job_id stamping                    |   Y    |  -   |    -    | Yath2 (queue path)         |
| `TO_JSON`                                       |   -    |  Y (lossy `%$self`) | Y (Role: explicit fields + class tag) | Role |
| `rehydrate(\%data)` (class-tagged)              |   -    |  -   |    Y (Role) | Role                  |
| `process_info()` (TO_JSON minus internals)      |   -    |  Y   |    -    | Yath2 (or drop)            |
| `defaults()` hashref of role defaults           |   -    |  -   |    Y (Role) | Role                  |
| `json_fields()` ordered field list              |   -    |  -   |    Y (Role) | Role                  |
| `_scanned` cache flag                           |   Y    |  Y   |    Y    | Yath2                      |
| `_headers` raw hash cache                       |   Y    |  Y   |    -    | Yath2 (internal only)      |

## 2. Per-feature notes (missing or weaker in current)

### 2.1 Construction-time invariants (current Class lacks)

Both legacy and old2 do work at `init()` time that current omits:

- `$file = clean_path($file, 0)` — normalize the path before storing. Current keeps the user-supplied form; it computes `absolute`/`relative` lazily but never canonicalizes.
- `croak "Invalid test file '$file'" unless -f $file` — refuse construction for a non-existent file.
- `if (-B $file && !-z $file) { die "Cannot run binary test file '$file': file is not executable.\n" unless $self->is_executable }` — guard binaries that aren't executable.

Current's `_scan` does check `-e` and sets `IS_BINARY`/`NON_PERL` but never enforces executability and never validates file existence at construction.

**Future home:** `App::Yath2::TestFile`. Harness2 receives static data and must not stat the filesystem.

### 2.2 Header / directive handling (parity but parser lives in current)

Current's `_scan` does cover every directive in the references. Parity items worth confirming during the split:

- HARNESS-JOB-SLOTS — current uses a scan-local `$job_slots_set` flag for "first wins"; old2 made max default to `-1` when unspecified, legacy made it equal to min. Choose one (legacy semantics match the role's documented "undef = same as min" statement).
- HARNESS-TIMEOUT — current correctly handles `POST EXIT` -> `postexit` and warns + skips on unknown types. Old2 issued the warning but still stored the bad type. Keep current behaviour.
- HARNESS-CATEGORY with a duration value — references and current both downgrade it to a duration. Preserve.
- `chomp` per line — references do it; current does not. Harmless because every regex tolerates `\n`, but porting `chomp` keeps parity for any future regex with `$` anchors.
- `_parse_shbang` returns `{}` for non-`#!` lines; current's `_scan` checks `%$shbang` before storing, which is stricter than legacy/old2 (they only checked truthiness). Current behaviour is fine.

**Future home:** `App::Yath2::TestFile` (the scanner). Harness2 should never see a HARNESS-* directive.

### 2.3 Mutators / setters (entirely absent from current)

Legacy and old2 ship a complete setter surface that lets finders / plugins override scan results before queueing:

- `set_duration` and `set_category` lower-case the argument before storing.
- `set_stage`, `set_min_slots`, `set_max_slots` are plain setters but skip the scan.
- `set_retry` / `set_retry_isolated` / `set_smoke` call `scan` first, then write into `_HEADERS`. Default value is `1` when called without argument.

The current code has none of these. The plan's "no mutation" rule for Harness2 is fine, but somebody (Yath2) needs to apply CLI overrides such as `--retry`, `--no-retry`, `--retry-isolated`, `--duration`, etc.

**Future home:** `App::Yath2::TestFile`. Optionally expose setter helpers on a Yath2 mutation trait.

### 2.4 `queue_item()` / `test_settings()` (entirely absent from current)

Legacy's `queue_item($job_name, $run_id, %inject)` is the canonical "produce the runner-queue payload" method. It:

1. Refuses to run when `check_feature(run => 1)` is false (`die`s with a clear message).
2. Pulls every classifier (`category`, `duration`, `stage`, `min_slots`, `max_slots`).
3. Resolves `smoke`, `fork`, `preload`, `timeout`, `stream`, `io_events` via `check_feature` defaults.
4. Mints `job_id` via `gen_uuid()`, stamps `time`, and assembles the hash with conditional keys (only present when defined).
5. Merges `env_vars` from the test with caller-supplied `env_vars` (caller's keys are overlaid).
6. Splices in `queue_args` and caller's `%inject`.

Old2 split this into `test_settings()` returning a `Test2::Harness2::TestSettings` object. It carries the same fork/preload safety override the current `check_feature` does (non-perl / binary / non-`-w` switches force fork+preload off).

Current ships neither. There is no method on either current file that produces a queue payload. This is the single biggest gap.

**Future home:** `App::Yath2::TestFile`. The Yath2 side is the only place that knows about `gen_uuid`, `job_name`, `run_id`, env merging, and the queue schema.

### 2.5 `input`, `env_vars`, `test_args`, `job_class`, `queue_args`

Legacy carries these as plain HashBase slots; old2 dropped them in favour of TestSettings. Current has none. They are needed at queue-time:

- `input` — stdin to feed the test process.
- `env_vars` — extra environment for the test process; merge semantics as in §2.4.
- `test_args` — arguments after `--` to the test script.
- `job_class` — alternate Job subclass for the runner.
- `queue_args` — arrayref of extra key/value pairs spliced into the queue payload.

**Future home:** `App::Yath2::TestFile` (CLI surface). They never need to be Role-level.

### 2.6 `headers()`, `shbang()`, `meta($key)` accessors

Legacy/old2 expose:

- `headers()` — defensive shallow copy of the raw `_HEADERS` hash. Useful for plugins and debugging.
- `shbang()` — defensive shallow copy of the parsed shebang hash.
- `meta($key)` — list-context accessor: returns the arrayref dereferenced, or `()` when missing.

Current Role has `feature($name)` but nothing for meta or shebang. The Role does declare `meta` and `switches` as default accessors (returning `{}` and `[]`). It does not provide a `meta($key)` lookup helper.

**Future home:** add `meta($key)` to Role (cheap helper around `meta`). `shbang()` and `headers()` are scanner artifacts — keep them on Yath2 only, or drop entirely if nothing reads them.

### 2.7 `check_feature` "fork/preload need -w-only switches and a perl interpreter"

Legacy did **not** apply this safety net inside `check_feature`; old2 applied it in `test_settings()`. Current correctly hoists it into `check_feature`. Keep this behaviour.

Note: current's check is `any { $_ !~ m/^-w$/ }` against `SWITCHES`, which forces fork/preload off when **any** non-`-w` switch is present. Old2's loop is equivalent. Match this exactly when porting.

**Future home:** Role (predicate-style) or Harness2 (which knows the static `non_perl`, `is_binary`, `switches` data). The Role's current `check_feature` doesn't do this safety override; Harness2's does. After the split, the Role's default `check_feature` should keep its plain "look up in `features`" behaviour, and Harness2 should override it with the safety net.

### 2.8 `conflicts_list` shape

Legacy and old2 return `$headers->{conflicts} || []` — an **arrayref**. Current Role returns a **list** (`@$c`) and adds `has_conflicts`. Callers that did `for my $c (@{$tf->conflicts_list})` will need updating; callers that did `for my $c ($tf->conflicts_list)` already work.

**Future home:** Role. Decide on shape and document. Recommend list form (current Role) and keep `conflicts` as the arrayref accessor.

### 2.9 `rank()` / `RANK` table

Identical across all four implementations, including the keys (`smoke`, `immiscible`, `long`, `medium`, `short`, `isolation`). Already in current Role.

### 2.10 `TO_JSON` / `rehydrate`

- Old2: `TO_JSON` is `{ %$self }` — leaks every internal slot and embeds blessed sub-objects (`TEST_SETTINGS`).
- Legacy: no `TO_JSON`.
- Current Role: explicit `json_fields` list, includes a `__test_file_class__` tag, paired with `rehydrate(\%data)` that strips the tag and calls `$class->new(%args)`. This is strictly better. Keep.

`process_info()` from old2 is `TO_JSON` minus the underscore-prefixed slots and TEST_SETTINGS. With current's explicit `json_fields`, `process_info` is redundant.

**Future home:** Role.

### 2.11 `defaults()` hashref + per-attribute reader methods

Current Role uses `defaults()` for both wholesale-override and as the read-through source for every default accessor. This is a new pattern not present in either reference. It is a clear improvement and should stay.

One subtle point: `defaults()` builds fresh mutable sub-containers on every call (per its docstring), but the per-attribute readers all dereference `defaults->{...}`. That means each call to e.g. `$tf->conflicts` on a Role-only consumer (no HashBase shadow) returns a **fresh empty arrayref** — modifications won't persist. The current Class shadows every slot in `init`, so that is fine for production. Worth documenting on the Role to avoid surprise.

### 2.12 `io_events` default

Legacy lists `io_events => 1` in `%DEFAULTS`. Old2 dropped it. Current's Class-level `%DEFAULTS` includes it; Role does not list it explicitly but its `check_feature` (which doesn't consult `%DEFAULTS`) will return `undef` for unknown features. The Class override is correct.

**Future home:** Role's `check_feature` should grow a `%DEFAULTS` table identical to the Class's, so consumers that only `with` the Role still get the right answer.

## 3. Methods/attributes in current that don't exist in references

These are net-new and intentional; calling them out only so the refactor doesn't lose them by accident.

- **`defaults()`** — wholesale-default hashref; new. Keep on Role.
- **`json_fields()`** — explicit serialization list; new. Keep on Role.
- **`rehydrate(\%data)`** — class-tagged constructor lookup; new. Keep on Role.
- **`has_conflicts`** — predicate; new. Keep on Role.
- **`feature($name)`** — single-feature accessor; new. Keep on Role.
- **`absolute()`** as a derived method — legacy/old2 had no absolute accessor (they normalized at init instead). Useful; keep.
- **`_scanned` / `_shbang` slot prefixes** — internal; current and old2 both use them. Keep on Yath2 only.

## 4. Pitfalls for the refactor

1. **`check_feature` is not pure on the current Class.** It calls `$self->scan` and reads `$self->{+NON_PERL}` / `$self->{+IS_BINARY}` / `$self->{+SWITCHES}`. After the split, Harness2 must already have `non_perl`, `is_binary`, `switches`, and `features` populated by Yath2 — no on-the-fly scanning. Drop the `$self->scan` calls; rely on the static data.

2. **`check_duration` / `check_category` / `check_stage` / `check_min_slots` / `check_max_slots` all call `scan`.** Same fix: in Harness2 they should be plain accessors with the documented fallback (`'medium'`, `'general'`, etc.).

3. **`scan()` is a side-effecting method.** It mutates `_HEADERS`, `_SHBANG`, `SWITCHES`, `NON_PERL`, `IS_BINARY`, `FEATURES`, `RETRY`, `RETRY_ISOLATED`, etc. Move it bodily to `App::Yath2::TestFile`. Harness2 must not own it.

4. **`init()` seeds defaults into HashBase slots so accessors don't fall through to the Role.** This works around HashBase shadowing the Role's reader, but it means the Role's accessors are dead in the Class. After the split, decide: either (a) keep HashBase + seed-from-defaults (current pattern) or (b) drop the HashBase slots that overlap defaults and let the Role serve them. Mixed is confusing.

5. **First-wins vs last-wins for HARNESS-JOB-SLOTS.** Legacy uses `//=` (first wins). Old2 uses `//=` and defaults max to `-1`. Current uses an explicit scan-local `$job_slots_set` because its `init()` pre-seeds `MIN_SLOTS` from the role default, so `//=` would never fire. Document the chosen semantics; the role's docs say "max_slots undef = same as min_slots" which conflicts with old2's `-1`.

6. **`conflicts_list` shape change.** Legacy/old2 returned an arrayref; current Role returns a list. Anything that wraps the call in `@{...}` will silently break (returning the count). Audit callers across the codebase before declaring victory.

7. **`absolute` and `relative` derivation lazy on Role, eagerly cached on Class.** If Yath2 sends a JSON payload with `absolute` and `relative` already populated, `rehydrate` keeps them — but the Role's default `absolute()` would re-derive from `file`. The Role's docstring acknowledges this; just make sure Harness2's HashBase shadowing wins so cross-host log replay (where `file` no longer exists) works.

8. **`set_*` mutators in legacy/old2 call `$self->scan` first then write to `_HEADERS`.** Yath2's TestFile, if it keeps mutators, must preserve that scan-then-mutate ordering, otherwise a later `scan()` will clobber the override. The cleaner approach in the new code is to scan first (during construction or finder pass), then freeze the data and pass it to Harness2 as-is.

9. **`THIS IS A GENERATED YATH RUNNER TEST` short-circuits to `features->{run} = 0`.** This is yath leaking into the harness ("Uhg, breaking encapsulation" — original comment). After the split, this lives in Yath2's scanner only; Harness2 just sees `run => 0`.

10. **`env_vars` merge order in `queue_item`.** Legacy does `{ %$mix, %$env_vars }` — caller's env wins **except** where the test file defines the same key. Re-read carefully when porting; it is easy to invert.

11. **`gen_uuid()` belongs to the queue path, not the value object.** `queue_item` stamps a fresh job_id every time it is called. After the split, only Yath2 mints job_ids; Harness2 receives them.

12. **`process_info` from old2 is now redundant.** The Role's `TO_JSON` already restricts to `json_fields`. Don't reintroduce it.

13. **`io_events` default missing on Role.** Role's `check_feature` returns `undef` instead of `1` for `io_events` unless the consumer overrides. Either move the `%DEFAULTS` table onto the Role or have Harness2 override `check_feature`.

14. **`comment` is a Role default of `'#'`** but the scanner reads it via `$self->{+COMMENT} // '#'`. After the split, the scanner should call `$self->comment` so a non-perl test's custom comment char is honoured even if the consumer doesn't seed the slot.

15. **`-B` test in current `_scan` runs against the same `stat` cache as `-e` (`-B _`).** Make sure that idiom survives the move; using `-B $abs` separately would do a second stat.

## 5. Resolutions from Phase 3 implementation

Phase 3 split the TestFile triangle into:

- **Role** — `lib/Test2/Harness2/Role/TestFile.pm`. Pure contract: defaults, helpers, predicates, JSON, rehydrate. No scanning, no mutation, no I/O.
- **Static class** — `lib/Test2/Harness2/TestFile.pm`. HashBase consumer of the role. Constructor takes already-formed data; suitable for harness-side rehydration on a different host.
- **Scanner** — `lib/App/Yath2/TestFile.pm` (new). HashBase consumer of the role; carries the shebang/header parser, the legacy mutator surface, queue-time slots (input, env_vars, test_args, job_class, queue_args), and `queue_item` that mints the runner-queue payload.

### 5.1 Pitfall resolutions

1. **`check_feature` impurity** — Resolved. The role's `check_feature` is now a pure data lookup with no `$self->scan`. `App::Yath2::TestFile` overrides `check_feature` with the scanner-aware "fork/preload off for non-perl, binary, or non-(-w-only) switches" guard, then defers to the role for the actual answer.
2. **`check_*` calling `scan`** — Resolved on the role: `check_duration`, `check_category`, `check_stage`, `check_min_slots`, `check_max_slots`, `check_retry`, `check_retry_isolated` are plain accessors. `App::Yath2::TestFile` overrides them to scan first; the static `Test2::Harness2::TestFile` inherits the pure role versions.
3. **`scan()` is side-effecting** — Resolved. The whole `_scan`, `_parse_shbang`, mutator-state surface moved to `App::Yath2::TestFile`. The harness static class has no scanner-shaped methods.
4. **`init()` seeding pattern** — Q3b option (a) confirmed. Both consumers (the static class and the scanner) seed every role default into their HashBase slots in `init`. The role's per-attribute accessors carry an explicit POD note saying HashBase consumers shadow them with slot readers; the role accessor is the documented fallback for non-shadowing consumers.
5. **HARNESS-JOB-SLOTS first-wins / max default** — Q3.4 option (c) implemented. First-wins kept (scan-local `$job_slots_set`); `max_slots` default `undef`, "each resource interprets". Role POD updated: removed the "undef = same as min_slots" wording in favour of "each resource interprets".
6. **`conflicts_list` shape** — Kept as a list-return on the role (no churn). Audited every caller in `lib/`, `t/`, `xt/`, `scripts/`; nothing in this repo wraps `conflicts_list` in `@{...}`. `queue_item` boxes the list as `[$tf->conflicts_list]` for the queue payload, so downstream consumers expecting an arrayref at the queue boundary still see one.
7. **`absolute`/`relative` derivation** — Resolved. Both static class and scanner cache the derived form into HashBase slots in `init`; the slot reader wins over the role's lazy derivation, so cross-host log replay (where `file` no longer exists) still works.
8. **`set_*` mutators must `scan` first** — Resolved. Every scan-affected mutator (`set_duration`, `set_category`, `set_stage`, `set_min_slots`, `set_max_slots`, `set_retry`, `set_retry_isolated`, `set_smoke`) calls `$self->scan` before writing the override slot. The queue-time slots (`set_input`, `set_env_vars`, `set_test_args`, `set_job_class`, `set_queue_args`) are pure plain setters with no scan side effect (they do not influence directive parsing).
9. **"THIS IS A GENERATED YATH RUNNER TEST" leak** — Resolved. The short-circuit lives in `App::Yath2::TestFile::_scan` only. The harness library never sees it.
10. **`env_vars` merge order in `queue_item`** — Resolved. Preserved as legacy: caller-supplied `$inject{env_vars}` is the base, the test file's `env_vars` layered on top via `{%$mix, %$env_vars}`. The test file wins for any key it defines; everything else from the caller passes through.
11. **`gen_uuid()` belongs to the queue path** — Resolved. `gen_uuid()` is called inside `App::Yath2::TestFile::queue_item` only. The harness static class does not import `Test2::Util::UUID` at all.
12. **`process_info` redundant** — Resolved. Not reintroduced. The role's explicit `json_fields` + `TO_JSON` is the only serialization path.
13. **`io_events` default missing on Role** — Resolved. `%FEATURE_DEFAULTS` (the table that `check_feature` consults when no caller default is supplied) is now defined on the role and includes `io_events => 1`. Consumers that only `with` the role get the documented fallback.
14. **`comment` accessor in scanner** — Resolved. `App::Yath2::TestFile::_scan` reads `$self->comment // '#'`, falling through to the role default for non-shadowing consumers.
15. **`-B _` against the `stat` cache** — Resolved. The init-time binary classification runs `-B _` against the cache from the preceding `-f $file`. The `_scan` lazy classification runs `-B _` against the `-e $self->{+ABSOLUTE}` cache (matching the legacy idiom).

### 5.2 Net-new items (§3) preserved

- `defaults()` — kept on Role.
- `json_fields()` — kept on Role.
- `rehydrate(\%data)` — kept on Role.
- `has_conflicts` — kept on Role.
- `feature($name)` — kept on Role.
- `meta_get($key)` — new helper on Role; legacy's `$tf->meta($key)` idiom collides with HashBase shadowing meta() with a plain slot reader, so the key-lookup variant has a distinct name.
- `absolute()` derived method — kept on Role; both static class and scanner cache the derived form in `init`.
- `_scanned` / `_shbang` slot prefixes — moved to scanner-only (`App::Yath2::TestFile`). The static `Test2::Harness2::TestFile` does not allocate these slots.

### 5.3 Notes for follow-up

- The legacy / old2 `headers()` and `shbang()` defensive-copy accessors were not ported. Nothing in the repo reads them; if a plugin future-need surfaces, expose them on the scanner only.
- `App::Yath2::Finder` previously called the long-dead `$test->test_settings->set_*` chain inside the per-file argv/stdin/env-handling branch. Phase 3.4 replaced it with the new direct setters on `App::Yath2::TestFile` (`set_input`, `set_test_args`, `set_env_vars`).
- HashBase slot vs role accessor: `App::Yath2::TestFile` declares its scanned-data slots as `+name` (constant only, no auto-generated reader) so the explicit "scan first then read" overrides are not shadowed by HashBase's read-only reader. Plain slots (`file`, `comment`, `ch_dir`, `input`, `env_vars`, etc.) keep `<name` for the auto-generated reader.

