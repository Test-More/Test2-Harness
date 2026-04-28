# AUDITS — multi-step project plan

This document turns the freeform feedback in `AUDITS` (the dash-separated note
file) and the inline `# ...` comments left in the working tree into a
sequenced project. Each step states what to do, why, the concrete touch-points
already identified, and the dependencies between steps. Three companion audit
reports — `TEST_FILE_AUDIT.md`, `COLLECTOR_CLEANUP.md`, `CWD_FILES.md` — were
produced as part of preparing this plan and are referenced where relevant.

Steps are grouped by phase. Phases are ordered to minimize churn: foundational
utility/style work first, then user-facing semantic changes, then larger
refactors that depend on the foundation, then audits/analyses that should be
revisited after the relevant code stabilizes.

Sources for each step are cited as `AUDITS:N` (the original note file at
working-copy line N) or `<path>:<line>` for inline comments.

---

## Phase 0 — Style and conventions baseline

These should land first. Several later steps cite the style guide; pulling it
out now means later commits can reference it instead of relitigating
formatting in every PR.

### Step 0.1 — Create `STYLE_GUIDE.md` and migrate the style sections

- Create `STYLE_GUIDE.md` at the repo root.
- Move every style-only rule out of `CLAUDE.md` and `ARCHITECTURE.md` into
  `STYLE_GUIDE.md` (object base class, role mechanism, eval pattern, fork
  pattern, `croak` vs `die`, perltidy use, `//=`, no trailing whitespace, no
  emojis, postfix conditionals, `push @x => ...`, named-subs-must-be-methods
  rule, etc.).
- Add the new rule from `AUDITS:194-228`: one-line subs go near the top of
  the file (after `use`/`BEGIN`); when grouped under a role-section "fold"
  comment, the one-liners go to the top of that section.
- Replace the migrated sections in `CLAUDE.md` and `ARCHITECTURE.md` with a
  one-line pointer to `STYLE_GUIDE.md` so neither doc carries a copy.

Sources: `AUDITS:194-228`.

### Step 0.2 — Sweep modules to match the one-liner-at-top convention

- For each module under `lib/Test2/Harness2/`, `lib/App/Yath2/`,
  `lib/App/Yath2DB/`, `lib/App/Yath2UI/`, audit accessor-style and
  predicate-style one-line subs and float them to the top of the file (or
  the top of the role-section fold).
- Do this **after** the bigger refactors in Phases 2 and 3, otherwise large
  module rewrites will undo the sweep. Tag the step as a follow-up; do not
  block other work on it.

Sources: `AUDITS:194-228`.

---

## Phase 1 — File / IO utility cleanup

Several inline comments and the first two `AUDITS` blocks line up: tear the
change-detection logic out of the `Util::File*` hierarchy, replace it with a
small dedicated `FileMonitor` class, and let the existing zstd
reader/writer classes do streaming directly. This is a prerequisite for the
JSON-logger relocation in Phase 4 and for the collector cleanup in Phase 5.

### Step 1.1 — Add `Test2::Harness2::Util::FileMonitor`

- New module `lib/Test2/Harness2/Util/FileMonitor.pm`.
- Constructor: `new(file => $path, delegate => $obj?)`. `file` required.
- Initial state: file is "changed" until first `changed()` call returns
  truthy.
- Use hi-res mtime (Time::HiRes / `stat` with `Time::HiRes::stat`), not
  low-res. Where Linux::Inotify2 is usable it should still feed this class
  (the inotify gating constant currently lives in `Util/File.pm` and should
  move here).
- API:
  - `changed()` — returns `$delegate` if present, else `1`, on change;
    returns `0` (false) when no change. No timeout.
  - `await_change($timeout?)` — blocks until change or timeout; returns
    `$delegate` / `1` on change, `0` on timeout.
  - `delegate()` — returns the delegate or `undef`.
- Idiomatic usage that the class must support:
  ```perl
  while (my $delegate = $f->changed) {
      push @lines => $delegate->read_lines;
  }
  ```
  An "extra empty read" race is acceptable (documented).

Sources: `AUDITS:3-25`, `lib/Test2/Harness2/Util/File.pm:29` ("Remove this
for FileMonitor"), `lib/Test2/Harness2/Util/File.pm:81`,
`lib/Test2/Harness2/Util/File/JSON.pm:33,47`.

### Step 1.2 — Strip change-detection out of `Util::File*`

- Revert `Util::File`, `Util::File::JSON`, `Util::File::JSONL`,
  `Util::File::JSON::Zstd`, `Util::File::JSONL::Zstd`, `Util::File::Stream`,
  `Util::File::Value` to plain read/write/decode/encode.
- Remove `read_if_changed`, the `_inotify*` HashBase slots, `reset()` flush
  helpers, and the inotify constant from `Util::File`.
- Remove `read_line` from `Util::File::Value` (single-value file does not
  need a line API). Source: `lib/Test2/Harness2/Util/File/Value.pm:23`.
- Touch `Util::JSON` to drop the `stream_json_l*` exports (no longer have a
  consumer once the `Stream` parent class is gone).

Sources: same as 1.1, plus `lib/Test2/Harness2/Util/JSON.pm:14`.

### Step 1.3 — Repoint consumers at FileMonitor + the right delegate

- Anything currently calling `read_if_changed` or polling file mtime gets a
  `FileMonitor` instance with the appropriate `Util::File::*` (or
  `Util::Zstd::Reader`) as the delegate.
- For zstd-streamed logs, use the zstd `Reader` class as the delegate
  directly.
- The JSONL consumer that the user flagged (`log_reader` in
  `Collector/Logger/JSONL.pm:187`) should be re-implemented this way. See
  Step 4.1 for the full JSONL rewrite.

Sources: `AUDITS:21-25`, `lib/Test2/Harness2/Collector/Logger/JSONL.pm:187`.

### Step 1.4 — Delete `Util::File::Stream` and `::JSONL::Zstd`, rework `::JSONL`

- Delete `Test2::Harness2::Util::File::Stream` and
  `Test2::Harness2::Util::File::JSONL::Zstd`.
- Rewrite `Test2::Harness2::Util::File::JSONL`:
  - Parent becomes `Test2::Harness2::Util::File::JSON` (not `::Stream`).
  - It assumes the file is **complete** (not still being written).
  - Override `read` to return the list of decoded items.
  - Add `read_line` (singular) that decodes one line.
  - Override `write` and `rewrite` to take lists, encoding each item with a
    trailing newline.
- For incremental log readers, callers use `FileMonitor` + the zstd
  `Reader`, not the `JSONL::Zstd` class.

Sources: `AUDITS:1`, `lib/Test2/Harness2/Util/File/JSONL.pm:10,17-19`,
`lib/Test2/Harness2/Util/File/Stream.pm:5`,
`lib/Test2/Harness2/Util/File/JSONL/Zstd.pm:5`,
`lib/Test2/Harness2/Util/File/JSON/Zstd.pm:5`.

### Step 1.5 — Zstd dictionary / level cleanup

- Benchmark our streaming zstd (`Reader` + `Writer`, no helper class) with
  and without the custom dictionary.
- If the dictionary's compression-ratio improvement is not material, delete
  the dictionary and every code path that loads, ships, or references it.
- Remove every place that explicitly sets compression level 3 (it is the
  library default).
- Remove the per-instance `bless` that exists only because IPC currently
  passes args to the zstd serializer; with no args the serializer can be
  used directly as a class. Touch points:
  `Test2::Harness2::Util::IPC.pm:26` (the `IPC_DEFAULT_ZSTD_LEVEL` constant
  to retire), and any `JSON::Zstd`/`Zstd::Stream` callsites that pass
  `level => 3`.

Sources: `AUDITS:28-30`, `lib/Test2/Harness2/Util/IPC.pm:26`.

---

## Phase 2 — Naming / terminology

### Step 2.1 — Disambiguate the word "synthetic"

The term currently means two unrelated things:

1. The skip/fail-when-resource-unavailable behavior (resources side).
2. Auto-generated events emitted when no `job completed` message is seen
   (auditor / collector side).

Pick one of the two to rename and update every reference (code, tests,
docs, `ARCHITECTURE.md`). Recommended: keep "synthetic" for the
event-fabrication case (it's the more idiomatic English use of the word)
and rename the resource-side behavior to something unambiguous — e.g.
`skip_unavailable` or `unavailable_action`. Confirm direction with
Exodist before doing the rename, since the code-search blast radius is
non-trivial.

Sources: `AUDITS:64-67`.

---

## Phase 3 — TestFile refactor

This is a structural change; most of the Phase 3 substeps depend on each
other. Do not start until Phase 0 is in place (style guide will apply to the
new files) and Phase 1 is done (the new TestFile classes will not need any
file-watching).

The companion audit `TEST_FILE_AUDIT.md` enumerates the gaps between the
current `Test2::Harness2::TestFile` / `Role::TestFile` and the
`reference/legacy` / `reference/old2` versions. Use it as the punch list for
3.3.

### Step 3.1 — Carve out the role

- `Test2::Harness::Role::TestFile` becomes the contract.
- It keeps: `defaults`, `TO_JSON`, `rehydrate`, `feature($name)`, `rank`,
  `comparable`, "is feature X enabled?" predicates, `meta($key)`, plus the
  cheap `check_*` helpers that operate purely on already-known data.
- It must not contain anything that scans the file or mutates state.
- `check_feature` and similar must become pure data lookups (no implicit
  `scan()`). See `TEST_FILE_AUDIT.md` "Pitfalls" for the full list.

Sources: `AUDITS:34-60`, `TEST_FILE_AUDIT.md`.

### Step 3.2 — `Test2::Harness2::TestFile` becomes static

- Implementation of the role with **set values** for every required
  field. No mutators. No scanning. Constructor takes the data already
  built.
- The harness and run services consume only this class (or a hashref of
  the same shape).
- Drop any method that scans, reads headers, validates `-f`/`-x`, or
  computes something that should already be computed by the producer.

Sources: `AUDITS:36-44`.

### Step 3.3 — `App::Yath2::TestFile` becomes the scanner

- Implementation of the role that knows how to:
  - Validate the file exists and is executable where required
    (the `-f` / `-x` checks the legacy code does).
  - Read shebang and `HARNESS-*` headers.
  - Apply CLI / settings overrides (the mutators
    `set_duration`, `set_category`, `set_stage`, `set_min_slots`,
    `set_max_slots`, `set_retry`, `set_retry_isolated`, `set_smoke`,
    plus `input`, `env_vars`, `test_args`, `job_class`, `queue_args`).
  - Produce the queue payload (the legacy `queue_item` /
    old2 `test_settings` equivalent).
  - Serialize itself to a hash (`TO_JSON` from the role) for handoff.
- `App::Yath2` constructs these, scans/builds them, then serializes to
  hashes that get queued to the harness — paths alone are no longer
  passed.
- The harness rehydrates a static `Test2::Harness2::TestFile` from each
  hash. `App::Yath2DB`/`UI` plugins (future) inject TestFiles here.
- The "THIS IS A GENERATED YATH RUNNER TEST" short-circuit moves to
  Yath2 (it is currently a Yath concern leaking into the harness scanner).

Sources: `AUDITS:34-58`, `TEST_FILE_AUDIT.md` "Biggest gap" / "No mutators"
/ "No queue-time attributes" / "Net-new in current".

### Step 3.4 — Migration sweep

- Update every queue producer (Yath commands) to construct
  `App::Yath2::TestFile` and pass the serialized form.
- Update every queue consumer (harness, run service, collector spec
  builder, JSON logger) to take the static form.
- Watch out for `conflicts_list` shape change (arrayref vs. list) — silent
  breakage of `@{...}` callers.
- Decide explicitly on `HARNESS-JOB-SLOTS`: legacy first-wins vs. old2's
  `-1` default for max. `TEST_FILE_AUDIT.md` flags this.

Sources: `AUDITS:46-49`, `TEST_FILE_AUDIT.md` "Pitfalls".

### Step 3.5 — TestFile audit follow-up

`TEST_FILE_AUDIT.md` already exists from this planning pass. Reread it as
the work in 3.1–3.4 lands; cross items off and append corrections. The
"Methods/attributes that exist in current but not in references" section
needs an explicit keep/drop call once the new home is decided.

Sources: `AUDITS:58-60`, `TEST_FILE_AUDIT.md`.

---

## Phase 4 — Run / Run::State split and log layout

These three changes are tightly coupled (the JSON logger writes the run
spec, and the on-disk layout depends on what is being written). Do them
together. Depends on the TestFile refactor (Phase 3) — `Run` carries
TestFile data, and the queue path will be cleaner once 3.3 is done.

### Step 4.1 — Split `Test2::Harness2::Run`

- `Test2::Harness2::Run` becomes a simple, immutable spec: what is needed
  to queue a run, construct it, add tests, and pass to `$harness->queue`.
  No state tracking.
- `Test2::Harness2::Run::State` is a new module that owns the runtime
  state (start time, completion, counters, sync-up-to-harness payload).
- Some attributes will overlap; some will be exclusive to one side. The
  state object is the one synced from the run service back up to the
  harness.

Sources: `AUDITS:232-238`.

### Step 4.2 — Rework the JSON logger's on-disk layout

- The JSON logger no longer writes `runs/UUID.json`. Instead:
  - `runs/UUID/spec.json` — the `Run` object.
  - `runs/UUID/state.json` — the `Run::State` object.
- The `.jsonl` event log moves to `runs/UUID/events.jsonl`.
- Update the JSONL log reader (already targeted in Step 1.3 / Step 1.4) so
  the new path is the canonical one and the old layout is migrated or
  rejected with a clear error.

Sources: `AUDITS:240-243`.

### Step 4.3 — Update consumers

- `yath replay`, `yath archive`, `yath extract`, the renderer pipeline,
  and the audit/observer subscribers must all read the new layout. The
  `CWD_FILES.md` audit lists every artifact and producer; reuse it as
  the change-set checklist.

Sources: `CWD_FILES.md`.

---

## Phase 5 — Collector cleanup

This depends on Phase 1 (the IO/file-monitor split) and on the
RunService cleanups in Phase 4. The companion report `COLLECTOR_CLEANUP.md`
contains the full analysis. Order the substeps low-risk → high-risk.

### Step 5.1 — Quick win refactors (in-tree)

From `COLLECTOR_CLEANUP.md` "In-tree options":

- Replace the two trivial subclasses `Collector::Service::Run` and
  `Collector::Service::Harness` with kwargs on the base.
- Move pure helpers (`_spec_class`, `_validate_spec`, `_win32_quote_arg`,
  `_kill_child`, `_make_warn_handler`, `FileLineReader`) into a new
  `Test2::Harness2::Collector::Util` module.
- Push Win32-specific code paths (~340 lines) into a `Collector::Win32`
  module loaded only on `IS_WIN32`.

These three together cut `Collector.pm` from ~1947 to ~1000 lines with no
behavior change.

Sources: `AUDITS:149-156`, `COLLECTOR_CLEANUP.md` "In-tree options".

### Step 5.2 — Optional follow-up: roles for cross-cutting concerns

Roles to consider per the report:

- `HasLoop` — the run loop.
- `HasIPC` — IPC outbox drain (currently entangled at
  `Collector.pm:1004-1035` and `:1740-1752`).
- `HasObserverChain` — parser → auditor → logger wiring.
- `HasAuditor` — only `Collector::Test` actually uses this; pull it off
  the base.

Defer until 5.1 ships and the file is small enough to read.

Sources: `COLLECTOR_CLEANUP.md`.

### Step 5.3 — Process-Collector extraction analysis (no extraction yet)

The user requested an analysis-only audit; that is `COLLECTOR_CLEANUP.md`.
The recommendation in that report is: do 5.1 now, do **not** extract
Process-Collector yet, and revisit only when there is a concrete second
consumer or when the loop / exit paths grow callback hooks for
outbox/exit-struct that make extraction a near-rename.

No code change in this step. Re-read the report and either schedule the
extraction (open a tracking issue) or close the question explicitly.

Sources: `AUDITS:158-190`, `COLLECTOR_CLEANUP.md` "Recommendation".

### Step 5.4 — Local hygiene: shorten oversized auditor methods

- `Collector::Auditor::Test::_audit` and `_subtest_process` are explicitly
  flagged as too long. Split each into smaller per-condition helper
  methods.
- Make sure `_normalize_event` and friends still benefit from being
  one-liners (apply Phase 0 ordering rules).

Sources: `lib/Test2/Harness2/Collector/Auditor/Test.pm:174,308`.

### Step 5.5 — Tidy `RunService` request-launch path

- `request_handler_launch_job` validates `test_file` is absolute by regex
  (`m{^/}`); replace with a portable check (e.g. `File::Spec->file_name_is_absolute`)
  so Win32 paths work.
  (`lib/Test2/Harness2/RunService.pm:189`)
- The dynamic `require Test2::Harness2::TestFile` inside the request
  handler should become a `use` at the top of the file.
  (`lib/Test2/Harness2/RunService.pm:222`)
- `run_on_general_message` should dispatch by method name with a
  prefixed namespace, e.g. `_handle_gen_msg_${kind}`, to avoid colliding
  with unrelated method names.
  (`lib/Test2/Harness2/RunService.pm:450`)
- The `spawn` method's parent branch was unfolded into a postfix `return`
  — keep the postfix form per the style guide.
  (`lib/Test2/Harness2/RunService.pm:905`)

Sources: same files, lines as cited.

---

## Phase 6 — Resource model overhaul

These items are interrelated: removing the implicit `JobCount` mandate from
the harness, moving it to `yath test`, and seeding the new utilization
machinery. Do 6.1 first (it is purely subtractive on the harness side), then
6.2 (yath test injection), then 6.3+ (utilization stubs).

### Step 6.1 — Harness no longer mandates a job limiter

- Drop the `is_job_limiter` method.
- Stop auto-injecting `JobCount` from inside the harness.
- A harness with **no resource classes** is a valid configuration (an
  unlimited concurrency harness). Anything that asserted the presence
  of a limiter loses the assertion.

Sources: `AUDITS:71-87`.

### Step 6.2 — `yath test` becomes the limiter source

- `yath test` decides:
  - If any resource class is specified at the CLI (directly, or pulled in
    by another flag like `-j`), do nothing.
  - Otherwise, inject `JobCount` with a default computed via `Sys::Info`,
    falling back to 2 if `Sys::Info` is unavailable.
- Adjust tests to construct the resource list at the Yath layer rather
  than relying on harness defaults.

Sources: `AUDITS:73-87`.

### Step 6.3 — Add the `--utilize` / `-U` option stub

- Option lives in the Resource options library.
- Accepts a number `0 < x < 100` (exclusive on both ends).
- Documented intent (in the option's POD/help): finds and includes any
  resource class implementing the new `UtilizerResource` role; each
  takes the percentage and returns "temporarily unavailable" once its
  monitored subsystem (cpu, memory, /tmp, etc.) exceeds that percentage.
- Pair the percentage gating with a spawn-throttle so the system has time
  to *actually* consume the resources before more spawn:
  - In a sliding 2-second window, count `(spawned - exited)` deltas.
  - If the delta is at or above a per-class threshold, wait one more
    second before starting the next batch.
  - If 40 spawn and 40 exit in 2s (delta 0), do not throttle.
- Stub the option only — leave the role and the per-resource implementations
  for follow-on steps.

Sources: `AUDITS:91-117`.

### Step 6.4 — Define `UtilizerResource` role + apply to existing resources

- New role: `Test2::Harness2::Resource::Role::Utilizer` (or similar).
  Required: ability to receive the `--utilize` percentage and signal
  temporary unavailability.
- Apply the role to existing resources that can be utilization-gated:
  - `lib/Test2/Harness2/Resource/Memory.pm`
  - `lib/Test2/Harness2/Resource/PipeLimits.pm`
  - `lib/Test2/Harness2/Resource/UnixLimits.pm`
- Add a `# Implementation note: this can use the percentage when wired up`
  comment at the top of each so the next reader knows.

Sources: `AUDITS:107-116`.

### Step 6.5 — New stub resources

- `lib/Test2/Harness2/Resource/TempSpace.pm` — subclass of the `Disk`
  resource with the disk auto-set to the system temp dir.
- `lib/Test2/Harness2/Resource/CPU.pm` — gates on aggregate CPU usage
  across all CPUs.
- Both implement `UtilizerResource`.
- Stub only; document the role contract and that they need the percentage.

Sources: `AUDITS:112-116`.

### Step 6.6 — Memory resource: history-aware (note for implementor)

When `Resource::Memory` is implemented, it should also consult the most
recent log (or yathdb / yathui history once they exist) for historical
per-test memory usage to decide whether running a test is safe given
current free memory. Capture this as a TODO comment in the stub now.

Sources: `AUDITS:120-121`.

---

## Phase 7 — Hash seed feature

Self-contained but touches both Yath and the harness preload story. Do
after Phase 4 (run/state split lands first because the seed lives on a
run, not globally).

### Step 7.1 — Add `--set-hash-seed` (auto option)

- New option in the Yath options layer. "Auto" type:
  - With no value: defaults to the year+month+day string the
    `App-Yath-Script` `yath` shim currently generates.
  - With a value: uses the user-supplied seed verbatim
    (`--set-hash-seed=12345`).
- The option emits an env var (the standard Perl hash-seed env var,
  `PERL_HASH_SEED`, plus any other knobs the existing shim sets) for
  every test process before spawn.

Sources: `AUDITS:124-129`.

### Step 7.2 — Preload integration

- A preload tied to a run with `--set-hash-seed` set must start with the
  env var set so the children it forks inherit the desired seed.
- `--set-hash-seed` also applies to global preloads attached to the
  harness.
- When `yath start` and `yath run` are rewritten, both must accept the
  option for global preloads.
- A run-queue attempt where the run's seed setting (or value) disagrees
  with the queue's global seed setting must be **rejected** with a clear
  error.

Sources: `AUDITS:131-143`.

### Step 7.3 — Drop the logic from `App-Yath-Script`

- Remove the seed-setting `exec` from `../App-Yath-Script/script/yath`.
- Coordinate the release of `App-Yath-Script` with the cpanfile bump in
  this distribution, since CI runs against both pinned and unreleased
  variants of the wrapper.

Sources: `AUDITS:146-147`.

---

## Phase 8 — Move artifacts out of CWD

Depends on the run/state on-disk layout from Phase 4. The companion audit
`CWD_FILES.md` already enumerates everything written today.

### Step 8.1 — Land defaults that already favor temp

- The workdir already defaults to `<sys_tmp>/yath-<uuid>`
  (`lib/App/Yath2/Options/Workspace.pm:14-30`); nothing to change there.
- Per `CWD_FILES.md`, the **only unconditional cwd writer** in a normal
  `yath test` is the archive. Make `--archive` default to the workdir
  (or to the temp area) and require an explicit flag/path to land it in
  cwd. Update the tests that pin the cwd-relative behavior
  (`t/AI/integration/test_command_loggers.t:117-124`).
- The IPC info file's directory order
  (`lib/App/Yath2/Options/IPC.pm:32`) defaults to `[user_rc, project_rc,
  cwd, tempdir]` — flip to `[tempdir, user_rc, project_rc, cwd]` so a
  user with no rc files lands the file in temp.

Sources: `CWD_FILES.md`, `AUDITS:248-254`.

### Step 8.2 — Add `--link-to-cwd` (or similar) flag

- New flag that, after a run, symlinks (or copies) "useful" artifacts —
  archive, IPC info file, primary log dir — into the cwd.
- Useful so users who *want* the files visible can keep that workflow
  without forcing every run to write there.

Sources: `AUDITS:248-252`.

### Step 8.3 — Cwd → temp association index

For artifacts that live in temp, we still want commands like `yath
replay` (no args) to find "the run that came from this cwd". Pick one of
the four options outlined in `CWD_FILES.md` "Association problem". The
report's recommendation is: maintain a small JSON index file in the
yath temp root, keyed by the cwd absolute path → run UUID(s), and have
each command look there first.

Sources: `AUDITS:248-254`, `CWD_FILES.md` "Association problem".

---

## Phase 9 — Documentation pass

A final pass, after the above phases land. None of this is interesting on
its own, but it is what catches stale references.

- Reread `ARCHITECTURE.md` end-to-end and reconcile it with everything
  done above. Wherever a phase produced a deviation from the original
  spec, append the deviation as an addendum at the bottom of
  `ARCHITECTURE.md` per the project rule in `CLAUDE.md`.
- Reread `PLAN` and either trim items now done or add follow-up entries
  for things this project deferred (Process-Collector extraction,
  utilization role implementations, memory history lookup, etc.).
- Confirm `STYLE_GUIDE.md` (Step 0.1) is the only place style rules live.
- Delete the planning artifacts that should not be persistent
  (`AUDITS` (the old freeform note), `IPC_AND_LOGGERS.bak.*`, the inline
  `# ...` review comments left in modified files), once each one's
  content has been absorbed by the relevant step.

---

## Sequencing summary

```
0.1 ──▶ 0.2 (deferred sweep)
0.1 ──▶ 1.x ──▶ 4.x ──▶ 8.x
0.1 ──▶ 3.x ──▶ 4.x
0.1 ──▶ 2.1 (independent)
0.1 ──▶ 6.x (independent of 1/3/4 but reads cleaner once 0 lands)
4.x ──▶ 7.x
1.x + 4.x ──▶ 5.x
all ──▶ 9 (docs)
```

Phases are roughly sized: 0 small, 1 medium, 2 small, 3 large,
4 medium-large, 5 large, 6 medium, 7 medium, 8 small-medium, 9 small.
