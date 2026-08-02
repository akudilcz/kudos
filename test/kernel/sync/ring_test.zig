//! Host tests of src/kernel/sync/ring.zig.

const std = @import("std");
const ring = @import("ring");
const Ring = ring.Ring;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "empty ring: pop is null, isEmpty true" {
    var r = Ring(u32, 4){};
    try expect(r.isEmpty());
    try expect(r.pop() == null);
}

test "push then pop preserves FIFO order" {
    var r = Ring(u32, 4){};
    try expect(r.push(10));
    try expect(r.push(20));
    try expect(r.push(30));
    try expect(!r.isEmpty());
    try expectEqual(@as(u32, 10), r.pop().?);
    try expectEqual(@as(u32, 20), r.pop().?);
    try expectEqual(@as(u32, 30), r.pop().?);
    try expect(r.pop() == null);
}

test "full ring: push returns false, no overwrite" {
    var r = Ring(u8, 4){};
    try expect(r.push(1));
    try expect(r.push(2));
    try expect(r.push(3));
    try expect(r.push(4)); // now full (cap=4)
    try expect(!r.push(5)); // rejected, not overwritten
    // The four originals survive in order.
    try expectEqual(@as(u8, 1), r.pop().?);
    try expectEqual(@as(u8, 2), r.pop().?);
    // A slot freed → one more push fits.
    try expect(r.push(6));
    try expectEqual(@as(u8, 3), r.pop().?);
    try expectEqual(@as(u8, 4), r.pop().?);
    try expectEqual(@as(u8, 6), r.pop().?);
}

test "lastMut: null on empty, points to newest, mutation observed by pop" {
    var r = Ring(u32, 4){};
    try expect(r.lastMut() == null); // empty
    try expect(r.push(10));
    try expect(r.push(20));
    try expectEqual(@as(u32, 20), r.lastMut().?.*); // newest is head-1
    r.lastMut().?.* = 99; // mutate in place
    try expectEqual(@as(u32, 10), r.pop().?); // older slot untouched
    try expectEqual(@as(u32, 99), r.pop().?); // mutation survived to the consumer
    try expect(r.lastMut() == null); // drained → empty again
}

test "index wraparound: many push/pop cycles keep FIFO across the mask boundary" {
    var r = Ring(usize, 4){};
    var next_push: usize = 0;
    var next_pop: usize = 0;
    var round: usize = 0;
    while (round < 100) : (round += 1) {
        // Fill, then drain — this walks head/tail well past cap and around MASK.
        while (r.push(next_push)) next_push += 1;
        while (r.pop()) |v| {
            try expectEqual(next_pop, v);
            next_pop += 1;
        }
    }
    try expectEqual(next_push, next_pop); // nothing lost or duplicated
}
