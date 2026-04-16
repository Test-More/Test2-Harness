# Test2::Harness2 Service — Resume Notes (2026-04-16)

**Branch:** `2.0_rewrite` — do not merge to master yet.

## Status

All 21 plan tasks plus two rounds of note-file feedback are complete. A third round is in progress: 2 of 4 items done, 1 stashed mid-work, 1 not yet started.

## Completed work

### Plan (tasks 1–21)

`docs/superpowers/plans/2026-04-16-test2-harness2-service.md`

28 commits from `ca70bf0c4` through `2533d1f98`. See `git log --oneline` for the chain.

Implements:
- `Test2::Harness2` — top-level IPC service consuming `IPC::Manager::Role::Service`
- `Test2::Harness2::Run`, `Test2::Harness2::Run::Job` — queue data model
- `Test2::Harness2::Spawn` — parent-side handle
- `Test2::Harness2::Util::EventEmitter` — Stream2-compatible atomic-pipe writer
- `Test2::Harness2::Collector::Logger::IPCNotify` — event-driven wake-up logger
- Collector additions: `new_pgroup` attribute, Unix setpgid, Windows guard, `Handle->is_done`
- Two integration tests covering Invariants 1 (no survivors on hard stop) and 2 (nothing survives its parent)
- `dist.ini` optional deps: `Linux::Prctl`, `Win32::Job`

### Notes round 1 (`notes` file, first version)

3 commits:
- `57dda7e82` — collector warnings to loggers via `$SIG{__WARN__}`
- `411aa8398` — collector signal handlers (TERM/INT/QUIT shutdown; USR1/USR2/HUP/PIPE ignore)
- `c81a4911c` — IPCNotify logger introduced
- `5346fb34f` (rebased) — Stream2 uses EventEmitter, EventEmitter gets `stderr_pipe` (autosquash fixup into EventEmitter's introducing commit)

Questions answered:
- **Stream2 + EventEmitter consolidation:** yes, done via fixup.
- **WNOHANG portability:** POSIX everywhere; Windows Collector path doesn't use it.

### Notes round 2 (`notes` file, second version)

4 commits:
- `b57119fdd` — `jid` → `job_id` rename (31 occurrences, 4 files)
- `3c2e2f4e8` — `job_complete_notify` converted from request to IPC::Manager message (non-blocking)
- `bd6c6b954` — `can()`-based request dispatch, all request types lowercased (`Terminate` → `terminate`, `Detach` → `detach`), handlers renamed `request_handler_<type>`
- `609cc440a` — Collector owns `run_id`/`job_id`/`job_try`/`ipcm_info`; roles require `set_process_info` + `set_ipcm_info`

### Notes round 3 (`notes` file, third version) — IN PROGRESS

Current `notes` file content:
```
1. Collector classes should require the ipcm_info attribute
2. _run_collector is very long, can it be broken up into multiple functions?
3. Add a comment to IPCNotify explaining that we send a message to wake up the service loop.
4. Instead of requireing set_process_info and set_ipcm_info, there can be default no-op implementations for both auditors and loggers. Remove no-op implementations from the classes that implement the roles.
```

Order of work:
- **Item 3 (done)** — `4db1b1d2a` — IPCNotify documentation added (code comment + POD DESCRIPTION).
- **Item 4 (done)** — `d868300b3` — moved `set_process_info` / `set_ipcm_info` defaults into `Role::Auditor` and `Role::Collector::Logger`. Removed duplicate implementations from `Auditor::Test`, `Logger::JSONL`, `Logger::IPCNotify`. IOParser kept its own setters because it does not consume either role. Default implementations use string keys (`$self->{run_id}` etc.) because HashBase constants aren't available in the role's namespace.
- **Item 1 (IN PROGRESS, stashed)** — Collector classes require `ipcm_info` at construction. Stash: `stash@{0}` — `"notes-v3-item1-WIP: require ipcm_info on Collector classes (partial, needs completion)"`.
- **Item 2 (not started)** — break up `_run_collector`.

## Resuming item 1

The stashed WIP added the `exists $self->{+IPCM_INFO}` croak to `Test2::Harness2::Collector::init` and updated several test files to pass `ipcm_info`. It was interrupted mid-run, not tested to completion, and likely incomplete.

**Recommended resume path:**

```bash
git stash pop   # recovers the WIP
# Inspect: git status, git diff
# Run tests to find remaining failures:
perl -Ilib t/unit/Collector.t
perl -Ilib t/unit/Collector/Auditor/Test.t
perl -Ilib t/unit/Collector/Parser/IOParser.t
perl -Ilib t/unit/Harness2/Collector/Logger/IPCNotify.t
perl -Ilib t/unit/Harness2.t
# Integration:
perl -Ilib t/integration/harness2_start.t
perl -Ilib t/integration/harness2_spawn.t
perl -Ilib t/integration/harness2_lifecycle.t
perl -Ilib t/integration/harness2_ipc_notify.t
```

Likely remaining work:
- Ensure every one of the five Collector-family classes (`Collector`, `Auditor::Test`, `Logger::JSONL`, `Logger::IPCNotify`, `Parser::IOParser`) has the `exists $self->{+IPCM_INFO}` check in its `init`.
- Remove any `$self->{+IPCM_INFO} //= ...` defaults that would bypass the check.
- Every test construction site needs `ipcm_info => undef` (or a real value for IPC-exercising tests).
- Add one subtest per class verifying the croak fires when `ipcm_info` is not passed.

Commit message (from the original prompt):
```
Require ipcm_info at construction on Collector classes

Every class in the Test2::Harness2::Collector family now requires
the ipcm_info key to be present in construction args; an undef
value is accepted but must be passed explicitly. This forces
callers to think about the service connection rather than silently
defaulting.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
```

## Remaining after item 1

- **Item 2 — break up `_run_collector`.** `lib/Test2/Harness2/Collector.pm`'s `_run_collector` is large. Refactor into smaller focused methods. Preserve existing behavior and lifecycle carefully: the `local $SIG{__WARN__}` and signal handlers installed at the top must stay in the same lexical scope as the main work (`local` is scoped to the block — splitting requires care). Likely approach: extract logical sections (setup, main loop iteration, shutdown) into helpers called by a thinner `_run_collector` that still owns the `local`-scope declarations.

## Spec + plan references

- Spec: `docs/superpowers/specs/2026-04-16-test2-harness2-service-design.md`
- Plan: `docs/superpowers/plans/2026-04-16-test2-harness2-service.md`
- This resume: `docs/superpowers/plans/2026-04-16-test2-harness2-service-RESUME.md`

## Task tracking

TaskCreate tasks 1–29 are all `completed`. Tasks 30 (item 3) and 31 (item 4) are completed. Task 32 (item 1) is `in_progress`. Task 33 (item 2) is `pending`.

## Test suite baseline

As of commit `d868300b3` (pre-item-1), all 13 test files pass:

| File | Subtests |
|------|----------|
| `t/unit/Harness2.t` | 20 |
| `t/unit/Harness2/Run.t` | 9 |
| `t/unit/Harness2/Run/Job.t` | 4 |
| `t/unit/Harness2/Spawn.t` | 2 |
| `t/unit/Harness2/Util/EventEmitter.t` | 7 |
| `t/unit/Harness2/Collector/Logger/IPCNotify.t` | 10 |
| `t/unit/Collector.t` | 42 |
| `t/unit/Collector/Auditor/Test.t` | 26 |
| `t/unit/Collector/Parser/IOParser.t` | 7 |
| `t/integration/harness2_start.t` | 5 |
| `t/integration/harness2_spawn.t` | 7 |
| `t/integration/harness2_lifecycle.t` | 4 |
| `t/integration/harness2_ipc_notify.t` | 1 |

Total: 144 subtests across 13 files, all green.
