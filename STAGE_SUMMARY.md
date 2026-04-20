# Stage 13 -- Non-daemon yath commands

## Branch

- `plan-stage-13-commands`
- Base: `plan-stage-11-log-archive` (3d7450146)

## What landed (one commit, seven new command modules)

1. **`Command stubs: help, list, which, init, failed, projects, do`**
   - `lib/App/Yath2/Command/help.pm` -- top-level dispatcher.
     With no args, delegates to `App::Yath2` for the usage
     banner. With a command name, loads the module and prints
     its optional `help` method's output.
   - `lib/App/Yath2/Command/list.pm` -- run
     `App::Yath2::Finder::Simple` and print each discovered test
     path. No finder options yet (layered in a later revision
     when `App::Yath2::Options::Finder` is activated).
   - `lib/App/Yath2/Command/which.pm` -- prints the `scripts/yath`
     + `App::Yath2.pm` + `Test2::Harness2.pm` paths the current
     invocation is using.
   - `lib/App/Yath2/Command/init.pm` -- writes a minimal
     `.yath.rc` with a `# V2` marker line. Refuses to overwrite
     an existing file.
   - `lib/App/Yath2/Command/failed.pm` -- stub (depends on
     Stage 12's artifact-reading layer).
   - `lib/App/Yath2/Command/projects.pm` -- stub (project
     enumeration shape not decided).
   - `lib/App/Yath2/Command/do.pm` -- stub (alias resolution
     depends on a richer config loader).
   - `lib/App/Yath2.pm` COMMANDS registry flips these seven from
     the placeholder `1` to their concrete class names. Daemon
     commands remain stubbed -- Stage 14 covers them.
   - `t/AI/unit/App/Yath2/Command/list.t` exercises list's return
     codes (the happy-path STDOUT capture is skipped because
     `local *STDOUT = ...` doesn't play nicely with Test2's
     formatter; see manual smoke below).

## Test results

- `prove -I lib -I t/lib -r -j16 t` -- **44 files / 424 tests,
  all passing** on this branch.

## Manual smoke coverage (CLI round-trip)

    $ perl -Ilib scripts/yath which
    script:         /.../scripts/yath
    App::Yath2:     lib/App/Yath2.pm
    Test2::Harness2 lib/Test2/Harness2.pm

    $ perl -Ilib scripts/yath list t/AI/unit/Util
    t/AI/unit/Util/JSON.t
    t/AI/unit/Util/JSON_no_null.t

    $ cd /tmp/new-project && perl -Ilib .../scripts/yath init
    Created .yath.rc

## Deliberate deferrals

Per PLAN Stage 13 scope:

> Explicitly out of scope for this stage: anything that reads a
> stored yath log (`replay`, `times`, `speedtag`, `recent`, and
> all `db` commands). Anything that needs a daemon: Stage 14.

Consequently `failed`, `projects`, and `do` are stubbed rather
than fleshed out:

- `failed` wants the artifact-reading layer (Stage 12) plus a
  last-run-workdir discovery path. Both are concrete follow-ups.
- `projects` doesn't have an agreed enumeration shape; a
  concrete consumer will decide whether projects are enumerated
  from a config file, a directory convention, or a CLI list.
- `do` wants alias resolution, which in turn needs a richer
  `.yath.rc` loader. The Stage 4 `.yath.rc` is intentionally
  trivial; alias-era config is a separate port.

Each stub explains the dependency in its error message so a
later revisit knows which upstream piece to wire in.

## Flip-back notes

- **Stage 14** inherits the remaining stubbed registry entries:
  `start`, `stop`, `status`, `ping`, `kill`, `ps`, `run`,
  `spawn`, `abort`, `watch`, `reload`, `resources`. Stage 14
  will flip them to real class names after the daemon machinery
  is in place.
- **Stage 12 (renderers / artifact-reading layer)** unblocks
  `failed`. When that lands, `Command::failed::run` walks the
  artifact tree of the most recent run and forwards the failing
  tests back through `Command::test`.
- **Later stages that add finder options** (e.g. `--ext=tx`)
  should layer `include_options('App::Yath2::Options::Finder')`
  on `Command::list` the same way Stage 6 did it for
  `Command::test`.
