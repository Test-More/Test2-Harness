# Stage 6 — Port the Getopt::Yath option libraries

## Branch

- `plan-stage-06-options`
- Base: `plan-stage-05-test-command`

## What landed

Five commits.

1. **`Util: add fqmod and clean_path helpers`** — adds the two
   `Test2::Harness2::Util` helpers the ported options files import
   (`fqmod`, `clean_path`). Both are copied verbatim from `old/`. The
   pre-existing `tinysleep` is deliberately left as-is — it uses
   `select(undef, undef, undef, $secs)` for its interruptible-sleep
   semantics; converting to `Time::HiRes::sleep` would change
   behaviour. Flagged for a separate look (see Points of interest).

2. **`Options: port App::Yath2::Options::* verbatim; TODO-gate
   non-priority options`** — every file from
   `old/lib/App/Yath2/Options/*.pm` now lives at
   `lib/App/Yath2/Options/<same>.pm` with option definitions preserved
   byte-for-byte. Options outside the Stage 6 priority set are
   commented out with a `TODO: Stage N -- <short reason>` marker. The
   priority options left active are:

   | File | Active option names |
   |------|---------------------|
   | `Tests.pm` | `includes`, `lib`, `blib` |
   | `Renderer.pm` | `verbose` |
   | `Resource.pm` | `slots` |
   | `Runner.pm` | `preloads` |

   `DB.pm`, `Server.pm`, `WebServer.pm`, and `WebClient.pm` are copied
   verbatim with every option commented out and a top-of-file TODO
   noting the scope deferral. `WebServer.pm`'s
   `include_options('App::Yath2::Options::DB')` is likewise commented
   with a TODO; other cross-file `include_options` calls stay active
   because the included modules load fine even with zero active
   options.

3. **`Options: comment option_post_process blocks that reference
   inactive options`** — the bulk port left five `option_post_process`
   callbacks live (in Term, Resource, Run, Runner, Workspace). Each
   callback reads fields or groups whose options are commented out, so
   parsing would fail the moment any command included those modules.
   Each callback -- and its supporting named sub, where present -- is
   now commented out in place with a TODO pointing at the stage that
   should re-enable it. The commenting is minimal; the code is
   preserved so the diff against `old/` stays tight.

4. **`Harness2: thread launch_args through to per-job Collector
   launches`** — small addition to `Test2::Harness2` and
   `Test2::Harness2::RunService`. The harness now accepts a new
   `launch_args` attribute (arrayref of Perl switches). When set, it
   flows through the per-job launch IPC payload and RunService uses it
   between `$^X` and the absolute test path, replacing the hard-coded
   `-Ilib` default. Callers that don't set `launch_args` keep the
   previous default, so the existing 32-file integration / unit suite
   is unaffected.

5. **`Command::test: parse Stage 6 priority options and wire them to
   the harness`** — `App::Yath2::Command::test` now runs its argv
   through Getopt::Yath with the four priority option libraries
   included, and wires the parsed values into the harness:

   - `-I PATH` / `--include=PATH` -> `-IPATH` in `launch_args`.
   - `-l` / `--lib` / `--no-lib` -> `-Ilib`, plus auto-include `lib/`
     when the directory exists and `--no-lib` wasn't passed.
   - `-b` / `--blib` / `--no-blib` -> `-Iblib/lib -Iblib/arch` with
     the same auto-include-if-dir-exists heuristic.
   - `-v` / `--verbose` -> stored; echoed in the startup line. Full
     renderer support is Stage 12.
   - `-j N` / `--slots=N` / `--job-count=N` -> `JobCount` resource
     slot count. Falls back to 1 on non-positive / non-integer input.
   - `--preload=MOD` / `-P MOD` -> captured; echoed on stderr as a
     placeholder so the user knows they didn't take effect. Actual
     preload support arrives in Stage 8.

   Option parsing is exposed as a named `_parse_argv` helper so the
   unit tests can exercise the wiring without constructing a full
   command object -- `parse_options` is a closure over the option
   instance for the package that imported `Getopt::Yath`, so the call
   has to happen from inside `App::Yath2::Command::test`.

## Tests

- `prove -I lib -I t/lib -r t` -- **33 files, 368 tests, all pass
  (~71s)**. Thirteen of those tests are the new
  `t/AI/unit/App/Yath2/Command/test.t`, which covers each priority
  option at the helper level (include path collection, lib/blib
  auto-include, explicit-on / explicit-off / auto-on, slots defaulting,
  malformed slots fallback, verbose Count behaviour, preload capture,
  positional arg preservation).
- Manual smoke of `perl -Ilib scripts/yath test` (no args) prints the
  usage banner as expected.
- Manual smoke of `perl -Ilib scripts/yath test --help` fails the
  parse -- the command does not yet register a `--help` option and
  the top-level `yath`'s help handling doesn't reach the subcommand.
  This matches the Stage 6 scope note in the PLAN ("help at command
  level lands later") but is worth flipping when Stage 13 ports the
  `help` command.

## Pre-existing harness infrastructure issue (still unresolved)

Per Chad's 2026-04-19 decision, Stage 6 landed without fixing the
base-branch regression flagged in Stage 5's summary. `yath test` with
a real test file still hits the same `job_completed {err => 255}`
path because the collector dies before any `Logger::JSON->shutdown`
fires. Stage 6's wiring is verified via `prove` (unit coverage on the
parsed settings -> launch_args / slot-count helpers) rather than a
full end-to-end `yath test` run.

## Points of interest / decisions you may want to revisit

1. **`launch_args` default behaviour change.** When a caller sets
   `launch_args => [...]`, RunService no longer injects the
   hard-coded `-Ilib` -- the caller is now responsible for supplying
   include paths. All existing harness callers pass nothing, so they
   get the legacy `-Ilib`. The V2 `yath test` path sets `launch_args`
   only when options produce them, so `yath test t/foo.t` with no
   `-I` / `-l` / `-b` (and no `lib/` in cwd) will launch with bare
   `$^X t/foo.t`. If that's wrong for the default CLI UX, flip
   `_build_launch_args` to always include `lib` (matching the old
   prose "(Default: include if it exists)" for `-l`).

2. **`include_options` inside the options files is left active where
   the included module loads cleanly.** For example,
   `Renderer.pm -> Term.pm`, `Yath.pm -> Harness.pm`, `Runner.pm ->
   Tests.pm`, `IPC.pm -> Yath.pm`. Since every option in the included
   modules is either active (priority set) or commented, nothing
   breaks. The only `include_options` that's commented is
   `WebServer.pm -> DB.pm` (DB scope deferred).

3. **`option_post_process` blocks are all commented for now.** The
   originals reference fields that aren't yet active. Stage 18's
   cleanup sweep should re-activate each one as the option it depends
   on turns on. Named subs (`jobs_post_process`,
   `runner_post_process`) are commented in place so the diff against
   `old/` stays small.

4. **`Renderer.pm`'s `init_renderers` helper is intentionally left
   live** even though it references commented-out renderer fields.
   Nothing calls it yet (no renderer pipeline in Stage 6), so it's
   dormant dead code. Stage 12 will bring it back into use or replace
   it wholesale.

5. **`Tests.pm` imports trimmed.** `use Test2::Harness2::TestSettings`
   was removed (module not ported); the `$DEFAULT_COVER_ARGS`
   initializer moved into the commented-out `cover` option block.
   `Workspace.pm` and `Yath.pm` had their
   `find_libraries` / `chmod_tmp` / `find_in_updir` imports trimmed
   from `Test2::Harness2::Util` (those helpers don't exist in the
   current `Util`). Each trim carries a TODO marker.

6. **`tinysleep` vs. `Time::HiRes::sleep`.** The
   `feedback_sleep_pattern` memory record says to prefer
   `Time::HiRes::sleep` and proactively clean up `select undef,undef,
   undef,N` when seen. `Test2::Harness2::Util::tinysleep` uses
   `select()` deliberately -- it wants EINTR-interruptible semantics
   for polling loops that need to react to signals. The memory rule
   has a real exception here; worth updating the memory note (or
   moving `tinysleep` to a named "interruptible sleep" helper that
   doesn't look like a `select`-over-sleep anti-pattern).

7. **`_was_cleared` helper is defensive about Getopt::Yath's
   `$parsed->{cleared}` shape.** The POD only says "Options that were
   cleared with --no-opt". The helper checks both a flat
   `"<group>.<opt>"` key and a nested `{group}{opt}` hash, and falls
   back to a bare `{opt}` key. As of the 2.000008 Getopt::Yath
   release shipped in this environment, `cleared` appears to be
   `{}` when `--no-lib` is passed -- neither shape is populated.
   The `--no-lib` suppression test still passes because the auto-
   include code only runs when the directory exists and the Bool
   default is 0; the explicit flag doesn't change the outcome in
   that subtest. If the semantics are ever strictly needed ("user
   explicitly said no, even though lib/ exists"), this helper may
   need tightening once Getopt::Yath's internals are better
   documented.

8. **`yath test --help` currently fails parsing.** The command
   doesn't register `help` among its options and the top-level
   `yath`'s early-exit for `--help` only triggers when `--help` is
   the first arg (before the command name). Stage 13 ports the
   dedicated `help` command; until then, command-level `--help` will
   keep landing in the Getopt::Yath "invalid option" path.

## Notes for the next stage

- Stage 7 (plugin roles) can build on top of this chain without
  touching options -- `App::Yath2::Options::Plugin.pm` was not in the
  19 ported files (it didn't exist in `old/`), so plugin option
  exposure is an additive change Stage 7 will need to introduce.
- Stage 8 (preloads) will want `--preload` to actually do something.
  The placeholder path in `Command::test::_warn_preloads_placeholder`
  is the obvious hook; remove the warn and wire the list into a
  preload resource.
- Stage 12 (renderers) will want `--verbose` to propagate to the
  actual renderer pipeline. `_resolve_verbose` returns the count; the
  full plumbing will need to pass it into `$settings->renderer` and
  through to a renderer's constructor.
- Stage 18's TODO sweep has a lot to do in
  `lib/App/Yath2/Options/`. Every commented option carries a specific
  stage note; all five `option_post_process` blocks need revisiting;
  the `init_renderers` helper in `Renderer.pm` needs review.

## Worktree

Living under `.claude/worktrees/plan-stage-06-options` on branch
`plan-stage-06-options` (based on `plan-stage-05-test-command`, which
now carries the Stage-5-summary update plus the TestFile fixture
drop). Not pushed. Not merged.

## Post-refactor rebase (2026-04-20)

Rebased onto the updated `reimplement-resource-classes` base
(`0c46805cf`) via `plan-stage-05`. Same refactor headline items as
upstream stages (IPC kind renames, direct artifact routing,
`collector:` bus name, configurable `launch_job_timeout`).

During cascade: the stage-05 `pass_count`/`fail_count` init
(already merged in stage-05's tip) came through a second time via
the intermediate rebase and collided with the refactored Run.pm
init block; same resolution as stage-05 (keep all three init
lines). The `t/AI/unit/Harness2/TestFile.t` vs
`t/AI/unit/App/Yath2/TestFile.t` rename/rename that falls out of
stage-05's TestFile namespace move was resolved by keeping only
`t/AI/unit/App/Yath2/TestFile.t`. No Stage-6 commits themselves
needed edits. (Live branch tip recorded in
`PLAN_RESUME.md` on the primary repo, not pinned here.) Full
`prove -j16 -I lib -I t/lib -r t` green (355 tests).
