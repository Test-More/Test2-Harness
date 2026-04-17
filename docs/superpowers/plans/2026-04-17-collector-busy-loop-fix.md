# Fix Test2::Harness2::Collector main I/O loop busy-spin

## One-line summary

`Test2::Harness2::Collector`'s main read loop (`lib/Test2/Harness2/Collector.pm:647-734`, the `while (1) { ... }` block inside `_run_collector`) never blocks. When both upstream pipes are idle, it burns a CPU core doing non-blocking reads in a tight loop until something closes a pipe.

## Evidence

Discovered on 2026-04-17 while tracking down a stuck `t/integration/harness2_ipc_notify.t` run I'd backgrounded and forgotten.

- Process tree: test harness `3174394` -> collector `3174396` (`Test2-Harness2-Collector - 3174397`) -> service `3174397`.
- `/proc/3174396/status`:
  - `State: R (running)`
  - `voluntary_ctxt_switches: 0` (never voluntarily yielded over 32+ minutes of wall time)
  - `nonvoluntary_ctxt_switches` monotonically rising (scheduler preemption only)
- Meanwhile service `3174397` was correctly idle in `poll_schedule_timeout` inside IPC::Manager's `watch()`. Service side is healthy; collector side is the bug.
- ptrace was denied under the sandbox so no stack/strace, but the source tells the story: the loop body is all non-blocking primitives.

## Why it matters

1. **Wasted CPU** whenever a collector has a live upstream with no immediate output -- i.e. almost any idle moment inside an interactive harness run.
2. **Race widens the shutdown window**: between the service POSIX::_exit and the pipes being drained + EOF observed, the collector is burning cycles rather than blocking on `can_read` that would wake the instant the pipe closes.
3. **Masks real hangs**: a busy-looping process looks "alive and working" in `ps`. The symptom that actually pointed me at this was `voluntary_ctxt_switches: 0`, not CPU usage. Makes post-mortem debugging harder.

The loop only *terminates* correctly -- when both pipes hit EOF the `last` at line 732 fires. The issue is purely that it doesn't *wait* between iterations when there is nothing to do.

## Code location

`lib/Test2/Harness2/Collector.pm`, sub `_run_collector`, lines ~600-737. Key block is the `while (1)` at ~647. The two relevant non-blocking reads:

```perl
unless ($stdout_eof) {
    for my $item ($self->_read_handle($out_r)) { ... }
}
unless ($stderr_eof) {
    for my $item ($self->_read_handle($err_r)) { ... }
}
```

`_read_handle` (line 939) wraps either `Atomic::Pipe->get_line_burst_or_data` (non-blocking by design -- returns undef when nothing is ready and the caller is expected to come back later) or `FileLineReader->read_lines`. Neither blocks, neither takes a timeout, so the outer loop is free to spin.

Also relevant: the pre-read phase does `kill(0, $ppid)` for each parent pid, and `waitpid(WNOHANG)` for the child. Those are the "we must check this every iteration" calls that are fine to keep, but they shouldn't set the iteration cadence.

## Fix approach

Add a short-timeout `select` (or `IO::Select`) around the reads so the loop parks when both pipes are idle. Sketch:

```perl
use IO::Select;
my $sel = IO::Select->new;
$sel->add($out_r) if defined $out_r && !$stdout_eof;
# Atomic::Pipe exposes an underlying fd -- confirm the right accessor
# before relying on this; otherwise fall back to selecting on the
# glob form _read_handle already accepts.
$sel->add($err_r) if defined $err_r && !$stderr_eof && !$merge_outputs;

while (1) {
    # Periodic bookkeeping (signal, parent pid, child pid) fires every
    # tick regardless of I/O, so block for *at most* $cycle seconds
    # (pick something like 0.2s to match IPC::Manager's default cycle).
    my @ready = $sel->can_read($cycle) if $sel->count;
    ...
}
```

Watch-outs:

1. **Atomic::Pipe** needs its raw fd for `IO::Select`. Check whether the object exposes `fileno` / `handle` / `fh` or whatever it's called in the installed version before writing the fix. If it does not, either add a trivial accessor there or fall back to selecting on a sibling glob that reflects the same fd.
2. **FileLineReader path** is used for "plain filehandle" mode (non-Atomic::Pipe). It must still be select-able. It already wraps a real `$handle`, so `$sel->add($handle)` should just work.
3. **Merged stdout/stderr** (`"$out_r" eq "$err_r"`): only add one. Current code already sets `$stderr_eof = 1` up front for that case; the `select` setup has to mirror that.
4. **Draining after signal/parent-gone**: when `$draining` flips, we kill the child and need to keep reading until EOF. The `select` timeout keeps that path responsive; don't special-case it.
5. **EOF detection** for `Atomic::Pipe`: the existing loop relies on `$handle->eof()` returning true from inside `_read_handle`. After a blocked `select` wakes, we still need to drive `_read_handle` to completion; the `while (1) { ($type, $data) = get_line_burst_or_data }` already drains everything currently ready, so that pattern stays the same -- the `select` only controls *when* we re-enter it.

## Verifying the fix

- **Regression**: all existing tests must still pass --
  - `perl -Ilib t/unit/Harness2.t`
  - `perl -Ilib t/unit/Collector.t`
  - `perl -Ilib t/integration/harness2_ipc_notify.t`
  - `perl -Ilib t/integration/harness2_spawn.t`
  - `perl -Ilib t/integration/harness2_lifecycle.t`
- **Busy-loop check**: add a test that spawns a Collector over an idle upstream, parks for ~0.5s, and asserts that `/proc/$pid/status`'s `voluntary_ctxt_switches` is non-zero (or that `nonvoluntary_ctxt_switches` is reasonably bounded). Skip on non-Linux where `/proc/$pid/status` is unavailable. Reference for reading `voluntary_ctxt_switches` lives in `t/unit/Harness2/Util/IPC.t` where procfs-gated tests already pattern.
- **Shutdown latency check**: a test that sends `finish`, waits for the service to exit, and asserts the parent `waitpid` returns within a tight bound (say 1s). Any regression where the collector sleeps past the pipe-close will fail this.

## Non-goals / do not touch in the same commit

- Do not refactor the rest of `_run_collector`. The loop body's order and responsibilities are correct; only the outer cadence is wrong.
- Do not change `_read_handle`'s signature or behavior. The fix lives at the caller layer.
- Do not touch `Test2::Harness2`'s service shutdown path -- that was audited on 2026-04-17 in commit 8807ba891 (subreaper work) and is independently correct. The busy-loop is the collector's problem alone.

## Related context

- This was surfaced during the `Switch from Linux::Prctl to Test2::Harness2::ChildSubReaper` audit (commit 8807ba891, 2026-04-17). The audit confirmed all `_perform_hard_stop`, `run_on_cleanup`, and `run_on_pid` paths close correctly; the busy-loop is pre-existing, dating back at least to commit 3b37f0b40 ("Collector: split _run_collector into focused helpers") and likely earlier.
- `IPC::Manager::Role::Service` (the service side) models the correct pattern: `watch()` uses `$select->can_read($cycle)` so the service yields between activity. Mirror that here.
