# process.md — the kudos engineering process

This file is the engineering process kudos is built to: the objectives every
change is measured against, the evidence each objective demands, and the
review rubric that hunts for violations. Objectives, evidence, independence, all scaled by blast radius —
in a single-repo operating system where the compiler and the gates, not
paperwork, carry the argument.

**No fitness claim.** kudos is not certified, qualified, or offered as fit for
safety-critical, life-critical, or otherwise regulated use, and nothing in this
process should be read as such a claim. The rigor here exists because it
produces a better operating system, not because it discharges anyone's
obligations.

Two ideas drive everything here:

- **The deliverable is code plus the argument.** A change is not done when it
  works; it is done when a third party who never met the author can conclude
  from the tree alone that it does what a requirement says and nothing else.
- **"And nothing else."** Behavior no requirement states is not a bonus — it is
  unanalyzed behavior, and unanalyzed behavior on a critical path is a defect.

## Document map

One concern, one document. Each artifact below is the single home of its role;
none restates another.

| artifact | role |
| --- | --- |
| `specs/*.md` | requirements: atomic, testable, what-not-how; `spec.md` is the index |
| `CLAUDE.md` | development standards: architecture and coding rails |
| `process.md` | this file: objectives, blast radius, traceability, verification, the review rubric |
| `build.zig` module table + `scripts/tests/` | the enforced structure and the gate inventory |
| commit history | incidents, stories, provenance — everything source is forbidden to say |

## Blast-radius levels

Every module has a level set by the blast radius of its failure. The level is
not recorded in a separate registry — it follows the layer graph: **a module's
level is the worst consequence its failure can cause, and a module imported by
higher-level code inherits that level.** The `build.zig` module table is
the graph's home; `scripts/tests/layering.sh` enforces its edges and holds
the per-group level map (`klevel`) — a group without a level fails the gate.

- **K1 — machine.** A defect can stop, wedge, or corrupt the whole machine, or
  blind the machinery that would report it: the kernel tree (scheduling,
  interrupts, memory, timebase, SMP, containment, crash reporting) and
  anything it imports.
- **K2 — subsystem.** A defect can take down one subsystem or a device for all
  users of it: drivers, the render pipeline, network transports.
- **K3 — session.** A defect is contained to one application or session by K1
  machinery (KRN-006): applications, desktop chrome.
- **K4 — dev-only.** Never on the product image: host scripts, test fixtures,
  tooling.

Objectives accumulate downward — each level owes everything the levels below
it owe, plus its own:

- **All levels**: the gates are green (`make check`); the rubric below applies
  on touch; failures are observable (§20).
- **K3 and up**: every behavior change traces to a requirement (§Traceability);
  regression tests are mutation-checked (§17).
- **K2 and up**: trust boundaries have hostile-input host suites (§41); every
  hardware wait has a budget and a recovery path (§38); overload behavior is
  designed and counted (§39).
- **K1**: every defect found is retired as a class (§Findings); fixes are
  invariants by construction, never runtime fallbacks; the review is
  adversarial and independent of the author (§Verification); the claim "met"
  requires the hardware gate (`make check-hw`), not just QEMU.

## Architecture & partitioning

The layering rules — one-way dependencies, contracts-only interface layers,
abstraction only at real seams — live in `CLAUDE.md`; this section states why
they are correctness objectives, not style. kudos runs mixed blast radii on one
machine: K3 applications share silicon with the K1 kernel, and the claim that
an application fault cannot disturb the machine (KRN-006) rests entirely on
enforced boundaries. That partitioning argument carries three obligations:

- **A layering violation is a partitioning breach.** An import that reaches
  past a public surface, or a lower layer reaching upward, silently promotes
  code into a level nobody verified it at. That is why an illegal
  edge fails the build (`scripts/tests/layering.sh` over the `build.zig`
  module table) rather than waiting for a reviewer: the partition is only as
  strong as its enforcement.
- **The import graph is the level-inheritance mechanism.** A module's
  level is inherited by everything it imports (§Blast radius) — so the layer
  manifest is not just structure, it is the assignment record. Moving a
  module down the stack moves it up in blast radius; that move is reviewed as
  such.
- **Architecture keeps the expensive argument small.** K1 objectives cost the
  most, so the design pushes logic out of K1 territory: anything expressible
  as a pure function leaves the IO/device edge for a host-testable module,
  where the cheapest rung of the ladder (host tests + mutation) carries its
  evidence. The pure-module list shrinking toward zero is a design failure;
  the kernel's untestable residue shrinking toward pure edges is the goal.
- **Containment is a verified function, not an assumption.** The machinery
  that holds the partition at runtime — fault containment, capability-scoped
  surfaces for foreign code (§43), watchdog coverage per wedge class (§40) —
  is itself K1 code with its own invariants and tests; a partition nobody
  has tried to breach is a wish (§17 applies to containment too).

## Requirements

`specs/README.md` owns the format rules: stable `PREFIX-NNN` identifiers, one testable
assertion per "shall", function and performance only — never mechanism. The
requirements themselves live one file per package in `specs/`; `spec.md` is
the index over them. This section owns the lifecycle around them:

- **A behavior change lands with its requirement.** New behavior either
  implements an existing requirement (name the ID in the commit) or arrives
  with the spec change that states it.
- **Derived behavior is a finding.** Code the spec does not call for —
  discovered in review, in a coverage gap, or by reading — is either promoted
  into `specs/` (and then re-examined: what new failure modes does it bring?)
  or deleted. There is no third state.
- **Requirements move only forward.** A withdrawn or moved requirement retires
  its identifier; an identifier is never reused (specs/README.md owns this rule; it is
  what makes the trace durable).

## Traceability

The loop is required to close in both directions (§48): every requirement ID
maps to the code that implements it and to at least one test that fails without
it; every test and every module answers "which requirement needs you?". It is
not closed today — `reqtrace_uncited.txt` is the measure of how far off it is.

The trace is regenerated, never maintained by hand:

```
grep -ohE '\b[A-Z]{2,4}-[0-9]{3}\b' specs/*.md         | sort -u   # required
grep -rhoE '\b[A-Z]{2,4}-[0-9]{3}\b' test/ scripts/tests/ | sort -u   # tested
```

The difference between those two sets is the finding list: a requirement no
test cites is unverified; an ID cited nowhere in `specs/` is a citation of a
retired or misspelled requirement. `scripts/tests/reqtrace.sh` enforces both
directions in `make check`; `scripts/tests/reqtrace_uncited.txt` is the
ratchet of requirements still awaiting citation — rows only leave, in the
same change that adds the citation.

## Verification

**Cheapest signal first, and say what ran.** The ladder is
`make check-fast` (host suites only) → `make check` (host + QEMU, the
iteration gate) → `make check-hw` (the native tracks on real hardware, the
final gate). Never spend an expensive rung on what a cheap one could answer —
and never claim a rung that did not execute. Every claim of "done" states the
highest rung that actually ran and its result.

**Coverage is measured, not targeted.** Tests come from requirements and from
known failure modes, never from a coverage number. kudos's structural-coverage
measure is mutation testing over the pure-module list (the host-suite table in
`build.zig` IS that list): a regression test proves it can fail by going RED
when its target bug is reintroduced, then the fix is restored. A coverage gap
found afterwards means one of exactly three things — a missing requirement,
dead code, or an inadequate test — and each is a finding to disposition, not
a number to raise.

**Independence at K1.** The author's confidence is not evidence. A K1 change
is reviewed by someone or something that did not write it, hunting to refute:
the reviewer's job is to construct the failing input, not to agree the code
looks right. A review "passes" a criterion only when a deliberate hunt for
violations comes back empty, with `file:line` evidence.

**Tools are suspects.** Anything whose output we trust instead of verifying —
the shader compiler loop, generated layout checkers, the trace tooling — gets
the same treatment as code: its output is diffed against a committed snapshot
or validated by an independent reference (e.g. the Khronos validator for
shipped glTF), so a tool defect shows in a diff, not in the field.

## Change control

- **The tree is only ever in a state the gates pass.** A change that cannot
  keep them green does not land; there is no "fix forward" window.
- **Widening a contract is a visible act.** Public surfaces are diffs someone
  reviews as a contract change (§11, §52), never absorbed silently.
- **Generated artifacts are traceable** (§47): every committed generated file
  names its source and regeneration command, and drift between the pair is a
  gate's job to catch.
- **Impact analysis is the ladder.** A change re-runs the cheapest gate that
  could catch its defect class and every rung above it that its level
  demands; a K1 claim is not "met" until the hardware rung ran on the tree
  that makes the claim (`BUILD_NUMBER` ties the binary to the tree).
- **Provenance lives in commits.** Stories, incidents, review archaeology —
  the commit message owns them; source states invariants only (CLAUDE.md).

## Findings

A defect on a K1 or K2 path is not just fixed — it is retired as a class. The
fix answers four questions, and **the answers live in the tree, never in a
register document** — a register is a second home that drifts from the code it
describes and outlives the work it tracks:

- **Defect** — what can go wrong and the mechanism that lets it. This is the
  commit message's job.
- **Invariant** — the property that must hold for the defect not to recur,
  stated at the code that owns it.
- **Construction** — how the design removes the mechanism instead of watching
  for it. A runtime fallback that detects-and-recovers is not a construction;
  prefer designs with nothing to detect (a clock that no interrupt can capture
  beats a watchdog on the interrupt).
- **Test** — the proof, mutation-checked: reintroduce the defect, watch it go
  RED, restore.

The finding is retired when the invariant is stated at the owning code, the
test is RED under the reintroduced bug, and any structural rule the fix
established has moved into a gate. Work still in flight is tracked wherever
the work is tracked; it does not accumulate a document of its own.

## Gates

The gate inventory is `scripts/tests/check.sh` — read it, don't restate it
here. The standing rule: **an objective in this file with no enforcing gate is
debt** — a human-vigilance rule will eventually be broken (§56), so a fixed
deviation or a new structural rule moves into a gate on touch, not onto a
wishlist.

---

# The review rubric — 56 criteria

The standing lens for reviewing kudos source. Each criterion is a question a
reviewer answers with evidence (file:line), not opinion. CLAUDE.md holds the
project rails; this rubric is the review lens over them. A review "passes" a
criterion only when a deliberate hunt for violations comes back empty.

Criteria 1–20 are universal software-review criteria; 21–40 are the real-time
operating-system dimensions — timing, interrupts, scheduling, memory
determinism, hardware interfaces, and behavior under overload and fault;
41–48 are security & trust, boot discipline, and traceability — the criteria
that close the loop between spec, source, artifacts, and tests; 49–56 are
files & modularity — directories, naming, size vs. cohesion, interface
growth, the source/test split, and structure enforced by gates.

## Correctness & robustness

1. **Does it do what it claims?** Diff vs. stated intent: every behavior change
   is intentional and named; nothing extra rides along.
2. **Edge and error paths.** Empty input, zero, max, overflow, truncation,
   malformed/hostile input: handled, propagated, or loudly rejected — never
   silently swallowed.
3. **Resource lifecycle.** Every acquisition (memory, handle, lock, texture,
   socket) has a named owner and a release path introduced in the same change;
   failure paths unwind partial state.
4. **Concurrency discipline.** Shared state has an identified owner and
   synchronization story; no data races or lock-order inversions; no blocking
   or allocation on hot paths (interrupt, per-frame, per-request).
5. **Numeric honesty.** Integer overflow/underflow, unit mismatches, precision
   loss (f32 accumulating over time), quantized clocks: considered, not assumed
   away.

## Design & architecture

6. **One concern per unit.** Each file/function does one job at one altitude;
   bit-twiddling and orchestration are not interleaved.
7. **Dependencies point one way.** No cycles; no lower layer reaching upward;
   callers go through a module's public surface, never around it.
8. **Abstraction only at real seams.** Indirection exists only where
   substitution is genuinely needed (hardware, IO, time, network, randomness).
9. **One fact, one home.** Constants, formulas, wire layouts, and sequences
   exist exactly once; everything else imports or calls the owner.
10. **Effects at the edges.** Anything expressible as a pure function is
    separated from the IO/device/handler code that uses it.
11. **Minimal public surface.** Everything `pub` has a caller; widening a
    contract is a visible, deliberate act.

## Readability & maintainability

12. **Names tell the truth.** Named for what the thing is, not its role
    (`_utils`/`_helper`/`_manager` are smells); units live in the name
    (`_MS`, `_KB`).
13. **No magic numbers.** Every spec or decision literal is a named constant,
    defined once at the owner, spelled as the spec spells it.
14. **Comments teach WHAT/WHY, never history.** No war stories, "used to", or
    review archaeology; a comment restating a constant or naming something that
    no longer exists is a lie.
15. **The diff reads like the codebase.** Idiom, naming, and structure match
    the surrounding code.
16. **Dead code is deleted, not documented.** Unused functions, stale branches,
    commented-out blocks: removed.

## Testing & verification

17. **Tests can actually fail.** Each test goes red if its target bug is
    reintroduced (mutation-check regression tests); a test that cannot fail is
    a comment.
18. **Tests import, never restate.** Tests reach code through the public
    surface production uses and import owner constants.
19. **Cheapest signal first — and it ran.** Host/unit → integration/QEMU →
    hardware, in that order; the review states what actually executed and its
    result.

## Operability

20. **Failures are observable.** Discarding paths count what they dropped,
    waits have budgets, errors surface where an operator sees them; nothing
    important fails silently.

## Timing & determinism (RTOS)

21. **Bounded execution on real-time paths.** Every loop, retry, and scan on a
    deadline path (interrupt, per-frame, per-request) has a stated bound or
    budget; worst-case time is reasoned about, not just typical-case.
22. **Deadlines are explicit and instrumented.** Frame, boot, and IO budgets
    are named constants, measured by counters, and enforced as tests — a
    deadline nobody measures is a wish.
23. **Jitter, not just average.** Periodic work is judged by its variance;
    timestamps for animation/pacing are sampled at a consistent point in the
    cycle so quantized or drifting clocks cannot alias into visible judder.
24. **One timebase, owned.** Each clock source is calibrated once with a single
    owner; tick↔time conversions are single-homed; monotonicity and wraparound
    (`-%`) are handled at the owner, not at call sites.
25. **Time-of-check vs. time-of-use.** A value sampled from a moving source
    (clock, counter, ring index) is sampled once per decision; re-reads that
    can disagree mid-decision are eliminated or justified.

## Interrupts & ISR discipline (RTOS)

26. **ISRs do minimal work.** Acknowledge, record, wake — heavy work is
    deferred to task context; nothing in an ISR blocks, allocates, or logs
    unboundedly.
27. **Interrupt-masked windows are short and bounded.** No waiting for an event
    while the interrupt that delivers it is masked; save/restore of the flag
    state goes through the one owning primitive.
28. **ISR↔task communication is race-designed.** Single-writer rings, atomic
    indices with stated memory ordering, and a documented reason the chosen
    ordering suffices on the target.
29. **Interrupt storms and spurious interrupts are survivable.** A stuck or
    misrouted line cannot livelock the system; spurious wakes are counted, not
    silently absorbed.

## Scheduling & priorities (RTOS)

30. **Priority and placement are deliberate.** Work is pinned or prioritized on
    purpose (render on its core, agents contained on theirs); priority
    inversion across shared resources is avoided or bounded.
31. **Starvation freedom.** Every waiter eventually runs: busy-waits yield or
    halt, fairness is designed or its absence justified, and no path spins
    against a condition another starved task must produce.
32. **Lock discipline on real-time paths.** Spinlock hold times are tiny and
    bounded; nothing blocks, allocates, or does IO under a spinlock; locks
    taken in ISR context use the IRQ-safe form everywhere.

## Memory determinism (RTOS)

33. **Static allocation on real-time paths.** All memory for hot paths is
    acquired at init; no heap alloc/free in ISRs or per-frame; long-run
    fragmentation cannot grow.
34. **Stack budgets.** Every task and ISR stack is sized deliberately, overflow
    is detectable (guard/canary/known size), and unbounded recursion cannot
    occur on kernel paths.
35. **Bounded queues with a named overflow policy.** Every ring and queue
    states its capacity and what happens when full (drop-oldest, reject,
    backpressure) — and drops are counted.

## Hardware interfaces (RTOS)

36. **MMIO ordering and barriers.** Device register access is volatile with the
    required barriers; posted writes are flushed where the protocol needs it;
    read-modify-write races on shared registers are considered.
37. **DMA and cache coherency.** Buffer ownership handoff between CPU and
    device is explicit (who owns it, when it flips); device-visible memory is
    never touched while the device owns it; alignment and lifetime rules are
    stated.
38. **Every hardware wait has a timeout and a recovery path.** No infinite
    polls on device state; a hung device produces a loud, attributable failure
    within its stated budget, not a wedge.

## Overload & fault behavior (RTOS)

39. **Overload degrades by design.** When input or work exceeds capacity the
    system sheds, coalesces, or skips predictably and observably (counted) —
    it never falls off a cliff or lies about keeping up.
40. **Faults are contained and watched.** A fault on one core/task cannot take
    down the rest; watchdog/deadman coverage exists for every wedge class;
    the recovery path (contain, report, reboot) is itself tested.

## Security & trust

41. **Trust boundaries are named, and everything crossing one is hostile until
    validated.** Network frames, USB descriptors, files from removable media,
    LLM/agent output, and loaded binaries are parsed defensively: length-checked,
    bounds-checked, malformed input rejected loudly — and the parser for each
    boundary has a host test suite feeding it garbage.
42. **Secrets never live in source, logs, or history.** Credentials arrive
    through a config channel, never a literal; they are redacted from logs,
    traces, and telemetry; nothing prints or persists them incidentally.
43. **Foreign code is contained.** Anything loaded and executed (blobs, hot-
    loaded features) is verified before it runs (integrity + ABI contract),
    receives the least capability that does its job, and fails inside its
    container — a bad module cannot take the system with it.
44. **Crypto hygiene.** Standard primitives only, validated against published
    test vectors; security-relevant randomness comes from a CSPRNG; no
    homegrown constructions, no downgraded modes accepted silently.

## Boot, build & traceability

45. **Init ordering is explicit and idempotent.** Every init states what it
    requires already up; double-init is harmless or loudly rejected; the boot
    sequence has a measured budget and failing to come up is a loud, attributable
    event — never a silent hang.
46. **Idle costs nothing.** Idle loops halt rather than spin; wake sources are
    correct and complete; no periodic work runs faster than its purpose needs.
47. **Generated artifacts are traceable to their source.** Every committed
    generated file (compiled shaders, API snapshots, fixtures) names its source
    and regeneration command, and drift between the pair is detectable — ideally
    by a gate, never only by a human noticing.
48. **Spec, code, and tests close the loop.** Every requirement ID maps to the
    code that implements it and at least one test that would fail without it;
    code implementing no requirement and requirements implemented nowhere both
    surface in review as findings.

## Files & modularity

49. **The directory tree mirrors the architecture.** A small fixed set of
    top-level groups; extra nesting only where the import graph proves
    separable layers, never deeper; a newcomer can predict a module's path
    from its concern (and vice versa) without grep. A directory whose files
    no longer share one concern is a missed subgrouping decision; a new
    top-level group is a real architectural decision, never a convenience.
50. **File names follow one convention and name the thing.** One naming
    pattern per kind — modules by concern (never `_utils`/`_helper`/`_impl`),
    tests as `<stem>_test.zig`, fakes as `*_sim.zig`, contracts in the
    interface layer — applied without exception; one casing convention per
    kind; the file name matches its primary declaration and its content, and
    a file whose name has drifted from what it now contains is a finding.
51. **File size tracks cohesion.** One file, one concern. Size is the
    symptom, not the crime: flag any file serving multiple independent
    clients, mixing layers, or grown past what a reader can hold — as a
    working heuristic, a second look around 500 lines and a documented
    justification or a designed split past 1000. Splits follow seams
    (concern, layer, client), never line counts.
52. **Interfaces stay narrow as modules grow.** A module's `pub` surface is
    proportional to its concern, not its size; fan-in and fan-out are
    watched over time; a module that everything imports *and* that imports
    everything is a god module — split it or demote it. Growth in a
    contract is reviewed as a contract change, not absorbed silently.
53. **Source and test code never mix — and pair one-to-one.** No test code,
    fixtures, helpers, or `pub`-for-tests-only surface in the source tree;
    no production logic in the test tree; product assets and test-only
    fixtures live in separate, designated homes. Every host-testable module
    has exactly one `<stem>_test.zig`; an orphan test file with no module,
    or a pure module with no test file, is a finding.
54. **Scripts are consistent and self-describing.** One naming convention,
    one shebang/safety idiom (`set -euo pipefail` or the project's
    equivalent), a usage header stating what the script does and requires,
    and a location that matches its purpose; a script nobody can run from
    its header alone is a finding.
55. **The repository root stays canonical.** The root holds only the entry
    points someone new needs (README, spec, rails, process, build, license);
    everything else lives in its group; stray outputs, scratch files, and
    one-off artifacts never land in the tree.
56. **Structure is enforced by gates, not vigilance.** The layer graph and
    allowed import edges live in one manifest the build checks — an illegal
    import fails to compile, a public-surface widening shows in a committed
    snapshot diff, and naming/pairing rules run in CI. Any structure rule
    that exists only in a reviewer's head will eventually be broken.
