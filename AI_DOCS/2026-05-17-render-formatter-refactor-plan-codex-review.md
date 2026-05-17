# Codex Re-Review: Render / Formatter / Concluder Refactor Plan

**Date:** 2026-05-17
**Reviewed document:** `AI_DOCS/2026-05-17-render-formatter-refactor-plan.md`
**Status:** Second-pass review after the plan was updated from prior feedback.

## Summary

The updated plan is materially better. The earlier major blockers are mostly
addressed:

* Live verbose rendering now has per-artifact monitors.
* `tty` is explicitly setting-bearing and non-persisted.
* Compressed formatter artifacts now have visible `.zst` suffixes.
* Renderer criticality now covers JUnit / CI-style output.
* Producer lifecycle/index API is called out as a required planning deliverable.

The remaining issues are mostly consistency and precision. The architecture is
close enough to hand to a planning agent once the contradictions below are
cleaned up.

## Remaining Findings

### 1. Formatter artifacts are not necessarily "what was shown"

The plan says persisted formatter output is setting-free: no theme baking, no
width wrapping, no verbosity filtering. That is the right boundary.

Later, it says formatter artifacts are "a record of what was shown to the user
when the run was originally captured." That is not generally true anymore.

Examples:

* `tty` output is not persisted.
* Quiet / QVF / verbose policy is renderer behavior, not formatter output.
* Terminal theme, color mode, and width are renderer behavior.

Recommended edit:

Replace the "what was shown" wording with something like:

> Formatter artifacts are durable records of canonical formatted artifact
> output produced at capture time. They are not necessarily a full transcript
> of what a renderer showed to a user.

If an exact user-visible terminal transcript is desired later, that should be a
separate artifact type, not the setting-free formatter artifact.

### 2. Watcher/lifecycle wording is contradictory

The implementation notes correctly say:

> `FileMonitor` on LIVE is the wake-up primitive, not the lifecycle
> abstraction.

But the "Open items that became non-issues" section still says the
watcher/lifecycle layer API collapsed to "`FileMonitor` on LIVE."

Those statements conflict. The second statement should be removed or rewritten.

Recommended edit:

> Watcher wake-up API collapsed to `FileMonitor` on LIVE plus optional
> artifact-level monitors. Producer lifecycle did not collapse; it is handled by
> the required producer-index/lifecycle API on the Log abstraction.

### 3. Renderer crash tests are stale

The plan now defines renderer criticality:

* `best_effort` renderer failures warn and do not affect exit code.
* `required` renderer failures affect exit code.

But the test list still says renderer crash surfaces in final output and
"doesn't fail the run."

Recommended edit:

Replace that single test bullet with:

* Best-effort renderer crash surfaces in final output and does not fail the
  run.
* Required renderer crash surfaces in final output and affects the command
  exit status.

JUnit or another explicit file-producing renderer should be used for the
required-path test.

### 4. Concurrent formatter artifact write policy conflicts

The formatter artifact section says both:

* Existing file wins concurrent races.
* Last-writer-wins is fine.

Those are different policies.

Recommended decision:

Use existing-file-wins.

Reasoning:

* It avoids replacing a complete artifact after another renderer has already
  published it.
* It maps naturally to temp-file + exclusive publish behavior.
* It avoids unnecessary inode churn for deterministic output.

The implementation should make the publish step explicit. If Perl's plain
`rename` would overwrite on the target platform, the helper needs a guard:
check target absence under an appropriate lock, or use a platform-appropriate
exclusive create/link/rename pattern.

### 5. `--reformat` needs read-only behavior specified

The plan says `--reformat` on `yath render` rewrites formatter artifacts in
place. It also says tarball logs are read-only.

Recommended edit:

Specify one behavior for read-only logs:

* `yath render --reformat LOG` on read-only logs regenerates current formatted
  output in memory only and does not write artifacts, or
* it errors clearly and tells users to run `yath reformat LOG OUTLOG`.

The second behavior is clearer for an explicit "rewrite artifacts" flag. The
first is friendlier for one-off render use. Either is acceptable if documented.

Also specify `yath reformat LOG OUTLOG` as the supported path for tarball logs
or other read-only backends.

### 6. Atomic write durability should be scoped

The plan says formatter artifacts are written with temp file + `fsync` +
rename. That guarantees non-partial publication if implemented correctly, but
full crash durability usually also requires syncing the containing directory
after rename on filesystems that support it.

Recommended edit:

Either state the helper's guarantee narrowly:

> `write_artifact_atomic` guarantees readers never observe partial formatter
> artifacts. It does not promise full power-loss durability on every
> filesystem.

Or require directory fsync after rename where supported.

For this feature, the narrow guarantee is probably sufficient.

## Resolved From Prior Review

These prior concerns are now adequately addressed:

* Live tailing: artifact-level `FileMonitor` instances solve the sparse LIVE
  wake-up problem.
* `tty` persistence: `tty` is setting-bearing and does not produce a persisted
  formatter artifact.
* Compression: visible `.zst` suffixes avoid misleading filenames.
* Required renderer output: criticality handles JUnit / structured-output
  failures.
* CLI serialization tests and flat option-prefix ownership are now carried
  forward as implementation notes.
* Producer-index/lifecycle API is explicitly required as part of the first
  planning deliverable.

## Bottom Line

The plan is close. Fix the contradictory wording and stale test expectations
before using it as the basis for implementation. The remaining concerns do not
require a new architecture; they require tightening the written contract so the
next agent does not implement the wrong behavior.
