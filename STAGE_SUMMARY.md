# Stage 2 — Move AI-generated tests under `t/AI/`

## Branch

- `plan-stage-02-ai-tests`

## What landed

- Every existing test file under `t/integration/` and `t/unit/` moved under
  `t/AI/integration/` and `t/AI/unit/` via `git mv` (rename, 100% similarity
  preserved).
- `t/lib/` (test-support library, not itself a test) stayed put.

## Commit

1. `Move existing AI-generated tests under t/AI/`

## Tests

- `prove -I lib -I t/lib -r t/AI/unit` — all pass.
- `prove -I lib -I t/lib -r t/AI/integration` — all pass.
- The existing `use lib 't/lib'` lines in the moved tests still resolve
  correctly because `yath`/`prove` runs them from the repo root.

## Points of interest / decisions you may want to revisit

1. **`t/lib/Test2/Harness2/TestFile.pm` stays at `t/lib/`.** It is a Perl
   test-support module, not a test file itself, so the `t/AI/` rule does
   not strictly apply. If you want test-support modules split by authorship
   too, move it to `t/AI/lib/` and update `use lib 't/lib'` call sites.

2. **`.gitignore` line referencing `t/integration/test-broken-symlinks/...`**
   references the old test path. It was stale already (no such path exists
   in this tree) and remains untouched; if the acceptance-test port in a
   later stage brings `test-broken-symlinks` into `t/`, that line may need
   updating to `t/integration/...` or `t/AI/integration/...` depending
   on authorship.

3. **Authorship rule placement.** The `t/AI/` rule is carried by
   `ARCHITECTURE.md` (authorship layout section) and by `CLAUDE.md`
   under **Testing**, both of which are tracked files in this tree.
