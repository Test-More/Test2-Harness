# Known pre-existing test failures (as of 2026-04-24)

While implementing the event streamer (see
`2026-04-24-event-streamer.md`) I ran the full test suite several
times and catalogued the failures that predate this work. None of
them were introduced by the streamer, and all of them still
reproduce when the streamer commits are stashed. Recording them
here so future runs do not waste time re-diagnosing.

## Baseline (before streamer work)

On the `2.0` branch at `9d6b7395f` (the merge base of the
streamer worktree), the following test files fail:

| File | Failing subtests | Total | Notes |
|------|------------------|-------|-------|
| `t/AI/unit/Collector.t` | 29 | 54 | IPC::Manager client stubbing regression |
| `t/AI/unit/Collector/burst_sync.t` | 2 | 2 | Known Atomic::Pipe ordering limitation |
| `t/AI/unit/Harness2/Role/Collector/Observer.t` | 2 | 3 | Observer lifecycle assertions break for the same reason Collector.t does |
| `t/AI/unit/Harness2.t` | 3 (#33, #34, #40) | 50 | RunService spawn mocking no longer matches harness call path |

Totals are stable -- stashing the streamer commits reproduces the
same failure counts in the same subtests.

## `t/AI/unit/Collector.t` (29/54)

Every failing subtest blows up with the same exception:

    Not sure what to do with HASH(0x...) at
      lib/Test2/Harness2/Collector.pm line 713.

Line 713 is `IPC::Manager->connect($self->bus_id, $self->{+IPCM_INFO})`.
The test file stubs `IPC::Manager::Service::Handle::new` /
`::client` etc. with no-ops, but the collector's lazy IPC client
path goes through `IPC::Manager->connect` directly and the stubs
do not cover it. Any subtest that lets the collector instantiate
its IPC client trips the connect() call with whatever `ipcm_info`
the test passed in (usually a plain hashref), and the real
`IPC::Manager::connect` refuses to recognise it.

Fix shape: extend the test's `BEGIN` stub block to also intercept
`IPC::Manager::connect` (or route through a fake `ipcm_info`
handshake the real connect() accepts). Out of scope for the
streamer work.

## `t/AI/unit/Collector/burst_sync.t` (2/2)

Both subtests fail for the same documented reason the TODOs in
the file already call out:

    TODO Atomic::Pipe mixed_data_mode same-pipe FIFO (see #389)

Mixed data mode on a shared pipe loses strict before/after
ordering between stdout lines, embedded events, and stderr
lines. The tests assert that ordering, so they fail. The TODO
markers mean the test file acknowledges the limitation; the
outer subtest still returns a non-zero exit, which is why the
suite reports it as "failed" even though the inner assertions
are TODO.

Fix shape: either finish the Atomic::Pipe work referenced in
issue #389 or soften the outer subtest's exit-code handling so a
fully-TODO'd run does not mark the file dubious.

## `t/AI/unit/Harness2/Role/Collector/Observer.t` (2/3)

The remaining passing subtest exercises a non-IPC code path; the
two failing ones hit the same
`lib/Test2/Harness2/Collector.pm:713` connect call as the
Collector.t failures and fail for the same reason. Same fix
shape as Collector.t -- stub (or accept) the IPC connect layer.

## `t/AI/unit/Harness2.t` (3/50)

Subtests #33, #34, and #40 mock `Test2::Harness2::RunService::spawn`
with a `local *...::spawn = sub { ... }` override and expect the
harness to call it when it lazy-spawns a run service. The test
records how many times the override was invoked and the
arguments. On current `2.0`, `@spawn_calls` is always empty:

    #   +-----+----+-------+
    #   | GOT | OP | CHECK |
    #   +-----+----+-------+
    #   | 0   | eq | 1     |
    #   +-----+----+-------+

The harness's spawn path presumably moved (or gained an extra
indirection) since the test was written, so the mock sits on a
branch the harness no longer reaches under these conditions.

Fix shape: update the mock to whatever entry point the harness
actually calls now (or rework the subtest to observe the effect
of a spawn rather than the literal spawn() call).

## Flaky parallel failure: 7z writers

Running the SevenZip tests in parallel (`prove -j16`) intermittently
trips:

    t/AI/unit/LogArchive/Writer_SevenZip.t  -- list_files mismatch
    t/AI/unit/LogArchive/SevenZip.t         -- list_files mismatch

When they fail, each archive contains the other's files. Observed
diff (Writer_SevenZip.t):

    GOT:      a.txt, b.txt, one.txt
    EXPECTED: one.txt

Both tests use `File::Temp::tempfile(OPEN => 0, SUFFIX => '.7z',
UNLINK => 1)` then `unlink $out` before invoking `7z a $out ...`.
`7z a` is an **append** operation: if the output path already
contains a valid 7z archive, the command adds new files to it
instead of replacing. The observed symptom -- one archive
containing both tests' fixtures -- is consistent with two
concurrent tests picking the same output path. File::Temp with
`OPEN => 0` cannot atomically reserve the name, and the inner
`unlink $out` opens a window where the other test's process can
publish its archive at the same path.

Sequential runs always pass. The failure reproduces in roughly
half of `prove -j16` invocations.

Fix shape: either make the `tempfile(OPEN => 0)` dance race-free
(e.g. open-then-unlink-then-close to lock the inode; or use
`tempdir(CLEANUP => 1)` and join a stable filename) or pass
`-y` (yes) and ensure the test creates a fresh directory for
each 7z invocation. Fix belongs in the test files, not in the
writer code.

## Scope note

The streamer work does not change the counts or the shapes of
any of the failures above. Any new test file failure in this
worktree should be attributed to streamer code, not to this
list.
