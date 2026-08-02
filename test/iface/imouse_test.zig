//! Host tests of src/iface/imouse.zig.

const std = @import("std");
const imouse = @import("imouse");
const MOUSE_RING_DEPTH = imouse.MOUSE_RING_DEPTH;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const inject = imouse.inject;
const poll = imouse.poll;

/// Reset the module's ring + drop counter so each test starts clean.
fn testReset() void {
    while (poll()) |_| {}
    imouse.dropped_events = 0;
}

test "same-button relative deltas merge into one summed event" {
    testReset();
    inject(.{ .dx = 3, .dy = 1, .buttons = 0 });
    inject(.{ .dx = 4, .dy = -2, .buttons = 0 });
    inject(.{ .dx = -1, .dy = 5, .buttons = 0 });
    const ev = poll().?;
    try expectEqual(@as(i32, 6), ev.dx); // 3+4-1
    try expectEqual(@as(i32, 4), ev.dy); // 1-2+5
    try expect(ev.abs == null);
    try expect(poll() == null); // collapsed to a single event
    try expectEqual(@as(u64, 0), imouse.dropped_events);
}

test "no merge across a button edge (0->1)" {
    testReset();
    inject(.{ .dx = 2, .dy = 2, .buttons = 0 });
    inject(.{ .dx = 3, .dy = 3, .buttons = 1 }); // press: new event, edge preserved
    const a = poll().?;
    try expectEqual(@as(u8, 0), a.buttons);
    try expectEqual(@as(i32, 2), a.dx);
    const b = poll().?;
    try expectEqual(@as(u8, 1), b.buttons);
    try expectEqual(@as(i32, 3), b.dx);
    try expect(poll() == null);
}

test "no merge across a full press-release (0->1->0) — three distinct events" {
    testReset();
    inject(.{ .dx = 1, .dy = 0, .buttons = 0 });
    inject(.{ .dx = 1, .dy = 0, .buttons = 1 }); // press edge
    inject(.{ .dx = 1, .dy = 0, .buttons = 0 }); // release edge
    try expectEqual(@as(u8, 0), poll().?.buttons);
    try expectEqual(@as(u8, 1), poll().?.buttons);
    try expectEqual(@as(u8, 0), poll().?.buttons);
    try expect(poll() == null);
}

test "absolute events never merge (abs->abs, and relative->abs stay separate)" {
    testReset();
    inject(.{ .dx = 5, .dy = 5, .buttons = 0 }); // relative
    inject(.{ .dx = 0, .dy = 0, .buttons = 0, .abs = .{ .x = 100, .y = 100 } });
    inject(.{ .dx = 0, .dy = 0, .buttons = 0, .abs = .{ .x = 200, .y = 200 } });
    const rel = poll().?;
    try expect(rel.abs == null);
    try expectEqual(@as(i32, 5), rel.dx);
    const abs1 = poll().?;
    try expectEqual(@as(i32, 100), abs1.abs.?.x); // not summed into abs2
    const abs2 = poll().?;
    try expectEqual(@as(i32, 200), abs2.abs.?.x);
    try expect(poll() == null);
}

test "relative -> abs -> relative yields three events (trailing rel does not fold into abs)" {
    testReset();
    inject(.{ .dx = 1, .dy = 1, .buttons = 0 });
    inject(.{ .dx = 0, .dy = 0, .buttons = 0, .abs = .{ .x = 10, .y = 10 } });
    inject(.{ .dx = 2, .dy = 2, .buttons = 0 });
    try expect(poll().?.abs == null); // rel
    try expect(poll().?.abs != null); // abs
    try expect(poll().?.abs == null); // rel again, own slot
    try expect(poll() == null);
}

test "true overflow of distinct button edges: dropped counted, oldest survive in order" {
    testReset();
    // Alternate buttons so no two adjacent events can merge — every push is a
    // distinct slot. The last-queued event has buttons == (127 & 1) == 1.
    var i: u32 = 0;
    while (i < MOUSE_RING_DEPTH) : (i += 1) {
        inject(.{ .dx = @intCast(i), .dy = 0, .buttons = @intCast(i & 1) });
    }
    // Overflow pushes must carry a DIFFERENT button state from the newest queued
    // slot (buttons=1), or coalescing would legitimately fold them in rather than
    // drop. buttons=2 (middle) can neither merge nor fit → two true drops.
    inject(.{ .dx = 1000, .dy = 0, .buttons = 2 }); // rejected
    inject(.{ .dx = 1001, .dy = 0, .buttons = 2 }); // rejected (still no free slot)
    try expectEqual(@as(u64, 2), imouse.dropped_events);
    // The oldest MOUSE_RING_DEPTH events survive in order.
    var n: u32 = 0;
    while (poll()) |ev| : (n += 1) {
        try expectEqual(@as(i32, @intCast(n)), ev.dx);
    }
    try expectEqual(@as(u32, MOUSE_RING_DEPTH), n);
}

test "coalescing avoids overflow: 10000 same-button relatives -> one summed event" {
    testReset();
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        inject(.{ .dx = 1, .dy = 2, .buttons = 0 });
    }
    try expectEqual(@as(u64, 0), imouse.dropped_events);
    const ev = poll().?;
    try expectEqual(@as(i32, 10_000), ev.dx);
    try expectEqual(@as(i32, 20_000), ev.dy);
    try expect(poll() == null);
}

test "single inject/poll: minimal case on an empty ring, fields unmodified" {
    testReset();
    inject(.{ .dx = 7, .dy = -3, .buttons = 1, .t_tsc = 42 });
    const ev = poll().?;
    try expectEqual(@as(i32, 7), ev.dx);
    try expectEqual(@as(i32, -3), ev.dy);
    try expectEqual(@as(u8, 1), ev.buttons);
    try expectEqual(@as(u64, 42), ev.t_tsc);
    try expect(ev.abs == null);
    try expect(poll() == null);
}

test "coalesced merge keeps the NEWEST t_tsc, not the first or a stale zero" {
    testReset();
    inject(.{ .dx = 1, .dy = 0, .buttons = 0, .t_tsc = 100 });
    inject(.{ .dx = 1, .dy = 0, .buttons = 0, .t_tsc = 200 });
    inject(.{ .dx = 1, .dy = 0, .buttons = 0, .t_tsc = 300 });
    const ev = poll().?;
    try expectEqual(@as(i32, 3), ev.dx); // sanity: still merged as one event
    // The acceleration curve's velocity computation needs the coalesced window's
    // TRUE elapsed time, so the merge must overwrite with the newest sample's
    // timestamp ("Pointer acceleration"), not keep the first.
    try expectEqual(@as(u64, 300), ev.t_tsc);
    try expect(poll() == null);
}

test "dropped_events accumulates correctly across two separate overflow episodes" {
    testReset();
    // First overflow episode: fill the ring with non-mergeable edges, then overflow it.
    var i: u32 = 0;
    while (i < MOUSE_RING_DEPTH) : (i += 1) {
        inject(.{ .dx = @intCast(i), .dy = 0, .buttons = @intCast(i & 1) });
    }
    inject(.{ .dx = 1000, .dy = 0, .buttons = 2 }); // rejected: 1st drop
    try expectEqual(@as(u64, 1), imouse.dropped_events);

    // Drain the ring fully (no testReset — dropped_events must NOT be cleared by draining).
    while (poll()) |_| {}
    try expectEqual(@as(u64, 1), imouse.dropped_events);

    // Second overflow episode on the now-empty ring: fill again, then overflow again.
    i = 0;
    while (i < MOUSE_RING_DEPTH) : (i += 1) {
        inject(.{ .dx = @intCast(i), .dy = 0, .buttons = @intCast(i & 1) });
    }
    inject(.{ .dx = 2000, .dy = 0, .buttons = 2 }); // rejected: 2nd drop
    inject(.{ .dx = 2001, .dy = 0, .buttons = 2 }); // rejected: 3rd drop
    // The counter accumulates across episodes rather than resetting: 1 (first
    // episode) + 2 (second episode) = 3, proving it is a persistent monotonic
    // counter as documented, not scoped to a single fill cycle.
    try expectEqual(@as(u64, 3), imouse.dropped_events);
    var n: u32 = 0;
    while (poll()) |_| : (n += 1) {}
    try expectEqual(@as(u32, MOUSE_RING_DEPTH), n);
}
