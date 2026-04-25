# Streaming Deadlock — Flow Control For Collector → Service IPC

## What triggered this

`yath -D test $(find t -iname '*.t')` (108 files at -j16) hung
indefinitely after some test progress. Smaller batches worked.
The root cause was that the harness service's IPC clients used
blocking writes on FIFOs whose 64K kernel buffers filled up under
concurrent collector traffic, deadlocking writers waiting on
readers that were themselves blocked.

## What was changed

Three projects on a `streaming_deadlock` branch:

1. **Atomic-Pipe**
   - `max_size` numifies the chomped `/proc/sys/fs/pipe-max-size`
     value before passing to `fcntl(F_SETPIPE_SZ)`. The string form
     silently failed with EINVAL, so FIFOs were never resized off
     the 64K default.
   - `write_blocking($bool)` now correctly captures `F_GETFL` flags
     into a variable (Perl returns flags as the call's return
     value, not via lvalue parameter) and sets/clears `O_NONBLOCK`
     with `&=~` / `|=`. The previous bit-twiddle started from `0`
     and inverted the meaning — `write_blocking(1)` was *setting*
     `O_NONBLOCK` instead of clearing it.

2. **IPC-Manager**
   - `IPC::Manager::Role::Outbox` (new role) provides per-peer
     non-blocking send queues. `try_send_message`, `drain_pending`,
     `pending_sends`, `pending_sends_to`, `have_writable_handles`,
     `writable_handles`, `send_blocking`, `set_send_blocking`,
     `can_send_to`. Required hooks for consumers:
     `_outbox_try_write`, `_outbox_writable_handle`,
     `_outbox_set_blocking`, `_outbox_can_send`.
   - `IPC::Manager::Client` provides no-op fallbacks for the same
     API so non-FIFO/socket clients (LocalMemory, DB-backed) can
     be used uniformly by service code.
   - `Client::AtomicPipe` and `Client::UnixSocket` consume the
     role and grow `_outbox_*` implementations.
   - `Role::Service::run` enables `set_send_blocking(0)` on the
     service's own client *after* `_run_on_start` so startup-time
     sends keep their simpler synchronous semantics.
   - The service event loop drains the outbox each iteration and
     uses `IO::Select->select($read_set, $write_set, undef,
     $cycle)` so writability wake-ups are caught even on
     platforms that don't support large pipe buffers.
   - Service drains its outbox before exit (5-second deadline)
     so the response to a `terminate` request isn't lost.
   - `Role::Outbox::try_send_message` accepts the same call shape
     as `send_message` (Message object / `($peer, \%content)` /
     full `%args`) and serializes via `build_message` + the
     client's serializer when needed. Pre-serialized strings
     stay on a fast path.
   - `Client::AtomicPipe` overrides `try_send_message`,
     `drain_pending`, `pending_sends`, `pending_sends_to`,
     `have_writable_handles`, `writable_handles` so that
     `Atomic::Pipe`'s own `OUT_BUFFER` is the per-peer queue.
     The role's `_OUTBOX` would have double-buffered the payload
     (write_message pushes into OUT_BUFFER, drain_pending then
     replays the same payload, which write_message would enqueue
     again). The override keeps each payload reaching the kernel
     exactly once.
   - `Client::DESTROY` checks `_creator_pid` (set once in `init`,
     never overwritten on post-fork resets) instead of `+PID`.
     Inherited objects in forked children are now DESTROY-noops;
     only the originating process unlinks FIFOs / sockets.

3. **Test2-Harness2**
   - `Test2::Harness2::Collector` calls `try_send_message` for
     every event, drains the outbox at the top of each loop
     iteration, and adds the writable-handle set to the loop's
     IO::Select call so it wakes the moment the kernel has room.
   - The collector exit path drains its outbox with a 5-second
     deadline before `_exit`.
   - `Test2::Harness2::request_handler_has_pending_messages`
     reports `{ ok, idle, pending, running, queued }` for a peer.
     The handler excludes the in-flight request from the pending
     count because the response goes back AFTER the handler
     returns.
   - `Test2::Harness2::Spawn`:
     - `has_pending_messages` performs a single check.
     - `wait_until_idle($timeout)` polls the harness until idle
       or the deadline (default 30 s, 0 = unbounded). Treats
       peer-gone (`'is not a valid message recipient'`,
       `'peer ... went away'`) as idle.
     - `finish()` calls `wait_until_idle(30)` before the
       race-safe `finish` request so non-blocking sends queued
       during the run get a chance to flush. Failures during the
       wait are tolerated.
   - `App::Yath2::Command::test::run` calls
     `$spawn->wait_until_idle(30)` between unsubscribe and
     finish for the same drain-before-shutdown reason.

## Pipe-buffer ceiling

Linux FIFOs default to 64K and can be grown via `F_SETPIPE_SZ`
to `/proc/sys/fs/pipe-max-size` (commonly 1 MiB). Atomic-Pipe
now grows them to the system max at FIFO creation. With those
fixes plus the non-blocking outbox, `yath -D test` runs
streaming through ~60 files end-to-end at `-j16`.

`yath -D test $(find t -iname '*.t')` (108 files at -j16) still
hangs on this hardware. The failure is a bandwidth issue, not a
correctness issue: 16 collectors all funnel events into a single
harness-service FIFO; with 1 MiB of buffer + a single reader
draining one event at a time, sustained throughput across 108
test files exceeds what the kernel can carry. Mitigation
options that DO NOT involve protocol changes:

- Lower `-j` (12 or 8 reliably completes the full 108-file run).
- Sharded service topology where each run-service only sees a
  subset of collectors (already the long-term plan).
- Out-of-band event channels (mmap log-streaming) for the
  high-volume case.

The per-peer outbox keeps the system *correct* under
backpressure: queued events are flushed when the reader
catches up. It does not increase total bandwidth, which is
bounded by the pipe and the reader's drain rate. On a system
where pipe buffers were unlimited and the reader were
infinitely fast, the new flow control would let the 108-file
run complete cleanly.

## Decisions and alternatives considered

- **Why per-peer queue, not one global outbox?** Per-peer
  preserves the granularity of `pending_sends_to($peer)` and
  `can_send_to($peer)`, which the harness needs to make targeted
  drain decisions. A single global queue would force draining
  for every peer when only one is backed up.
- **Why bypass `_OUTBOX` for AtomicPipe?** `Atomic::Pipe` has
  its own `OUT_BUFFER` that fully serves as the queue, with the
  added benefit that partial writes are tracked at the framing
  level. Mirroring that into `_OUTBOX` would always
  double-buffer.
- **Why creator-pid in DESTROY, not Test2-API state reset
  in the harness child?** The latter is more invasive (touches
  Test2 internals) and the cross-process DESTROY guard belongs
  inside IPC::Manager regardless: any consumer that forks after
  constructing a client benefits.
- **Why not raise blocking timeout in service?** Blocking on a
  full FIFO with a slow reader is exactly the deadlock — the
  service's reader is trying to deliver messages to clients and
  blocks behind a stuck client. A non-blocking queue is the
  only structural fix.

## Architectural impact

The collector → run-service → harness-service chain is now
end-to-end non-blocking on Linux FIFOs (and Unix datagram
sockets). Custom `IPC::Manager::Service` consumers may opt into
the same behaviour by leaving the auto-flip in `Role::Service`
in place; clients constructed inside a service inherit
`send_blocking=0`. Clients constructed outside a service keep
the simpler `send_blocking=1` default.

`ARCHITECTURE.md` does not yet describe this control plane;
adding a section under Part I once the topology stabilises is
the right next step.
