//! Host tests of src/drivers/gpu/present/tri_ring.zig.

const std = @import("std");
const tri_ring = @import("tri_ring");
const TriRing = tri_ring.TriRing;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// The boot-time role assignment present.zig uses (any starting permutation of
/// the 3 roles is correct; ring[0] = the modeset's live surface).
const BOOT = TriRing{ .scanout = 0, .pending = 1, .compose = 2 };

/// The rotation invariant: the three roles always hold distinct ring indices.
fn isPermutation(r: TriRing) bool {
    var seen = [_]bool{ false, false, false };
    seen[r.compose] = true;
    seen[r.pending] = true;
    seen[r.scanout] = true;
    return seen[0] and seen[1] and seen[2];
}

test "roles are always a permutation of {0,1,2} across many rotations" {
    var r = BOOT;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try expect(isPermutation(r));
        r.rotate();
    }
}

test "rotate maps compose→pending→scanout→compose" {
    var r = BOOT;
    r.rotate();
    try expectEqual(BOOT.compose, r.pending); // the just-armed buffer is now pending
    try expectEqual(BOOT.pending, r.scanout); // the old pending has latched → scanout
    try expectEqual(BOOT.scanout, r.compose); // the old scanout is freed → compose
}

test "scanout handoff: new compose is never the old pending or old scanout roles' buffers in flight (PERF-005: tear-free by ring ownership)" {
    // The invariant the always-open pump gate rests on: the buffer we are about to
    // compose is the one that was ON scanout before the rotation — i.e. the buffer
    // whose replacement (old pending) latches at the vblank waitFlipLatched holds
    // for. It is never the buffer just armed (old compose→new pending) and never
    // the buffer now displayed (old pending→new scanout).
    var r = BOOT;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const before = r;
        r.rotate();
        try expect(r.compose != before.pending); // not the flip that just latched onto the panel
        try expect(r.compose != before.compose); // not the flip armed this frame (in flight)
        try expectEqual(before.scanout, r.compose); // exactly the surface being replaced on-panel
    }
}

test "3 rotations = identity" {
    var r = BOOT;
    r.rotate();
    r.rotate();
    r.rotate();
    try expectEqual(BOOT, r);
}

test "rotation is role-consistent from any starting permutation" {
    // Any of the 6 permutations is a legal boot assignment (present.zig's comment);
    // the rotation must preserve permutation-ness and the role handoff for all.
    const starts = [_]TriRing{
        .{ .scanout = 0, .pending = 1, .compose = 2 },
        .{ .scanout = 0, .pending = 2, .compose = 1 },
        .{ .scanout = 1, .pending = 0, .compose = 2 },
        .{ .scanout = 1, .pending = 2, .compose = 0 },
        .{ .scanout = 2, .pending = 0, .compose = 1 },
        .{ .scanout = 2, .pending = 1, .compose = 0 },
    };
    for (starts) |s| {
        var r = s;
        r.rotate();
        try expect(isPermutation(r));
        try expectEqual(s.compose, r.pending);
        try expectEqual(s.pending, r.scanout);
        try expectEqual(s.scanout, r.compose);
    }
}
