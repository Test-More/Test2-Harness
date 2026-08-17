# RULINGS.md

Decisions this project's owner has already made. A recorded ruling stands
until the owner changes it.

Read this file when a decision is in front of you, not for general context.
When new evidence — a bug report, a pull request, a user request, a changed
constraint — suggests a ruling needs revisiting, flag it for the owner rather
than acting against it. See `~/projects/Agents/AGENTS.md` under "Rulings".

Newest first. Each entry gives the date, what was ruled, and enough evidence
for the next reader to judge whether the situation has changed.

Only decisions that could be raised again belong here — contentious calls,
questions likely to recur, and rulings that may need revisiting when
circumstances change. Routine decisions nobody will ever question stay out;
see `~/projects/Agents/AGENTS.md` under "What earns a place in `RULINGS.md`".

---

## 2026-08-17 — `find_yath()` does not look for `./scripts/yath`

**Ruling: `find_yath()` returns `$App::Yath::Script::SCRIPT` when it is set,
then searches `YATH_SCRIPT`, a `blib/script` beside any `blib/lib` or
`blib/arch` in `@INC`, the `Config` paths, a `bin` beside any `lib/perl5` in
`@INC`, and `PATH`. It does not check a `scripts/` directory in the current
directory.**

The check was there because this distribution once shipped the script as
`scripts/yath`. It stopped shipping it in 1.000171, when `b5134b33c` moved the
script logic into `App::Yath::Script::V1` and the script itself into the
App-Yath-Script distribution; no top-level `scripts/` directory has existed
here since. The one tracked path that still ends in `scripts/yath` is the
`t/yath_script/nested` fixture, which `t/yath_script.t` chdirs into: it is an
empty, non-executable file, so neither the removed check nor `find_alt_script`
ever matched it.

The behavior it provided did not go away, it moved up a layer.
`App::Yath::Script::do_begin` calls `find_alt_script()`, which swaps to an
executable `./scripts/yath` when the current directory has one and re-execs it.
That script sets `$ENV{YATH_SCRIPT}` to itself, and `find_yath()` checks
`YATH_SCRIPT` first, so a checkout's own script still wins — through the layer
that owns the behavior.

Keeping the check meant a second, cwd-relative source that outranked the
authoritative one and whose answer changed under a `chdir`. Five integration
tests (`t/integration/includes.t`, `init.t`, `inc_hook.t`, `projects.t`,
`speedtag.t`) call `find_yath()` early with `# cache result before we chdir`.
Those calls stay load-bearing: a relative `@INC` entry or `PATH` element still
makes the remaining search cwd-dependent.

Revisit if: something needs `find_yath()` to prefer a checkout's script in a
process that yath did not start — plain `prove` or `perl` in a tree that has
`scripts/yath`. No such caller is known; App-Yath-Script's own suite does not
use `find_yath()`.

---

## 2026-08-15 — `@INC` hooks are not propagated to test jobs

**Ruling: yath filters `@INC` hook refs out of every snapshot it takes and does
not carry them into runner or forked job processes. Forked jobs consequently
lose hooks that exec'd jobs keep; that asymmetry is known and accepted.**

`@INC` may hold coderefs, arrayrefs, or blessed objects (`perlvar "@INC"`).
Carmel injects one via `PERL5OPT=-MCarmel::Setup`. Yath snapshots `@INC` in
`App::Yath::Script::V1::do_begin` (into `settings->harness->orig_inc`) and in
`Test2::Harness::Util::process_includes(include_current => 1)`; both assume
plain path strings. Unfiltered, a blessed hook aborts the run when
`write_settings_to` JSON-encodes the settings, and coderef/arrayref hooks are
stringified by `clean_path` into bogus `/cwd/CODE(0x...)` entries that reach
child `-I` flags. Filtering fixes both, and is all this ruling requires.

Scope of what remains broken, measured with a hook that serves a module
reachable no other way: yath never touches `PERL5OPT` — it manages `PERL5LIB`
only (`Test2::Harness::Runner::Job` `set_env`) — so an exec'd job re-runs
whatever `-M` injection the parent had and recovers its hook unaided.
`yath test --no-fork` therefore already works with the filter alone. Only the
default fork path fails, because the job inherits the runner's `@INC` after
`Test2::Harness::Runner::process` has replaced it.

Propagating hooks was measured and works: preserve refs across the
`@INC = process_includes(...)` assignments in `Test2::Harness::Runner::process`
**and** `App::Yath::Command::runner::build_init_state`. Neither site alone is
enough — `Runner::process` wipes the hook before the fork so `build_init_state`
has nothing left to preserve, and preserving only in `build_init_state` wipes
it again first.

It is rejected for now on one ground, and it is not doubt about the mechanism:
the change puts hooks at the **front** of `@INC` in every runner and job
process, giving them first refusal on every `require` including the harness's
own preloads. Yath has never done that, it affects every user rather than only
hook users, and it is far easier to add later than to withdraw once a workflow
depends on it. Demand is one report (#277), self-closed by the reporter,
against `2.0` where these files no longer exist in this form.

Revisit if: a concrete Carmel or `PAR` workflow needs working forked test jobs
rather than merely a run that does not abort. The two-site change above is the
starting point; it wants its own commit, a functional-hook fixture, and a
decision about where in `@INC` the preserved hooks belong.
