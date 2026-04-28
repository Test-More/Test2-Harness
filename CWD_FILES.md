# CWD / non-temp artifacts produced by yath

Audit of every path yath writes that is NOT inside a system temp directory
(or that may land in CWD by default), with module + line cites, triggers,
lifetime, and downstream readers. Goal: inform the planned move-to-temp
+ symlink/write-back option work. Findings only. No code changes.

## 1. Summary table

| # | Artifact | Producer (path decided at) | Default location | Configurable? | Trigger / command |
|---|---|---|---|---|---|
| 1 | `<YYYYMMDD-HHMMSS>.yath` archive | `lib/App/Yath2/Command/test.pm:261` (stamp), `:274` (cwd fallback), `:276` (`LogArchive->create`) | **CWD** (relative; resolved against process cwd by `open` in `LogArchive::TarZIdx::write_archive` `lib/App/Yath2/LogArchive/TarZIdx.pm:265`) | Yes -- `--log-file PATH` (verbatim) or `--log-dir DIR` via `lib/App/Yath2/Options/Logging.pm` | `yath test` always (the archive is unconditional, regardless of `-L`) |
| 2 | `<YYYYMMDD-HHMMSS>.yath` archive | `lib/App/Yath2/Command/archive.pm:53` (stamp), `:59` (`LogArchive->create`) | **CWD** | Optional positional second arg to `yath archive` | `yath archive` when no archive name positional arg supplied |
| 3 | Extracted log tree (`./logs/`) | `lib/App/Yath2/Command/extract.pm:76` (default `'./logs'`), `:82` `make_path`, `:126` per-file `open '>'` | **CWD/logs/** (relative) | Optional positional `destination` arg | `yath extract ARCHIVE` with no explicit destination |
| 4 | `test.pl` runner shim | `lib/App/Yath2/Command/init.pm:39` `open_file('test.pl', '>')` | **CWD** | No (always cwd) | `yath init` |
| 5 | Edited test files (in place) | `lib/App/Yath2/Command/speedtag.pm:206` per-file `open '>'` | The test file's own absolute or relative path | n/a (rewrites existing files) | `yath speedtag` |
| 6 | `durations.json` | `lib/App/Yath2/Command/speedtag.pm:42` (autofill), `:223` `$jfile->write` (uses `Test2::Harness2::Util::File::JSON->new(name=>...)` and `write_file_atomic` in `lib/Test2/Harness2/Util.pm:444`) | **CWD/durations.json** when `--durations-file` is supplied with no path | Yes -- `--durations-file=/path/to/x.json` | `yath speedtag --durations-file` |
| 7 | IPC info file `.yath-<type>-<host>-<pid>-<uuid>` | `lib/App/Yath2/Util/IPC.pm:120` `publish_ipc_file`; dir resolution at `:77` `resolve_ipc_dir`; per-symbol mapping at `:55` `_dir_for_symbol` | First writable dir in `dir_order` default `[user_rc, project_rc, cwd, tempdir]` (`lib/App/Yath2/Options/IPC.pm:32`). `cwd` value = `$settings->yath->cwd`, set in `lib/App/Yath/Script/V2.pm:72`. So in practice: `~` (when `~/.yath.user.rc` exists) or project dir (when `.yath.rc` lives in repo) or **CWD** or **`/tmp`** (only when nothing earlier in the order is writable) | Yes -- `--ipc-dir`, `--ipc-dir-order`, `--ipc-file` (`lib/App/Yath2/Options/IPC.pm:21-57`); env vars `T2_HARNESS_IPC_DIR`, `YATH_IPC_DIR` | `yath test` (`type=nonce`) -- `lib/App/Yath2/Command/test.pm:156`. Also `yath start` (`type=persistent`) when reimplemented. |
| 8 | Workdir tree `yath-<uuid>/` (logs, IPC sockets, child tmpdirs) | `lib/App/Yath2/Options/Workspace.pm:14-30` `_workdir_default`; option default at `:66`; `Test2::Harness2->init` validates and creates `$logdir`/services at `lib/Test2/Harness2.pm:108-122` | `<system tmpdir>/yath-<uuid>` | Yes -- `--workdir` / `T2_WORKDIR` / `YATH_WORKDIR` (`lib/App/Yath2/Options/Workspace.pm:41-67`) | All commands that spawn a harness (`yath test`, `yath start`, ...). Removed at end of run unless `--keep-dirs` (`lib/App/Yath2/Command/test.pm:283`). |
| 9 | Workdir-internal tmpdir `<workdir>/tmp/` | `lib/App/Yath2/Options/Workspace.pm:69-90` (sets `TMPDIR`, `TEMPDIR`, `TMP_DIR`, `TEMP_DIR`) | `<workdir>/tmp` | Yes -- `--tmpdir` / `T2_HARNESS_TEMP_DIR` / `YATH_TEMP_DIR` | All commands using a harness |
| 10 | `start` daemon log `log.jsonl` | `lib/App/Yath2/Command/start.pm:206` `log_file` accessor uses `$settings->workspace->workdir`; `:230` `open '>', $out_file` | `<workdir>/log.jsonl` (under `/tmp/yath-<uuid>` by default; never in cwd unless caller pinned `--workdir`) | Inherits `--workdir` | `yath start` (currently dies before reaching this -- see XXX TODOs in `start.pm:7-9`) |

The **per-run on-disk artifacts** all live under `$logdir = <workdir>/logs/`,
which by default is inside the system tmpdir. Listed in section 2 below for
completeness because the user's plan to "default these to a temp directory"
implies awareness of every file even when the file is already temp-based.

## 2. Per-artifact detail

### 2.1 Archive file (`yath test`'s `<stamp>.yath` in CWD)

This is the headline cwd offender.

- **Where path is decided:** `lib/App/Yath2/Command/test.pm:260-274`.
  - `:261` builds `$stamp = strftime('%Y%m%d-%H%M%S', localtime)`.
  - `:267-273` honors `--log-file` / `--log-dir`.
  - `:274` `$archive //= "$stamp.yath";` -- bare relative filename, so the
    later `open` resolves it against process cwd.
- **Where it actually gets written:** `lib/App/Yath2/Command/test.pm:276-281`
  calls `App::Yath2::LogArchive->create(source => "$workdir/logs", path => $archive, ...)`.
  Writer is `App::Yath2::LogArchive::TarZIdx::write_archive`, which opens
  `"$out.tmp.$$"` then renames over `$out` (`lib/App/Yath2/LogArchive/TarZIdx.pm:259-265`).
  Both path and tmp are resolved against cwd if `$archive` is relative.
- **Lifetime:** persisted; NOT deleted -- the workdir is removed
  (`lib/App/Yath2/Command/test.pm:283`) but the archive is the only
  surviving copy of run state after exit.
- **Read by:** `yath replay LOG`, `yath extract ARCHIVE`, `yath speedtag`,
  `App::Yath2::LogArchive` callers, the user. These all need the path
  given to them on the CLI -- the archive does not have to be discoverable
  by yath itself.
- **Test that pins this:** `t/AI/integration/test_command_loggers.t:117-124`
  asserts the archive is named `YYYYMMDD-HHMMSS.yath` and lives in cwd.
- **Migration note:** safe to default-route to a temp location so long
  as the path printed by `:281` `Wrote archive: $archive ...` continues
  to point users at the location, and so long as `--log-file` and
  `--log-dir` continue to honor whatever the user specifies verbatim.
  This is the artifact most likely to need a CWD <-> temp-path index
  (see section 3).

### 2.2 Archive file (`yath archive`'s default name)

- `lib/App/Yath2/Command/archive.pm:53`: `$archive //= strftime(...) . '.yath';`
  -- relative, written via the same `LogArchive::TarZIdx` writer.
- Same cwd-resolution semantics as 2.1 but only fires when the user
  did not pass an output filename. User-supplied paths pass through verbatim.
- **Migration note:** mirroring whatever policy is chosen for `yath test`'s
  archive.

### 2.3 `yath extract` default destination

- `lib/App/Yath2/Command/extract.pm:76`: `my $dest = shift @$args // './logs';`
- Refuses to overwrite if `$dest` exists (`:80`); creates it via
  `make_path` (`:82`); each entry is opened with `open '>', $abs`
  (`:126`) where `$abs = File::Spec->catfile($dest, $out_rel)` (`:100`).
- **Lifetime:** persisted by user choice.
- **Read by:** the user; `yath replay` accepts an extracted directory
  carrying `artifacts.json` at the top level (`replay.pm:37-50`,
  `LogArchive::Directory.pm:78`).
- **Migration note:** would not be moved to temp -- this is a
  user-driven extract. Could grow a "stash to temp by default" mode,
  but not in scope.

### 2.4 `yath init` -- `test.pl`

- `lib/App/Yath2/Command/init.pm:39`: `open_file('test.pl', '>')`. Always
  cwd, by design (the command's purpose is to seed a project's runner).
- Out of scope for this audit; behavior is correct.

### 2.5 `yath speedtag` -- in-place file edits + `durations.json`

- `lib/App/Yath2/Command/speedtag.pm:206` writes back over each test file
  whose duration tag changed (paths are wherever the test file lives;
  not cwd-relative).
- `:42` autofill default for `--durations-file` is the relative literal
  `'durations.json'` (cleaned by `clean_path`). Written via
  `Test2::Harness2::Util::File::JSON->write` (`:223`), which delegates to
  `write_file_atomic` (`lib/Test2/Harness2/Util.pm:444`) and resolves the
  `$pend` next to the target (`"$file.pend"`).
- **Migration note:** speedtag is explicitly a "modify the user's working
  copy" command; keep cwd default. Out of scope.

### 2.6 IPC info file (`.yath-<type>-<host>-<pid>-<uuid>` / `yath-<type>-<user>-<pid>-<uuid>`)

- Producer: `lib/App/Yath2/Util/IPC.pm:120-170` `publish_ipc_file`.
  - When `--ipc-file` is set the path is used verbatim (`:135-137`).
  - Otherwise `resolve_ipc_dir` (`:77-95`) walks `dir_order`. Default
    order from `lib/App/Yath2/Options/IPC.pm:32`:
    `[user_rc, project_rc, cwd, tempdir]`. The first writable dir wins.
  - Filename (`resolve_ipc_filename`, `:28-46`): non-tempdir variant is
    dotfile-prefixed (`.yath-...`), tempdir variant is plain (`yath-...`).
- Producer call site for `yath test`: `lib/App/Yath2/Command/test.pm:156-161`,
  with `type => 'nonce'`.
- **Default location in practice:**
  - If `~/.yath.user.rc` exists, the user_rc dir wins -- usually `$HOME`,
    so `~/.yath-nonce-<host>-<pid>-<uuid>`.
  - Otherwise if `.yath.rc` lives in the project, project_rc wins --
    project root, so `<project>/.yath-nonce-...`.
  - Otherwise `cwd` wins -- **CWD** gets the dotfile.
  - Only when none of those are writable does `tempdir` get hit.
- **Lifetime:** for `yath test` it lives only for the run --
  `Scope::Guard` at `test.pm:164-166` plus signal handlers at `:173-175`
  unlink it. Crashes before guard install or signal-uncaught aborts can
  leave it behind; `find_ipc_files` (`Util/IPC.pm:222-272`) reaps stale
  files via `pid_is_running` liveness check on later runs.
- **Read by:** future client commands (`yath ping`, `yath status`,
  `yath kill`, etc.) via `find_ipc_files`; also `yath test`'s own
  re-resolution if multiple harnesses live concurrently.
- **Contents:** harness pid, ipcm_info bus address, workdir, project,
  uuid, user, hostname (`Util/IPC.pm:151-167`). The *contents* already
  contain the workdir path, so this file is itself a candidate for the
  CWD-association index (see section 3).
- **Migration note:** the dir-order machinery already exists. The user's
  goal could be expressed by changing the default order to put `tempdir`
  first, with `cwd`/`project_rc`/`user_rc` available as opt-in via
  `--ipc-dir-order`. Or by writing primary file to temp and a small
  pointer/symlink in cwd.

### 2.7 Workdir `<sys_tmp>/yath-<uuid>/`

- Producer: `lib/App/Yath2/Options/Workspace.pm:14-30`. Default uses
  `File::Spec->tmpdir()` so this is **already temp**. Just listing here
  for completeness because every run-time artifact below lives inside it.
- **Lifetime:** removed at end of run by `lib/App/Yath2/Command/test.pm:283`
  unless `--keep-dirs` (`Workspace.pm:33-39`).
- **Override:** `--workdir`, `T2_WORKDIR`, `YATH_WORKDIR`.

### 2.8 Workdir-internal tmpdir `<workdir>/tmp/`

- Producer: `lib/App/Yath2/Options/Workspace.pm:69-90`. Default
  `<workdir>/tmp`. Sets `TMPDIR`, `TEMPDIR`, `TMP_DIR`, `TEMP_DIR` for
  child processes (tests + services) so their own `File::Temp` calls
  land here.
- Also already temp-rooted. Listed for completeness.

### 2.9 Run service log dir `<workdir>/logs/`

`Test2::Harness2->init` (`lib/Test2/Harness2.pm:96-152`):

- `:108-111` resolves `$logdir = <workdir>/logs/` (relative paths under
  workdir, absolute paths used as-is).
- `:113-120` refuses to clobber a non-empty existing logdir.
- `:122` `make_path("$logdir/services")` creates the harness-scope
  service log subdir.
- `:149-151` copies the active zstd dictionary to
  `<logdir>/zstd-dict.bin` so loggers downstream resolve it locally.
- All `<logdir>/...` paths below are inside this tree.

#### Files written under `<logdir>` by various producers

The path-derivation rule is centralized in
`lib/Test2/Harness2/Role/Collector/Logger.pm:111-138` (`output_file_basename`).

| Pattern | Decided in | Producer | Trigger | Lifetime |
|---|---|---|---|---|
| `<logdir>/zstd-dict.bin` | `lib/Test2/Harness2.pm:150` | Harness init | Always when a dict is available | Per-harness; lives until workdir removed |
| `<logdir>/artifacts.json.zst` | `lib/Test2/Harness2.pm:715` (`_write_artifacts_manifest`); writer `lib/Test2/Harness2/Util/JSON.pm:93+` | Harness service | On every `collector_artifacts` IPC message merge | Per-harness; rewritten incrementally |
| `<logdir>/services/<service_name>.{jsonl,json}.zst` | Logger role rule `Role/Collector/Logger.pm:131-132`, JSONL output `Logger/JSONL.pm:49`, JSON output `Logger/JSON.pm:52` | Per-service collector (harness-scope service collectors -- e.g. `harness.jsonl.zst`) | Whenever a service collector with a JSONL/JSON logger runs | Per-service-instance; appended (jsonl) or atomically replaced (json) |
| `<logdir>/runs/<run_id>.{jsonl,json}.zst` | Logger role rule `Role/Collector/Logger.pm:133` (the `is_run==1` collapse for the run service's own collector) | Per-run service collector (`Collector::Service::Run` interpose) | Once per run | Per-run; jsonl appended, json atomically replaced |
| `<logdir>/runs/<run_id>/services/` | `lib/Test2/Harness2/RunService.pm:97-98` `make_path` | RunService init | Once per run | Per-run |
| `<logdir>/runs/<run_id>/services/<svc>.{jsonl,json}.zst` | Logger role rule `Role/Collector/Logger.pm:134` | Per-run service collector for resource services, etc. | When a per-run service runs with a logger | Per-service-instance under a run |
| `<logdir>/runs/<run_id>/tests/<job_id>.{jsonl,json}.zst` | Logger role rule `Role/Collector/Logger.pm:128` | Per-test-job collector | Every test job spawned by `RunService::request_handler_launch_job` (`lib/Test2/Harness2/RunService.pm:159-274`) | Per-job; lives in archive |
| `<logdir>/runs/<run_id>/artifacts.json.zst` | `lib/Test2/Harness2/RunService.pm:653-670` `_write_artifacts_manifest` (path at `:656-657`); writer `lib/Test2/Harness2/Util/JSON.pm` | Run service | On every `collector_artifacts` merge from a job | Per-run; rewritten incrementally |
| `*.pend` sibling files (transient) | `lib/Test2/Harness2/Util.pm:447` `write_file_atomic` (and `:482` `write_file_atomic_mode`) | Every atomic-write site | Briefly during each atomic write | Microseconds (renamed over target) |
| `<archive>.tmp.<pid>` | `lib/App/Yath2/LogArchive/TarZIdx.pm:260` | `LogArchive->create` | During archive write | Briefly during write (renamed over `$archive`) |

These all live inside the workdir, which is already temp-rooted.
Inventoried so the move-to-temp conversation has a complete map.

#### Read by

- `App::Yath2::LogArchive::Directory` (`lib/App/Yath2/LogArchive/Directory.pm:78`)
  treats a logdir as a readable archive (used by `yath replay` against a
  directory and by `yath archive` when bundling).
- `App::Yath2::LogArchive::TarZIdx::write_archive`
  (`lib/App/Yath2/LogArchive/TarZIdx.pm:255-300`) walks the logdir to
  pack the tar.zidx archive at end of `yath test`.
- `App::Yath2::Streamer::Live` (instantiated at
  `lib/App/Yath2/Command/test.pm:195-200` with `log => "$workdir/logs"`)
  tails individual files inside the logdir during the run.
- `Test2::Harness2::Collector::Logger::JSONL::log_reader`
  (`Logger/JSONL.pm:188-208`) and the JSON sibling
  (`Logger/JSON.pm:176-199`) are used during streaming/replay; they
  walk up from the path looking for `zstd-dict.bin`.

### 2.10 IPC bus / unix sockets

- Created by `IPC::Manager` (external dist) inside the system TMPDIR
  (Tester sets `TMPDIR=/tmp` in spawned children at
  `lib/App/Yath2/Tester.pm:152` to avoid hitting Linux's 104-byte
  `sun_path` limit).
- Out of scope for this audit -- already temp.

## 3. Association problem

Several artifacts that the user wants to move into a temp directory still
need to be *findable from CWD* later. Inventory of candidates and minimal
proposals.

### 3.1 Candidates

The artifacts that, once relocated to temp, will need a CWD -> temp-path
mapping:

- **The archive file (2.1).** This is the big one. After `yath test` exits,
  the user expects `*.yath` discoverable from cwd by `yath replay`,
  `yath extract`, `yath speedtag`, etc. If it moves to temp, those
  follow-up commands run from the same cwd need to know which archive
  was the last one for that cwd.
- **The IPC info file (2.6).** Already partially temp-aware via the
  `dir_order` machinery. If the default is flipped to temp-first, daemon
  commands (`yath ping`, future `yath stop`, etc.) run from a project
  cwd will need to filter the temp directory's IPC files to ones whose
  recorded `project` or `workdir` matches the caller's cwd. The IPC file
  itself already records `workdir` and `project` (`Util/IPC.pm:163-164`),
  so its contents are sufficient -- only the discovery side needs work.
- **The workdir (2.7) and the archive (2.1) together.** During a live
  `yath test` an outside observer (a status command, a test rerunning
  from cwd) should be able to map "I am in cwd X" to "the live workdir
  is /tmp/yath-<uuid>/". `find_ipc_files` already covers that via the
  IPC info file's recorded `workdir`.

### 3.2 Proposal options (minimal; not implementation)

Pick one or combine:

#### Option A: small JSON index file in temp

- Path: e.g. `<system_tmp>/yath-cwd-index.json` (or per-user variant).
- Schema: `{ <sha1(absolute_cwd)> : { latest_archive: PATH, latest_workdir: PATH, last_run_uuid: ..., updated_at: TS } }`.
- Producer: `yath test` updates the entry on success.
- Consumer: any command that wants "the last archive for this cwd"
  hashes its own cwd and looks it up.
- Pros: no symlinks; works on filesystems that ban them; dead-simple
  to garbage-collect (entries with stat-missing paths get pruned).
- Cons: serialization races between concurrent `yath test` runs in
  the same cwd -- need atomic-write-via-rename and a flock or accept
  last-writer-wins.

#### Option B: symlink in cwd pointing at temp

- After writing `<temp>/<stamp>.yath`, drop a `./.yath-latest` (or
  `./.yath/<stamp>.yath`) symlink in cwd that points at the temp path.
- Pros: no central index, no serialization.
- Cons: leaves a dotfile in cwd anyway -- defeats half the point of
  the move; symlink semantics on Windows are messy. Also doesn't
  survive cleanup if the user wipes cwd.

#### Option C: reuse the IPC info file as the index

- The IPC info file (`Util/IPC.pm`) already records `workdir` and
  `project`. Extend its contents to also record `latest_archive` once
  written. Keep the file in temp (flip `dir_order` default), and
  leave one well-known dotfile in cwd that points at the temp file by
  uuid (or just hash cwd to derive the temp filename deterministically).
- Pros: no second index file; reuses existing reaping logic
  (`find_ipc_files` already prunes dead pids).
- Cons: IPC file's lifetime is tied to the harness pid; a finished run
  has no live pid to keep the file alive. Would need to split
  "harness identity" (transient, temp-only) from "run history per cwd"
  (persisted, indexed).

#### Option D (recommended for proposal):

Two things, kept separate:

1. **Per-cwd archive index in temp** (option A). The single canonical
   answer to "what's the latest .yath archive for this cwd?".
   Garbage-collected by missing-file scrub on each yath invocation.
2. **Live IPC discovery stays as today** (option C-lite): only flip
   the default `dir_order` to put `tempdir` first so the dotfile no
   longer lands in cwd by default. `find_ipc_files` already filters
   by hostname/pid liveness, and the `project` / `workdir` fields
   inside each record let consumer commands narrow to the caller's
   cwd if they want.

Both need only filename conventions plus small atomic-write helpers
that already exist (`write_file_atomic`, `write_file_atomic_mode`).

## 4. Already temp / out of scope

- `<system_tmp>/yath-<uuid>/` workdir (2.7) -- explicit temp by default.
- `<workdir>/tmp/` (2.8) -- nested temp dir for child processes.
- All `<logdir>/...` per-run artifacts (2.9) -- under workdir, so already temp.
- IPC bus / unix sockets -- managed by `IPC::Manager`, lives in the
  system tmp.
- `*.pend` sibling files from `write_file_atomic` -- microsecond
  lifetime, sit next to their target.
- Tester-spawned files (`lib/App/Yath2/Tester.pm:25,94,100,246`) all
  use `File::Temp::tempdir`/`tempfile` with `TMPDIR => 1` and
  `CLEANUP => 1`. Visible in this checkout's git status (`logs/`,
  `pass.t`, `fail.t`, etc.) only because the cwd-archive convention
  has dropped artifacts into the repo over development.
- `yath init`'s `test.pl` (2.4) and `yath speedtag`'s in-place edits
  (2.5) -- by-design cwd writes; not the kind of "harness scratch
  data" the move-to-temp conversation is about.
- `yath extract`'s default `./logs` (2.3) -- user-driven extract;
  destination is a positional arg, default is fine to leave.

## 5. Notes for the migration

- The single current cwd offender produced unconditionally by a normal
  `yath test` invocation is the **`<stamp>.yath` archive** (2.1). The
  IPC info file (2.6) usually does *not* hit cwd because most users
  have either a project `.yath.rc` or a user `~/.yath.user.rc` earlier
  in the resolution chain.
- Other cwd writes (`yath init` -> `test.pl`, `yath speedtag` ->
  `durations.json`, `yath extract` -> `./logs`) are by design and
  not part of the routine `yath test` flow.
- The artifact most likely to need an index entry is the archive file,
  because all downstream commands (`replay`, `extract`, `speedtag`)
  take a path argument and have no current discovery mechanism.
- IPC discovery already has its own mechanism (`find_ipc_files`).
  Flipping `dir_order`'s default to `[tempdir, user_rc, project_rc, cwd]`
  would silently move the IPC file off cwd today without needing any
  other change, since `find_ipc_files` does not assume a particular dir.
- The hard pin in `t/AI/integration/test_command_loggers.t:117-124`
  asserts the cwd-archive behavior; it will need to be updated (or made
  conditional) when the default destination moves.
