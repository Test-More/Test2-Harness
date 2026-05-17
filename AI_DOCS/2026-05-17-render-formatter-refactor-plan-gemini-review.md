# Gemini's Review: Render / Formatter / Concluder Refactor Plan

This document provides a formal evaluation of `AI_DOCS/2026-05-17-render-formatter-refactor-plan.md`.

## 1. Executive Summary

The proposed design is a significant architectural advancement for `yath2`. By moving from a push-based event stream to an autonomous, pull-based model, the system gains substantial reliability, simpler logic for replaying logs, and a much cleaner separation of concerns.

The plan successfully addresses the "Lifecycle Synthesis" problem—the most brittle part of the current `Driver`—by allowing renderers to query the `Log` abstraction directly for producer state.

## 2. Key Strengths

### 2.1. CLI as the Serialization Wire Format
Using `yath render NAME [opts]` as the bridge between parent and child is an elegant solution.
*   **Debuggability:** Being able to see the exact state of a renderer by looking at `ps` output is invaluable for field debugging.
*   **Portability:** It side-steps the quoting and length limits of Windows shell execution by using the established `Getopt::Yath` patterns.

### 2.2. The "Concluder" Category
The decision to run **Concluders** sequentially in the parent process *after* reaping all renderer children is the correct approach to terminal management. This eliminates race conditions where `ResetTerm` or `Summary` might interleave with a renderer's final output buffer.

### 2.3. The LIVE Sentinel Wake-up
Using the `LIVE` file purely as a wake-up signal (via `FileMonitor`) rather than an event source is a major simplification.
*   **Unified Code Paths:** This ensures that "Live" rendering and "Sealed" rendering use the exact same scanning logic, with the only difference being whether the renderer waits for a file change at the end of a pass.
*   **Efficiency:** Appending a few bytes to a file is significantly cheaper than the current IPC overhead of pushing thousands of JSON events across process boundaries.

### 2.4. Cache Strategy (Setting-Free Formatters)
The "Pure Conversion" contract for formatters ensures the cache is durable. By moving theme-baking and width-wrapping to the Renderer layer, the cached artifacts (HTML, Text, etc.) remain valid regardless of environmental changes.

## 3. Technical Recommendations for Implementation

### 3.1. Option Namespace Collisions
With "flat namespacing" (e.g., `--junit-out`), there is a risk of collision if multiple renderers use common names. 
*   **Recommendation:** Establish a "core" set of shared options (like `--out`, `--verbose`) and require renderers to prefix their specific options (e.g., `--junit-xml-version`) if they diverge from the standard.

### 3.2. Atomic Cache Writes
The "last-writer-wins" strategy for sibling-file caching is acceptable, but it must be truly atomic.
*   **Recommendation:** The `Renderer` base role should provide a `write_artifact_atomic($name, $content, $suffix)` helper that handles the `tempfile` + `rename` dance to ensure no partial artifacts are ever visible to other processes.

### 3.3. Log Iterator Performance
The `Log->jobs`, `Log->runs`, etc., iterators are the foundation of this design.
*   **Recommendation:** For `DB` and `TarZIdx` backends, ensure these iterators use "bulk-fetch" or "windowed" queries to avoid N+1 overhead when a renderer is scanning for new producers.

### 3.4. Three-Layer Shutdown
The shutdown logic is robust, but the order of checks in the renderer loop matters.
*   **Recommendation:** The renderer should check "Parent PID alive" first, then "LIVE sentinel exists," then "IPC signal." This ensures that a crashed parent (orphaned child) is detected even if the `LIVE` file wasn't cleaned up.

## 4. Final Verdict

**Approved for Implementation.** 

The staging plan (Stages 1–10) is logical and prioritizes the foundational Log/Collector changes. The separation of `yath render` as a first-class command will also improve the developer experience for those needing to re-format logs manually.

---
*Reviewed by Gemini CLI on 2026-05-17.*
