# Phase 7 — `--set-hash-seed`: harness owns `PERL_HASH_SEED`

## What and why

The `App-Yath-Script` wrapper (a separate distribution shipping the
`yath` binary) historically forced `PERL_HASH_SEED` to today's date in
`YYYYMMDD` format whenever it was unset, then `exec`'d perl with that
seed in place. The goal was reproducibility: identical perl runs of the
same test on the same day produce identical hash orderings.

The wrong place for that logic is the wrapper. Reasons:

- The wrapper has no opinion about whether the user actually wants a
  fixed seed; everyone gets one.
- The wrapper cannot disambiguate "I want today's seed" from "I want a
  specific custom seed".
- A daemon-mode harness (eventually `yath start` + `yath run`) needs
  the seed pinned at harness-startup time so its preloaded perl
  processes inherit a stable hash table layout. Different runs against
  that daemon must agree on the seed or refuse to share preloads.

So Phase 7 moves the responsibility into the harness/yath options
layer:

- The user opts in with `--set-hash-seed` (value optional).
- The harness is the authoritative producer of `PERL_HASH_SEED` for
  child test processes.
- A queue-vs-harness mismatch on the seed is a hard error.

## Option semantics (Phase 7.1)

`--set-hash-seed` is an `Auto`-typed option in
`App::Yath2::Options::Tests`:

| invocation                   | resolved value             |
|------------------------------|----------------------------|
| (option absent)              | undef — env left untouched |
| `--set-hash-seed`            | today as `YYYYMMDD`         |
| `--set-hash-seed=12345`      | `12345` (verbatim)          |
| `--set-hash-seed=DEADBEEF`   | `DEADBEEF` (verbatim)       |

The autofill resolves through `App::Yath2::Options::Tests::today_yyyymmdd()`,
which is `strftime('%Y%m%d', localtime)` — bit-for-bit the same shape
the App-Yath-Script wrapper produces, so callers who relied on the old
default get the same value once they pass `--set-hash-seed`.

When the option is absent we deliberately do **not** synthesize a seed.
Children inherit whatever the parent's `PERL_HASH_SEED` already is
(today often the wrapper's; tomorrow nothing). The harness is in charge
when asked, and silent otherwise.

## Wiring (Phase 7.1)

The path from CLI to test child:

1. `App::Yath2::Command::test::run` resolves
   `$settings->tests->set_hash_seed` and forwards it as
   `hash_seed => ...` to `Test2::Harness2::Spawn::queue_test_run`.
2. `Test2::Harness2::request_handler_queue_test_run` hands the value
   to `Test2::Harness2::Run->from_files(hash_seed => ...)`. The Run
   carries it on a new `hash_seed` slot.
3. `Test2::Harness2::_launch_job`, when it builds the per-job env
   hashref, sets `PERL_HASH_SEED` from the run's `hash_seed` (if
   defined). The collector applies `env_vars` immediately before
   `exec`'ing the test.

No `App-Yath-Script` modules are loaded at any point. The harness
remains free of yath-side imports.

## Mismatch rejection (Phase 7.2)

`Test2::Harness2` itself gains a `hash_seed` HashBase slot. When `yath
start` (eventually) brings up a daemon harness and seeds a global
preload, the slot stores that seed.

`request_handler_queue_test_run` rejects a queued run whose seed value
disagrees with the harness's. The error message names both seeds and
the preload context:

```
--set-hash-seed=20260202 on the run does not match
--set-hash-seed=20260101 on the harness;
preload was started with seed 20260101 and cannot be reused
```

Two cases are intentionally **accepted** while the preload story is not
yet fleshed out:

- Harness unset, run set: there is no global preload commitment. The
  run service simply propagates the run's seed into `PERL_HASH_SEED`
  for that run's test children.
- Run unset, harness set: the run inherits the harness's seed via the
  test environment.

A TODO at the queue handler notes that once a real
`Test2::Harness2::Resource::Preload` exists (currently absent), the
rule must tighten: any unset-vs-set status mismatch is also a refuse,
because the preload's hash table is already baked.

### Stubs

`App::Yath2::Command::start` and `App::Yath2::Command::run` are still
stubs (their `run()` methods `die` with a PR #390 message about removed
IPC layers). Both received a clearly-marked Phase 7.2 TODO at the top
describing exactly how `--set-hash-seed` should be wired in once the
global-preload daemon path returns. The reject-on-mismatch validation
is already in place on the harness side, so once those commands wire
the option through `queue_test_run`, no further harness change is
needed.

## Cross-distribution coordination (Phase 7.3)

The seed-setting `exec` in
`App-Yath-Script/lib/App/Yath/Script.pm::seed_hash` is now duplicative
in any run that uses `--set-hash-seed`: the harness sets
`PERL_HASH_SEED` in the test child's env right before `exec`, after the
wrapper has already set it once for the parent.

The wrapper change is a separate distribution release. Sequencing:

1. **(this commit)** Phase 7 lands here: `--set-hash-seed` is the
   sanctioned source of `PERL_HASH_SEED` for child test processes
   running under `yath test`.
2. **App-Yath-Script next release** removes `seed_hash()` (and the
   `exec`-based reload it triggers when the env var is unset). The
   wrapper becomes neutral; users who previously got today's seed
   "for free" must opt in with `--set-hash-seed`.
3. **This dist's cpanfile** bumps the minimum
   `App::Yath::Script` to that release. CI's `ubuntu-script-branch`
   job will catch the transition because it runs against the
   unreleased wrapper before the cpanfile bump propagates.

Until step 2 ships, the wrapper's `seed_hash` continues to set
`PERL_HASH_SEED` once per `yath` invocation. That value is harmless
when `--set-hash-seed` is absent (children inherit it; reproducibility
matches today's behaviour), and harmless when `--set-hash-seed=X` is
present (the harness overrides it inside the test child's env). The
only risk is users who currently rely on the wrapper's automatic seed
without realizing — once step 2 ships, they will need to add
`--set-hash-seed` to their invocation to keep the same behaviour.

## Decisions and alternatives

- **Auto type with autofill, not Bool + Scalar.** The natural shape of
  this option — "default to today, but accept a value" — is exactly
  what `Auto` is for. A Bool toggle plus a separate
  `--hash-seed=VALUE` would split the same intent across two flags.
- **Default format is `YYYYMMDD`, not Unix epoch or random.** This
  matches the App-Yath-Script wrapper bit-for-bit. Anyone relying on
  the wrapper's seed for "all of today's runs share a hash order" gets
  the same value once they add `--set-hash-seed`. A random default
  would break that property without giving anything back.
- **No `set_env_vars` on the option.** The option is purely a request;
  the harness does the actual env injection right before `exec`. We
  intentionally do not pollute the harness or yath parent's
  environment, only the test children.
- **Mismatch is rejected, not silently overridden.** Per the AUDITS
  source ("A run queue attempt should be rejected if the run and the
  queue disagree…"), the daemon's preload commitment is binding. We
  could have downgraded to a warning, but a silent change to the hash
  seed of preloaded perl processes is a recipe for non-reproducible
  weird-bug bisects later.
- **Unset/set asymmetry is provisionally accepted.** With no
  `Test2::Harness2::Resource::Preload` yet, there is nothing to be
  bound to. Tightening this once the resource lands is captured as a
  TODO in `request_handler_queue_test_run`.

## File map

- `lib/App/Yath2/Options/Tests.pm` — new `set_hash_seed` option +
  `today_yyyymmdd()` helper (also exported for tests).
- `lib/Test2/Harness2/Run.pm` — new `hash_seed` HashBase slot.
- `lib/Test2/Harness2.pm` — new `hash_seed` HashBase slot;
  `request_handler_queue_test_run` forwards `hash_seed` to
  `Run->from_files` and rejects mismatches; `_launch_job` injects
  `PERL_HASH_SEED` into the per-job env from the run's seed.
- `lib/App/Yath2/Command/test.pm` — passes the option through to
  `queue_test_run`.
- `lib/App/Yath2/Command/start.pm`, `lib/App/Yath2/Command/run.pm` —
  Phase 7.2 TODO comments describing the global-preload wiring once
  those commands return.
- `t/AI/unit/Yath2/Options/HashSeed.t` — option-level coverage
  (absent, autofill, explicit value, helper).
- `t/AI/unit/Harness2/HashSeed.t` — harness-level coverage (forward,
  accept, reject-on-mismatch in all four shape combinations).
- `t/AI/unit/Harness2/Run.t` — added a `hash_seed` slot subtest.
