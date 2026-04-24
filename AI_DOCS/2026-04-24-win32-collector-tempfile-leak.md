# AI_DOCS: Windows collector tempfile leak fix

## Task

Fix GitHub issue #395: the temporary JSON file created by `_spawn_collector_win32()` was
not guaranteed to be cleaned up if the spawned child process died before
`decode_json_file` was called.

## What Triggered It

Audit session flagged that tempfiles could accumulate unboundedly over long
test runs on Windows, eventually exhausting `/tmp` and causing cryptic
failures.

## Root Cause

`_spawn_collector_win32()` creates a tempfile via `encode_json_file(\%params)`
and passes its path to the child as `$ARGV[0]`.  The child calls
`collect_from_file($file)`, which calls
`decode_json_file($file, unlink => 1)` to read and delete the file.

The parent only unlinks on spawn failure.  The child is expected to unlink
on success.  However, if the child dies *before* `decode_json_file` is
reached — e.g., because `require Test2::Harness2::Util::JSON` fails to load
— neither side cleans up the file.

## Fix

Added a `Scope::Guard` at the top of `collect_from_file`, before the
`require`, that unlinks the file when the guard goes out of scope:

```perl
my $file_guard = Scope::Guard->new(sub { unlink $file if -f $file });
```

`Scope::Guard` fires via `DESTROY` during normal scope exit *and* during
exception-driven stack unwind, so the file is removed regardless of the exit
path.  The existing `decode_json_file($file, unlink => 1)` call still fires
on the normal path; the guard then becomes a no-op (`-f $file` is false).

The existing `Scope::Guard` that calls `POSIX::_exit(255)` is installed
*after* `decode_json_file` succeeds, so `_exit` can only be reached when the
file is already gone — the new guard never needs to fire against `_exit`.

## Alternatives Considered

**`END` block** — `END` blocks survive `die` but are bypassed by
`POSIX::_exit`.  Since `_exit` is used later in the same function, an `END`
block would have the same "already cleaned up" property but is less
idiomatic when `Scope::Guard` is already in use and already imported.

**Parent-side cleanup after a delay** — not viable on Windows because NTFS
prevents unlinking a file that is open by another process.  The child must
own the cleanup.

**`unlink` immediately after spawn** — suggested in the issue but wrong for
Windows: the child needs to open the file before the parent can safely
remove it.

## Test Added

`t/AI/unit/Collector.t` — new subtest
`collect_from_file cleans up tempfile even if require fails before decode_json_file`.

The test forks, deletes `Test2::Harness2::Util::JSON` from `%INC` in the
child, and adds a blocking `@INC` hook so the next `require` fails.  It then
calls `collect_from_file` and verifies the tempfile is gone after the child
exits.

## Files Changed

- `lib/Test2/Harness2/Collector.pm` — added `Scope::Guard` in `collect_from_file`
- `t/AI/unit/Collector.t` — added regression test
