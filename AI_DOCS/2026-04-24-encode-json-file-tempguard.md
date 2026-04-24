# encode_json_file TempGuard — Robustness fix for tempfile leaks

**Date**: 2026-04-24
**Issue**: https://github.com/Test-More/Test2-Harness/issues/396
**Commit**: Util::JSON: encode_json_file returns a self-cleaning TempGuard

## What triggered this task

An audit flagged that `encode_json_file()` in
`lib/Test2/Harness2/Util/JSON.pm` created a `File::Temp` handle with
`UNLINK => 0` and returned only the path string, leaving cleanup entirely
to callers.  Two callers exist:

- `Collector.pm` — only unlinked on the error path; success path leaked
  the tempfile (the child was expected to unlink via `decode_json_file
  (..., unlink => 1)`, but there was no fallback if the child crashed
  before reading).
- `DB.pm` — never unlinked from the parent side at all; relied entirely
  on the child process.

## What was done

### TempGuard class (JSON.pm)

Added `Test2::Harness2::Util::JSON::TempGuard` — a tiny blessed hashref
with:

- **`use overload '""'`** so the object stringifies to the file path,
  keeping all existing call-sites that treat the return value as a string
  working without modification (except where we added `"$guard"`
  explicitly for clarity).
- **`DESTROY`** that unlinks the file if it still exists and the guard
  has not been dismissed.
- **`dismiss()`** that sets a flag so `DESTROY` becomes a no-op — used by
  callers that hand cleanup to a child process.

`encode_json_file` now returns a `TempGuard` instead of a bare path.

### Caller updates

**Collector.pm** (`_windows_spawn`):
- Replaced `$json_file` (string) with `$guard` (TempGuard).
- Removed the explicit `unlink($json_file)` on the error path — the
  guard auto-cleans when it goes out of scope on any failure.
- Added `$guard->dismiss` after a successful `system 1, @cmd` spawn, so
  the parent does not race with the child on cleanup.

**DB.pm** (`start`):
- Captured the guard in a named variable `$settings_guard` rather than
  using the return value of `encode_json_file` inline (inline usage
  would destroy the guard immediately when the array goes out of scope
  after `start_process`).
- Added `$settings_guard->dismiss` after `start_process` returns
  without throwing, so the child's `unlink => 1` remains the owner of
  cleanup.

## Design alternatives considered

**`UNLINK => 1` on the File::Temp handle**: This would auto-delete when
`$fh` goes out of scope inside `encode_json_file` — i.e., immediately,
before the caller even receives the path.  Not viable.

**Return `($path, $guard)` tuple**: Would require all callers to receive
two values and explicitly hold the guard.  More explicit but a more
invasive API change, and Perl callers using the result as a plain string
would silently get only the first element.  The overloaded object avoids
all that.

**`Scope::Guard` or `Guard` CPAN module**: Would add a dependency for a
ten-line class.  Kept it inline.

## Architectural changes

None.  `TempGuard` is a private implementation detail of
`Test2::Harness2::Util::JSON`; it is not exported and is not part of the
public API.  Existing callers that pass the guard to `decode_json_file` or
as a command-line argument see no change because of the stringification
overload.
