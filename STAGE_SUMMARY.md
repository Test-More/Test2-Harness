# Stage 4 — Port `App::Yath::Script::V2` (yath script glue)

## Branch

- `plan-stage-04-yath-script`
- Base: `plan-stage-03-utility-classes`

## What landed

Four commits:

1. **`App::Yath::Script::V2: scaffold the V2 handler`** —
   `lib/App/Yath/Script/V2.pm`. Thin wrapper that implements the
   versioned-handler contract defined by
   `App::Yath::Script` (from the external `App-Yath-Script`
   distribution). `do_begin` captures the dispatcher's parameters,
   `do_runtime` delegates to `App::Yath2->run`. A `run()` class
   method lets tests bypass `App::Yath::Script`.

2. **`App::Yath2: minimal application class with --help / --version`** —
   `lib/App/Yath2.pm`. A small `Object::HashBase` class with fields
   `script`, `config`, `user_config`, and a hand-written `argv`
   accessor (Perl reserves bareword `ARGV` for its magic filehandle,
   so `Object::HashBase` cannot safely generate a constant for a
   field named `argv`). `run()`:
     - no args, `--help`, `-h`, `help`: print usage banner, exit 0.
     - `--version`, `-V`: print `"$script (App::Yath2 $VERSION)"`, exit 0.
     - unknown `-` option: print error + usage to STDERR, exit 2.
     - known command name (from the stubbed registry): print
       `"yath2: the '$cmd' command has not been ported yet in this rewrite."`
       to STDERR, exit 2.
     - other: print `"yath2: unknown command '$cmd'"` + usage, exit 2.
   The command registry is populated with every command Stage 13
   and Stage 14 will port; all entries currently evaluate to the
   stub branch.

3. **`scripts/yath: launcher delegating to App::Yath::Script`** —
   `scripts/yath` (executable). Mirrors the launcher shipped by
   `App-Yath-Script`: it re-plays `T2_HARNESS_INCLUDES` into `@INC`
   at BEGIN and hands off to `App::Yath::Script::do_begin` /
   `do_runtime`. With `-Ilib scripts/yath`, this reaches the V2
   handler in this repository.

4. **`.yath.rc: mark project as V2`** — add a top-of-file `# V2`
   comment so `App::Yath::Script`'s config-scan picks V2. The old
   V1-style options in the file (`-D`, `--project`, `[test]`
   section) are commented out with a `TODO` pointing at Stage 6;
   V2 does not parse those yet.

## Manual verification

Run from the worktree root:

```
$ perl -Ilib scripts/yath --version
PERL_HASH_SEED not set, setting to '20260419' for more reproducible results.
scripts/yath (App::Yath2 2.000011)
# exit 0

$ perl -Ilib scripts/yath --help
... USAGE banner + command list, exit 0

$ perl -Ilib scripts/yath test some.t
yath2: the 'test' command has not been ported yet in this rewrite.
See PLAN for the planned port order; until then this command is not available.
# exit 2

$ perl -Ilib scripts/yath bogus
yath2: unknown command 'bogus'.

... usage banner ...
# exit 2
```

## Tests

`prove -I lib -I t/lib -r t` — 32 files, 355 tests, all pass. The
new modules do not have dedicated tests yet; this stage only adds
the scaffolding. Dedicated tests start arriving in Stage 5 when
the `test` command gets implemented.

## Points of interest / decisions you may want to revisit

1. **`argv` cannot be an Object::HashBase field** because Perl
   reserves the bareword `ARGV` as the name of the magic filehandle
   used by `<>`. `old/App::Yath2` avoided this by quietly using the
   string hash key `{argv}` alongside the constant for `ORIG_ARGV`.
   I made the hack explicit: the field is listed neither in the
   `use Object::HashBase` block nor via `{+ARGV}` anywhere in the
   file, and an explicit `sub argv { $_[0]->{argv} }` provides the
   read accessor. If you'd prefer the field renamed (`args`? `cli_argv`?),
   that's one Edit away.

2. **The command registry in `App::Yath2.pm` is a `my %COMMANDS` hash
   with value `1` for each entry.** When a command is ported, the
   value flips to the command's module name (e.g. `App::Yath2::Command::test`).
   Stage 5 will be the first to do this. The current list covers
   every non-log, non-UI/DB command I saw in `old/lib/App/Yath2/Command/`.
   If you want the list centralised elsewhere (e.g. a dedicated
   `App::Yath2::CommandRegistry` module), say so and I'll move it.

3. **The `# V2` marker in `.yath.rc` commits the repo's V2 switch.**
   CI does not invoke `yath` (I checked `.github/workflows/testsuite.yml`
   — no yath or prove calls there), so this is safe. Locally, any
   invocation of `yath` in this branch will now load V2 instead of
   V1. If you need V1 to still work during the transition, either:
     - Revert this commit, or
     - Add a sibling `.yath.user.rc` with a `# V1` marker (user-
       level marker wins per `App::Yath::Script` semantics).

4. **The V1-specific `.yath.rc` options are commented out, not
   translated.** Translating them requires the Stage 6 option
   libraries, which deliberately land later. The TODO block points
   at Stage 6 so the reactivation is easy to find.

5. **`scripts/yath` is created here, not in Stage 2.** ARCHITECTURE.md
   section 13 says the canonical test runner is
   `perl -Ilib scripts/yath test -D -j24 [files...]`, but the file
   didn't actually exist in the tree until now. Stage 4 adds it
   because that is the first stage with something to dispatch to.
   Note that `CLAUDE.md` says `perl -Ilib yath -D test -j16` — the
   two docs disagree on `yath` vs `scripts/yath`; ARCHITECTURE.md
   wins for our purposes, but you may want to sync them.

6. **No unit test for `App::Yath2->run`.** The four manual
   invocations above are the only verification. A unit test that
   captures STDOUT / STDERR and asserts the four branches would be
   easy to add; I intentionally skipped it to keep this stage
   focused on scaffolding, and because Stage 5 will rewrite parts
   of `run()` anyway when the `test` command wires in.

7. **`--help` is also accepted as the word `help`.** `App::Yath2->run`
   special-cases the bareword `help` as equivalent to `--help`. This
   is a small convenience; if you want `help` reserved for the
   future `App::Yath2::Command::help` (which will know more about
   per-command help), remove the `$first eq 'help'` branch from
   `run()`. I added it because typing `yath help` is the common
   muscle-memory shape.

## Note on App-Yath-Script

This stage assumes `App::Yath::Script` (version 2.000011) is
installed in the running perl. It is: `which yath` points at
`App-Yath-Script`'s launcher, and `perldoc -l App::Yath::Script`
resolves. If your CI image ever lacks it, `scripts/yath` will fail
at `require App::Yath::Script`. Worth adding a sanity check to
CI (if/when CI runs `yath`) that the dep is installed.

## Post-refactor rebase (2026-04-20)

Rebased onto the updated `reimplement-resource-classes` base
(`0c46805cf`), which now carries the IPC_AND_LOGGERS-alignment
refactor (message-kind renames `job_complete` → `test_job_completed`
and `loggers_ready` → `collector_artifacts`, direct artifact
routing to `ipc_run`/`ipc_harness`, collector bus-name convention
`collector:<service>[:<run_id>]`, configurable per-run
`launch_job_timeout` defaulting to 5s).

Stage-04's own commits (yath script + App::Yath2 skeleton)
replayed cleanly except for the recurring `t/AI/unit/Util/JSON_no_null.t`
move conflict (known base-branch rename already resolved the same
way every cascade). (Live branch tip recorded in
`PLAN_RESUME.md` on the primary repo, not pinned here.) Full
`prove -j16 -I lib -I t/lib -r t` run green downstream.
