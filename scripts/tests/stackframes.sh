#!/usr/bin/env bash
# The kernel stack-frame budget gate.
#
# Kernel-heap task stacks are sched.STACK_SIZE (128 KiB) with no guard page
# (session arenas DO carry one — sessionspace punches it, MEM-010): a frame
# that outgrows the stack does not fault, it silently initializes its locals on
# top of whatever heap neighbor sits below — a live Task struct, another task's
# stack, an allocator header. One oversized local (a compression window) or one
# large struct returned by value is enough. The compiler fixes each frame's
# reservation at build time, so a single oversized frame is detectable statically —
# that is what this gate bounds. It does not bound total call-chain depth or
# recursion, which can overflow the stack with every individual frame in budget.
#
# RULE: no function in a kernel image may reserve more than BUDGET_BYTES of
# stack in one frame. Known pre-existing violators live in stackdebt.txt with a
# per-function ceiling: they may only shrink (fix on touch), never grow, and a
# fixed one must have its debt line deleted. A NEW function over budget fails
# the gate outright.
#
# Usage: stackframes.sh [elf ...]   (default: builds and scans both kernels)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUDGET_BYTES=16384
DEBT="scripts/tests/stackdebt.txt"

if [ "$#" -gt 0 ]; then
    ELFS=("$@")
else
    zig build iso iso-smp -p build --cache-dir build/.zig-cache
    ELFS=(build/bin/kudos build/bin/kudos-smp)
fi

python3 scripts/tests/stackframes.py "$BUDGET_BYTES" "$DEBT" "${ELFS[@]}"
echo "  ✓ no scanned frame reserves more than ${BUDGET_BYTES} bytes (debt-listed frames are over budget and shrinking)"
