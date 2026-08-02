//! Host tests of src/kernel/debug/tracering.zig — the lock-free trace ring's
//! reservation algebra. The property under test is the one the trace bus's
//! spinlock cannot provide: concurrent writers never wait on each other, and a
//! writer that DIES mid-record costs its own bytes and nothing else.

const std = @import("std");
const tracering = @import("tracering");

const CAP: usize = 64;

/// A ring exercised the way the kernel would: reserve, then copy. Reservation
/// and copy are deliberately separate calls so a test can interleave two
/// writers — which is exactly the race the spinlock used to forbid.
const Ring = struct {
    buf: [CAP]u8 = @splat(0),
    head: u64 = 0,

    fn reserve(self: *Ring, n: usize) tracering.Reservation {
        return tracering.reserve(&self.head, n);
    }
    fn commit(self: *Ring, r: tracering.Reservation, bytes: []const u8) void {
        const sp = tracering.spans(CAP, r);
        @memcpy(self.buf[sp[0].off..][0..sp[0].len], bytes[0..sp[0].len]);
        @memcpy(self.buf[sp[1].off..][0..sp[1].len], bytes[sp[0].len..][0..sp[1].len]);
    }
    /// The readable window, oldest byte first.
    fn read(self: *const Ring, out: []u8) []u8 {
        const w = tracering.window(CAP, self.head);
        for (0..w.count) |i| out[i] = self.buf[(w.start + i) % CAP];
        return out[0..w.count];
    }
};

test "two writers interleaved claim disjoint storage — neither waits, neither overwrites" {
    var r: Ring = .{};
    // BOTH reserve before EITHER copies: the interleaving a lock exists to
    // prevent, and the one this algebra must survive.
    const a = r.reserve(5);
    const b = r.reserve(5);
    r.commit(b, "BBBBB"); // the second writer finishes first
    r.commit(a, "AAAAA");

    var out: [CAP]u8 = undefined;
    // Stream order follows RESERVATION order, not completion order, so the
    // trace reads back in the order the calls were made.
    try std.testing.expectEqualStrings("AAAAABBBBB", r.read(&out));
}

test "a writer that dies mid-record leaves a hole, not a wedge" {
    var r: Ring = .{};
    r.commit(r.reserve(4), "one ");
    const doomed = r.reserve(4); // reserved, then the core faults — never commits
    _ = doomed;
    r.commit(r.reserve(4), "two ");

    var out: [CAP]u8 = undefined;
    const got = r.read(&out);
    // The dead writer's four bytes are whatever storage held; every OTHER
    // writer's bytes are exactly where they belong, and the later writer was
    // not blocked for an instant.
    try std.testing.expectEqual(@as(usize, 12), got.len);
    try std.testing.expectEqualStrings("one ", got[0..4]);
    try std.testing.expectEqualStrings("two ", got[8..12]);
}

test "a record straddling the wrap is split into two spans that reassemble" {
    var r: Ring = .{};
    r.head = CAP - 3; // next claim starts three bytes before the end
    const rs = r.reserve(6);
    const sp = tracering.spans(CAP, rs);
    try std.testing.expectEqual(@as(usize, 3), sp[0].len); // to the end
    try std.testing.expectEqual(@as(usize, 3), sp[1].len); // and around
    try std.testing.expectEqual(@as(usize, 0), sp[1].off);
    r.commit(rs, "abcdef");
    try std.testing.expectEqualStrings("abc", r.buf[CAP - 3 ..]);
    try std.testing.expectEqualStrings("def", r.buf[0..3]);
}

test "the readable window is the newest cap bytes, oldest first" {
    var r: Ring = .{};
    // Under-full: everything written is readable.
    r.commit(r.reserve(3), "abc");
    var out: [CAP]u8 = undefined;
    try std.testing.expectEqualStrings("abc", r.read(&out));

    // Over-full: the oldest bytes are gone, the newest cap remain in order.
    var i: usize = 0;
    while (i < CAP) : (i += 1) r.commit(r.reserve(1), "z");
    const w = tracering.window(CAP, r.head);
    try std.testing.expectEqual(CAP, w.count);
    const got = r.read(&out);
    try std.testing.expectEqual(CAP, got.len);
    for (got) |c| try std.testing.expectEqual(@as(u8, 'z'), c);
}

test "a reservation longer than the ring keeps its newest bytes, never overruns" {
    // A caller can hand the bus more than the whole ring; the span must still
    // be bounded by the storage, or the copy walks off the end of BSS.
    const sp = tracering.spans(CAP, .{ .pos = 7, .len = CAP * 3 });
    try std.testing.expectEqual(CAP, sp[0].len);
    try std.testing.expectEqual(@as(usize, 0), sp[0].off);
    try std.testing.expectEqual(@as(usize, 0), sp[1].len);
}

test "a span's intactness is answerable — a recycled claim reports itself stale" {
    // The honest half of the trade: a slow writer CAN have its storage reused,
    // and a caller that must not lose bytes can ask rather than assume.
    try std.testing.expect(tracering.intact(CAP, 10, 0)); // 10 bytes since: fine
    try std.testing.expect(tracering.intact(CAP, CAP, 0)); // exactly a lap: still
    try std.testing.expect(!tracering.intact(CAP, CAP + 1, 0)); // lapped: gone
}

test "an empty reservation claims nothing and moves no index" {
    var r: Ring = .{};
    const rs = r.reserve(0);
    try std.testing.expectEqual(@as(u64, 0), r.head);
    const sp = tracering.spans(CAP, rs);
    try std.testing.expectEqual(@as(usize, 0), sp[0].len);
    try std.testing.expectEqual(@as(usize, 0), sp[1].len);
}
