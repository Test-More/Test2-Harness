# Pending decisions — answer inline below each question

Three questions blocking the next subagent dispatch. Write your answer inline
under the **ANSWER:** marker for each.

---

## Q3b — TestFile HashBase shadowing pattern

**Context.** Phase 3 splits TestFile into:
1. `Test2::Harness2::Role::TestFile` — contract (defaults, predicates, `TO_JSON`, `rehydrate`).
2. `Test2::Harness2::TestFile` — static consumer (set values for every required field).
3. `App::Yath2::TestFile` — scanner that reads shebangs/headers and produces the static form.

**The shadowing problem (current code, see `lib/Test2/Harness2/TestFile.pm:22` + `lib/Test2/Harness2/Role/TestFile.pm:49-50`).**

Current `Test2::Harness2::TestFile` declares HashBase slots:

```perl
package Test2::Harness2::TestFile;
use Object::HashBase qw{ <min_slots <max_slots <duration <category ... };
```

HashBase installs reader methods (`min_slots`, `max_slots`, etc.) directly into the class symbol table.

Current `Role::TestFile` also defines reader methods:

```perl
package Test2::Harness2::Role::TestFile;
sub min_slots { $_[0]->defaults->{min_slots} }   # default 1
sub max_slots { $_[0]->defaults->{max_slots} }   # default undef
sub duration  { $_[0]->defaults->{duration}  }   # default 'medium'
```

When `$tf->min_slots` is called on a `Test2::Harness2::TestFile` instance, **the HashBase reader runs** (slots are looked up in class first; Role only fills holes). Role's `min_slots` is never reached from the Class. The Role's accessor is **dead code in the Class**.

`init()` reconciles by seeding the slot from `defaults`:

```perl
sub init {
    my $self = shift;
    my $d = $self->defaults;
    $self->{+MIN_SLOTS}  //= $d->{min_slots};
    $self->{+MAX_SLOTS}  //= $d->{max_slots};
    $self->{+DURATION}   //= $d->{duration};
    ...
}
```

So defaults flow Class HashBase slot ← `init()` ← `Role->defaults`, never via Role's per-attribute accessors. That works but is confusing: the Role *looks* like it serves defaults via accessors, but it actually only serves them via the `defaults()` hash that `init()` reads.

**The two consistent options:**

### Option (a) — Keep current pattern (HashBase + seed-from-defaults)

- Class declares HashBase slot for every attribute.
- `init()` seeds slot from `Role->defaults` when not provided.
- Role's per-attribute accessors stay (as documentation / contract spec) but are dead code in the Class.

Pros:
- Fast attribute access (slot lookup, no sub call).
- Single data shape — every attribute is in `$self`'s hash.
- `TO_JSON` / `rehydrate` are trivially "dump/load HashBase slots".
- New scanner (`App::Yath2::TestFile`) can write straight to slots before serializing.

Cons:
- Role's per-attribute readers are dead code; misleading to future readers.
- Two-step contract: Role declares default, init reads it, slot stores it.

### Option (b) — Drop overlapping HashBase slots; Role accessors serve defaults

- Class only declares HashBase slots for attributes that the scanner *sets* (file, absolute path, scanned shebang/headers, mutated overrides).
- For attributes that have a default and are not always set (`min_slots` if never overridden, `category` if never overridden, etc.), no HashBase slot — Role's accessor returns `defaults->{name}`.
- Concrete: `min_slots` with no override = call `min_slots()` method → returns `defaults->{min_slots}` → returns 1.
- Scanner sets the slot only when overriding the default: `$tf->set_min_slots($n)` writes the slot; Role accessor short-circuits to slot if present.

Pros:
- Single source of truth for defaults: Role's `defaults()`.
- No dead code; accessors are real.
- Cleaner semantic split: "do I have a value of my own?" = "is the slot present?"

Cons:
- Mixed-pattern class (some attrs have HashBase slots, others don't).
- Slower reads on default attrs (sub call vs slot access).
- `TO_JSON` needs to walk Role's `json_fields()` calling accessors, not iterate HashBase slots — a bit more work.
- Role accessors need a "slot if set, default otherwise" implementation pattern, e.g. `sub min_slots { exists $_[0]->{+MIN_SLOTS} ? $_[0]->{+MIN_SLOTS} : $_[0]->defaults->{min_slots} }`. That works but every accessor needs the same boilerplate, or a helper that generates them.

**ANSWER:**

Options A, but add comments/pod to the role indicating that most classes will override the default making them unused in most cases.


---

## Q4a (identity) — harness/collector identity fields in Run vs Run::State

**Context.** Phase 4.1 splits `Test2::Harness2::Run` into:
- `Run` (Spec) — immutable; what's needed to queue + add tests + pass to `$harness->queue`.
- `Run::State` — runtime state (start/end times, counters, sync payload).

**The fields in question.** The current `Run` (and surrounding code) carries identifiers that locate "who runs what":

- **harness_uuid** — the harness instance that owns the run.
- **collector_uuid** — the collector that produced the events log.
- **bus / IPC address** — the IPC bus / unix-socket path the run reports to.
- **session run UUID** — sometimes there's a per-session UUID separate from the per-run UUID.

**Why ambiguous.**

- At queue time, the user/Yath knows which harness they queued the run *to*. That's a Spec property — frozen at submission.
- At run time, the harness that *actually executes* may differ — daemon-mode re-route, harness restart with a new UUID, work stolen by another harness, etc. That's a State property — only known after dispatch.
- Same for collector: the collector that ends up writing the log may not be predictable at queue time (depends on which harness handles the run, which collector that harness spins up, etc.).
- Bus/IPC address is harness-derived — same ambiguity.

**The three options:**

### Option (a) — All identity fields are State

- Spec carries no identity beyond `run_id`.
- State holds `harness_uuid`, `collector_uuid`, `bus_address`, etc., populated when the harness picks up the run.
- Simpler boundary. Anything identity-shaped lives in State.

Trade-off: lose the "this run was queued to harness X" record on the Spec side. If you queue to a specific harness and the daemon re-routes, no audit trail of original target.

### Option (b) — Split queue-time vs runtime identities

- Spec has `requested_harness_uuid` (or `target_harness_uuid`), nullable.
- State has `running_harness_uuid`, `collector_uuid`, `bus_address`.
- Two fields per identity type — one frozen at submission, one populated at execute.

Trade-off: more fields, clearer audit trail. "Queued to X, actually ran on Y" is recoverable.

### Option (c) — Subagent decides per field, reports

- Subagent reads code, picks placement per field, justifies in commit.
- I review the report.

Trade-off: removes my decision now, but I have to actively review later.

**ANSWER:**

option b.


**If (b), preferred naming pattern?** (`requested_X`/`running_X`, `target_X`/`actual_X`, or other)

**ANSWER:**

Thats fine.

---

## Q8a — Windows shortcut fallback for `--local-artifact-links`

**Context.** Phase 8.2 adds `--local-artifact-links` (your name, recorded). After a run, symlinks "useful" artifacts (archive, IPC info file, primary log dir) into cwd. No copy mode. On Windows, `symlink()` may not work for non-admin users.

**Background on Windows linking.**

Three mechanisms on Windows:

1. **Perl `symlink()`** — works on Vista+ if the process holds `SeCreateSymbolicLinkPrivilege`. Granted to admin and to non-admin in Developer Mode (Win10 1703+). Otherwise `symlink()` returns 0 and sets `$!`. Creates real symlinks (file or dir variants).
2. **Windows shell shortcut (`.lnk` file)** — a binary file the Explorer shell follows when double-clicked. Created via `Win32::Shortcut` (separate CPAN dist, optional dep) or `Win32::OLE` + `WScript.Shell`. Works for any user, no privilege needed. Only the shell follows it — `open()`/`stat()` see the `.lnk` file itself, not the target. So tooling that wants to `cd` into the linked dir, or `read` the linked archive, gets the `.lnk` blob, not the target. Useful only for explorer/GUI navigation.
3. **NTFS junction / hardlink** — junction is dir-only, hardlink is file-only. `link()` (hardlinks) works for any file on the same volume. Junctions need `Win32::Junction` or shelling out to `mklink /J`. Both are transparent to `open()`/`stat()` — they look like the real thing.

**The four strategies:**

### Option (a) — Always try `symlink()`. On failure, warn + skip.

- Unix: works. Win32: works in admin/dev-mode, fails+warns otherwise.
- Simplest. No optional deps.
- On non-dev-mode Windows = no link at all.

### Option (b) — `symlink()` first; fall back to `Win32::Shortcut` `.lnk` on Win failure.

- On Win, tries real symlink first; if fails, drops a `.lnk` next to it.
- `.lnk` only useful via Explorer — user can't `yath replay <link>` and have it follow.
- Adds optional dep `Win32::Shortcut`.

### Option (c) — On Win32 always create `.lnk` (skip `symlink()`); elsewhere `symlink()`.

- Predictable Win behavior (no privilege check needed).
- Same `.lnk` GUI-only limitation.

### Option (d) — `symlink()` first; on Win failure, use NTFS junction (dirs) / hardlink (files).

- `link()` works for the archive (file). `Win32::Junction` or shelling `mklink /J` for the log dir.
- Junctions/hardlinks are transparent to `open()` and `cd` — tooling sees the target.
- Hardlinks have a same-volume restriction; if temp and cwd are on different drives, hardlink fails. Junction has no volume restriction (dir-only).
- Adds optional dep (`Win32::Junction` or shells out).
- Most native-on-Win behavior; cleanest for tooling.

**ANSWER:**

A

**If (b) or (d), OK to add the optional Win32-only dep (gracefully missing → fall back to (a) "warn + skip" behavior)?**

**ANSWER:**



---

(end of file)
