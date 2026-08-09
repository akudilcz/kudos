//! Host tests of stack-overflow detection (spec MEM-011).
//!
//! Kernel task stacks have no guard page, so an overflow does not fault — it
//! writes into whatever the allocator put below and surfaces later, somewhere
//! else, as a wild jump. The canary is what makes it attributable instead. These
//! tests exist because a detector that silently never fires is worse than none:
//! it reads like coverage.

const std = @import("std");
const stackcanary = @import("testroot").kernel.stackcanary;

const expect = std.testing.expect;

test "an armed stack reads intact; growing past the bottom does not (MEM-011)" {
    var stack: [256]u8 = @splat(0xAA);
    stackcanary.arm(&stack);
    try expect(stackcanary.intact(&stack));

    // A task running off the low end writes THROUGH the canary — that is the
    // whole failure, and the byte it happens to write is not ours to choose.
    stack[0] = 0x00;
    try expect(!stackcanary.intact(&stack));
}

test "any byte of the canary being disturbed is caught (MEM-011)" {
    // An overflow does not necessarily land on byte 0: a frame can begin part
    // way through the canary. Checking only the first byte would miss exactly
    // the overflows that are a few bytes deep — the near misses, which are the
    // ones a growing frame produces first.
    var i: usize = 0;
    while (i < stackcanary.BYTES) : (i += 1) {
        var stack: [64]u8 = @splat(0);
        stackcanary.arm(&stack);
        try expect(stackcanary.intact(&stack));
        stack[i] ^= 0xFF;
        try expect(!stackcanary.intact(&stack));
    }
}

test "re-arming after a report lets the NEXT overflow be seen (MEM-011)" {
    // The scheduler re-arms after reporting, so a second overflow is a second
    // report rather than the first one echoing on every switch for the life of
    // the machine — which would bury whatever followed it.
    var stack: [64]u8 = @splat(0);
    stackcanary.arm(&stack);
    stack[3] = 0x11;
    try expect(!stackcanary.intact(&stack));

    stackcanary.arm(&stack);
    try expect(stackcanary.intact(&stack));
    stack[3] = 0x22;
    try expect(!stackcanary.intact(&stack));
}

test "a stack too small to hold a canary reports intact, not broken (MEM-011)" {
    // Inventing a failure here would raise a false alarm on every single switch
    // — the loudest possible way to be useless.
    var tiny: [4]u8 = @splat(0);
    stackcanary.arm(&tiny);
    try expect(stackcanary.intact(&tiny));
    try expect(stackcanary.intact(&.{}));
}
