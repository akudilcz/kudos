---
paths:
  - "src/**"
  - "test/**"
  - "scripts/**"
---

# Layout: where a file goes, and what it may be called

`scripts/tests/layering.sh` enforces these — run it for the current state, read its comments
for why. A rule that lives only here is a rule that comes back.

- **`src/` root holds module roots and NOTHING else** (`*_root.zig`): only files that must
  resolve imports across every group belong there. Anything else escaped its group.
- **One host-test root**, `src/test_root.zig`: one line per host-testable file, namespaced by
  group. Never a second shim — the count is what creeps.
- **The apex is a group**: code that knows every group (the steady-state loop) lives in
  `boot/`. K1 — a defect there stops the machine.
- **Top-level groups are a closed set**, declared in the gate with a K-level.
- **`test/` mirrors `src/`'s groups**, plus `support/` for shared fakes. A test is `*_test`,
  `*_sim`, `*_conformance` or `*_shot`; new kinds go in the gate. Nothing in `src/` wears a
  test suffix.
- **Scripts: one per role, with SUBCOMMANDS** — never a file per variant, which is how 80
  accumulate. Unused is deleted; `scripts/README.md` maps role and caller.
