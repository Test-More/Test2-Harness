# System-load sampler: steady CPU/memory tracking synced to monitors

## Task

The harness needs an always-current view of system CPU and memory load, captured
on a consistent interval, so that (later) resource classes can throttle job
concurrency. Prior iterations sampled load at irregular, caller-driven moments,
which made CPU% meaningless. The load must also be available to any process that
subscribes to the harness and keeps its own monitor.

## Decision: a dedicated sampler service

Rather than sample inside the main harness loop (which does many other things and
has variable timing), a dedicated child process does nothing but loop / poll /
report. With an otherwise-empty loop its cadence is steady, which is what makes
the CPU delta meaningful. Per the consistency preference it is a real
`Role::Service` (so it runs under a collector and is tracked like other
services), even though it never serves requests of its own.

Interval is a constructor arg (default 0.2s). Platforms: Linux + the BSDs /
DragonFly.

## What landed

- **`Test2::Harness2::SystemLoad`** — the sampling primitive. `sample()` returns
  `{cpu_pct, ncpu, load_avg, mem_total, mem_available, mem_used, mem_pct,
  stamp}`. Holds the previous CPU reading; the first sample reports `cpu_pct =>
  undef` (baseline), later ones a real percentage over the interval since the
  prior call. Backends:
  - Linux: `/proc/stat`, `/proc/meminfo`, `/proc/loadavg`.
  - BSD: `sysctl` (`kern.cp_time`, `vm.loadavg`, `hw.ncpu`, `hw.physmem`, and
    FreeBSD `vm.stats` page counters for available memory).
  - `/proc` reads and `sysctl` are overridable test seams.

- **`Test2::Harness2::Service::Sampler`** — the dedicated process. Consumes
  `Role::Service`; `service_on_start` opens one outbound connection to the
  harness socket; `service_tick` samples at most once per `interval` (drift-free
  `next_at += interval`, resync if it falls behind) and writes a one-way
  `system_load` request. Stops itself if that write fails or the harness closes
  the connection (a non-blocking EOF check covers steady periods with no writes).

  **Reporting policy (change-gated; added 2026-06-03).** It samples every tick
  but does not report every sample. CPU and memory usage are each rounded **up**
  to the nearest 5% and tracked independently with the same policy: an
  **increase** is reported immediately; a **decrease** only once the lower value
  has held for `decrease_delay` seconds (default 1.0s ≈ five ticks); an unchanged
  value reports nothing. A message is sent when **either** metric triggers and
  carries the current rounded value of both. Rounding/throttling is a reporting
  concern in the sampler; `SystemLoad` still measures raw values. The per-metric
  state machine is `_metric_triggers` (decides, tracks the decrease window) +
  `_commit_metric` (records last-sent on send); `_round_up_5` does the ceiling.

- **`Role::Service`** — two small additions: a `service_on_stop` hook (called
  after the loop exits, before the socket closes) and support for a
  `request_handler_*` returning `undef` to send **no** response (one-way
  requests).

- **`Service::Harness`** — spawns the sampler under a collector in
  `service_on_start` (recording to `sampler.jsonl.zst`, transitions to the
  monitor) when `sampler_interval` is set (default 0.2s);
  `request_handler_system_load` stores the snapshot in a `system_load` slot
  (for resources, in-process) and `announce`s a `harness_system` message to the
  monitor; `service_on_stop` TERMs **and reaps** the sampler.

- **`Monitor`** — a `harness_system` facet stores the latest snapshot in a
  single `system` slot (accessor `system_load`). It is broadcast to **every**
  proxy unfiltered (system load is global, not run-scoped) and only the latest
  frame is retained for replay, so a late subscriber immediately gets current
  load.

## Key correctness fixes

- **CPU math.** The old `Resource::CPU` summed *all* `/proc/stat` fields,
  double-counting `guest`/`guest_nice` (already folded into `user`/`nice`),
  skewing busy%. The new code sums only fields 0..7. On BSD, `kern.cp_time` has
  5 or 6 states across flavors but idle is always last, so `idle = last,
  total = sum` is flavor-agnostic.

- **30s shutdown stall (root-caused this task).** `Test2::Harness2::_read_one_frame`
  treated `sysread` returning 0 (EOF) as "keep waiting" and busy-spun to its 30s
  deadline. The sampler changed shutdown timing enough that the `stop` request
  began racing the service's self-stop and hit a closed connection, exposing the
  bug as a reliable 30s hang. Fixed to treat EOF/error as connection-closed and
  croak immediately. (Pre-existing latent bug; the sampler only surfaced it.)

## Lifecycle gotcha handled

The sampler tree inherits the harness service's stdout/stderr write ends (it is
forked from the service process, which is itself under a collector). A long-lived
sampler would hold those open, so the service's collector would stall on its
orphan timeout at shutdown. `service_on_stop` reaps the sampler before the
service process exits, closing those FDs first. (Job collectors avoid this
naturally by being short-lived.)

## Testing

- `SystemLoad.t`: Linux + BSD backends via the read seams (CPU delta math, 5/6
  state `kern.cp_time`, meminfo fallback, missing-counter degradation).
- `Service/Sampler.t`: `service_tick` reports once per interval over a real
  socketpair, throttles within the interval, stops on a broken connection.
- `Collector/Monitor.t`: `system_load` stored/replaced, broadcast live, replayed
  to a late proxy, and delivered even to a run-filtered proxy.
- `integration/monitor_runs_jobs.t`: a downstream monitor receives a system-load
  snapshot end to end.

## Not done (deferred)

- Resource classes that consume the snapshot to throttle concurrency.
- Per-core CPU breakdown; BSD memory-available on non-FreeBSD flavors.
