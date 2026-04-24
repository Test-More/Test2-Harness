# encode_json_file TempGuard — Optional guard for tempfile cleanup

**Date**: 2026-04-24
**Issue**: https://github.com/Test-More/Test2-Harness/issues/396
**Commit**: Util::JSON: encode_json_file returns a self-cleaning TempGuard

## What triggered this task

An audit flagged that `encode_json_file()` in
`lib/Test2/Harness2/Util/JSON.pm` created a `File::Temp` handle with
`UNLINK => 0` and returned only the path string, leaving cleanup entirely
to callers.

## Review feedback

The project maintainer clarified that the bare-path-no-auto-cleanup design
is **intentional**: these temp files live under the workdir and are cleaned
up when the harness exits (or preserved when a keep flag is set).  Making
`TempGuard` the default return would break that contract.

The reviewer requested that the guard be made **opt-in** via a parameter,
so callers that do want auto-cleanup (e.g. `Collector.pm`'s Windows spawn
path) can request it explicitly.

## What was done

### TempGuard class (JSON.pm)

Added `Test2::Harness2::Util::JSON::TempGuard` -- a tiny blessed hashref
with:

- **`use overload '""'`** so the object stringifies to the file path.
- **`DESTROY`** that unlinks the file if it still exists and the guard
  has not been dismissed.
- **`dismiss()`** that sets a flag so `DESTROY` becomes a no-op -- used by
  callers that hand cleanup to a child process.

`encode_json_file` returns a bare path by default (preserving the original
contract).  Pass `guard => 1` to get a `TempGuard` instead.

### Caller updates

**Collector.pm** (`_spawn_collector_win32`):
- Uses `encode_json_file(\%params, guard => 1)` for auto-cleanup on
  failure.
- Calls `$guard->dismiss` after successful spawn so the child owns cleanup.

**DB.pm** (`start`):
- Left unchanged -- uses the default bare-path return.  The child reads
  and unlinks via `unlink => 1`; the workdir handles any remaining cleanup.

## Design alternatives considered

**Always return TempGuard (original PR)**: Rejected by reviewer -- the
no-auto-cleanup default is intentional for workdir-based temp files.

**`UNLINK => 1` on the File::Temp handle**: Would auto-delete when
`$fh` goes out of scope inside `encode_json_file` -- i.e., immediately,
before the caller even receives the path.  Not viable.

**`Scope::Guard` or `Guard` CPAN module**: Would add a dependency for a
ten-line class.  Kept it inline.

## Architectural changes

None.  `TempGuard` is a private implementation detail of
`Test2::Harness2::Util::JSON`; it is not exported and is not part of the
public API.
