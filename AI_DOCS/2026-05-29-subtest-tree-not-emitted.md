# Known defect: nested subtest verdict tree is computed but not emitted

**Status:** FLAGGED, deferred. Fix soon.
**Discovered:** 2026-05-29 during a fat/dead-code audit of `lib`.
**Module:** `lib/Test2/Harness2/Collector/Auditor.pm`

## Summary

The auditor recursively audits nested subtests and builds a per-subtest
verdict tree, then throws most of it away. Three attributes are written but
never read, and the one summary that *is* emitted
(`final_state.subtests`) is a flat, top-level-only list — it loses the nested
structure that the legacy implementations preserved and surfaced.

This is not a verdict-correctness bug (pass/fail is decided correctly; see
below). It is a **result-recording** bug: the structured nested-subtest
result a renderer would need is discarded.

## What is correct (do not "fix" this)

Pass/fail derivation matches `reference/legacy`
(`lib/Test2/Harness/Auditor/Watcher.pm`) and `reference/old2`
(`lib/Test2/Harness2/Collector/Auditor/Job.pm`) line-for-line:

- Each buffered subtest is re-audited by a fresh sub-auditor
  (`Auditor.pm:591`, `blessed($self)->new(nested => ...)`).
- A child *structural* failure (plan mismatch, assertion-number gap,
  incomplete/abruptly-ended subtest, nested sub-failure) forces the parent to
  fail regardless of the parent assert's own `pass` flag (the `@errors` path,
  `Auditor.pm:604-608`). A buggy/malicious producer cannot hide a structural
  failure.
- A *direct* failing child assertion is carried by the parent assert's own
  `pass=0` flag (the fallback branch). All three implementations — legacy,
  old2, and current — deliberately rely on the producer here:
  `subtest_fail_error_facet_list` omits `_FAILURES` on purpose, because real
  Test2 always stamps the parent assert `pass=0` when a child fails. This is
  intended behavior, not a regression.

## What is the bug

`reference/legacy` and `reference/old2` build `FAILED_SUBTEST_TREE` (a
recursive `[name, [children...]]` structure) **and emit it** in the final
result (legacy `Auditor.pm:100` ships `failed_subtest_tree`). A renderer can
therefore show exactly which nested subtest (and sub-subtest) failed.

The current auditor:

- Builds the same `FAILED_SUBTEST_TREE` (`Auditor.pm:617`) but **never reads
  it** — it is write-only, absent from `final_state()`.
- Adds `PASSING_SUBTESTS` (`621`) and `FAILING_SUBTESTS` (`618`) — both new
  (neither reference had them) and both **write-only**.
- Emits `final_state.subtests` (`264`) from `TOP_LEVEL_SUBTESTS`, but that
  list is **flat and gated to `NESTED == 0`** (`624-629`): name, pass,
  count_pass, count_fail for top-level subtests only. Nesting is lost.

Net: the nested failure structure is computed every run and discarded. The
raw buffered subtest *events* still reach `events.jsonl.zst`, so the data is
not entirely gone from disk, but the auditor's per-nested-subtest verdict
summary — which legacy surfaced — is not recorded in the verdict.

## Fix direction (when undeferred)

Mimic legacy/old2: emit the nested verdict tree into the recorded result.
Concretely, one of:

- Recurse `TOP_LEVEL_SUBTESTS` (drop the `NESTED == 0` gate, or build a
  nested child list per sub-auditor) so `final_state.subtests` carries the
  full tree with per-node pass/fail and counts; and/or
- Emit `FAILED_SUBTEST_TREE` in `final_state` as legacy did.

Then delete whichever of `FAILED_SUBTEST_TREE` / `PASSING_SUBTESTS` /
`FAILING_SUBTESTS` does not feed the emitted output. The goal is one live,
nested, recorded result instead of three dead structures.

## Test coverage gap to close at the same time

Current tests (`t/AI/unit/Collector/Auditor.t`) cover a failing buffered
subtest only where the test input already sets the parent assert `pass=0`
(`buffered_subtest_fail`), and assert only the flat top-level summary. Add:

- A nested-failure case asserting the emitted result preserves which nested
  subtest failed (the tree).
- A subtest with an internal plan mismatch / assertion-number gap whose
  parent assert is `pass=1`, asserting the auditor independently fails it
  (exercises `subtest_fail_error_facet_list` via the `@errors` path) — this
  is the "do not trust the producer for structural failures" guarantee, and
  it is currently unexercised.
