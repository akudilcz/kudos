---
name: debug-issue
description: Debug a kudos defect — pick the cheapest reproduction rung, read the counter trail before guessing, and land the fix as an invariant with a mutation-proven test.
---

# Debugging kudos

## Reproduce on the cheapest rung that can show the bug

Host test → `make check-fast` → QEMU (`make gui`, `make test-guest-qemu`) → real hardware on
lemon. Most defects are reachable on the host: if the failing logic is pure, write the failing
host test first and never boot anything.

Some classes QEMU can never prove — real HID timing, igc RX stalls, GSP/4090 behaviour, SMP on
32 cores. Those need lemon, and that is the last rung, not the first.

## Read the evidence before forming a theory

- **The trace bus is the channel.** kudos has no serial port: `klog.zig` is the trace bus and
  netdebug carries it over UDP :9514. Use the `kudos-netdebug` MCP tools (`netdebug_tail`,
  `netdebug_grep`, `netdebug_status`, `netdebug_gaps`). On real wire, run `netdebug_recover`
  before declaring lines lost — gaps are recoverable by sequence.
- **Counters name the failure mode in one run.** Discarding paths count what they dropped and
  waits state a budget, so read the counter trail rather than adding print statements.
- **A deterministic wild instruction pointer means "jumped somewhere fixed and wrong", not
  "memory corruption".** The repeated address is the clue.
- **Kernel task stacks have no guard page.** An overflow does not fault — it scribbles the heap
  underneath and surfaces much later as an unrelated wild jump. `scripts/tests/stackframes.sh`
  and `stackdebt.txt` hold the frame budget; re-measure after any toolchain change.

## Use the graph for reach, not for layering

`query_graph_tool` `callers_of` / `tests_for` at `detail_level: "standard"`, impact radius at
depth 1. For a changed `src/iface/` contract the graph reports zero importers — contracts are
imported by name, so use `grep -rl '@import("<stem>")' src/`. See the `explore-codebase` skill
for the full list of graph blind spots.

## Land the fix the way process.md requires

A defect on a K1 or K2 path is retired as a class, and the four answers live in the tree:

- **Defect** — the mechanism that allowed it. This is the commit message's job.
- **Invariant** — the property that must hold, stated at the code that owns it.
- **Construction** — how the design removes the mechanism rather than watching for it. A
  runtime fallback that detects-and-recovers is not a construction.
- **Test** — mutation-proven: reintroduce the defect, watch it go RED, restore.

If the fix establishes a structural rule, it moves into a gate (`scripts/tests/layering.sh`),
not onto a wishlist. Never `git checkout <file>` to undo a mutation while the file carries
uncommitted work — restore with the inverse edit.
