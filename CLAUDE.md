# conventions — shaping source and tests, and the quality bar

**Rails, not descriptions. Where the tree disagrees, the tree is wrong. Never cite existing
code as precedent for breaking a rule.** Rules and canonical homes only, never lists of
instances — give the command that regenerates a list instead.

## Architecture: layers and coupling

- The codebase is a stack of layered APIs: each layer speaks only to the public API of the
  layer directly below it. Dependencies point one way; no cycles. A module imported upward
  is misfiled — move it down the stack.
- High cohesion, low coupling: one file, one concern. A module's public API is its whole
  contract; callers never reach past it into internals or the layers beneath it — go through
  the toolkit, not around it.
- Peer groups that must not know each other talk through a narrow interface layer that holds
  contracts only, no logic. The interface lets the HIGH layer call down; a low layer reaching
  up is inverted.
- The directory tree mirrors the layering: a small fixed set of top-level groups; one extra
  nesting level only where the import graph proves separable layers, never deeper.
  New subsystem = a real decision. New group = no.
- Name the thing, not its role: never `_impl`/`_utils`/`_helper`/`_manager`. Contracts, fakes
  and tests each follow one project-wide naming pattern. Module-qualified types at every
  site; local aliases are banned.

## Layout: where a file goes, and what it may be called

The rules here are checked by `scripts/tests/layering.sh`; run it to see what it
enforces today and the current state, and read its comments for why each rule exists. A rule that only lives in this
document is a rule that comes back.

- **`src/` root holds module roots and NOTHING else**, each named `*_root.zig`. A Zig
  module's import path is its own directory, so the files that must resolve imports
  across every group — the kernel entry points and the host-test root — are forced to
  sit at the top. Any other file there has not been forced up, it has escaped its
  group. Ordinary files live in a group and reach across with relative imports.
- **One host-test module root**, `src/test_root.zig`: one line per host-testable file,
  namespaced by group. A suite reaches through it (`@import("test_root").gl.foo`).
  Never a second root-level shim — the count is the thing that creeps.
- **The apex is a group like any other.** Code that legitimately knows every group (the
  steady-state loop) lives in `boot/`, not loose at the top. It is K1: a defect there
  stops the machine.
- **Top-level groups are a closed set**, listed once in the layering gate. Adding one is
  an architecture decision: it fails the gate until it is declared AND given a K-level.
- **`test/` mirrors `src/`'s groups**, plus `support/` for shared fakes. A test file is
  `*_test`, `*_sim`, `*_conformance` or `*_shot` — a new kind is recorded in the gate,
  not improvised. Nothing in `src/` wears a test suffix.
- **Scripts are a small, role-organised set.** One script per role, with SUBCOMMANDS —
  never a new file per variant, which is how 80 accumulate. A script nothing calls is
  deleted, not kept "in case": `scripts/README.md` maps each to its role and caller.

## Interfaces

A runtime abstraction (interface, vtable, injected dependency) only at a REAL seam — hardware,
IO, time, network, randomness. Before adding one, in order: the file is misfiled
(the most common case); the caller needs a VALUE, not a dependency —
pass it in; the contract already exists — grep the interface layer; the importer is in the
wrong group; only then add one — when a test must substitute the implementation or two groups
must not see each other.

## Rendering: GPU product, soft-display dev builds

kudos is GPU-only OpenGL hardware acceleration: on the product image the desktop renders on
the RTX 4090 through `gles → kgl → idraw` and nowhere else; the kernel never rasterises the
desktop on the CPU when that GPU is present (spec ARCH-015). "The desktop is shown" means the
**first present** (PERF-001), and from that instant it is required to hold a smooth 60 Hz. The firmware
framebuffer is adopted for geometry only (no pixels) on the GPU path. QEMU runs GPU
passthrough as its operating mode. `drivers/gl/soft.zig` is the software IDraw implementation
with exactly two consumers: the host-test fixture that exercises the `gles`/`idraw` pipeline
on a laptop, and `drivers/gl/softdisplay.zig`, which on a `-Dsoft-display` build (off by
default, spec RND-012, RND-013) publishes it as the draw device when no GPU is coming and the
rasteriser's in-place delivery into the firmware framebuffer IS the present. Only
`softdisplay.zig` and `test/` may import `soft` (layering gate); with the flag off, no
kernel path publishes the software rasteriser as the draw device.

## Resources & state

- Effects live at the edges: anything expressible as a pure function is pulled out of the
  IO/device/handler code that uses it. No global mutable state shared across groups.
- Every acquired resource has a named owner and a release path, introduced in the same change;
  acquisition failure is a value, never a sentinel. Error paths unwind partial state.
- No allocation or blocking work on hot paths (interrupt, per-frame, per-request) —
  set up at init.

## Constants & duplication

- One fact, one home. Grep before writing a helper; import or extend, never re-derive.
  A test never restates a constant — it imports the owner.
- No magic numbers: a literal from an external spec is a named constant even when used once,
  spelled exactly as the spec spells it, defined once atop the owning module. Timeouts and
  sizes carry their unit in the name (`_MS`, `_KB`).

## Comments & docs

The code is a reference implementation — every line teaches or lies. Expand acronyms on first
use; doc comments say WHAT and WHY in plain sentences. No provenance in source: no dates, war
stories, "used to", review tags — state the invariant, not the incident;
stories go in the commit message. Everything you name must exist — check first. Delete dead
code, don't document it.

## Tests

**All test code lives in the test tree, never in the source tree** — no inline test blocks in
production files; a test imports its module through the same public surface production callers
use; helpers and fakes stay in the test file, never `pub` bait in the module. Logic
expressible as a pure function lives in a host-testable module, never entangled with the IO
edge — the host-test list IS the list of pure modules. A test that cannot fail is a comment —
mutation-test every regression test (reintroduce the bug, confirm RED, restore).

## Verification

- **Write the whole batch, then verify it once.** A gate run costs tens of minutes, so the
  unit of work is a BATCH of tasks, not a task: implement every task in the batch — source,
  tests, docs, gate rows — and only then run the suite. Never interleave one change with one
  run. A run that reports five failures at once is five fixes for the price of one wait; five
  runs reporting one failure each is the same information for five times the cost.
- Cheapest signal first: fast host/unit tests → integration/simulation → the real environment
  LAST; never spend an expensive run on what a cheap one could answer.
- Verification is incremental: `build/verified/` is the test register — a passing track
  records the content digest of the paths it covers, and `make check` re-runs only stale
  tracks. `make status` reads the register (~1 s); `make test T=<track>` runs and records
  one track. Never re-run a track the register shows green against this tree — the record
  IS the evidence.
- Failures are never silent: a discarding path counts what it dropped; every wait states a
  budget; rates are counters, not logs.
- Long runs stream progress: any test/build/suite invocation must show liveness at least
  every 5 seconds — stream the output, or background it and poll its log visibly. Never
  launch a long run with its output swallowed behind a final `| tail`: an hour of silence
  is indistinguishable from a hang and hides where a red run died.

## Scale

At thousands of modules, only compiler-enforced structure and checks generated from one
source of truth hold:

- Layers and allowed edges live in one manifest the build wires modules from — an
  illegal import fails to compile.
- One conformance suite per contract; every implementation, real or fake, passes it.
- The root rules file holds universals; each subsystem carries its own small rules file.
- Public API surfaces are committed, generated snapshots — widening a contract shows in the
  diff that did it.
- New modules are scaffolded (module + test + wiring + doc stub): the easy path IS the rails.
- Discipline runs in CI: mutation-test the pure-module list; check doc-cited names exist;
  trend fan-in/fan-out; budget hot metrics as tests.

## Deviations

Fix on touch, never extend, never cite as precedent. A fixed deviation moves into a gate,
not merely out of this file.

<!-- code-review-graph MCP tools -->
## MCP Tools: code-review-graph

**IMPORTANT: This project has a knowledge graph. ALWAYS use the
code-review-graph MCP tools BEFORE using Grep/Glob/Read to explore
the codebase.** The graph is faster, cheaper (fewer tokens), and gives
you structural context (callers, dependents, test coverage) that file
scanning cannot.

### When to use graph tools FIRST

- **Exploring code**: `semantic_search_nodes_tool` or `query_graph_tool` instead of Grep
- **Understanding impact**: `get_impact_radius_tool` instead of manually tracing imports
- **Code review**: `detect_changes_tool` + `get_review_context_tool` instead of reading entire files
- **Finding relationships**: `query_graph_tool` with callers_of/callees_of/imports_of/tests_for
- **Architecture questions**: `get_architecture_overview_tool` + `list_communities_tool`

Fall back to Grep/Glob/Read **only** when the graph doesn't cover what you need.

### Key Tools

| Tool | Use when |
| ------ | ---------- |
| `detect_changes_tool` | Reviewing code changes — gives risk-scored analysis |
| `get_review_context_tool` | Need source snippets for review — token-efficient |
| `get_impact_radius_tool` | Understanding blast radius of a change |
| `get_affected_flows_tool` | Finding which execution paths are impacted |
| `query_graph_tool` | Tracing callers, callees, imports, tests, dependencies |
| `semantic_search_nodes_tool` | Finding functions/classes by name or keyword |
| `get_architecture_overview_tool` | Understanding high-level codebase structure |
| `refactor_tool` | Planning renames, finding dead code |

### Workflow

1. The graph auto-updates on file changes (via hooks).
2. Use `detect_changes_tool` for code review.
3. Use `get_affected_flows_tool` to understand impact.
4. Use `query_graph_tool` pattern="tests_for" to check coverage.
