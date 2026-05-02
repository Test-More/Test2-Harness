# Full audit refactor (AUDIT3)

## Trigger

User staged AUDIT3 and a fan-out of inline TODO comments across the
codebase, then asked for the full set to be executed in one
connected branch (`full_audit`). The review covers archive format,
LogArchive consumer API, logger / file_ext machinery, the
artifacts manifest, the per-cwd index, IPC info file naming,
project name resolution, the Options::Logging library, the test
command's structure, and the zstd writer's frame layout.

This branch is the response. Each of the eleven commits below is
the resolution of one item from AUDIT3 or one inline-comment
cluster, with paired test updates.

## Commits

| # | Commit | Item |
|---|---|---|
| 1 | `aa5ce1aaa` | Drop `App::Yath2::LogArchive::Format` |
| 2 | `15742b6e2` | Drop `file_ext` + `ChangeWatch` role; `FileMonitor.static`; `Artifact->watch` |
| 3 | `34ff5cd23` | `spec.json` via `run_queued` event + Logger::JSON |
| 3 | `d0ff09910` | Drop `artifacts.json` manifest; LogArchive scans files |
| 4 | `6e8750af8` | Project name fallback chain |
| 4 | `e09370ab6` | Options::Logging -> Options::LogArchive |
| 4 | `6e57181bf` | IPC filename project/user/command/stamp/pid |
| 4 | `d0ff09910` | (combined) Eliminate CwdIndex; last_log.yath |
| 5 | `ad366d803` | Command::test refactor |
| 6 | `f8ca41024` | Command::extract -> Getopt::Yath |
| 7 | `e25ddc9f8` | Command::archive default name |
| 8 | `d8d38e874` | LogArchive.pm import cleanup |
| 9 | `1e02a6078` | `say()` compresses payload+newline |

## Architectural decisions

### LogArchive: only one format, simpler factory

The `Format` module's catalogue was scaffolding for archive formats
that were deleted in the zstd-loggers spec. With tar.zidx the only
output, format detection collapses to a `-d` test on the path:

```
LogArchive->open(file => ...)  # TarZIdx
LogArchive->open(dir  => ...)  # Directory
LogArchive->open(path => ...)  # -d decides
```

`viable()` and `default_writer_format()` go away with the catalogue.
The `TAR_ZIDX_MAGIC` / `TAR_ZIDX_FOOTER_LEN` constants move into
`LogArchive::TarZIdx` since that is now their only consumer. The
`create()` shim that wrapped `open->archive` is dropped; callers do
the two-step explicitly.

### Logger lookup by class name, not file_ext

`file_ext` was removed from the Logger role's required methods. An
artifact with extension `.xyz` is produced by
`Test2::Harness2::Collector::Logger::XYZ` (also tried as `Xyz` and
`xyz`). LogArchive reverses the mapping by name lookup: per-ext,
try the three casings in upper / capital / lower order; first class
that loads + responds to `update_type` wins. The result is cached
per-ext; on miss, `LogArchive->artifact($logical)` croaks with a
message naming the extension and the namespace to install into.

This eliminates a class-method round-trip on every logger and lets
new loggers slot in without registry editing -- name the class
right and LogArchive finds it.

### Drop the artifacts.json manifest

`Test2::Harness2::_write_artifacts_manifest` and the per-run
counterpart in `RunService` were the only producers of
`artifacts.json[.zst]`; both are deleted. The on-disk manifest
existed solely to map physical paths back to logger classes. Once
the extension itself names the producing logger, the manifest
becomes redundant -- consumers walk `list_files()` and dispatch by
extension directly.

`LogArchive::artifacts` and `iter_artifacts` rebuild from
`list_files`. `manifest_drift()` is gone -- there is no manifest
to drift from.

Post-AUDIT4 follow-up: `runs()` initially used
`runs/<id>/spec.json[.zst]` as the "this is a real run" marker
(replacing the old artifacts.json gate). That was wrong --
existence of a run is the directory itself, even when no files
have landed yet. `runs()`, `jobs()`, and `services()` now report
every immediate child of `runs/`, `runs/<run>/tests/`, and
`services/` (or the run-scoped equivalent). The `include_empty`
option is gone. A new `list_dirs()` backend method drives this:
the Directory backend walks the filesystem, the TarZIdx backend
reads explicit directory entries from its index and additionally
derives parent-of-file paths for older archives. The TarZIdx
writer now records every source directory as a typeflag-`'5'`
index entry so empty directories survive archive -> extract.

Service layout migrated as part of the same change so the
directory-presence rule applies to services too. Each service
gets a per-name directory; `Logger::JSONL` / `Logger::JSON`
write per-leaf files under it (`events.jsonl`, `state.json`).
The is_run case keeps run-leaves at the run-dir level
(`runs/<run>/events.jsonl`, `runs/<run>/state.json`) -- the run
directory itself is the run signal, not a nested
`runs/<run>/services/<name>/` subdir. `run_log_leaf` is renamed
`log_leaf` and now applies to both the is_run and the
service-scope branch.

### spec.json migrates to a logger

Per AUDIT3 §5: spec.json should be written by a logger, not by a
RunService-side direct write. Implementation:

- `RunService::service_on_start` emits a new harness event:
  `kind => 'run_queued', run_data => $run->TO_JSON`, before any
  state broadcast.
- `Logger::JSON::log_event` branches on `kind`:
  - `run_mutation` -> update the cached run snapshot for state.json
  - `run_queued`   -> write `runs/<run_id>/spec.json.zst` from the
    payload, gated on `is_run` so non-run-service collectors ignore
    it.
- `RunService::_write_run_spec` is gone.

Other event consumers may also see the run_queued event; only the
JSON logger acts on it.

### ChangeWatch role removed; FileMonitor learns static mode

`App::Yath2::LogArchive::Role::ChangeWatch` is deleted. The role
existed to give Artifact change-watch semantics that mirrored
FileMonitor's, with separate code paths for live vs. sealed
archives. Two simpler primitives replace it:

1. `FileMonitor` gains a `static` attribute. When true, change
   detection is bypassed entirely: the first
   `changed/peek_changed/await_change` returns the truthy result,
   every subsequent call returns 0. `await_change` no longer
   sleeps in static mode.

2. `LogArchive` (the base class) gains `static`, derived from
   `is_live`. `Directory` mirrors `!is_live`; `TarZIdx` is always
   static.

`Artifact` no longer consumes the role and no longer implements
changed/peek_changed/await_change/delegate. Instead it grows a
`->watch` method that constructs (and does NOT cache) a
FileMonitor with the artifact as the delegate and the archive's
static flag forwarded. Consumers drive the standard
`while (my $del = $monitor->changed) { ... }` loop on the returned
monitor regardless of backend.

`LogArchive->watch_artifact($logical)` is a one-liner shortcut for
`->artifact($logical)->watch`.

### Eliminate CwdIndex; introduce last_log.yath

`Test2::Harness2::Util::CwdIndex` was Phase-8 infrastructure
(per-cwd JSON store of "the latest yath archive for this cwd").
Two simpler affordances replace it:

1. `./last_log.yath` symlink, written by `Command::test` after
   every archive is written. Refuses to clobber a regular file at
   the target name.

2. `App::Yath2::LogArchive->find_latest($settings)` -- single
   canonical no-arg discovery for `extract` / `replay` / `failed` /
   `speedtag` / `times`. Honours `./last_log.yath` first; if absent,
   globs `${TMPDIR}/${project}-${user}-*.yath`, sorts by stamp
   parsed from the filename, breaks ties on hi-res mtime. Returns
   undef when project is `__UNKNOWN__` (refuses to glob across
   projects).

### Project name resolution

A new option_post_process on `App::Yath2::Options::Yath` derives the
project name when `--project` was not set:

1. Basename of the rc-file directory (`$settings->yath->config_file`
   / `user_config_file`, populated by App::Yath::Script::V2).
2. Walk up from cwd looking for any of `.git`, `.svn`, `.cvs`,
   `lib`, `t`. Stops one step before `$HOME` or `/`.
3. Basename of cwd itself.
4. The literal sentinel `__UNKNOWN__` when cwd is `/` or `$HOME`,
   or when no other rule produced a name.

The fallback uses values App::Yath::Script::V2 already populates;
no new config file lookup is performed at this layer.

### IPC info filename: project + user + command + stamp + pid

The old `yath-${type}-${user|host}-${pid}-${uuid}` shape (with
`type` being `nonce` or `persistent`) becomes:

```
${project}-${user}-${command}-${stamp}-yath-${pid}-ipc.json
```

`stamp` is `YYYYMMDD-HHMMSS`, `command` is the user-facing yath
subcommand. Filenames sort by stamp; pid disambiguates concurrent
same-command runs in the same project. `publish_ipc_file` takes
`command =>` instead of `type =>`; `find_ipc_files` filters by
`command =>`. The JSON payload drops `type` and gains `command`,
`project`, `stamp`.

### Options::Logging -> Options::LogArchive

Renamed for what it actually owns (the log archive destination, not
the logging system in general). Group renames `logging ->
log_archive`; help category renames `Logging Options -> Log Archive
Options`. `Renderer::Logger`'s separate 'logging' group is unrelated
and stays as-is.

### Default archive path

`Command::archive` and `Command::test` both default to:

```
${TMPDIR}/${project}-${user}-${stamp}-${pid}.yath
```

(Replaces `yath-${stamp}-${pid|uuid}.yath`.) Pairs cleanly with the
glob `find_latest` uses.

### Zstd writer: newline lives inside the frame

JSONL needs a trailing newline per record. `Util::Zstd::Writer->say`
compresses `payload + "\n"` together so a frame uncompresses to a
complete line. `Logger::JSONL` always uses `->say` (the cached
compressed-frame fast path is dropped -- the cached bytes had no
newline). `Command::extract` simplifies: the multi-frame walk just
concatenates decompressed frames; no per-frame newline injection.

### Command::test structural cleanup

`run()` was 250+ lines of mixed orchestration, defensive guards, and
side effects. Now it is a thin orchestrator that delegates to:

- `_collect_test_files` -- walk @args + extension filter
- `_spawn_harness` / `_build_resources` -- instantiate the resource
  set Options::Resource's post-process settled on
- `_publish_ipc` -- publish_ipc_file + signal handlers
- `_queue_run` -- hand the file list to the harness
- `_drive_streamer` -- stream events through the renderer
- `_shutdown_harness` -- unsubscribe + drain + finish + reap
- `_resolve_archive_path` -- --log-file / --log-dir / default

The `eval { $settings->can('check_group') && ... }` guards are gone.
Tests must mock the option groups they exercise (per AUDIT3:
production code does not contain test-aware logic).

## Decisions made by user

These came up during execution and were resolved by the user:

- IPC `type` field: drop, callers pass `command =>`.
- Archive filename: include `-${pid}` to disambiguate same-second
  runs.
- Project unresolvable: error (sentinel `__UNKNOWN__`).
- Run-queued event consumed by JSON Logger; other consumers may
  also see it.
- Logger ext lookup: strict ext match, no substring fallback.
- LogArchive->open arg shape: keep all three of file/dir/path; the
  path form uses `-d` to decide.
- Drop `viable()` everywhere.
- `Writer->say` compresses payload + newline together.
- No test-only branches in lib/. Tests must mock properly.
- `last_log.yath` symlink wins; else glob by stamp + hi-res mtime
  tiebreak. Project-only.

## Alternatives considered and rejected

- **Keep `manifest_drift`**: there is no manifest to drift from.
- **Surface spec/state/events from `iter_artifacts`**: when both
  spec.json and state.json exist with same `run_id`, the
  Streamer::Static state-collection path picks one as base and
  loses the others' results (spec.json's empty `done` clobbers
  state.json's populated one). Kept iter_artifacts manifest-only;
  once spec is naturally in the manifest (after the spec-via-logger
  change), the special case goes away.
- **Croak in `find_latest` when project is `__UNKNOWN__`**: caller
  needs the standard "no archive" error path, not a different one.
  Returns undef instead.
- **Recompress every cached event frame to add the newline**:
  evaluated keeping the cached-frame fast path with a trailing
  newline frame appended; the bookkeeping outweighed the saved
  compress, so the fast path is just gone. Always recompress
  through `->say`.

## Tests removed

- `t/AI/unit/Util/CwdIndex.t` -- module gone.
- `t/AI/integration/cwd_index_wiring.t` -- integration for gone module.
- `t/AI/unit/Harness2/Harness_artifacts.t` -- pinned manifest writes.
- `t/AI/unit/Harness2/RunService_artifacts.t` -- same.
- `t/AI/integration/local_artifact_links.t` -- the
  --local-artifact-links option is gone (replaced by
  unconditional last_log.yath).
- `t/AI/unit/LogArchive/Format.t` -- module gone.
- `t/AI/unit/Collector/Logger/JSONL_compressed_form.t` -- the
  cached-compressed-frame fast path is gone.

## Tests updated

Roughly two dozen tests across the AI suite needed Fake-settings
mocks fleshed out (project / user / finder / resource->classes /
log_archive / tests groups), or assertions adjusted to the new
filename shapes / no-manifest behaviour.

## Final state

`AUTHOR_TESTING=1 prove -j8 -Ilib -It/lib -r t/AI` -> 911 tests
pass across 103 files. Three reruns to confirm stability.
