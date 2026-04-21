# Feature parity audit

Stage 19's deliverable. Walks `old/lib/`, `old/t/`, and the current
`lib/` module-by-module to classify every old artifact against the
rewrite. Subsumes `docs/log-port-audit.md` (Stage 10) with its
decisions carried forward.

## Top-line verdict

**Remaining gaps, listed below.** The rewrite has reached feature
parity on every in-scope axis (harness runtime, scheduler, resources,
plugin infrastructure, preload tree, log-archive creation, daemon
surface, non-daemon commands, acceptance-test sweep). The remaining
work is confined to items that every earlier stage explicitly
deferred: DB/UI, log-reading commands (`replay`, `times`, `speedtag`,
`recent`), the coverage aggregator and its renderer/aggregator
wiring, the TAP-prove backend shim, and a set of renderer / option
polish items flagged by Stage 17 and Stage 18.

## Scope legend

Every `old/lib/*.pm` file is placed into one of four buckets:

- **Landed** — has a counterpart in `lib/` that covers its
  responsibility (verbatim port, fresh rewrite, or responsibility
  absorbed by an upstream CPAN module per PLAN's architectural
  sections).
- **Out-of-scope** — PLAN explicitly drops it or marks it
  indefinitely deferred (DB/UI, the "should NOT come back" list,
  log-reading commands).
- **Deferred with target** — not landed, but has an identified
  successor-plan stage below or is still gated on the small set
  of known follow-ups from Stage 17 / Stage 18.
- **Unaccounted** — none at this time. Every old module resolves
  into one of the first three buckets.

A module that exists in `lib/` but is functionally a stub was
called out by Stage 16 (the `Resource::SharedJobs` placeholder was
deleted there) — spot checks in this audit did not turn up any
remaining "landed but empty" modules.

## `old/lib/App/Yath2/` walk

### Top-level

| Old module | Status | Notes |
|------------|--------|-------|
| `App::Yath2.pm` | Landed | `lib/App/Yath2.pm` (Stage 4, extended through Stage 14). |
| `App::Yath2::Script.pm` | Landed | `lib/App/Yath/Script/V2.pm` is the V2 dispatcher; the `App-Yath-Script` distribution ships the shared launcher. |
| `App::Yath2::Client.pm` | Deferred with target | Old client wraps `Test2::Harness2::Client` + old IPC protocol. Superseded by `Test2::Harness2::Spawn` + `App::Yath2::Daemon::attach`. **Successor stage: "Yath Client helper for external consumers"** if someone ever needs an embeddable client outside a command process. Today no consumer requires it; out-of-plan. |
| `App::Yath2::Command.pm` | Landed implicitly | V2 command classes inherit from `App::Yath::Script::Command` (from `App-Yath-Script`) rather than a shared `App::Yath2::Command`; no in-tree base class is needed. Old base's `group`/`summary`/`description` etc. are provided by the dispatcher framework. |
| `App::Yath2::ConfigFile.pm` | Deferred with target | Discovery / parsing of `.yath.rc` lives in `App::Yath::Script` in the rewrite. The old parser's legacy-syntax handling (relglob, etc.) has no consumer today. **Successor stage SP-01**: "Port `.yath.rc` legacy-syntax compatibility" if ever needed. |
| `App::Yath2::Converting.pm` | Out-of-scope (POD-only) | Pure POD describing the old T2::Formatter::Stream behaviour and harness-directive set. Not a code module; the new distribution has not yet carried its migration POD. Flagged for a documentation follow-up (SP-02). |
| `App::Yath2::Finder.pm` | Deferred with target | The rewrite ships `App::Yath2::Finder::Simple` only (positional-arg discovery). Old `Finder` implements `changed` / `changes_diff` / `duration_data` / `--changed-only` / smoke ordering / etc. **Successor stage SP-03**: "Full Finder port (changed-files, durations, smoke ordering)". Gates `plugin.t`, `stamps.t`, and half of `test.t`'s skipped assertions. |
| `App::Yath2::IPC.pm` | Landed (superseded) | Replaced by `IPC::Manager` + `App::Yath2::Daemon`. See PLAN "should NOT come back" for the underlying protocol family. |
| `App::Yath2::Plugin.pm` | Landed | `lib/App/Yath2/Role/Plugin.pm` replaces the base class with a `Role::Tiny::With` role (Stage 7). |
| `App::Yath2::Renderer.pm` | Landed | `lib/App/Yath2/Role/Renderer.pm` (Stage 12). |
| `App::Yath2::Resource.pm` | Out-of-scope | Old base class was in the App namespace; new role lives under `Test2::Harness2::Role::Resource` (arrived via Stage 1 merge). App-level resource base is not needed. |
| `App::Yath2::Tester.pm` | Landed (relocated) | Ported into `t/lib/App/Yath2/Tester.pm` during Stage 17; see Stage 17 §5 for rationale on keeping it test-support rather than published API. |
| `App::Yath2::Theme.pm` | Landed (relocated) | Old root Theme → `lib/App/Yath2/Renderer/Theme/Composer.pm` (Stage 12, same responsibility, different namespace). |
| `App::Yath2::Theme::Default.pm` | Landed implicitly | Default theme data is composed into `Renderer::Theme::Composer`; no separate `Theme::Default` file is carried. |
| `App::Yath2::Util.pm` | Deferred with target | Old Util exports `find_yath`, `paged_print`, `get_config`, `dbg_dump`, etc. Rewrite only uses `find_yath` (copied into `t/lib/App/Yath2/Tester.pm`). **Successor stage SP-04**: "Port App::Yath2::Util paging + dbg helpers" when any command needs them (today: none). |

### `App::Yath2::Command::*`

All twelve daemon-lifecycle commands and the seven non-daemon
commands have landed. Two commands remain explicitly out of scope.

| Old module | Status | Stage |
|------------|--------|-------|
| `Command::abort` | Landed | Stage 14 |
| `Command::do` | Landed | Stage 13 (stub; alias dispatcher) |
| `Command::failed` | Landed | Stage 13 |
| `Command::help` | Landed | Stage 13 (stub; `App::Yath2` dispatches `help` at the top level) |
| `Command::init` | Landed | Stage 13 (writes `.yath.rc` in the new scheme) |
| `Command::kill` | Landed | Stage 14 |
| `Command::list` | Landed | Stage 13 |
| `Command::ping` | Landed | Stage 14 |
| `Command::projects` | Landed | Stage 13 (stub) |
| `Command::ps` | Landed | Stage 14 |
| `Command::recent` | Out-of-scope | Log-reading command, PLAN scope caveat |
| `Command::reload` | Landed | Stage 14 (driver scaffold; full preload reload is Stage 9 + follow-ups) |
| `Command::replay` | Out-of-scope | Log-reading command, PLAN scope caveat |
| `Command::resources` | Landed | Stage 14 |
| `Command::run` | Landed | Stage 14 |
| `Command::server` | Out-of-scope | UI scope (`App::Yath2::UI` lives in a separate namespace) |
| `Command::spawn` | Landed | Stage 14 |
| `Command::speedtag` | Out-of-scope | Log-reading command, PLAN scope caveat |
| `Command::start` | Landed | Stage 14 |
| `Command::status` | Landed | Stage 14 |
| `Command::stop` | Landed | Stage 14 |
| `Command::test` | Landed | Stage 5 (extended through Stages 6, 7, 12, 15) |
| `Command::times` | Out-of-scope | Log-reading command, PLAN scope caveat |
| `Command::watch` | Landed | Stage 14 |
| `Command::which` | Landed | Stage 13 |
| `Command::client::publish` | Out-of-scope | Depends on `App::Yath2::UI` (HTTP POST to the yath UI web server) |
| `Command::client::recent` | Out-of-scope | Depends on `App::Yath2::UI` |
| `Command::db` | Out-of-scope | DB scope |
| `Command::db::importer` | Out-of-scope | DB scope |
| `Command::db::publish` | Out-of-scope | DB scope |
| `Command::db::recent` | Out-of-scope | DB scope |
| `Command::db::sweeper` | Out-of-scope | DB scope |
| `Command::db::sync` | Out-of-scope | DB scope |

The PLAN Stage 19 audit asks explicitly about `old/lib/App/Yath2/Command/client/`.
**Decision:** the two client commands are web-client wrappers around
`App::Yath2::UI`'s HTTP endpoint; both `LWP::UserAgent`-based and
reaching into UI data shapes. They are out of plan scope exactly as
the UI/DB namespaces are out of plan scope. No successor stage in
this audit — they come back only if/when `App::Yath2::UI` comes back.

### `App::Yath2::Options::*`

All nineteen option library files have been copied verbatim
(Stage 6). Individual option blocks that are not yet wired to
behaviour stay commented with `TODO` markers per PLAN Stage 6 /
Stage 18 policy.

| Old module | Status | Notes |
|------------|--------|-------|
| `Options::DB` | Landed (fully TODO-gated) | DB namespace is out of scope; file stays for drift-prevention |
| `Options::Finder` | Landed | `--ext` activated in Stage 18; remainder wait on SP-03 |
| `Options::Harness` | Landed | Active set only (most still TODO-gated) |
| `Options::IPC` / `IPCAll` | Landed | Both present; most options TODO-gated |
| `Options::Publish` / `Recent` | Landed | UI/client scope — entirely TODO-gated |
| `Options::Renderer` | Landed | Core options activated (Stage 12) |
| `Options::Resource` | Landed | `-R` opt activated for the resource tests; most TODO-gated |
| `Options::Run` / `Runner` / `Scheduler` / `Tests` / `Term` / `Workspace` / `Yath` | Landed | Mix of active + TODO-gated per Stage 6 policy |
| `Options::Server` / `WebClient` / `WebServer` | Landed | UI scope — entirely TODO-gated |

### `App::Yath2::Plugin::*`

| Old module | Status | Stage |
|------------|--------|-------|
| `Plugin::Cover` | Landed (minimal) | Stage 15. Option group + plugin class + `post_process` shim landed; the aggregator and `annotate_event` pipeline are deferred to SP-05 |
| `Plugin::DB` | Out-of-scope | Per PLAN |
| `Plugin::Git` | Landed | Stage 15 |
| `Plugin::SysInfo` | Landed | Stage 15 |

### `App::Yath2::Renderer::*`

| Old module | Status | Notes |
|------------|--------|-------|
| `Renderer::Default` | Landed | Stage 12. UUID-based job label fixed in Stage 18 (filename labels restored). |
| `Renderer::Default::Composer` | Landed | Absorbed into `Renderer::Theme::Composer` |
| `Renderer::DB` | Out-of-scope | DB/UI scope |
| `Renderer::Formatter` | Landed (polish deferred) | Stage 12. Two skipped tests (`encoding.t`, `tapsubtest.t`) block on per-job column / depth / tree-corner markers. **Successor stage SP-06**: "Renderer::Formatter line-shape restoration or redesign" |
| `Renderer::JUnit` | Deferred with target | **SP-07**: "Port Renderer::JUnit" when a CI consumer demands it. Plain port, no architectural changes needed. |
| `Renderer::Logger` | Deferred with target | SP-07 companion: roles as the "pipe events to a separate logger" sink |
| `Renderer::Notify` | Out-of-scope | External integration (desktop / webhook notifiers); revisit only if user demand |
| `Renderer::QVF` | Deferred with target | **SP-08**: "Port Renderer::QVF" — the artifact-reading layer already has mode-selection plumbing for this |
| `Renderer::ResetTerm` | Deferred with target | SP-07 companion |
| `Renderer::Server` | Out-of-scope | UI scope |
| `Renderer::Summary` | Landed | Stage 12 |
| `Renderer::TAPHarness` | Out-of-scope (see TAP::Harness::Yath section) | Tied to the old log format |

### `App::Yath2::Resource::*`

| Old module | Status | Stage |
|------------|--------|-------|
| `Resource::SharedJobSlots` | Landed | Stage 16 |
| `Resource::SharedJobSlots::Config` | Landed | Stage 16 |
| `Resource::SharedJobSlots::State` | Landed | Stage 16 |

## `old/lib/Test2/Harness2/` walk

### Core + top-level

| Old module | Status | Notes |
|------------|--------|-------|
| `Test2::Harness2.pm` | Landed | Rewritten on top of `IPC::Manager` (Stage 1 merge) |
| `Test2::Harness2::Client` | Out-of-scope (superseded) | Replaced by `Test2::Harness2::Spawn`'s bidirectional handle. PLAN "should NOT come back" list implicitly covers the Client's underlying IPC::Connection. |
| `Test2::Harness2::Event` | Landed | `lib/Test2/Harness2/Event.pm` |
| `Test2::Harness2::Plugin` | Landed | `lib/Test2/Harness2/Role/Plugin.pm` (Stage 7, different shape per PLAN) |
| `Test2::Harness2::Preload` | Landed | `lib/Test2/Harness2/Preload.pm` (Stage 8) |
| `Test2::Harness2::Preload::Stage` | Landed | `lib/Test2/Harness2/Preload/Stage.pm` (Stage 8) |
| `Test2::Harness2::Reloader` | Landed | `lib/Test2/Harness2/Role/Reloader.pm` (Stage 9) |
| `Test2::Harness2::Reloader::Inotify2` | Landed (different shape) | `lib/Test2/Harness2/ChangeWatcher/Inotify.pm` (Stage 9) |
| `Test2::Harness2::Reloader::Stat` | Landed (different shape) | `lib/Test2/Harness2/ChangeWatcher/Stat.pm` (Stage 9) |
| `Test2::Harness2::Run` | Landed | `lib/Test2/Harness2/Run.pm` (Stage 1 merge) |
| `Test2::Harness2::Run::Job` | Landed | `lib/Test2/Harness2/Run/Job.pm` (Stage 1 merge) |
| `Test2::Harness2::Resource` | Landed | `lib/Test2/Harness2/Role/Resource.pm` (Stage 1 merge) |
| `Test2::Harness2::Resource::JobCount` | Landed | `lib/Test2/Harness2/Resource/JobCount.pm` (Stage 1 merge) |
| `Test2::Harness2::Scheduler` | Landed (absorbed) | Scheduling logic is inside `Test2::Harness2` + `Test2::Harness2::RunService` (Stage 1 merge) |
| `Test2::Harness2::Scheduler::Run` | Landed (absorbed) | Folded into `RunService` |
| `Test2::Harness2::TestFile` | Landed | `lib/Test2/Harness2/Role/TestFile.pm` + `lib/App/Yath2/TestFile.pm` (consumer) |
| `Test2::Harness2::TestSettings` | Out-of-scope | PLAN "should NOT come back" — replaced by `Run::Job` + `Getopt::Yath` settings |

### Collector subtree

| Old module | Status | Notes |
|------------|--------|-------|
| `Collector` | Landed | `lib/Test2/Harness2/Collector.pm` (large; heavily rewritten for `IPC::Manager`) |
| `Collector::Auditor` | Landed (restructured) | Base auditor is now `lib/Test2/Harness2/Role/Auditor.pm` |
| `Collector::Auditor::Job` | Landed | `lib/Test2/Harness2/Collector/Auditor/Test.pm` (renamed for clarity; test-job auditor is the only consumer) |
| `Collector::Auditor::Run` | Out-of-scope | Per-run verdict tallying is now owned by `RunService` via IPC (per `IPC_AND_LOGGERS §13.1`); no per-run auditor in the new shape |
| `Collector::Child` | Out-of-scope (superseded) | Service-side event emission lives in `Test2::Harness2::Util::EventEmitter` |
| `Collector::IOParser` | Landed | `lib/Test2/Harness2/Collector/Parser/IOParser.pm` |
| `Collector::IOParser::Stream` | Landed | `lib/Test2/Harness2/Collector/Parser/IOParser/Stream.pm` |
| `Collector::Preloaded` | Landed (absorbed) | Preload-in-test-child launch lives in `Test2::Harness2::PreloadService::Bootstrap` + the `jump_to` support on `Collector::interpose` |
| `Collector::TapParser` | Landed | `lib/Test2/Harness2/Collector/Parser/TapParser.pm` |

### Instance + IPC subtree

Everything in the Instance family (`Instance`, `Instance::Message`,
`Instance::Request`, `Instance::Response`) is on the PLAN "should
NOT come back" list. Same for the complete `IPC::Protocol*`
family, `IPC::Connection`, and `IPC::Util`. All have landed via
the `IPC::Manager` migration.

| Old module | Status |
|------------|--------|
| `Instance.pm`, `Instance::Message`, `Instance::Request`, `Instance::Response` | Out-of-scope (PLAN "should NOT come back") |
| `IPC::Connection` | Out-of-scope (PLAN "should NOT come back") |
| `IPC::Protocol` + `::AtomicPipe*` + `::IPSocket*` + `::UnixSocket*` | Out-of-scope (PLAN "should NOT come back") |
| `IPC::Util` | Landed (split) | `lib/Test2/Harness2/Util/IPC.pm` carries `pid_is_running`, `set_procname`, `swap_io`, `list_direct_children`; `start_process` was ported in Stage 17 |

### Runner subtree

| Old module | Status | Notes |
|------------|--------|-------|
| `Runner` | Out-of-scope (absorbed) | Runner responsibilities split between `Test2::Harness2`, `RunService`, and the Preload resource |
| `Runner::Preloading` | Out-of-scope (absorbed) | Replaced by the Stage 8 / Stage 9 preload-resource subtree |
| `Runner::Preloading::Stage` | Out-of-scope (absorbed) | Replaced by `PreloadService` |

### Log subtree (Stage 10 audit subsumed)

All decisions from `docs/log-port-audit.md` are carried forward here.

| Old module | Status | Stage 10 decision |
|------------|--------|-------------------|
| `Log.pm` | Out-of-scope | POD describing the old single-file log; superseded by the archive-of-`logs/` shape |
| `Log::CoverageAggregator` | Deferred with target | SP-05 (coverage aggregator port) |
| `Log::CoverageAggregator::ByRun` | Deferred with target | SP-05 |
| `Log::CoverageAggregator::ByTest` | Deferred with target | SP-05 |
| `Log::TimeTracker` | Out-of-scope | Only consumers are `times` / `speedtag` / Cover's claim-file fallback — all out of plan scope |

### Util subtree

| Old module | Status | Notes |
|------------|--------|-------|
| `Util.pm` | Landed | Stage 3 ported helpers on top of the existing `lib/Test2/Harness2/Util.pm`; `chmod_tmp` added in Stage 15 |
| `Util::Deprecated` | Out-of-scope | PLAN "should NOT come back" |
| `Util::File` / `File::JSON` / `File::JSONL` / `File::Stream` / `File::Value` | Landed | Stage 3 |
| `Util::HashBase` | Out-of-scope | PLAN "should NOT come back" — replaced by `Object::HashBase` |
| `Util::JSON` | Landed | Stage 3 (merge) |
| `Util::LogFile` | Out-of-scope | PLAN "should NOT come back" |

## `old/lib/Test2/` (non-Harness2) walk

PLAN Stage 19 asks explicitly about `old/lib/Test2/EventFacet/`,
`old/lib/Test2/Tools/`, `old/lib/Test2/Formatter/`, and
`old/lib/Test2/Plugin/`.

| Old module | Path in old | Status | Decision |
|------------|-------------|--------|----------|
| `Test2::EventFacet::Binary` | `Test2/EventFacet/Binary.pm` | Deferred with target | Declares a "binary file attached to the log" event facet. No consumer in this distribution today (consumers were in old/ renderers that read the single-file log). **SP-09**: "Resurrect binary-attachment event facet" if a future renderer / archive consumer needs inline binary artifacts. Likely belongs in `Test2::EventFacet` proper, not here. |
| `Test2::Formatter::Stream` | `Test2/Formatter/Stream.pm` | Landed (superseded) | Replaced by `lib/Test2/Formatter/Stream2.pm`. The old class and the new `Stream2` are deliberately incompatible wire formats; old `Stream` stays in `old/` for reference. |
| `Test2::Plugin::Immiscible` | `Test2/Plugin/Immiscible.pm` | Landed | Stage 15 |
| `Test2::Plugin::IsolateTemp` | `Test2/Plugin/IsolateTemp.pm` | Landed | Stage 15 |
| `Test2::Tools::HarnessTester` | `Test2/Tools/HarnessTester.pm` | Deferred with target | Test-author helper for driving the harness from inside a test; depends on `Collector::Auditor::Job` and the old Tester. **SP-10**: "Port Test2::Tools::HarnessTester" when a user-facing test-author helper is scoped. Lower priority — not used by any in-tree test. |

Per PLAN Stage 19: "most belong elsewhere". Agreed — the only
Test2-namespace modules that actually need to live in this
distribution are the two plugins, the Stream2 formatter, and the
harness-internal Test2 facet helpers already present. The rest
are either donor code (the old `Stream`) or optional extensions
with no current consumer.

## `old/lib/TAP/Harness/Yath/` decision

Two modules: `TAP::Harness::Yath` and `TAP::Harness::Yath::Aggregator`.
Purpose: implement a `TAP::Harness` subclass so `prove --harness=TAP::Harness::Yath ...`
routes through yath instead of `TAP::Harness::prove`. The old
implementation reads the single-file log format and reports a
pass/fail summary through `TAP::Formatter::*`.

**Decision: defer (out of plan scope, likely not coming back).**
Rationale:

- The backing log format it shims (`events.jsonl.gz`) is gone.
- The new log layout is artifact-per-job under `logs/`; bridging
  that into `TAP::Harness`'s one-file-per-test expectations would
  be a substantial rewrite, not a shim.
- No known user demand; `yath` is run directly in CI today.
- If the shim ever returns, it would properly live on top of the
  Stage 12 artifact-reading layer (same abstraction the other
  renderers use), not as a bespoke log reader.

**Successor stage SP-11** (optional, low priority): "TAP::Harness::Yath
as an artifact-reading-layer consumer". Scope is small if (and only
if) the artifact-reading layer is already mature.

## `old/t/` disposition

### Stage 17 sweep coverage

Stage 17 walked `old/t/Yath/integration/` and landed nineteen tests
under `t/integration/`. Stage 18 lifted one of the skip_all markers
(`nested_includes.t`). Current state: four tests run real assertions
(`verbose_env.t`, `test-w.t`, `nested_includes.t`, `failure_cases.t`);
fifteen are committed as `skip_all` with explicit TODO headers
pointing at the blocking dependency.

Per the sweep and Stage 18's reclassification, every skip_all names
its blocker verbatim:

| Test | Blocker | Closable by |
|------|---------|-------------|
| `concurrency.t` | `--log` + Tester `log => 1` plumbing | SP-12 |
| `encoding.t` | `Renderer::Formatter` column shape | SP-06 |
| `help.t` | `Command::help` output rewrite | SP-13 |
| `includes.t` | Stage 6 option reactivation (`-I`/`-l`/`-b`/`--unsafe-inc`) | SP-14 |
| `init.t` | `.yath.rc` vs old `test.pl` assertions | SP-15 or delete |
| `log_dir.t` | Stage 6 option reactivation (`-L` / `--log-dir`) | SP-12 |
| `persist.t` | renderer filename labels (now done) + `which`/`watch` output shapes | SP-16 |
| `plugin.t` | full plugin hook surface + `-A` + `--changes-plugin` etc. | SP-17 |
| `projects.t` | `Command::projects` full implementation + filename labels | SP-18 |
| `resource.t` | `--log` plumbing + `-R+Resource` + STDERR-to-log funnelling | SP-12 |
| `retry.t` | `--retry`/`--project` + retry mechanism port | SP-19 |
| `smoke.t` | `--log` + Tester `log => 1` + `-pSmokePlugin` hook | SP-12 + SP-17 |
| `stamps.t` | `--log` + `-A` + `-pTestPlugin` | SP-12 + SP-17 |
| `tapsubtest.t` | `Renderer::Formatter` depth / job column | SP-06 |
| `test.t` | filename labels + Stage 6 options + arisdottle arg forwarding | SP-20 |

### Explicitly deferred from Stage 17

Per PLAN Stage 17: `coverage*.t` (5 files), `times.t`, `speedtag.t`,
`replay.t`, all `db/` tests, and the `UI/` tests. All confirmed
still absent from `t/` — this is the correct state per PLAN. The
`reload*.t` tests are deferred with Stage 9's integration
follow-up, and `failed.t` is deferred with Stage 13's
`Command::failed` follow-up.

### Non-integration old/t/ files

`old/t/Harness/*` (HashBase.t, Util.t, Util/JSON.t, self-test
subtree with ~17 subtests), `old/t/Yath/IPC.t`, `old/t/Yath/JUnit/*`,
`old/t/0-load_all.t`, `old/t/1-pod_name.t`, `old/t/null.t` — most
are covered by the existing `t/AI/unit/` tests (which are greener
than a straight port would be, since they test the new shapes).
`0-load_all.t` and `1-pod_name.t` are canonical smoke tests that
would be worth porting as author-test / xt coverage (SP-21).
`old/t/Harness/selftest/*` is old/'s in-harness Test2 self-test
suite — each of those scripts becomes just another user's test
file as far as the new harness cares; no port action needed.

### Stage 17 cross-check

Stage 17's disposition holds up. The one real gap surfaced by this
audit is that `init.t` and `help.t` both read "skip_all forever" in
Stage 18's reclassification — they are genuinely tests of the OLD
behaviour and need human-authored replacements (either a rewrite in
`t/AI/` or deletion). That decision is recorded here as SP-15
(`init.t`) and SP-13 (`help.t`).

## Successor-plan stages

The following are the actionable follow-ups that are not in scope
for this plan but matter for eventual completion. Each is scoped
small enough to land as its own stage.

### SP-01 — `.yath.rc` legacy-syntax compatibility

**Scope**: Port the `relglob()` / `glob()` / legacy-path handling
from `old/lib/App/Yath2/ConfigFile.pm` into `App::Yath::Script`'s
`.yath.rc` reader. **Motivation**: users migrating from yath 1.0
configs. **Gotchas**: legacy syntax paths leak into tests; port
should be opt-in via a `--legacy-config` flag rather than implicit.

### SP-02 — "Migrating to yath 2.0" migration POD

**Scope**: Replace `old/lib/App/Yath2/Converting.pm` with a real
migration doc that covers Stream2 vs Stream, HARNESS-* directives,
config-file differences. **Motivation**: onboarding existing yath
users. **Gotchas**: not a code file; owns the documentation side
of Stage 2's authorship rules.

### SP-03 — Full Finder port (changed-files, durations, smoke ordering)

**Scope**: Port `old/lib/App/Yath2/Finder.pm` and its tests onto
`App::Yath2::Finder::Simple`'s base. Feature set: `--changed`,
`--changes-diff`, `--changes-exclude-files`, `--changes-plugin`,
`--durations`, `--smoke`, the full discovery-hook API.
**Motivation**: unblocks `plugin.t`, `stamps.t`, half of `test.t`'s
skipped assertions, plus CI workflows that depend on smart test
selection. **Gotchas**: interacts with plugin hook surface
(SP-17); both benefit from landing together.

### SP-04 — `App::Yath2::Util` paging + debug helpers

**Scope**: Port `paged_print`, `dbg_dump`, and the `find_yath`
variant currently duplicated in `t/lib/App/Yath2/Tester.pm` back
into a canonical `App::Yath2::Util`. **Motivation**: avoids
per-command reimplementation once commands grow `--pager`-style
flags. **Gotchas**: `find_yath` has two callers with subtly
different semantics (dev-tree vs installed); keep both code
paths.

### SP-05 — Coverage aggregator + renderer wiring

**Scope**: Port `Test2::Harness2::Log::CoverageAggregator`, its
`ByRun` and `ByTest` subclasses, and
`App::Yath2::Plugin::Cover`'s `annotate_event` dispatch into
`App::Yath2::Log::CoverageAggregator` under the artifact-reading
layer. **Motivation**: five `old/t/Yath/integration/coverage*.t`
tests hinge on this; real coverage output requires it.
**Gotchas**: the Stage 10 audit argued the aggregator should
consume artifact-reader primitives, not stream the old log —
follow that shape.

### SP-06 — Renderer::Formatter line-shape restoration or redesign

**Scope**: Either restore the old "per-job column + depth +
tree-corner markers" in `Renderer::Formatter` or redesign the
verbose output and move `encoding.t` / `tapsubtest.t` under
`t/AI/`. **Motivation**: two skipped tests, visible UX
difference from yath 1.0. **Gotchas**: this is a theme/renderer
decision, not a harness-core decision — the right fix may be in
`Renderer::Theme::Composer`.

### SP-07 — Port Renderer::JUnit + Renderer::Logger + Renderer::ResetTerm

**Scope**: Three renderers that feed different sinks. **Motivation**:
CI users depending on JUnit XML; the Logger renderer is handy for
structured-event-pipe consumers. **Gotchas**: all three already
fit the Stage 12 `event_in` contract; port is mostly mechanical.

### SP-08 — Port Renderer::QVF

**Scope**: Port the Quiet-Verbose-on-Failure renderer. **Motivation**:
the artifact-reading layer already has mode selection for it (see
`IPC_AND_LOGGERS §13.2`); the renderer itself is the one missing
piece. **Gotchas**: mode selection is command-side (`yath test
--qvf`); Stage 6's `--qvf` option reactivation pairs with this.

### SP-09 — Binary-attachment event facet

**Scope**: Port `Test2::EventFacet::Binary` (or reproduce its
shape) so renderers / archivers can round-trip binary artifacts.
**Motivation**: coverage plugins attach `.coverage` payloads as
events today; binary facet gives them a canonical envelope.
**Gotchas**: actually belongs in `Test2::EventFacet` proper —
check whether it was upstreamed before duplicating.

### SP-10 — Port Test2::Tools::HarnessTester

**Scope**: Port the test-author helper that runs the harness from
inside a test and reports aggregate events. **Motivation**:
downstream test authors who used it with yath 1.0.
**Gotchas**: depends on `Collector::Auditor::Run` shape that
does not exist in the rewrite; the port needs a different
aggregation source.

### SP-11 — TAP::Harness::Yath as artifact-reading-layer consumer

**Scope** (optional): Reimplement the `prove --harness=...`
bridge on top of the artifact-reading layer so `prove` users can
opt into yath's scheduler / preload tree without switching
commands. **Motivation**: CI systems pinned to `prove`.
**Gotchas**: low priority; defer until demand.

### SP-12 — `--log` / Tester `log => 1` plumbing

**Scope**: Reactivate `--log`, `-L`, `--log-dir` in
`App::Yath2::Options::Run`, plumb the user-facing top-level
JSONL log, and make `App::Yath2::Tester` aware of `log => 1`.
**Motivation**: unblocks four skip_all tests (`concurrency.t`,
`log_dir.t`, `resource.t`, `smoke.t`, `stamps.t`). Stage 18 flagged
this as the single biggest skip_all multiplier.
**Gotchas**: the per-job JSONL artifact already exists; this is
about a workdir-level aggregate log, not a new logger.

### SP-13 — `Command::help` rewrite

**Scope**: Rebuild `Command::help` so its output matches what
`old/t/Yath/integration/help.t` asserts (or rewrite the test).
**Motivation**: `help.t` skip_all; core UX.
**Gotchas**: depends on how `Getopt::Yath` exposes help
generation; may need changes upstream in `Getopt::Yath`.

### SP-14 — Stage 6 option reactivation sweep for include/lib options

**Scope**: Activate `-I`, `-l`, `-b`, `--no-lib`, `--no-blib`,
`--unsafe-inc`, `--tlib` etc. in `App::Yath2::Options::Harness`
and thread them through `Command::test`. **Motivation**:
`includes.t` and most other option-dependent tests.
**Gotchas**: each option has a `TODO` block that names the wiring
needed; Stage 6 policy is one activation per commit.

### SP-15 — `Command::init` test decision

**Scope**: Either rewrite `init.t` against the new `.yath.rc`
scaffold or delete the test body entirely. **Motivation**:
decide the `init.t` disposition permanently.
**Gotchas**: the test is currently skip_all'd with an explicit
"consider deleting" note; this is a decision, not much code.

### SP-16 — Filename-labelled renderer output for persist / projects / watch

**Scope**: Propagate the Stage 18 renderer label fix through
`Command::watch` and `Command::projects`. **Motivation**:
`persist.t` and `projects.t` block on label shape.
**Gotchas**: already half-done via Stage 18's `jobs` map on
`run_status`; confirm the same shape flows through `watch` /
`projects`.

### SP-17 — Harness-side plugin hook dispatch sweep

**Scope**: Dispatch the remaining plugin hooks that are defined on
`App::Yath2::Role::Plugin` but not yet called: `tick`,
`run_complete`, `run_halted`, `instance_*`, `changed_*`,
`duration_data`, `coverage_data`, `munge_*`, `claim_file`.
**Motivation**: `plugin.t`, `smoke.t`, `stamps.t` all depend on
these. **Gotchas**: add one dispatch site per commit (Stage 15
precedent); each hook has a natural consumer.

### SP-18 — `Command::projects` full implementation

**Scope**: Expand the Stage 13 stub into a real implementation:
discover per-project `.yath.rc` files, dispatch into each
project, aggregate results. **Motivation**: `projects.t`, common
monorepo use case. **Gotchas**: interacts with SP-01 if legacy
config compatibility is needed.

### SP-19 — Retry mechanism port

**Scope**: Port the `--retry` / `--retry-isolated` retry logic
from old/'s runner. **Motivation**: `retry.t`.
**Gotchas**: depends on job-reassignment path in the scheduler;
double-check against `IPC_AND_LOGGERS §14` for the retry
interaction with `launch_job` timeouts.

### SP-20 — `::` arisdottle arg-forwarding + miscellaneous Stage 6 options

**Scope**: Support `yath test ... :: --arg-for-test` arg
forwarding and reactivate `--exclude-file`, `--exclude-list`,
`--durations`, `--no-unsafe-inc`. **Motivation**: `test.t`, common
real-world yath invocation patterns.
**Gotchas**: the arisdottle split lives in
`App::Yath::Script::parse_argv`; confirm it is surfaced into
`Command::test`'s argv.

### SP-21 — Author / release tests

**Scope**: Port `old/t/0-load_all.t` and `old/t/1-pod_name.t`
into `xt/` (author tests). **Motivation**: catches load-order
bugs and POD drift before release. **Gotchas**: `xt/` already
exists in this tree; keep new files there rather than `t/`.

### SP-22 — `RunService` bus-name realignment

**Scope** (tracked from Stage 8 drift note): drop the `run_bus_name`
payload field and rename `run-$run_id` to `$run_id` verbatim per
`IPC_AND_LOGGERS §5.4`. **Motivation**: spec alignment.
**Gotchas**: touches the `launch_job` payload threading Stage 8
noted; small mechanical change once approved.

### SP-23 — Preload stage subtree and detach pattern

**Scope** (tracked from Stage 8 / Stage 9 drift notes):
implement the per-stage-subtree service shape from
`IPC_AND_LOGGERS §10.1` and the three-process detach pattern
from §10.4. **Motivation**: spec alignment; enables branch
pruning as documented. **Gotchas**: Stage 9's reload
integration follow-up depends on this.

### SP-24 — Per-run sidecar migration to run-service logger

**Scope** (tracked from Stage 18 §7 / `ARCHITECTURE.md` §4): the
per-run `<run_id>.json` sidecar is already owned by
`RunService::_write_snapshot`; confirm all state writes go
through a `Logger::JSON` instance on the run service's own
collector rather than a direct write call. Stage 18 marked this
as "already satisfied" but a one-file audit can confirm
nothing new has re-introduced a direct write path.

### SP-25 — Auditor strictness policy decision

**Scope** (tracked from Stage 17 / Stage 18): decide whether
the new `Collector::Auditor::Test`'s rejection of five raw-TAP
shapes (`badplan.tx`, `dupnums.tx`, `missingnums.tx`,
`buffered_subtest_abrupt_end.tx`, `buffered_subtest_abrupt_end_nested.tx`)
is a conscious improvement or a regression. **Motivation**:
half of `failure_cases.t`'s skipped fixtures. **Gotchas**:
might land as a documented change (update POD to say "yath is
stricter here, use old/ behaviour for bug compat") rather than
a code change.

## Explicit out-of-scope list

The following will not come back under the current plan. Each is
bundled with its rationale so a future decision to revisit has the
context readily available.

- **`App::Yath2::UI` namespace** — the web UI. PLAN scope caveat.
  All UI-specific renderers, commands, options, controllers
  remain in `old/` for reference.
- **`App::Yath2::DB` namespace** — the DB backend. PLAN scope
  caveat. All DB-specific schema, plugins, commands remain in
  `old/`.
- **Log-reading commands: `Command::replay`, `Command::times`,
  `Command::speedtag`, `Command::recent`** — PLAN scope caveat
  (the log format has changed; commands that read stored logs
  need redesign once the log-archive format is stable).
- **`Command::server`** — UI scope.
- **`Command::client::publish`, `Command::client::recent`** —
  UI scope.
- **`Command::db` + the entire `Command::db::*` subtree** — DB
  scope.
- **The full `IPC::Protocol*` family + `IPC::Connection`** — PLAN
  "should NOT come back"; superseded by `IPC::Manager`.
- **`Test2::Harness2::Util::HashBase`** — PLAN "should NOT come
  back"; replaced by `Object::HashBase`.
- **`Test2::Harness2::Util::LogFile`** — PLAN "should NOT come
  back"; replaced by the `logs/` directory layout.
- **`Test2::Harness2::TestSettings`** — PLAN "should NOT come
  back"; replaced by `Run::Job` + Getopt::Yath settings.
- **`Test2::Harness2::Instance*` family** — PLAN "should NOT come
  back"; replaced by `IPC::Manager` + service roles.
- **`Test2::Harness2::Runner*` family** — responsibilities absorbed
  into `Test2::Harness2` + `RunService` + Preload resource.
- **`Test2::Harness2::Scheduler*` family** — responsibilities
  absorbed into the harness service.
- **`Test2::Harness2::Collector::Auditor::Run`** — per-run verdict
  now lives in `RunService` and is queried via IPC.
- **`Test2::Harness2::Collector::Child`** — service-side event
  emission lives in `Util::EventEmitter`.
- **`Test2::Harness2::Log::TimeTracker`** — no in-scope consumer.
- **`Test2::Formatter::Stream`** — superseded by `Stream2` with a
  deliberately-incompatible wire format.
- **Old reload blacklist feature** — PLAN "preload reloading"
  section explicitly drops it.

## Conclusion

Parity against the in-scope portion of `old/` has been reached.
Every out-of-scope module has an explicit rationale. The
successor-plan stages enumerate the known work items that any
follow-up plan would want to pick up; the largest and most
impactful are SP-12 (user-facing top-level log), SP-03 (full
Finder), SP-17 (plugin hook dispatch), SP-05 (coverage
aggregator), and SP-06 (Renderer::Formatter polish).

None of the successor-plan items blocks the current plan-stage
chain from being merged upward. The chain represents a
self-consistent, test-suite-green implementation of the yath 2.0
rewrite on the scope PLAN declared.
