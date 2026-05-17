# Gemini's Analysis of Render/Formatter Refactor

This document contains a technical analysis and set of recommendations based on the `render_formatter_refactor` proposal. It is intended to serve as context and guidance for planning the architectural implementation.

## 1. Architectural Model Shift

The shift from an event-driven push model (via a central Driver) to an autonomous, pull-based model is highly endorsed.
*   **Decoupling:** Allowing renderers to query the log directory/DB directly removes complex synchronization logic from the parent process.
*   **Resiliency:** Renderers become self-sufficient state machines. If a renderer crashes, it does not necessarily crash the entire harness run.
*   **Re-rendering:** This architecture makes "live" rendering and "post-run" rendering identical from the renderer's perspective, vastly simplifying log replay.

## 2. The "Third Category" (Summary/Notify/ResetTerm)

The proposal asks for a name for components that only act at the end of a run or produce final outputs without processing every event.

**Recommendation:** Name this category **Concluders** (e.g., `App::Yath2::Concluder::*`).
*   *Alternative:* **Finalizers** (though this can conflict with language-level object destruction semantics).
*   *Alternative:* **Reporters** (fits Summary/Notify, but less so ResetTerm).

"Concluders" accurately describes their role in the run lifecycle: they wrap up the process once the test execution phase has concluded.

## 3. Renderer / Formatter Separation

The distinction is clear and highly beneficial:
*   **Renderer:** The controller/process that iterates producers and orchestrates output.
*   **Formatter:** The stateless (or isolated) transformer that converts artifacts (e.g., JSONL -> text/HTML).

**Caching Strategy:**
The proposal to cache formatted artifacts (like `.html` or `.txt` generated from `.jsonl`) back into the log directory/DB is a major performance win, especially for the future Web Server UI. 
*   *Recommendation:* Establish a strict naming convention for cached artifacts (e.g., `<artifact_name>.<formatter_ext>`).
*   *Recommendation:* Ensure the caching mechanism only engages on completed artifacts to avoid corrupting the cache with partial JSONL data.

## 4. Lifecycle & Concurrency Considerations

**Child Process Initialization:**
Because renderers run in a `fork+exec` (or `system(1)` on Windows) child process, the parent must serialize all configuration.
*   *Recommendation:* Use a lightweight JSON config file passed via command line to the child renderer process. This avoids shell escaping issues and handles complex configurations easily.

**IPC for `finish()`:**
The parent needs to signal the child when the live run is complete.
*   *Recommendation:* Use a simple signaling mechanism (e.g., a specific file appearing in the log dir, or an IPC pipe). The child should cleanly finish its current loop, process remaining artifacts, and exit.

**Polling Contention:**
Multiple renderers polling the same live log directory could cause excessive disk I/O.
*   *Recommendation:* Ensure the `App::Yath2::Log` abstraction caches directory listings or uses a fast-path for "new producers" to minimize system calls across multiple renderers.

## 5. Specific Component Migration

*   **JUnit:** Agree with the proposal to keep JUnit self-contained rather than forcing it into the Formatter pattern. JUnit XML is generally a monolithic document per run/suite, which doesn't align well with the piecemeal, artifact-by-artifact caching designed for Formatters.
*   **Default Renderer:** This should become a thin Dispatcher that instantiates the correct Formatter (`tty` or `text`) based on `-t STDOUT` and environmental variables.

## 6. Open Questions for the Implementation Plan

When drafting the implementation plan, please address:
1.  **Polling Mechanism:** Will the base Renderer class use a generic sleep/poll interval (e.g., 0.1s), or attempt OS-specific hooks (like `inotify`) for live log watching?
2.  **Formatter Interface:** Define the exact contract for a Formatter. (e.g., `convert($input_fh, $output_fh)` or does it return a string?).
3.  **Renderer Discovery:** How do Formatters get discovered and loaded by the Renderers?
