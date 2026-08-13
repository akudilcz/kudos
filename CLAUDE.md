# conventions — shaping source and tests, and the quality bar

**Rails, not descriptions. Where the tree disagrees, the tree is wrong. Never cite existing
code as precedent for breaking a rule.** Rules and canonical homes only, never lists of
instances — give the command that regenerates a list.

Subsystem rails live in `.claude/rules/` and load when a matching file is opened: `layout.md`
(`src/`, `test/`, `scripts/`), `rendering.md` (`gl/`, `gpu/`, `ui/`, `widgets/`), `tests.md`
(`test/`, `*_test.zig`). `process.md` holds the review rubric; `specs/` holds requirements.

## Working autonomously

**At a fork in the road, choose and keep going.** These rails, `process.md` and `specs/` are
the tie-breaker: if the standard already decides it, the decision is made — implement it and
say which rule you applied. Do not stop to ask what the tree already answers, and do not
deliver half the work while waiting on a reply. Where a question is genuinely open, pick the
option you can defend, state the assumption, and finish the task under it.

Interrupt only for what a wrong guess makes expensive: a change that is hard to reverse, one
that alters the product's behaviour or a published contract, or one that spends real hardware
or money. Everything else is a judgement call you are expected to make, and the record of it
belongs in the commit message.

## Commands

Toolchain is **Zig 0.16.0** (`~/.local/bin/zig`). A pure-module test root may not relatively
import above its root dir — that is what the `src/*_testroot.zig` umbrellas are for; never root
a module below the deepest file its graph reaches.

| Command | What it does |
| --- | --- |
| `make status` | the test register: what this tree has proven, what is stale (~1 s) |
| `make check` | THE GATE (iterate): host + QEMU, runs only stale tracks |
| `make check-fast` | host tracks only, still register-incremental |
| `make check-hw` | THE GATE (final): also demands the native tracks on real hardware |
| `make test T=<track>` | run one register track and record it (`FORCE=1` overrides) |
| `make test-unit ONLY=<substr>` | narrow host run, records nothing |
| `make watch ONLY=<substr>` | sub-second warm rebuild+rerun loop on every save |
| `make gui` | local QEMU window; the ISO must be built `-Dsoft-display` or it renders black |
| `make help` | the full target list, scraped from the Makefile so it cannot drift |

Never re-run a track `make status` shows green against this tree — the record IS the evidence.
Branch on `make`'s exit code, never on grepping its output for PASS: a grep succeeds on a red
gate. The laptop has no RTX 4090 and no reference stick, so `qemu-boot-1`, boot-2/3-native, the
model sweep and `check-hw` all run on lemon; everything else runs locally.

## Architecture: layers and coupling

- Layered APIs: each layer speaks only to the public API of the one below. No cycles. A module
  imported upward is misfiled — move it down.
- One file, one concern. A module's public API is its whole contract; callers never reach past
  it into internals — through the toolkit, not around it.
- Peers that must not know each other meet in a narrow interface layer: contracts, no logic.
  It lets the HIGH layer call down; a low layer reaching up is inverted.
- The tree mirrors the layering: a small fixed set of top-level groups, one extra nesting level
  only where the import graph proves separable layers. New subsystem = a real decision. New
  group = no.
- Name the thing, not its role: never `_impl`/`_utils`/`_helper`/`_manager`. Contracts, fakes
  and tests each follow one project-wide pattern. Module-qualified types; no local aliases.

## Interfaces

A runtime abstraction (interface, vtable, injected dependency) only at a REAL seam — hardware,
IO, time, network, randomness. Before adding one, in order: the file is misfiled (the usual
cause); the caller needs a VALUE — pass it in; the contract exists — grep the interface layer;
the importer is in the wrong group. Only then add one, and only for a test substitution or two
groups that must not see each other.

## Resources & state

- Effects at the edges: anything expressible as a pure function comes out of the IO/device/
  handler code. No global mutable state across groups.
- Every acquired resource has a named owner and a release path in the same change; acquisition
  failure is a value, never a sentinel; error paths unwind partial state.
- No allocation or blocking work on hot paths (interrupt, per-frame, per-request) — set up at
  init.

## One source of truth

- One fact, one home. Grep before writing a helper; import or extend, never re-derive. A test
  imports a constant, never restates it.
- **One behaviour, one function.** How an input is found, a path resolved, a refusal worded, a
  walk bounded: written once, called everywhere. Two functions that must change together are
  one function with a parameter — a copy is not wasted bytes but a fork that drifts, and the
  drift surfaces as two tools disagreeing about the same input.
- The **second** occurrence is the trigger: when a block is about to be copy-adapted it moves,
  in that same change and with the first caller converted, to the layer both callers import.
  Place a helper by what it is ABOUT, never in a role-bag; give it the narrowest arguments
  that serve every caller (a value, not the context).
- Before adding a module, grep its group for the noun it is named after: a near-duplicate
  module is an inline copy one directory up.
- No magic numbers: an external-spec literal is a named constant even when used once, spelled
  as the spec spells it, atop the owning module. Units in the name (`_MS`, `_KB`).

## Comments & docs

Every line teaches or lies. Expand acronyms on first use; doc comments say WHAT and WHY in
plain sentences. No provenance: no dates, war stories, "used to", review tags — state the
invariant, not the incident; stories go in the commit message. Everything you name must exist.
Delete dead code, don't document it.

## Verification

- **Write the whole batch, then verify it once.** A gate run costs tens of minutes: implement
  every task — source, tests, docs, gate rows — then run. Five failures in one run is five
  fixes for the price of one wait.
- Cheapest signal first: host/unit → integration/simulation → the real environment LAST.
- Incremental: `build/verified/` is the register — a passing track records the digest of the
  paths it covers, `make check` re-runs only stale tracks, `make status` reads it (~1 s),
  `make test T=<track>` records one. Never re-run a green track: the record IS the evidence.
- Failures are never silent: a discarding path counts what it dropped, every wait states a
  budget, rates are counters not logs.
- Long runs stream progress at least every 5 s — stream the output, or background it and poll
  the log. Never swallow one behind a final `| tail`: silence is indistinguishable from a hang.

## Scale

At thousands of modules only compiler-enforced structure and generated checks hold: allowed
edges in one manifest the build wires from, so an illegal import fails to compile; one
conformance suite per contract, passed by every implementation, real or fake; universals here,
a small rules file per subsystem; committed API snapshots, so a widened contract shows in the
diff that did it; scaffolded new modules (module + test + wiring + doc stub) so the easy path
IS the rails; CI discipline — mutation-test the pure-module list, check doc-cited names exist,
trend fan-in/fan-out, budget hot metrics as tests.

## Deviations

Fix on touch, never extend, never cite as precedent. A fixed deviation moves into a gate, not
merely out of this file.

<!-- code-review-graph MCP tools -->
## Exploring the tree

This project carries a code-review-graph knowledge graph, auto-updated on file change. Reach
for its MCP tools before Grep/Glob/Read: they answer callers, dependents, impact and coverage,
which file scanning cannot. Fall back to Grep/Glob/Read only where the graph does not reach.
