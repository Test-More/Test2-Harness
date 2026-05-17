# Test2::Harness2 refactor — open questions for Chad

Plan lives at `AI_DOCS/2026-05-16-harness2-subsystem-extraction-plan.md`. The
questions below are the decisions baked into that plan that I want your sign-off
on (or pushback) before any code moves.

Reply inline under each `**Your answer:**` heading. Anything left blank, I'll
proceed with my pick.

---

## Q1. Who owns `RUN_STATES` + `RUN_FLAGS` + `COMPLETED_RUNS`?

**Context.** These three slots track per-run state: which jobs are queued,
which are running, which finished, and the per-run flag bits (e.g.
`completed_job_ids`, `aborted`). Today, the scheduler is the only writer; the
broadcaster, run-results request handler, status request handler, and a few
job-lifecycle handlers read them.

**Options.**

- **A. Scheduler owns them.** All writes go through scheduler methods; every
  reader calls `$h->scheduler->run_states->{$run_id}` (or a narrower
  accessor). Codex's recommendation; my current pick.
- **B. Harness keeps them; Scheduler reads via accessor and writes via
  `$h->_mutate_run_state(...)`.** Lower coupling between Scheduler and
  run-state shape, but two writers (Scheduler + job-lifecycle handlers on
  Harness) and the harness still carries the slots.
- **C. Separate `Test2::Harness2::RunRegistry`.** Cleanest separation of
  concerns but adds a sixth module and means Scheduler does not "see" its
  own queue's state without indirection.

**My pick:** A. Co-locate the state with its only writer. Readers go through
narrow accessors that become trivial passthroughs.

**Cost if wrong:** rework all five extractions' cross-domain calls. High.

**Your answer:**

Make a run states module, both the scheduler and the main harness have a reference to it so the harness does not need to go through the scheduler to read state, nor does anything else that wants to look at the state (anything can get a reference to the object).

---

## Q2. Do we extract a sixth module for job lifecycle (RUNNING_JOBS + test_job_* handlers)?

**Context.** After the five planned extractions, the residual harness still
carries `RUNNING_JOBS` (18 references), `PENDING_SYNTH_COMPLETIONS` (3), and
the full test_job_* + collector_* + job_release lifecycle (~12 methods,
~500 lines). It's the single biggest chunk left.

**Options.**

- **A. Defer.** Land the five extractions, then look at the residual surface.
  If it's small enough to live on the harness without dominating the file,
  do nothing. If it justifies a sixth module, plan it then. My current pick.
- **B. Commit now to a sixth extraction (`JobTracker` or `RunLifecycle`).**
  Means the refactor plan ends at six modules, not five. Bigger up-front
  scope but a cleaner end-state.
- **C. Roll job lifecycle into the Scheduler.** Cheap by line count; very
  bad by separation-of-concerns (Scheduler becomes a god object again).

**My pick:** A. The five planned extractions reduce the harness to ~1,200
lines. That's a major win on its own. Decide on a sixth only after seeing
what's left.

**Cost if wrong:** if we defer and later regret it, one more extraction
commit. Low.

**Your answer:**

B, see my notes for the last question as well, similar idea, multiple things can reference the same object if needed.

I want things broken up into smaller easier to understand modules.

---

## Q3. Module names — lock in now

**Context.** Naming is bikeshed but rename-late is expensive (test paths,
commit history, POD cross-refs all break). The three reports used different
names for the same concept.

**Options (per module).**

- Scheduler: only candidate.
- Pid map: `PidIndex` (Codex + Claude) vs `PidTracker` (alternative).
- yath spawn pathway: `SpawnGateway` (Codex + Claude) vs `SpawnRouter`.
- State fanout: `StateBroadcaster` (Codex + Claude) vs `Notifier` (Gemini).
- Preload routing: `PreloadRouter` (Codex + Claude) vs `PreloadManager`
  (Gemini, conflicts with the existing `Test2::Harness2::PreloadService`
  vibe; legacy used "Manager" too).

**My picks:**

| Concept | Name |
|---|---|
| Pid map | `Test2::Harness2::PidIndex` |
| `yath spawn` pathway | `Test2::Harness2::SpawnGateway` |
| State fanout to subscribers | `Test2::Harness2::StateBroadcaster` |
| Job/run scheduling | `Test2::Harness2::Scheduler` |
| Preload routing + watchdog | `Test2::Harness2::PreloadRouter` |

**Your answer:**

These are fine.

---

## Q4. `request_handler_*` shims — keep, or change `Role::Service`?

**Context.** `Role::Service` (from `IPC::Manager`) dispatches incoming IPC
requests by method name on the service object. So a request handler MUST be
a method on the harness, not on a subsystem.

**Options.**

- **A. Thin shims on harness.** Each subsystem-owned request becomes a
  2-line wrapper:
  ```perl
  sub request_handler_subscribe {
      my $self = shift;
      return $self->broadcaster->subscribe(@_);
  }
  ```
  Five shims today. My current pick. Local change.
- **B. Teach `Role::Service` to accept a dispatch table.** Subsystems would
  register `subscribe => sub { ... }`. Cleaner but touches `IPC::Manager`,
  which is out of scope for this refactor.

**My pick:** A. Don't touch `Role::Service` as part of this work.

**Cost if wrong:** five shims is trivial; can change later.

**Your answer:**

A

---

## Q5. `_handle_resource_state_message` — where does it live?

**Context.** Currently on Harness2. Handles resource state-change IPC
messages (resource becomes available/broken/paused/resumed). Reads/mutates
resource service state.

**Options.**

- **A. Stays on harness.** No move. My current pick.
- **B. Moves into PreloadRouter.** Since most resource state changes affect
  preload availability.
- **C. Future `ResourceMonitor` module.** Out of scope for this refactor.

**My pick:** A. Don't move it now. Revisit only if a separate
`ResourceMonitor` extraction lands.

**Your answer:**

A, add a followup when we are done to re-evaluate

---

## Q6. `PidIndex` scope — RUN_PIDS only, or also RESOURCE_SERVICES?

**Context.** `Role::ResourceServiceHost` (which the harness consumes) expects
a `resource_services` accessor on the host. Moving the slot into PidIndex
requires either shimming the role's accessor or moving the role's logic too.

**Options.**

- **A. Only RUN_PIDS moves.** RESOURCE_SERVICES stays on the harness; the
  role keeps its existing contract. My current pick. Minimal disruption.
- **B. Both move.** PidIndex becomes the canonical "what processes do we
  own". Requires a passthrough accessor on the harness so
  `Role::ResourceServiceHost` still works:
  ```perl
  sub resource_services { $_[0]->pid_index->resource_services }
  ```

**My pick:** A. Defer the role coupling question. Revisit if/when the role
is refactored.

**Your answer:**

A

---

## Q7. `harness => $self` backref pattern — uniform across all subsystems?

**Context.** Some subsystems (`PidIndex`, `StateBroadcaster`) don't strictly
need the harness backref for their core logic. They could be constructed
without it. Others (`Scheduler`, `PreloadRouter`, `SpawnGateway`) absolutely
need it for launch glue.

**Options.**

- **A. Uniform pattern: every subsystem takes `harness => $self`, always
  weakened in `init`.** Even if some don't use it today. Costs one slot
  per module; gains uniformity, easier to understand cross-cutting
  patterns later. My current pick.
- **B. Pass only when needed.** PidIndex and StateBroadcaster constructed
  without it; Scheduler / PreloadRouter / SpawnGateway take it.

**My pick:** A. Uniformity beats minor footprint savings.

**Your answer:**

A, in fact create a Harness2 subsystem role (suggest names) and each subsystem should consume it, it handles the attribute, weakening (if possible), etc.

---

## Q8. Execution order — confirm

**My pick:**
1. PidIndex
2. SpawnGateway
3. StateBroadcaster
4. Scheduler
5. PreloadRouter

**Rationale:** small/safe first, biggest cross-cutting (PreloadRouter) last
so it can call into the Scheduler's accessors from day one. Tag each step;
green-tests gate.

**Alternative:** Scheduler first to get the biggest payoff up front, accept
that PreloadRouter rewrites its scheduler-touching code once when Scheduler
arrives.

**Your answer:**

Whatever you think is best.

---

## Q9. Anything else you want to add to the plan before I start?

E.g.: a slot I missed, an invariant I should know about, a coding-style
preference, a "don't touch this" warning, etc.

**Your answer:**

See previous answers

