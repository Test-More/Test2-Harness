# Thread `kill_timeout` through the shutdown cascade

## Trigger

`t/AI/integration/harness2_lifecycle.t` was taking ~61s wall-clock for four
small subtests. Two of the four (`Terminate mid-run kills collector and
test process` and `service dies when its caller dies (no detach)`) each
spent ~29s in stacked `kill_timeout` grace windows.

## What was happening

`Test2::Harness2::Role::Service::perform_hard_stop`
(`lib/Test2/Harness2/Role/Service.pm`) is the shared TERM->KILL escalator
used by `Test2::Harness2`, `Test2::Harness2::RunService`, and
`Test2::Harness2::Collector`. Each layer defaulted `kill_timeout` to 15s
and never inherited the value from the layer above it. When a shutdown
cascaded, each new layer the harness's escalator picked up (after the
parent layer had been KILLed and the children re-parented through the
subreaper) entered with an empty signal map and got a fresh 15s grace
window. Two cascade hops -> ~30s.

The `RunService` `SIG{TERM}` handler at
`lib/Test2/Harness2/RunService.pm` is intentionally minimal (just flips
`STATE` to `'terminating'`); it does not actively shut anything down,
which is what makes the harness fall through to the KILL path and
trigger the second cascade hop.

## Decision

Thread `kill_timeout` from the harness through to every downstream
service it spawns:

- `lib/Test2/Harness2.pm` `_ensure_run_service_started`: pass
  `kill_timeout => $self->{+KILL_TIMEOUT}` into
  `Test2::Harness2::RunService->spawn(...)`.
- `lib/Test2/Harness2/RunService.pm` `start`: pass
  `kill_timeout => $self->{+KILL_TIMEOUT}` into
  `Test2::Harness2::Collector::Service::Run->interpose(...)`.
- `lib/Test2/Harness2/RunService.pm` `request_handler_launch_job`: pass
  `kill_timeout => $self->{+KILL_TIMEOUT}` into
  `Test2::Harness2::Collector::Test->spawn(...)` so per-test-job
  collectors inherit the same value.

The 15s default at each layer is unchanged, so production behaviour for
any caller that does not set `kill_timeout` is identical. The lifecycle
test now passes `kill_timeout => 2` to its `Test2::Harness2->spawn`
calls and the file completes in ~9s instead of ~61s.

## Alternatives considered

1. **Make the `RunService` `SIG{TERM}` handler call `perform_hard_stop`
   directly.** Rejected: the handler runs in signal context and the
   escalator does `waitpid`/`kill`. Easy to land an inside-of-signal
   regression on a real production code path; the config-threading fix
   is strictly safer and gives callers a knob they can already use.
2. **Add a `YATH_HARNESS2_KILL_TIMEOUT` env var.** Rejected: the harness
   already accepts `kill_timeout` as a constructor arg. An env var would
   be a second redundant way to set the same value.
3. **Reduce the polling cadence in `wait_until` (test side) or in the
   escalator's `tinysleep(0.05)`.** Rejected: 50ms is not the
   bottleneck.

## Architectural change

None to the spec — `ARCHITECTURE.md` already describes `kill_timeout` as
a per-service grace window. The change just makes it controllable
end-to-end from the entry-point spawn instead of requiring callers to
wire it in at every layer.
