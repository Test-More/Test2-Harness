# Stage 16 -- Port additional resources (SharedJobSlots)

Branch: `plan-stage-16-resources`
Base:   `plan-stage-15-plugins` (tip `dfa981ab9`)
Final HEAD (before this summary): `8e7ff098f`
Commit count: 7 code + 1 summary

## What landed

### Primary deliverable: `App::Yath2::Resource::SharedJobSlots`

Cross-project / cross-invocation job-slot coordination. The resource
keeps a shared JSON state file on disk (path comes from a YAML config
discovered by walking up from cwd) and every participating yath
invocation reads / writes that file under `flock` to agree on who
gets how many slots at any moment.

Modules added under `lib/`:

| File | Role |
|------|------|
| `App/Yath2/Resource/SharedJobSlots.pm` | Resource consumer (the thing the harness attaches). Composes `Test2::Harness2::Role::Resource`. |
| `App/Yath2/Resource/SharedJobSlots/Config.pm` | YAML config loader. Finds `.sharedjobslots.yml` walking upward from cwd; merges host-specific / COMMON / DEFAULT sections. |
| `App/Yath2/Resource/SharedJobSlots/State.pm` | Flock-protected transactional state-file coordinator. Owns the `allocate_slots` / `assign_slots` / `release_slots` API and the `fair` / `first` redistribution algorithms. |

The resource has **no** `service_*_start` methods: see "Points of
interest" below for why the port does not introduce an IPC-reachable
coordinator service.

### Stub removal

`lib/Test2/Harness2/Resource/SharedJobs.pm` -- a Stage 1 stub that
croaked on every call -- was deleted. The real implementation lives
under `App::Yath2::Resource::SharedJobSlots` (the old/ name,
restored).

### Option wiring

`App::Yath2::Options::Resource` activates two options:

* `--shared-jobs` (Bool, `maybe => 1`) -- tri-state: unspecified
  means auto-detect, true requires a config, false forces off.
* `--shared-jobs-config PATH` (Scalar, default `.sharedjobslots.yml`).

Wired into `App::Yath2::Command::test` via a new
`_resolve_shared_jobs` helper that decides the three-state outcome
and hands constructor args for the resource down to `_run_tests`.
When shared jobs are on, `SharedJobSlots` replaces the default
`JobCount` limiter (they are both job limiters; running both would
double-cap without coordinating).

### Util helper

`Test2::Harness2::Util::find_in_updir` -- walk upward from cwd
looking for a named path. Ported verbatim from old/. Needed by the
Config loader.

## Per-commit notes

| SHA | Subject |
|-----|---------|
| `a21ef8c7c` | `Util: port find_in_updir from old/` -- prerequisite for the Config loader. |
| `9a82da09c` | `App::Yath2::Resource::SharedJobSlots::Config: port config loader` -- YAML host/COMMON/DEFAULT merge + algorithm-name resolution. Switched `Test2::Harness2::Util::HashBase` to `Object::HashBase` (project standard) and added the matching imports. |
| `d4c0f1efa` | `App::Yath2::Resource::SharedJobSlots::State: port shared state store` -- flock transactions, fair/first redistribution. Replaced `sleep 0.2` with `Time::HiRes::sleep`, tightened the `_redistribute_fair` exit condition, dropped a couple of unused lexicals. |
| `15e613bba` | `App::Yath2::Resource::SharedJobSlots: port resource consumer` -- thin resource wrapper over State + Config. Consumes `Test2::Harness2::Role::Resource` directly. Construction takes plain args (`slots`, `job_slots`, `shared_jobs_config`, `host`, `project`, `cwd`, `procname_prefix`, `runner_id`, `runner_pid`, `observe`) instead of reading from a legacy settings tree. |
| `0ee07d691` | `Resource::SharedJobs: drop stub superseded by SharedJobSlots port` -- Stage 1 stub deleted; nothing in `lib/` or `t/` referenced it. |
| `ca9a186d5` | `Options + Command::test: wire --shared-jobs / --shared-jobs-config` -- option activation + Command::test hookup. |
| `8e7ff098f` | `Tests: unit coverage for SharedJobSlots port` -- three t/AI/unit/ test files plus the `.sharedjobslots.yml` fixture. |

## Tests

New tests under `t/AI/unit/App/Yath2/Resource/`:

* `SharedJobSlots.t` -- resource consumer behaviour (construction
  checks, available/assign/release, impossible-slot rejection,
  observe mode, state transitions).
* `SharedJobSlots/Config.t` -- YAML loader coverage across host /
  COMMON / DEFAULT / `use_common=0` sections, `algorithm: first`
  resolution, and the missing-config branch.
* `SharedJobSlots/State.t` -- construction-arg checks, entry
  expiration predicate, one allocate/assign/release roundtrip, and
  multi-runner coexistence via a shared state file.
* `SharedJobSlots/.sharedjobslots.yml` -- fixture mirroring the
  legacy one with a `DEFAULT.no_warning: 1` added so the
  fall-through branch doesn't spam the test run.

### Ported / deferred from `old/t/`

Neither `old/t/` nor the `old/` integration suite has tests for
SharedJobSlots -- the relevant historical coverage sits under
`legacy/t/unit/Test2/Harness/Runner/Resource/SharedJobSlots/` and
targets the 1.0 class name (`Test2::Harness::Runner::Resource::
SharedJobSlots::*`). Porting those verbatim would require a
~100% rewrite to compile against the new names, so the new
t/AI/ tests above cover the same surface instead. Flagged for
Stage 17's sweep to confirm the legacy tests stay deferred; the
conceptual coverage is already present under `t/AI/`.

### Final test-suite result

```
prove -I lib -I t/lib -r -j16 t
Files=65, Tests=565, 60 wallclock secs
Result: PASS
```

Running on top of `plan-stage-15-plugins` (tip `dfa981ab9`) which
was also green.

## Points of interest / decisions you may want to revisit

### Why SharedJobSlots does not declare a `service_*_start` method

The task brief asked for the port to conform to `IPC_AND_LOGGERS`
section 9 and mentioned the resource "declares service methods".
On closer reading of both the spec and the old/ implementation:

* `IPC_AND_LOGGERS` section 9.1 is explicit that a resource with
  zero `service_*_start` methods is a supported shape (`JobCount`
  is the canonical example). What the role requires is the
  `available` / `assign` / `release` / `status` contract, not a
  service.
* Old/'s `App::Yath2::Resource::SharedJobSlots` has no
  `service_*_start` method. Cross-invocation coordination lives
  entirely in a shared state file plus `flock` on a sibling `.LOCK`
  file.
* The "coordinator reachable over IPC or a shared medium" the
  brief cited is the state file itself: every yath invocation on
  the host agrees on a path in a YAML config and they serialise
  on `<state_file>.LOCK`. That is the authoritative shared
  medium; no central "coordinator service" exists in old/.

Introducing a new coordinator service would have required either
(a) a well-known rendezvous-discovery mechanism (socket path,
daemon PID file) both yaths can agree on without IPC, or (b)
restricting the feature to a single yath "owning" the bus.
Neither matches the old/ user-visible behaviour or the "two
independent yath invocations share slots" motivation the brief
cites. The file-coordinated model was kept and the rationale is
recorded in the resource's POD under *DISCOVERY AND COORDINATION
MEDIUM*.

If a later stage wants a per-host long-lived coordinator daemon
(nice for one-shot yath invocations that would otherwise burn a
lock acquisition per command), the spec's "resource may declare
service methods" escape hatch still applies: adding a
`service_sharedjobslots_start` method later is strictly additive
and would let runs that find an already-running daemon
short-circuit the flock path. The file-coordinated path stays
authoritative in the absence of such a daemon.

### Resource naming: `SharedJobSlots` vs `SharedJobs`

Stage 1 shipped a stub `Test2::Harness2::Resource::SharedJobs`
(note the missing "Slots"). Old/'s module is
`App::Yath2::Resource::SharedJobSlots`. The port went back to the
old/ name since (a) the stub was stubbed-only and had zero
dependents, and (b) dropping the `Slots` suffix would have
collided with the visible name users learned in old/. The Stage
1 stub was deleted in the same stage to avoid two modules
claiming the same responsibility.

### Tri-state `--shared-jobs` and the config-file discovery rule

The option behaviour matches old/:

* Not specified at all -- opt in iff `.sharedjobslots.yml` exists
  under cwd or a parent. Quiet fall-through to JobCount when
  absent.
* `--shared-jobs` (true) -- require a config; clear error if none
  is found.
* `--no-shared-jobs` (false) -- disabled regardless of config
  presence.

Decision made inline in `Command::test::_resolve_shared_jobs`
instead of via a Getopt::Yath `option_post_process`, because
old/'s `shared_post_process` poked at `resource->classes` (a Map
option still commented-out in Stage 6). When Stage 18's TODO
sweep re-enables the `classes` option, the post-process can
migrate.

### `App::Yath2::Resource` base class not ported

Old/'s `App::Yath2::Resource` was a thin base adding a `settings`
slot so resources could read `$settings->...` directly. The new
resources in `lib/` (`JobCount`, `Preload`, `Disk`, `Memory`) all
consume `Test2::Harness2::Role::Resource` directly and take plain
constructor args -- no settings object in sight. `SharedJobSlots`
followed suit: takes plain args at construction and converts them
from the Getopt::Yath settings tree inside
`Command::test::_resolve_shared_jobs`. If a future stage decides
it wants the shared `App::Yath2::Resource` base after all, this
resource would be a one-edit candidate (add `parent` +
`<settings>` slot). Until then the port avoids adding a class
that nobody uses.

### `_job_concurrency` accepts both TestFile shapes

Old/'s test_file had `check_min_slots` / `check_max_slots`
accessors; the new in-tree TestFile uses `min_slots` /
`max_slots` (see `Test2::Harness2::Resource::JobCount`). The
resource honours either: `can`-checks both and prefers the new
names. This keeps the code portable for a future `Role::TestFile`
widening.

### Deviations from `IPC_AND_LOGGERS`

None. Section 9.1 is explicit that resources without service
methods are a supported shape, and the port follows that exactly.
The "coordinator discovery" bit of the brief is handled by the
YAML config + state-file path contract, documented in the
resource's POD.

## Open follow-ups

None that block later stages. The "if we ever want a daemonised
host-local coordinator" path is orthogonal and would land as a
separate additive change whenever the need arises.

## Safety
- Did not merge `reimplement-resource-classes`.
- Did not push any branch.
- Did not rebase any `plan-stage-*` branch.
- Did not modify PLAN / ARCHITECTURE.md / IPC_AND_LOGGERS.
- Did not delete or modify other worktrees.
- No hook bypass.
