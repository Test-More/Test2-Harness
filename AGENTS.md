# AGENTS.md

## MANDATORY: read the universal agent rules first

This project opts into shared agent guidance while keeping its own documents
authoritative for project-specific rules and design.

- Repository: `git@github.com:exodist/Agents.git`
- Expected location: `~/projects/Agents`

If `~/projects/Agents` does not exist, clone it before doing anything else:

    git clone git@github.com:exodist/Agents.git ~/projects/Agents

Then read `~/projects/Agents/AGENTS.md` and follow the shared guidance this
project has adopted. It points at task-specific guides and procedures.

All documents in THIS repository take priority over the shared repository.
Read the project documents named below; `AGENTS_OVERRIDE.md` records
declarations and explicit shared-rule overrides when present.

---

## What this project is

`yath` version 1 — the Test2 test harness: a runner, a set of `yath`
commands, event collection and rendering, and the `Test2::Harness::*`
libraries behind them.

CPAN distribution name: `Test2-Harness`

This is the maintenance line. Version 2 of the harness is a separate rewrite
in the `Test2-Harness2` distribution; this repository takes bug fixes and
compatibility work, not new architecture.

---

## Canonical sources of truth

1. **`AGENTS_OVERRIDE.md`** — this project's declarations and overrides.
2. **This file** — project context and conventions.

There is no `ARCHITECTURE.md`. The shipped POD and the code are the
specification.

---

## Testing

The suite is large, forks heavily, and starts real `yath` runs. Take the
shared concurrency lock for anything above `-j4`:

```
~/projects/Agents/bin/agent-test-lock -- prove --timer -Ilib -j16 -r t/
```

- `t/` is the main suite. `t2/` is a second suite that exercises the harness
  against its own bundled test libraries and needs `-It2/lib`:

  ```
  ~/projects/Agents/bin/agent-test-lock -- prove --timer -Ilib -It2/lib -j16 -r t2/
  ```

- `.yath.rc` is what a bare `yath test` in this repository uses:
  `-It2/lib` plus `--default-search glob(t/*)`. It does not cover `t2/`.
- `xt/author/pod-spell.t` requires `Test::Spelling` and is not wired into
  `dist.ini`; run it by hand when POD changes.
- `t/integration/` drives full harness runs and is the slow part of the
  suite. Individual files there can take minutes.
- Crashed runs leave debris in `/tmp`; `~/projects/Agents/bin/sweep-test-debris`
  clears it.

---

## Related repositories

- **`Test-Simple`** (`~/projects/Test-More/test-more`) — this distribution
  pins `Test2`, `Test::Builder`, and `Test::More` at `1.302170`. A change
  that depends on newer Test2 behavior needs that floor raised here.
- **`App-Yath-Script`** (`~/projects/Test-More/App-Yath-Script`) — supplies
  the shared `yath` executable; required at `App::Yath::Script` 2.000011 so
  both harness generations can dispatch through one script. Anything touching
  script detection, the `yath` entry point, or the `App::Yath::Script::V#`
  handshake must be checked against it.
- **`Test2-Harness2`** (`~/projects/Test-More/Test2-Harness2`) — the version 2
  rewrite. It is a separate distribution; changes do not propagate either way,
  but a behavior decision made there is the one to match when both must agree.

---

## CPAN Testers

Distribution name for report queries: `Test2-Harness`. The query procedure is
`~/projects/Agents/CPAN_TESTERS.md`.

---

## Architecture quick-reference

- Objects use the **in-tree** `Test2::Harness::Util::HashBase`, not
  `Object::HashBase`. It is a bundled copy so the harness has no external
  object dependency; do not swap it for the CPAN module.
- `use parent` for inheritance.
- `App::Yath::Command::*` is one class per `yath` subcommand;
  `App::Yath::Plugin::*` is the plugin surface. Both are public API — CPAN
  distributions subclass them.
- The harness must keep working on perl 5.10 and on systems where the only
  requirement is real `fork`. `Makefile.PL` refuses to build without it.
