---
name: explore-codebase
description: Navigate kudos with the code-review-graph MCP — callers, dependents, impact radius — including the four places the graph lies about this repo.
---

# Exploring kudos

The graph answers callers/dependents/impact, which file scanning cannot. It is a **second
opinion on structure, never the layering oracle** — `scripts/tests/layering.sh` is ground truth
for what is legal, and it runs in seconds with no build.

## Order of attack

1. `list_graph_stats_tool` / `get_architecture_overview_tool` — orientation only. Its 32
   auto-named communities do not line up with the project's nine declared groups; treat low
   cohesion as a modularity smell to investigate, never as a verdict.
2. `query_graph_tool` with `callers_of` / `callees_of` / `tests_for` — the workhorse. An
   ambiguous bare name returns a disambiguation list of qualified names; pick from it.
3. `get_impact_radius_tool` at **depth 1**.
4. `find_large_functions_tool` — no function-length rule is enforced, so this is pure signal.

## Four things the graph gets wrong here — check every time

- **`detail_level: "minimal"` returns empty result objects.** Always pass `"standard"`.
- **Depth 2 impact radius is useless**: it returns ~500 nodes truncated from ~2096 across 138
  files, i.e. most of the tree. Depth 1, or query per file.
- **`importers_of` returns 0 for every `src/iface/` contract.** Contracts are imported by
  *name* (`@import("inet")`) through `build.zig`'s `iface_mods`, and relative iface imports are
  banned by the gate — so the graph sees none of the ~121 import sites across ~88 files. For a
  contract, find dependents with:

      grep -rl '@import("<stem>")' src/

  This is the highest blast-radius dependency question in the repo. Getting it wrong silently
  under-scopes the review.
- **`get_affected_flows_tool` returns 0** for files that demonstrably sit on `onKey`,
  `conSpawnApp` and `spawnBootLayout`. Do not build on it.

Also: new and untracked files are absent until `build_or_update_graph_tool` runs, and hub/bridge
rankings are polluted by test fan-out (several top hubs are test functions).

## Structure questions the graph cannot answer

Read these instead — they are the manifests, and they are enforced:

- `scripts/tests/layering.sh` — `GROUP_EDGES` (legal edges), `EDGE_DEBT`, `GROUP_CYCLE_DEBT`,
  `MODULE_CHANNEL` (named modules), `IFACE_DISPOSITION` (which contracts a module may bind),
  `klevel()` (blast radius per group), the size and god-module allowlists.
- `process.md` — blast-radius obligations and the 56-criteria review rubric.
- `specs/README.md` — the requirement index; IDs are `PREFIX-NNN` and are never reused.
