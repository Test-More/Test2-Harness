# Stage 2 — Move AI-generated tests under `t/AI/`

## Branch

- `plan-stage-02-ai-tests`

## What landed

- Every existing test file under `t/integration/` and `t/unit/` moved under
  `t/AI/integration/` and `t/AI/unit/` via `git mv` (rename, 100% similarity
  preserved).
- `t/lib/` (test-support library, not itself a test) stayed put.

## Commit

1. `Move existing AI-generated tests under t/AI/`

## Tests

- `prove -I lib -I t/lib -r t/AI/unit` — all pass.
- `prove -I lib -I t/lib -r t/AI/integration` — all pass.
- The existing `use lib 't/lib'` lines in the moved tests still resolve
  correctly because `yath`/`prove` runs them from the repo root.

## Points of interest / decisions you may want to revisit

1. **`t/lib/Test2/Harness2/TestFile.pm` stays at `t/lib/`.** It is a Perl
   test-support module, not a test file itself, so the `t/AI/` rule does
   not strictly apply. If you want test-support modules split by authorship
   too, move it to `t/AI/lib/` and update `use lib 't/lib'` call sites.

2. **`.gitignore` line referencing `t/integration/test-broken-symlinks/...`**
   references the old test path. It was stale already (no such path exists
   in this tree) and remains untouched; if the acceptance-test port in a
   later stage brings `test-broken-symlinks` into `t/`, that line may need
   updating to `t/integration/...` or `t/AI/integration/...` depending
   on authorship.

3. **Authorship rule placement.** The `t/AI/` rule is carried by
   `ARCHITECTURE.md` (authorship layout section) and by `CLAUDE.md`
   under **Testing**, both of which are tracked files in this tree.

# Stage 3 — Port the utility classes listed in "These need to be ported in"

## Branch

- `plan-stage-03-utility-classes`
- Base: `plan-stage-02-ai-tests`

## What landed

Four commits, each one mechanical-ish but separately reviewable:

1. **`Util: add file-IO helpers (open_file/read_file/write_file/lock_file/...)`**
   — port the file-IO helpers from `old/Test2::Harness2::Util` into the
   current focused `Util.pm`. New exports: `open_file`, `maybe_open_file`,
   `close_file`, `read_file`, `maybe_read_file`, `write_file`, `lock_file`,
   `unlock_file`. `write_file_atomic` is rewritten to route its pending
   write through `write_file` (same behaviour; simpler code).
   `open_file` keeps the old transparent `.gz` / `.bz2` decompression on
   read.

2. **`Util::File: port the base file class`** — port
   `Test2::Harness2::Util::File` from `old/`, swapping
   `Test2::Harness2::Util::HashBase` (in the "do not bring back" list)
   for `Object::HashBase` directly. Public API identical:
     - Attributes: `name`, `done`, `skip_bad_decode`.
     - Methods: `read`, `maybe_read`, `write`, `rewrite`, `read_line`,
       `reset`, `open_file`, `exists`, `fh`, `decode`, `encode`.
   While porting I reformatted `read_line`'s eval into the project's
   three-step form (`my $ok = eval { ... }; my $err = $@; ...`) per
   `CLAUDE.md`.

3. **`Util::File::{Stream,Value,JSON,JSONL}: port the File subclasses`**
   — port all four subclasses with the same `Util::HashBase` →
   `Object::HashBase` swap. `Value.pm` now calls `SUPER::init()` before
   setting `DONE`; the old version skipped `SUPER::init()`, which also
   skipped the `'name' is a required attribute` check and the
   `_INIT_FH` handoff. That alignment is a deliberate behavioural
   change called out in the commit message — see "Points of interest"
   below.

4. **`Util::JSON: merge stream_json_l* and decode_json_no_null from old`**
   — merge the `old/` `Util::JSON` helpers that were missing from the
   current thin `Cpanel::JSON::XS` wrapper:
     - `decode_json_no_null` — replacing the old's
       `print-and-exit(1)` error path with a normal `die`.
     - `stream_json_l`, `stream_json_l_file`, `stream_json_l_url` —
       iterate a local file or http(s) URL of JSON / JSONL records.
   Also port the `decode_json_no_null` subtest from
   `old/t/Harness/Util/JSON.t` to `t/unit/Util/JSON_no_null.t`.
   Tests copied from `old/t/` count as human-authored so it sits
   under `t/unit/`, not `t/AI/`.

## Tests

- `prove -I lib -I t/lib -r t` — 32 files, 355 tests, all pass (72s
  wall-clock). Previously-noisy `Collector IPC send failed` warnings
  on STDERR are pre-existing and unrelated to this stage.

## Points of interest / decisions you may want to revisit

1. **`Util::File::Value` now calls `SUPER::init()`.** The old version
   skipped it. This is likely a latent bug in `old/` (no `name`
   check, `_INIT_FH` ignored), but fixing it is a behavioural change.
   If you want to preserve the old behaviour verbatim, drop the
   `$self->SUPER::init();` call in
   `lib/Test2/Harness2/Util/File/Value.pm`. No test in this tree
   exercises the constructor error path for Value, so nothing breaks
   either way today.

2. **`open_file` compression support is a no-op for writes.** Old
   behaviour (write modes ignore the `.gz` / `.bz2` extension) is
   preserved. When the log archive stage lands (Stage 11), we may want
   to add write-side compression so `Util::File::Value` and friends
   can transparently write a `.log.gz`. Flagging this as a
   forward-looking decision rather than something to do now.

3. **`Util.pm` now carries 8 new exports.** The PLAN classes
   `Test2::Harness2::Util` as "copy functionality as needed". I ported
   exactly the surface the Util::File family needs. The other old
   helpers (`find_libraries`, `file2mod`, `fqmod`, `chmod_tmp`,
   `hash_purge`, `is_same_file`, `render_status_data`, `clean_path`,
   `find_in_updir`, `looks_like_uuid`) are **not** ported in this
   stage. They will come in later stages that need them (plugin
   discovery, config-file conversion, the render layer, etc.).

4. **`decode_json_no_null`'s error path changed.** `old/` hard-exited
   the whole process on failure (`exit(1)`) after printing the two
   versions of the JSON. The port raises a `die`, which is what every
   other decode helper in this file does. If you specifically wanted
   the "crash-loudly" behaviour for this one function, I can put a
   `confess` wrapper back. I judged the normal `die` more consistent
   with the surrounding code.

5. **`stream_json_l_url` is untested.** The old code wasn't tested
   either, and bringing in a live HTTP test is out of scope. It's
   paper-ported only; the first time it sees real usage (log-server
   fetches, much later in the plan) it may need adjustment.

6. **No AI-generated unit tests were added for File.pm / Stream.pm /
   JSON.pm / JSONL.pm / Value.pm** in this stage. The smoke tests I
   ran inline (see commit messages) exercise the happy paths. If you
   want explicit `t/AI/unit/Util/File*.t` coverage, that's an easy
   follow-on; I intentionally skipped it to keep this stage focused.

7. **POD is present on every new module.** I followed the existing
   house style (name, description, synopsis, attributes, methods,
   source/maintainers/authors/copyright). `old/` had "POD NEEDS AUDIT"
   markers at the end of many files; I did not port those markers —
   the POD in these ports has been audited (by me, just now) against
   the code.

# Stage 4 — Port `App::Yath::Script::V2` (yath script glue)

## Branch

- `plan-stage-04-yath-script`
- Base: `plan-stage-03-utility-classes`

## What landed

1. **`App::Yath::Script::V2: scaffold the V2 handler`** —
   `lib/App/Yath/Script/V2.pm`. Thin wrapper that implements the
   versioned-handler contract defined by `App::Yath::Script` (from
   the external `App-Yath-Script` distribution). `do_begin` captures
   the dispatcher's parameters, `do_runtime` delegates to
   `App::Yath2->run`. A `run()` class method lets tests bypass
   `App::Yath::Script`.

2. **`App::Yath2: minimal application class with --help / --version
   and top-level Getopt::Yath options`** — `lib/App/Yath2.pm` plus
   `lib/App/Yath2/Options/Yath.pm`. An `Object::HashBase` class with
   fields `script`, `config`, `user_config`, and a hand-written
   `argv` accessor (Perl reserves bareword `ARGV` for its magic
   filehandle, so `Object::HashBase` cannot safely generate a
   constant for a field named `argv`). `run()` does a pre-command
   pass over argv using `Getopt::Yath` with `stop_at_non_opts=1`,
   consuming the yath-level options (`--help`/`-h`,
   `--help=GROUP`, `--version`/`-V`, `--dev-lib`/`-D`) and leaving
   everything from the first bare token onward in
   `state->{stop} + state->{remains}` for the command dispatcher.
   Behaviour:
     - no args, `--help`, `-h`, `help`: print usage banner, exit 0.
     - `--help=GROUP`: group-scoped docs via
       `Getopt::Yath::Instance::docs('cli', group => $g)`; unknown
       group prints known groups on STDERR and exits 2.
     - `--version`, `-V`: print `"$script (App::Yath2 $VERSION)"`,
       exit 0.
     - command name whose class loads (via `load_command`, i.e.
       `App::Yath2::Command::$name` can be required and
       `->isa('App::Yath2::Command')`): print the Stage 4
       'dispatch not yet wired' banner on STDERR and exit 2. Stage
       5 will replace that with the real dispatch.
     - unknown command (no matching class): print `"yath2: unknown
       command '$cmd'"` + usage, exit 2.
     - unrecognised `-` option: print error + usage to STDERR,
       exit 2.
   Command resolution has no in-dist registry: `load_command`
   tries to `require "App::Yath2::Command::$name"` and returns
   the class if it subclasses `App::Yath2::Command`. This keeps
   the command set an open extension point — third-party dists
   can ship new commands by shipping modules in that namespace.
   `App::Yath2::Options::Yath` is the Stage 4 minimum: just
   `version`, `help`, and `dev_libs`. Plugins, project, base_dir,
   show-opts, scan_options, and the real dev-lib exec-relaunch
   logic are deferred to Stage 6 (the full port of
   `old/lib/App/Yath2/Options/Yath.pm`).

3. **Depend on `App::Yath::Script` for the `yath` launcher** — no
   in-repo `scripts/yath` ships any more. `App::Yath::Script` is
   listed as a runtime prereq (`>= 2.000011` in `dist.ini`,
   `Makefile.PL`, and `cpanfile`); the installed `yath` script it
   ships discovers `.yath.rc` / `.yath.user.rc`, picks the V2
   handler, and reaches `App::Yath::Script::V2` in this
   repository. Tests drive the dispatcher through `App::Yath2`
   directly rather than shelling out to a launcher.

4. **`.yath.rc: mark project as V2`** — rename the file to
   `.yath.v2.rc` and replace `.yath.rc` with a symlink to it.
   `App::Yath::Script` selects the handler version from the
   config filename, not from file content, so the earlier bare
   `# V2` comment inside a plain `.yath.rc` was a no-op and the
   launcher would have fallen back to V1. The `[GatherFile]`
   block in `dist.ini` picks up both the symlink and the
   versioned file. The old V1-style options (`-D`, `--project`,
   `[test]` section) remain commented out with a `TODO` pointing
   at Stage 6; V2 does not parse those yet.

5. **`t/AI/unit/App/Yath2.t: cover the top-level dispatcher`** —
   captures STDOUT/STDERR via in-memory filehandles and exercises:
   no args, `--version` / `-V`, `--help` / `-h`, `--help=yath`,
   `--help=<bad>`, bare command name, `-D` / `-D <cmd>` /
   `-D=lib <cmd>`, `--no-such-option`, bogus command, `help`
   subcommand, and verifies argv is not mutated by `run()`.

## Manual verification

Run from the worktree root with the installed `yath` (resolved via
`PATH`, supplied by `App::Yath::Script`):

```
$ yath --version
yath (App::Yath2 2.000011)
# exit 0

$ yath --help
... USAGE banner + top-level option docs, exit 0

$ yath test some.t
yath2: unknown command 'test'.
... usage banner ...
# exit 2  (no App::Yath2::Command::test installed yet; Stage 5 lands it.)

$ yath bogus
yath2: unknown command 'bogus'.
... usage banner ...
# exit 2
```

## Tests

`prove -I lib -I t/lib -r t` — all pass, now including the new
`t/AI/unit/App/Yath2.t`.

## Points of interest / decisions you may want to revisit

1. **`argv` cannot be an Object::HashBase field** because Perl
   reserves the bareword `ARGV` as the name of the magic filehandle
   used by `<>`. `old/App::Yath2` avoided this by quietly using the
   string hash key `{argv}` alongside the constant for `ORIG_ARGV`.
   I made the hack explicit: the field is listed neither in the
   `use Object::HashBase` block nor via `{+ARGV}` anywhere in the
   file, and an explicit `sub argv { $_[0]->{argv} }` provides the
   read accessor. If you'd prefer the field renamed (`args`?
   `cli_argv`?), that's one Edit away.

2. **Command resolution is module-loaded, not registry-driven.**
   `load_command('$name')` tries to `require` the file for
   `App::Yath2::Command::$name` and returns the class if it
   subclasses `App::Yath2::Command`. This matches the pattern in
   `old/lib/App/Yath2.pm` (`load_command` at line 342) and
   `legacy/lib/App/Yath.pm` (`load_command` at line 284) and
   leaves the command set an open extension point for
   third-party dists. Stage 5 lands `App::Yath2::Command` and
   the first concrete command (`test`); Stage 4 itself ships
   no command classes, so every command name resolves to
   'unknown command' during this stage's tests.

3. **The `.yath.rc -> .yath.v2.rc` symlink commits the repo's V2
   switch.** `App::Yath::Script` version-detection keys off the
   filename: a `.yath.rc` symlink whose target matches
   `.yath.v#.rc` wins over a plain `.yath.rc` (which would default
   to V1). CI does not invoke `yath`, so this is safe. Locally,
   any invocation of `yath` in this branch will now load V2
   instead of V1. If you need V1 to still work during the
   transition, either revert this commit, or drop a sibling
   `.yath.user.v1.rc` (user-level version wins per
   `App::Yath::Script` semantics).

4. **The V1-specific options are commented out, not translated.**
   They live in `.yath.v2.rc`. Translating them requires the
   Stage 6 option libraries, which deliberately land later. The
   TODO block points at Stage 6 so the reactivation is easy to
   find.

5. **No project-local `scripts/yath` is shipped.** Stage 4 depends
   on `App::Yath::Script` for the launcher instead of mirroring it
   in-repo; the V2 handler in this tree is reached via the
   installed `yath` script. The dependency is declared in
   `dist.ini` / `Makefile.PL` / `cpanfile`.

6. **`--help` is also accepted as the word `help`.** `App::Yath2->run`
   special-cases the bareword `help` as equivalent to `--help`.
   This is a small convenience; if you want `help` reserved for
   the future `App::Yath2::Command::help` (which will know more
   about per-command help), remove the `$first eq 'help'` branch
   from `run()`. I added it because typing `yath help` is the
   common muscle-memory shape.

7. **`App::Yath2::Options::Yath` is intentionally tiny.** It only
   exposes the yath-level options the Stage 4 scaffold actually
   consumes. The full port (plugins, project, base_dir, show-opts,
   scan_options, real dev-lib exec-relaunch) lands in Stage 6
   alongside the rest of the option libraries.

## Note on App-Yath-Script

This stage declares `App::Yath::Script >= 2.000011` as a runtime
prereq (`dist.ini`, `Makefile.PL`, `cpanfile`). The installed
`yath` script is what dispatches to V2; no launcher is shipped
from this repo. If a target environment lacks the prereq, the
installation fails at the prereq check before `yath` is ever
invoked.
