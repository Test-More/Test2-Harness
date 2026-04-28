# Test command options audit

## Method

Compared `include_options(...)` chains for the `test` command across:

- Current: `lib/App/Yath2/Command/test.pm`
- Old2:    `reference/old2/lib/App/Yath2/Command/test.pm` (inherits `start->option_modules` + `run` includes + inline `preload_threshold`)
- Legacy:  `reference/legacy/lib/App/Yath/Command/test.pm`

Then cross-referenced with the actual `run()` body in current `test.pm` to see which options are *parsed but ignored*.

## A. Option groups loaded by test command

| Group (current name) | Legacy 1.0 | Old2                       | Current    | Notes                                                  |
|----------------------|------------|----------------------------|------------|--------------------------------------------------------|
| Yath / PreCommand    | PreCommand | Yath                       | Yath       | renamed                                                |
| Harness / Debug      | Debug      | Harness                    | Harness    | split — see C                                          |
| Workspace            | Workspace  | Workspace                  | Workspace  |                                                        |
| Finder               | Finder     | Finder                     | Finder     | many renames — see C                                   |
| IPC                  | (internal) | IPC                        | IPC        | new in old2                                            |
| Logging              | Logging    | (NOT in old2 test)         | Logging    | trimmed; old2 dropped from test                        |
| Renderer             | Display    | Renderer                   | Renderer   | split with Term                                        |
| Term                 | Display    | (declared, NOT in old2 test) | Term     | new group; old2 had bug — not loaded                   |
| Resource             | (Runner)   | Resource                   | Resource   | extracted                                              |
| Run                  | Run        | Run                        | Run        | reduced                                                |
| Runner               | Runner     | Runner                     | Runner     | reduced                                                |
| Scheduler            | (n/a)      | Scheduler                  | Scheduler  | new                                                    |
| Tests                | (Run+Runner) | Tests                    | Tests      | extracted                                              |
| DB                   | —          | DB                         | NOT loaded | old2 test had it                                       |
| WebClient            | —          | WebClient                  | NOT loaded | old2 test had it                                       |
| Collector            | Collector  | —                          | —          | gone (`max_open_jobs`, `max_poll_events`)              |

## B. Per-option status

Legend: ✅ parsed AND used by `run()` · ⚠️ parsed but IGNORED by `run()` · ❌ missing entirely · 🔁 renamed

### Workspace

| Option                              | Status                                                        |
|-------------------------------------|---------------------------------------------------------------|
| `--workdir`                         | ✅ used (line 114)                                            |
| `--tmpdir` (legacy `--tmp_dir`)     | ⚠️ parsed, never read 🔁                                       |
| `--clear`                           | ⚠️ parsed, never read                                          |
| `--keep-dirs` (legacy from Debug)   | ⚠️ parsed; runtime force-sets to 1 (line 228)                  |

### IPC

| Option                                          | Status                              |
|-------------------------------------------------|-------------------------------------|
| `--ipc-protocol`                                | ✅ used (line 118)                  |
| `--ipc-dir`, `--ipc-dir-order`, `--ipc-file`    | ⚠️ parsed, never read                |

### Finder

| Option                                                                  | Status                                                       |
|-------------------------------------------------------------------------|--------------------------------------------------------------|
| `--extensions` (legacy `--extension`)                                   | ✅ used (line 86) 🔁                                         |
| `--exclude-files` (legacy `--exclude-file`)                             | ⚠️ parsed, never read 🔁                                     |
| `--exclude-patterns` (legacy `--exclude-pattern`)                       | ⚠️ parsed, never read 🔁                                     |
| `--exclude-lists` (legacy `--exclude-list`)                             | ⚠️ parsed, never read 🔁                                     |
| `--default-search`, `--default-at-search`                               | ⚠️ cmd `die`s if no args (line 76) — defaults never apply    |
| `--changed`, `--changed-only`, `--changes-*` (10 opts)                  | ⚠️ all parsed, never read                                    |
| `--durations`, `--maybe-durations`, `--durations-threshold`             | ⚠️ parsed, never read                                        |
| `--rerun`, `--rerun-plugins` (legacy `--rerun-plugin`), `--rerun-modes` | ⚠️ parsed, never read 🔁                                     |
| `--no-long`, `--only-long`, `--show-changed-files`                      | ⚠️ parsed, never read                                        |
| `--finder-class` (legacy `--finder`)                                    | ⚠️ parsed, never read 🔁                                     |
| legacy `--search`                                                       | ❌ removed entirely                                          |

### Resource

| Option                                                                       | Status                                                  |
|------------------------------------------------------------------------------|---------------------------------------------------------|
| `-j` / `--jobs` / `--job-count` / `--slots` (legacy `--job-count` in Runner) | ⚠️ **IGNORED** — line 119 hardcodes `slots => 16` 🔁    |
| `-x` / `--job-slots` (legacy `--slots-per-job`)                              | ⚠️ parsed, never read 🔁                                |
| `--resource-classes` (legacy `--resources`)                                  | ⚠️ parsed, never read 🔁                                |
| legacy `--shared-jobs-config`                                                | ❌ removed                                              |
| legacy `--fail-on-resource-skip`                                             | ❌ removed                                              |
| legacy `--resource-timeout`                                                  | ❌ removed                                              |

### Tests (legacy split between Run and Runner)

All ⚠️ parsed but never read by `run()` unless noted otherwise:

- `--use-fork`, `--use-timeout`, `--event-timeout`, `--post-exit-timeout`
- `--includes`, `--tlib`, `--lib`, `--blib`, `--unsafe-inc`
- `--cover`
- `--switches` (legacy `--switch` 🔁)
- `--env-vars` (legacy `--env-var` 🔁)
- `--load`, `--load-import`
- `--stream` (legacy `--use-stream` 🔁)
- `--test-args`, `--input`, `--input-file`
- `--event-uuids`, `--mem-usage`
- `--allow-retry`, `--retry`, `--retry-isolated`

❌ legacy `--tap`, `--io-events` removed.

### Run

All ⚠️ parsed but never read by `run()`:

- `--links` (legacy `--link` 🔁)
- `--dbi-profiling`, `--author-testing`, `--fields`, `--run-id`
- `--abort-on-bail`, `--nytprof`, `--run-auditor`, `--interactive`

### Runner

| Option                                                                       | Status                                            |
|------------------------------------------------------------------------------|---------------------------------------------------|
| `--preloads`, `--preload-early`, `--preload-retry-delay`                     | ⚠️ parsed, never read                              |
| `--runner-class` (legacy `--runner`)                                         | ⚠️ parsed, never read                              |
| `--dump-depmap`, `--reload-in-place`, `--reloader`, `--restrict-reload`      | ⚠️ parsed, never read                              |
| legacy `--preload-threshold` (-W)                                            | ❌ removed (was inline in old2 test)               |
| legacy `--runner-id`                                                         | ❌ removed                                         |

### Scheduler

| Option              | Status                |
|---------------------|-----------------------|
| `--scheduler-class` | ⚠️ parsed, never read  |

### Renderer

All ✅ consumed via `App::Yath2::Options::Renderer->init_renderers($settings)` (line 161):

- `--quiet`, `--verbose`, `--qvf`, `--theme`, `--wrap`, `--show-times`
- `--hide-runner-output`, `--truncate-runner-output`
- `--show-job-end`, `--show-job-info`, `--show-job-launch`, `--show-run-info`, `--show-run-fields`
- `--renderer-classes` (legacy `--renderers` / `--formatter` 🔁)
- `--renderer-server`

❌ legacy `--no-final-table` removed.

### Term

| Option                                       | Status                |
|----------------------------------------------|-----------------------|
| `--color`, `--progress`, `--term-width`      | ✅ via Renderer init   |

### Logging

| Option                                          | Status                                                                  |
|-------------------------------------------------|-------------------------------------------------------------------------|
| `--log` (-L)                                    | ⚠️ parsed; comment at line 236-237 calls it "no-op opt-in" — archive always written |
| `--log-dir`                                     | ✅ used (line 248)                                                       |
| `--log-file`                                    | ✅ used (line 245)                                                       |
| legacy `--log-file-format`, `--bzip2`, `--gzip` | ❌ removed                                                               |

### Yath / PreCommand

Mostly handled by the yath wrapper before the command runs; relevant ones ✅ via wrapper.

- `--project`, `--user`, `--base-dir`, `--version`, `--dev-libs`, `--dev-libs-verbose`, `--help`, `--plugins`
- `--scan-options` (legacy `--no-scan-plugins` 🔁)
- `--project` ⚠️ never read by test cmd itself.
- ❌ legacy `--persist-dir`, `--persist-file` removed (no daemon-persist concept in test cmd).
- Debug-era `--summary`, `--interactive`: partially gone; `--interactive` survives in Run group but unused by test.

### Harness

| Option                                       | Status                |
|----------------------------------------------|-----------------------|
| `--dummy`, `--procname-prefix` (both ex-Debug) | ⚠️ parsed, never read |

## C. Renames legacy → old2/current

| Legacy                                          | Current/Old2                                          | Group move              |
|-------------------------------------------------|-------------------------------------------------------|-------------------------|
| `--extension`                                   | `--extensions`                                        | Finder (pluralized)     |
| `--exclude-file`                                | `--exclude-files`                                     | Finder                  |
| `--exclude-pattern`                             | `--exclude-patterns`                                  | Finder                  |
| `--exclude-list`                                | `--exclude-lists`                                     | Finder                  |
| `--changes-exclude-file`                        | `--changes-exclude-files`                             | Finder                  |
| `--changes-exclude-pattern`                     | `--changes-exclude-patterns`                          | Finder                  |
| `--changes-filter-file`                         | `--changes-filter-files`                              | Finder                  |
| `--changes-filter-pattern`                      | `--changes-filter-patterns`                           | Finder                  |
| `--rerun-plugin`                                | `--rerun-plugins`                                     | Finder                  |
| `--finder`                                      | `--finder-class` (`class` in Finder)                  | Finder                  |
| `--search`                                      | dropped                                               | Finder                  |
| `--env-var`                                     | `--env-vars`                                          | Run → Tests             |
| `--switch`                                      | `--switches`                                          | Runner → Tests          |
| `--link`                                        | `--links`                                             | Run                     |
| `--use-stream`                                  | `--stream`                                            | Run → Tests             |
| `--job-count` (-j)                              | Resource `--slots` (-j alias kept)                    | Runner → Resource       |
| `--slots-per-job` (-x)                          | Resource `--job-slots` (-x kept)                      | Runner → Resource       |
| `--resources` (-R)                              | Resource `--classes`                                  | Runner → Resource       |
| `--runner`                                      | Runner `--class`                                      | Runner                  |
| `--renderers` / `--formatter`                   | Renderer `--classes`                                  | Display → Renderer      |
| `--no-wrap`                                     | Renderer `--wrap` (Bool, neg)                         | Display → Renderer      |
| `--no-scan-plugins`                             | Yath `--scan-options`                                 | PreCommand → Yath       |
| `--tmp-dir`                                     | `--tmpdir`                                            | Workspace               |
| `--keep-dirs`                                   | same                                                  | Debug → Workspace       |

## D. Fully removed (no current equivalent)

`--shared-jobs-config`, `--fail-on-resource-skip`, `--resource-timeout`, `--preload-threshold` (-W), `--runner-id`, `--tap`, `--io-events`,
`--no-final-table`, `--persist-dir`, `--persist-file`, `--log-file-format`, `--bzip2`, `--gzip`, `--summary`, `--max-open-jobs`,
`--max-poll-events`, legacy `--search`.

## E. Critical fix list (priority order)

Real user-visible bugs in current test command (parser accepts, runtime ignores):

 1. **`-j` / `--slots`** — most-used flag, hardcoded to 16 at `test.pm:119`. Must read `$settings->resource->slots`.
 2. **`--includes` / `--lib` / `--blib` / `--tlib` / `--unsafe-inc` / `--switches`** — `Tests.*` never propagated to spawned jobs.
    Without these, `-Ilib` etc do nothing.
 3. **`--env-vars`** — never set on child env.
 4. **`--use-fork` / `--use-timeout` / `--event-timeout` / `--post-exit-timeout`** — timing/forking knobs ignored.
 5. **`--cover`** — coverage flag silently dropped.
 6. **`--retry` / `--retry-isolated` / `--allow-retry`** — retry semantics absent.
 7. **`--preloads` / `--preload-early`** — Runner preload ignored; whole preload feature dead in test cmd.
 8. **`--resource-classes`** — only JobCount available; no plugin resources.
 9. **Finder filters**: `--exclude-files`, `--changed`, `--rerun`, `--durations` — all parsed, ignored. Test cmd uses raw `File::Find`
    (`test.pm:93-105`) instead of the Finder.
10. **`--log` / `-L`** — comment admits it's a noop; archive always written regardless of opt-in.

## F. Notable

- `App::Yath2::Options::Renderer->init_renderers($settings)` (line 161) is the only path that actually consumes a non-trivial
  chunk of options (Renderer+Term group). That's the model the rest should follow.
- Old2 `test` had a Term-options bug (Term not in `start->option_modules`). Current fixes it.
- Old2 `test` had inline `--preload-threshold` (-W) inside the command; current dropped it without re-adding anywhere.
- Current loads DB/WebClient nowhere in test cmd; old2 did. Probably intentional given current test cmd is "minimal"
  (per its description), but means `--db-*`/`--url`/`--api-key` are unavailable even though declared.

## G. Pre-parsed by App::Yath::Script (separate dist on `origin/script`)

The `yath` binary's `BEGIN` calls `App::Yath::Script::do_begin()` *before* any `App::Yath2::Command::*` ever sees `@ARGV`.
Source: `/home/exodist/projects/Test2/App-Yath-Script/lib/App/Yath/Script.pm`. This layer consumes (or re-acts on) several arguments.
Anything it handles is either stripped from `@ARGV` or duplicated in the per-command parse — both matter for the audit.

### `V#` / `v#` as first arg

- **Source:** `do_begin` lines 35-39
- **Behavior:** Stripped from `@ARGV`. Selects `App::Yath::Script::V#` handler module. `V0` reserved for self-validation.
- **Reaches test cmd?** No — gone before command parses.

### `-D` / `--dev-lib` / `--dev-libs` (bare or `=path[,path,...]`, glob `*` expanded)

- **Source:** `parse_new_dev_libs` lines 157-189
- **Behavior:** Bare form pushes `lib`, `blib/lib`, `blib/arch` onto `@INC`. Then **re-execs** the script (`exec($^X, $SCRIPT, @argv)`) so
  new `@INC` affects compile of yath itself. `T2_HARNESS_INCLUDES` env carries `@INC` across the exec.
- **Reaches test cmd?** Yes — args NOT removed from `@ARGV`. `App::Yath2::Options::Yath` re-declares `dev_libs` and re-parses them
  (Getopt::Yath consumes them again). End-to-end working for `-D`.

### Auto-set `PERL_HASH_SEED`

- **Source:** `seed_hash` lines 196-206
- **Behavior:** If env unset, sets to `YYYYMMDD` and re-execs for reproducibility. No flag. Prints notice line.
- **Reaches test cmd?** N/A — env, not arg.

### `./scripts/yath` shadow

- **Source:** `find_alt_script` lines 143-155
- **Behavior:** If cwd has executable `./scripts/yath` and it differs from current script path, swap `$SCRIPT` and re-exec. Lets a
  project ship its own yath wrapper.
- **Reaches test cmd?** N/A — no arg.

### `T2_HARNESS_INCLUDES` env

- **Source:** `inject_includes` lines 191-194
- **Behavior:** Restores `@INC` after the re-exec triggered by any of the above. Internal mechanism.
- **Reaches test cmd?** N/A — env.

### `.yath.rc` / `.yath.user.rc` / `.yath.v#.rc` / `.yath.user.v#.rc`

- **Source:** `find_rc_updir` lines 219-259
- **Behavior:** Discovered by walking up from cwd. Symlink `.yath.rc → .yath.v#.rc` extracts version from target name. User-level
  version wins over project. Path passed to `V#->do_begin` as `config` / `user_config`.
- **Reaches test cmd?** **Discovered, NOT MERGED.** `App::Yath::Script::V2` (in this repo at `lib/App/Yath/Script/V2.pm`) stashes paths
  in `$settings->yath->{config_file, user_config_file}`. The actual argv-merge in `lib/App/Yath2.pm:394-400` is **commented out**.
  Net: rc files have no effect on the test command today. Big gap vs legacy.

### `--begin LIST`, `--goto-file PATH`

- **Source:** `App::Yath::Script::V0` only
- **Behavior:** V0 validation handler — only relevant when running `yath V0 ...` to test the script wrapper itself.
- **Reaches test cmd?** No — V0 never delegates to a real command.

### Implications for audit

1. **`-D` works** (only because both Script and the Yath option group parse it). The double-parse is harmless but wasteful.
2. **Config file (`.yath.rc`) support is dead in 2.0.** Script discovers them, V2 stores the paths, but
   `App::Yath2.pm:394` has the merge loop commented out:
   ```
   #    for my $attr (qw/config_file user_config_file/) {
   #        my $config = App::Yath2::ConfigFile->new(file => $file);
   #        push @configs => $config;
   #        unshift @$argv => $config->global;
   ```
   Means: **no rc-file options reach any command, including test**. Separate fix from the test-cmd-ignores-options
   bugs in §E but compounds them — a user can't even write a `.yath.rc` to set `-j32` or `--includes lib`.
3. **Version selector (`V#`)** is invisible to the test command. Not a bug.
4. **Pre-parser does not strip `-D`.** Worth verifying that downstream `Getopt::Yath` parsers tolerate it
   (they do — `Yath` group declares `dev_libs` precisely so the second parse succeeds).
5. The pre-parser does NOT touch any of the IGNORED options listed in §B — those are 100% the test command's
   `run()` body's fault, not the wrapper's.

### Updated critical fix list (additions to §E)

11. **Wire `App::Yath2::ConfigFile` back in.** Uncomment the loop at `lib/App/Yath2.pm:394-400` (or rewrite).
    Without it `.yath.rc` silently does nothing, breaking the most basic project-level config workflow.
