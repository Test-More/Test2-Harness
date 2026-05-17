# Render / Formatter / Concluder Refactor — Design Decisions

## Trigger

Brainstorming session driven by `render_formatter_refactor` (root proposal) plus two
companion review documents:

- `render_formatter_refactor_codex.md` — detailed planning notes flagging the
  current `Driver`'s lifecycle-derivation role as the largest migration risk and
  recommending a leaf-only formatter boundary plus a reusable
  watcher/lifecycle component.
- `render_formatter_refactor_gemini.md` — shorter review converging on the same
  shape and surfacing concrete questions around naming, polling, formatter
  interface contracts, and discovery.

This document captures the decisions made during interactive Q&A on
2026-05-17, ready to hand off to a plan-writing agent. The root proposal,
both reviews, and this file together are the inputs for the implementation
plan.

This is an architectural change to the renderer contract, process topology,
log abstraction, and Collector behavior — written as an AI doc per
`CLAUDE.md` rules. An addendum referencing this doc will be appended to
`ARCHITECTURE.md` once the plan is in flight.

## Goals

- Replace the push-stream `Driver` + `OutputManager` architecture with a pull
  model where each renderer runs in its own process and queries a durable log.
- Unify live and replay code paths: same renderer code, different wake-up
  source.
- Introduce a clean `Renderer` / `Formatter` / `Concluder` taxonomy.
- Move artifact-conversion concerns out of renderers into reusable formatters.
- Eliminate Driver's lifecycle-event synthesis — renderers handle lifecycle
  directly.

## Top-level taxonomy

Three categories, with non-overlapping responsibilities:

- **Renderer** — owns a child process, pulls producers and artifacts from a
  `Log`, emits live or replay output to a sink.
- **Formatter** — pure conversion of one artifact (or a subset of items) to a
  target format. Stateless, no log access, no cache awareness.
- **Concluder** — runs in the parent process at end-of-run. Reads the Log
  directly. Replaces the existing `Summary`, `Notify`, and `ResetTerm`
  renderers, which were never really renderers.

Rejected alternatives for the third category:

- `Finalizer` — Codex's pick; rejected because of perceived overlap with
  destructor semantics in mixed-language readers.
- `Reactor` — too broad; would imply mid-run hooks, which are out of scope.
- `PostRun` — generic, but `Concluder` reads better in module paths and POD.

## Process model

`yath render NAME [opts] LOGPATH` becomes a first-class command, both
user-facing (recommended path for one-off use is `yath replay`) and used
internally by `yath test`, `yath run`, and `yath replay` to spawn renderer
children.

Key consequences:

- **CLI is the serialization wire format.** No JSON config file, no special
  parent→child bootstrap protocol. Each renderer registers a `Getopt::Yath`
  option group; parent walks active renderers and forwards each group's
  flags to its child.
- Parent forks one `yath render` child per active renderer. `fork+exec` on
  Linux/BSD/Mac/Solaris; `system(1, ...)` on Windows. Same code path on
  every platform.
- `yath replay LOGPATH` is a thin wrapper that fans out one `yath render`
  child per active renderer, then runs concluders in the parent after
  reaping.
- Concluders run in the parent process **sequentially after all renderer
  children have been reaped**. Guarantees `ResetTerm` runs after the tty
  renderer's child has exited and released the terminal.

Rejected alternatives:

- Per-renderer JSON config file in logdir, child reads on startup — extra
  artifact, more cleanup, no win over CLI.
- Inline JSON in a single CLI arg — Windows quoting pain, ARG_MAX limits.
- Stdin pipe for config — blocks renderer from reading stdin for any other
  purpose; small ergonomic loss.

## Renderer and concluder selection

Symmetric flag pattern, easy to learn:

| Flag | Meaning |
|------|---------|
| `--renderer NAME` | Append `NAME` to active renderer set. |
| `--no-renderer` | Clear renderer set. |
| `--concluder NAME` | Append `NAME` to active concluder set. |
| `--no-concluder` | Clear concluder set. |

Defaults:

- Renderers: `terminal-auto` (picks tty or text formatter based on `-t STDOUT`).
- Concluders: `summary`, `resetterm`.

Per-renderer / per-concluder options use **flat namespacing**:
`--junit-out=res.xml`, `--terminal-color=auto`, etc. Position-dependent
grouping (`--renderer junit --out=...`) was rejected as harder to parse with
`Getopt::Yath`.

If a user activates multiple renderers that target STDOUT, output interleaves.
No protection: garbage in, garbage out.

## Live wake-up mechanism

Two-tier wake-up, both layers built on
`Test2::Harness2::Util::FileMonitor` (inotify on Linux with hi-res-stat
polling fallback elsewhere).

### Producer-level wake-up: LIVE

Built on the existing `$logdir/LIVE` sentinel.

- Collectors **append** one minimal JSON line to LIVE on each producer open
  and close. Schema is intentionally tiny — LIVE is purely a producer-level
  wake-up signal, not an event log:

  ```
  {"k":"producer","id":"...","state":"open","ts":...}
  {"k":"producer","id":"...","state":"close","ts":...}
  ```

  State is fetched from the Log on wake, not parsed from LIVE. Keeping
  semantics out of LIVE keeps live and sealed code paths nearly identical.

- Writes are bracketed by `flock(LOCK_EX)` per existing codebase convention
  (`Util::lock_file` / `Util::unlock_file`). This is the only correct option
  on NFS/SMB-mounted log dirs and matches what `Util/File/Stream.pm` already
  does for similar multi-writer files. Bare `O_APPEND` atomicity is
  insufficient: POSIX guarantees only per-syscall offset-then-write
  atomicity (with a roughly page-sized data-write ceiling on Linux), and
  PerlIO buffering breaks the "one `print` = one syscall" assumption that
  small-write atomicity depends on.

- Lines are kept well under `PIPE_BUF` (4 KB on Linux). The current minimal
  schema is dozens of bytes.

### Artifact-level wake-up: per-file monitors

Producer-level LIVE wake-up is too sparse for verbose live rendering: a
long-running job emits events for minutes between producer open and close,
and the renderer would never see updates in between.

Solution: when a renderer opts into tailing a partial artifact (e.g. a
verbose terminal renderer tailing `events.jsonl.zst` while the job is
still running), it instantiates its own `FileMonitor` on that artifact
file. LIVE stays minimal; artifact-level monitoring is the renderer's
responsibility, scoped to exactly the artifacts it cares about.

Drop the artifact monitor when the producer closes. No central
coordination; each renderer process owns its own watches; the kernel
deduplicates inotify watches across processes.

### Loop summary

- Sealed log: single-pass scan loop over Log, exit.
- Live log: same scan loop + `FileMonitor` on LIVE blocks until producer
  state changes; in verbose modes, additional per-artifact `FileMonitor`
  instances wake the renderer for incremental events. Loop again on any
  wake.

Same renderer code regardless of backend. The watcher "layer" stays small:
LIVE wrapper + opt-in per-artifact wrappers.

## Shutdown signal (three-layer redundancy)

To prevent hung renderer children if the harness exits abnormally:

1. **LIVE removal** by the parent on clean shutdown is the primary signal.
   `FileMonitor` notices, renderer enters drain mode (one final scan loop),
   exits cleanly.
2. **IPC backup signal** from `yath start` / `yath run` covers the case
   where the parent exits without removing LIVE.
3. **PID watch** by the renderer child on harness + command PIDs covers a
   parent crash before any IPC was sent. `kill 0, $pid` is cheap.

Renderer children take `--ipc-endpoint X --parent-pid N --command-pid M`
CLI args so the parent's identity is explicit, visible in `ps`, and
debuggable.

All three checks are evaluated independently on each loop pass; any one
turning positive triggers drain mode. No fixed ordering — simpler logic
and correctness does not depend on which fires first.

## Log abstraction additions

- **Per-kind producer iterators**: `Log->jobs`, `Log->runs`, `Log->services`,
  `Log->collectors`. Each returns an iterator (aligns with the existing
  `Log/Iterator/` infrastructure). Renderers cherry-pick the kinds they
  handle. JUnit only calls `Log->jobs`; default terminal calls `Log->jobs`
  + `Log->runs`; etc.
- **Artifact states**: three values — `missing`, `partial`, `sealed`.
  Corruption surfaces as an out-of-band error from the Log layer, not a
  fourth state, so the renderer state machine stays simple.
- **Live mode is file-backed only.** DB-backed logs are always sealed in
  this design — there are no plans for a live run to write to a database
  directly. DB renderers single-pass, exit. No DB notification channel
  needed yet.

Renderers maintain their own per-producer state hashes and revisit
producers across loop passes (start → events → stop). No persistent
renderer state file: renderer crash + restart loses cursor and replays from
the beginning, which is acceptable since live runs are short and replay is
always single-pass.

## Formatter contract

Pure conversion. The formatter never touches the Log and never reads or
writes the on-disk artifact store.

- **Input modes**: list, filehandle, or one-at-a-time `->append($item)`.
  The last is useful when something wants to format only a subset of items
  on demand.
- **Output**: dual mode. With `out_fh => $fh` the formatter writes to the
  supplied filehandle. Without, it returns a string. One method, two
  call shapes.
- **Setting-free output (default).** Most formatter output is canonical:
  no theme baking, no width wrapping, no verbosity filtering. Renderer
  applies those at display time. Persisted formatter artifacts are
  reusable across settings.
- **`produces_artifact` attribute on the formatter class.** True by
  default. Setting-bearing formatters (those whose output is meaningfully
  parameterized by theme/color/width/etc.) set this to false: their output
  is not persisted as a formatter artifact because there is no single
  canonical form to record. `tty` is the primary example — its output
  depends on theme, color mode, and possibly terminal width. The renderer
  runs the `tty` formatter live and writes to the terminal, but does not
  persist the result to the log.
- **Discovery via namespace convention**: `App::Yath2::Formatter::<Name>`.
  No registry, no plugin hook. Matches existing yath plugin conventions.

Rejected alternatives:

- Per-setting persisted artifacts (e.g. `events.tty.dark`,
  `events.tty.light`) — filename explosion, no clear win.
- Formatter recurses into Log to fetch related artifacts — Codex's
  warning: blurs renderer/formatter line, makes the artifact store
  unmanageable.

## Formatter artifacts

Formatter output that is persisted to the log is treated as a **formatter
artifact** — a first-class artifact alongside `events.jsonl`,
`spec.jsonl`, etc. The term "cache" is intentionally avoided: these files
are not an invalidatable cache. They are durable records of the canonical
formatter output produced at capture time. They are not a transcript of
what the renderer actually showed the user — renderer-applied behavior
(theme, color mode, width wrapping, quiet/QVF/verbose policy) is not
baked into a formatter artifact. Looking at the original canonical output
later is the primary purpose; refreshing to current formatter output is
opt-in. (A separate user-visible terminal transcript artifact could be
added later if needed; it is out of scope for v1.)

Storage and writing:

- Owned by the **renderer layer**, not the formatter layer. Formatters
  are pure functions; renderers decide when and where to persist output.
- Only formatters with `produces_artifact = true` write artifacts.
  Setting-bearing formatters such as `tty` never write to the log because
  there is no single canonical form to record.
- Sibling-file model: `events.jsonl` → `events.txt`. Filename extension
  matches formatter name.
- Compression matches the source artifact: zstd-compressed output when
  the source artifact is zstd-compressed, plain bytes otherwise. Reuses
  the existing `Util::Zstd::Writer` infrastructure. **The compression
  extension is always visible in the filename**: a plain source produces
  `events.txt`; an `events.jsonl.zst` source produces `events.txt.zst`.
  Filenames must never lie about whether the bytes are compressed.
- Atomic write via temp file + `fsync` + rename, encapsulated in a
  `write_artifact_atomic` helper on the Renderer base/role so individual
  renderers cannot accidentally publish partial files.
  **Existing-file-wins on concurrent publication**: if a complete artifact
  is already in place at publish time, the helper does not overwrite it.
  The publish step is explicit (exclusive create / link / rename guarded
  by an appropriate lock or absence check, depending on platform — Perl's
  plain `rename` overwrites on most platforms, so the helper cannot rely
  on it alone). This avoids inode churn and avoids replacing a complete
  artifact already published by another renderer. The helper's durability
  guarantee is scoped narrowly: readers never observe partial formatter
  artifacts. Full power-loss durability on every filesystem is not
  promised; directory-fsync-after-rename can be added later if a use case
  requires it.
- Tarball logs are read-only — no formatter artifact writes there.

Validation (deliberately permissive):

- **Silent stale-use is intentional, not an oversight.** Formatter
  artifacts in a log are the historical canonical output captured at run
  time. A later yath upgrade ships a new formatter version, but rendering
  an old log still surfaces the originally captured output by default.
  This is the desired behavior. Refreshing to current formatter output is
  opt-in.
- `meta.json` at log root carries `{ formatters: { txt: '1.0', ... } }`.
  Informational, consulted only when the user explicitly asks for a
  refresh.
- `--reformat` opt-in flag on `yath render` rebuilds any formatter
  artifacts whose `meta.json` version doesn't match the current formatter
  for the current invocation. The log on disk is rewritten in place.
  Against a read-only log (tarball, etc.) `--reformat` errors clearly and
  directs the user to `yath reformat LOG OUTLOG`. `--reformat` is the
  "rewrite artifacts" flag; it does not silently degrade to in-memory
  regen when it cannot write.
- `yath reformat LOG [OUTLOG]` standalone command rebuilds all formatter
  artifacts in a log. One arg = in-place rewrite (requires writable log);
  two args = updated copy at `OUTLOG` (original untouched, supported path
  for tarball and other read-only backends). Useful for refreshing
  captured logs after a yath upgrade without re-running tests.

## Verbosity

Global default with per-renderer override. Only renderers whose output
meaningfully varies by verbosity declare a flag. JUnit ignores verbosity
entirely (its output is always the full set of test results in the
contracted XML shape).

Verbosity decides which artifacts a renderer requests and what detail level
is passed to formatters. It is **not** implemented as a global event filter
chain (the legacy `OutputManager` approach).

## Daemon mode (`yath start`)

Per-run renderer lifetime. Each `yath run` spawns its own renderer
children and reaps them when the run ends. The persistent daemon itself
does not host renderers. Matches the non-daemon test flow exactly; no
"renderer reset between runs" logic needed.

## Concluder execution

v1 concluder execution is strictly sequential and synchronous in the
parent process after all renderer children have been reaped. A slow
concluder (e.g. a Notify concluder waiting on an external service) will
delay command exit. This is an accepted tradeoff for simplicity and
deterministic ordering of `ResetTerm`.

Future work may add an async opt-in slot for concluders that can run in
the background (typically external-notification concluders that do not
need to complete before command exit). This is documented as a planned
extension, not a v1 deliverable. The v1 API must not foreclose it — keep
the concluder dispatch loop arranged so a future `async` attribute on
the concluder class can be honored without an architectural rework.

## Renderer crash handling and criticality

Each renderer class declares its criticality:

- `best_effort` — crash is logged as a warning, other renderers and
  concluders proceed, run exit code is unaffected. Used for human-facing
  output where missing output is annoying but not failure-mode.
- `required` — crash logs a warning and sets a nonzero renderer-failure
  status that affects the run's exit code. Used for outputs whose absence
  is a real problem (typically machine-consumed: JUnit XML, structured
  reports). Default for file-producing renderers whose output is the
  whole point of running the renderer.

Defaults:

- Default terminal renderer: `best_effort`.
- JUnit and other explicit file-producing renderers: `required`.
- Concluders: `best_effort` by default, with exceptions only where
  existing behavior already treats failure as fatal.

The user can override per-renderer with a flag (e.g.
`--renderer-critical NAME` to mark required, or
`--renderer-best-effort NAME` to mark best-effort).

A crashed renderer always appears in the final summary so the user knows
to investigate.

Rejected alternatives:

- Auto-restart — extra complexity; renderer has no persistent cursor, so
  restart replays from the beginning anyway. User can rerun `yath replay`
  if they want the output.
- Flat policy across all renderers — too coarse. CI users need JUnit to
  fail loudly; humans don't need a missing terminal renderer to fail their
  test run.

## Disposition of current renderers

| Current renderer | Disposition |
|------------------|-------------|
| `Default` | Split into `terminal-auto` selector + `txt` and `tty` formatters reused by the terminal renderer. |
| `Summary` | Move to Concluder. |
| `Notify` | Move to Concluder. |
| `ResetTerm` | Move to Concluder. |
| `JUnit` | Migrate. Self-contained, no XML formatter (XML's monolithic `<testsuites>` wrapper does not align with piecemeal artifact caching). Writes the whole document at end of run. |
| `DB` | Remove. DB is a log source now, not a sink. |
| `Driver` | Remove once all renderers migrated. |
| `Formatter` (legacy) | Remove. Was never used. |
| `Logger` | Remove. The log layer is the authoritative event store. |
| `TAPHarness` | Remove. |
| `Server` | Stub for now. Future server renderers will pull cached formatter output. |

## Migration staging

No bidirectional adapter. Codex's option of translating watcher events back
into synthetic lifecycle facets was considered but rejected: those
synthetic events were an artifact of the old push-stream design, not a
durable interface. New renderers handle producer lifecycle directly.

Old renderers continue to run via the current `Driver` path until each is
individually rewritten. The two systems run in parallel during the
migration window. No cross-translation glue.

Stages, roughly in order:

1. Add per-kind producer iteration to the `Log` abstraction.
2. Extend `Collector` to append minimal LIVE lines on producer open/close,
   bracketed by `flock`.
3. Add Formatter infrastructure: namespace convention,
   `App::Yath2::Formatter::Txt`, `App::Yath2::Formatter::Tty`, dual-mode
   output contract.
4. Build the new Renderer base/role: Log-pull loop, `FileMonitor`-driven
   wake-up, three-layer shutdown detection, renderer-layer
   sibling-file caching.
5. Convert the default terminal renderer first. This validates the
   end-to-end path.
6. Convert `Summary`, `Notify`, `ResetTerm` to Concluders. Add Concluder
   dispatch in the parent process after renderer reap.
7. Convert JUnit (self-contained, end-of-run write).
8. Add `yath render` and `yath reformat` commands.
9. Remove `Driver`, `OutputManager`, legacy `Formatter`, `Logger`,
   `TAPHarness`, `DB` renderer.
10. Stub `Server` for future work.

## Test approach

Parity testing is deferred. New renderers are tested on their own merits;
output may differ from the old renderers. The refactor is an opportunity
to improve output, not a contract to preserve old formatting verbatim.

The test suite still needs to cover, per Codex:

- Live terminal rendering against a live log.
- Sealed / extracted log replay rendering.
- QVF behavior: passing job suppresses verbose event output, failing job
  prints it.
- Cache hit/miss for sealed artifacts.
- Tarball logs never produce cache writes.
- Concurrent renderers requesting the same artifact don't corrupt the
  cache (atomic rename, last-writer-wins).
- Concluder execution at end of run.
- Best-effort renderer crash surfaces in final output and does not affect
  the run's exit code.
- Required renderer crash (e.g. JUnit or another explicit file-producing
  renderer) surfaces in final output and affects the command exit
  status.

## Open items that became non-issues

Several open questions from Codex / Gemini either dissolved or were
answered by earlier decisions:

- **Polling contention** (Gemini) — dissolved. Each renderer process owns
  its own `FileMonitor` instances; the kernel deduplicates inotify
  watches.
- **Directory-listing cache** (Gemini) — unneeded; renderers never list
  directories, they iterate via `Log`.
- **Cache key fields** (Codex) — collapsed. Formatter artifacts are keyed
  by filename only. Setting-free formatters write artifacts;
  setting-bearing formatters (like `tty`) don't write artifacts at all.
- **Watcher wake-up API** (Codex) — collapsed to `FileMonitor` on LIVE
  plus optional renderer-owned per-artifact monitors. Producer lifecycle
  did **not** collapse: it is handled by the producer-index/lifecycle API
  on the Log abstraction (the required first planning deliverable).
  `FileMonitor` is the wake-up primitive, not the lifecycle abstraction.
- **Producer descriptor schema for notifications** (Codex) — LIVE schema is
  minimal (wake-up only). Full producer data comes from the Log
  abstraction, where its shape is already defined by existing producer
  artifacts.

## Suggested first planning deliverable

A plan-writing agent should produce, in order:

1. Detailed spec for the per-kind producer iterators on each Log backend
   (`Live`, `Directory`, `TarZIdx`, `DB`).
2. Schema for the minimal LIVE append line and the Collector hook points
   that emit it.
3. Renderer base/role API: Log-pull loop, FileMonitor integration,
   shutdown-detection layers, per-producer state machine.
4. Formatter base/role API: dual input/output modes, namespace discovery.
5. Renderer-layer formatter-artifact helper (sibling-file write,
   `write_artifact_atomic`, compression-visible filenames).
6. `yath render` and `yath reformat` command skeletons + flat option
   namespacing example.
7. Per-renderer migration table with conversion order and test scope.
8. Migration stages 1–10 above, expanded into reviewable tasks.

The plan should not start with formatter modules in isolation — the Log
producer iterators and Collector LIVE-append hooks are the foundation
everything else builds on.

## Implementation notes from reviews

Carry forward into the plan, but they do not change the design above:

- **Atomic-write helper on the Renderer base/role** (Gemini 3.2): provide a
  single `write_artifact_atomic($name, $content, $suffix)` helper that
  encapsulates `tempfile` + `fsync` + `rename`, so individual renderers
  cannot accidentally publish partial files.
- **Bulk-fetch / windowed iterators on DB and TarZIdx backends** (Gemini
  3.3): `Log->jobs`, `Log->runs`, etc. should batch their underlying
  reads to avoid N+1 query patterns when renderers scan for new producers
  on each loop pass.
- **Option-spec sharing via templates** (optional): renderers all use
  strictly flat-namespaced options (`--junit-out`, `--terminal-out`,
  etc.), but the option specs themselves can be generated from a small
  shared template so naming stays consistent across renderers without
  introducing a shared `--out` flag.
- **Producer-index/lifecycle API spec** (Codex Bottom Line item 2): the
  per-kind Log iterators (`Log->jobs`, `->runs`, `->services`,
  `->collectors`) must each define producer identity, parentage, type,
  state (`missing`/`partial`/`sealed`), artifact references by kind,
  status/report availability, start/end timestamps, retry/try identity,
  and per-backend behavior across `Live`, `Directory`, `TarZIdx`, and
  `DB`. The first planning deliverable must include this descriptor
  schema in full — `FileMonitor` on LIVE is the wake-up primitive, not
  the lifecycle abstraction.
- **CLI-as-wire-format escaping tests** (Codex Medium): cover spaces and
  shell metacharacters in log paths, Windows argument passing, repeated
  options, empty-string option values, and very long option sets in the
  test suite for the `yath render` boundary.
- **Flat option prefix ownership** (Codex Medium): document the rule that
  each renderer/concluder name owns its option prefix exactly. A plugin
  or future renderer may not register an option prefix already owned by
  another component. Enforce in registration time, not at parse time.
