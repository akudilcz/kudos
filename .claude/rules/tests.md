---
paths:
  - "test/**"
  - "src/**/*_test.zig"
  - "scripts/tests/**"
---

# Tests

**All test code lives in the test tree** — no inline test blocks in production files; a test
imports its module through the public surface production callers use; helpers and fakes stay
in the test file, never `pub` bait. Pure logic lives in a host-testable module, never
entangled with the IO edge — the host-test list IS the list of pure modules. A test that
cannot fail is a comment: mutation-test every regression test (reintroduce the bug, confirm
RED, restore).
