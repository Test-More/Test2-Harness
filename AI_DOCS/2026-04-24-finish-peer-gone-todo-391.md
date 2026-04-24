# finish() peer-gone race: TODO-wrapped visible assertion (#391)

**Date**: 2026-04-24
**Issue**: https://github.com/Test-More/Test2-Harness/issues/391

## What the task was

`$spawn->finish` and `$spawn->wait` were called bare in two subtests of
`t/AI/integration/harness2_run_service.t`. When the harness service exits before
the IPC `finish` ACK completes, `IPC::Manager::Service::Handle::sync_request`
raises a "peer went away" (or "is not a valid message recipient") exception that
killed the entire test with a hard die. The goal was to replace that silent crash
with a visible TAP TODO so CI stays green while the race remains audible.

## Decisions made

### Approach chosen: TODO-wrapped visible assertion in a `finish_and_wait` helper

A helper sub `finish_and_wait` was extracted to `t/lib/Test2/Harness2/Test/SpawnRace.pm`
rather than inlined into each test, so it can be reused across integration tests and
updated in one place when issue #388 (source-side fix) lands.

The helper:
1. Wraps `$spawn->finish` in an `eval`.
2. On success, falls through to `$spawn->wait` and clears `terminate_on_destroy`.
3. On a `$SERVICE_GONE`-matching error, records a `fail()` under `todo(...)` so
   TAP emits `not ok ... # TODO` and the caller proceeds.
4. On any other error, re-throws — the helper is not a general exception sink.

`$spawn->clear_terminate_on_destroy` is called after `$spawn->wait` so that DESTROY
does not attempt a second IPC call to a dead peer.

### Alternatives rejected

- **Silent eval-swallow**: what the original issue was moving away from. A regression
  that makes `finish()` always raise would go undetected.
- **Source-side tolerance in `Spawn::finish`**: correct long-term, tracked in #388.
  Premature tolerance would mask real regressions. This approach depends on #388 being
  stable before landing.

### Regex for peer-gone detection

`$SERVICE_GONE` covers two message shapes emitted by `IPC::Manager`:
- `"peer 'X' went away while awaiting response ..."` — service closed its channel
  mid-flight.
- `"'X' is not a valid message recipient ..."` — client registry no longer knows
  the peer; service already tore down before this call.

The regex is deliberately narrow. Other failure shapes (timeouts, decode errors,
handler croaks) propagate as hard failures.

## Architectural changes

- New test-library module: `t/lib/Test2/Harness2/Test/SpawnRace.pm`
  Exports `finish_and_wait`. Intended as a temporary shim until #388 lands.
- `t/AI/integration/harness2_run_service.t` updated to import and call
  `finish_and_wait` at both cleanup points (lines 64 and 112).

## Phase 2 (cleanup, pending #388)

Once `Spawn::finish` and `Spawn::terminate` natively tolerate "peer went away" (#388),
remove `SpawnRace.pm` entirely and revert the call sites to bare `$spawn->finish;
$spawn->wait;`. The two changes must not coexist: source-layer tolerance + test-layer
TODO would produce unexpected-success false negatives.
