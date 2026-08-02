//! Host tests of src/kernel/memory/heap.zig.

const std = @import("std");
const heap = @import("testroot").kernel.heap;
const FreeListHeap = heap.FreeListHeap;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

// These drive FreeListHeap over a stack buffer — the exact code the kernel
// runs over the PMM arena.

/// A small test arena. align(16) so block bases stay pointer-aligned exactly as
/// the page-aligned kernel arena guarantees.
const TestArena = struct {
    buf: [4096]u8 align(16) = undefined,
    fn heap(self: *TestArena) FreeListHeap {
        return FreeListHeap.seed(@intFromPtr(&self.buf), self.buf.len);
    }
};

/// Recover {base,total} of a live test allocation from its payload pointer —
/// same header layout blockOf reads (blockOf itself is host-analyzable too, but
/// keeping the test reader explicit documents the on-disk layout under test).
fn hdrOf(p: [*]u8) struct { base: usize, total: usize } {
    const base = @as(*usize, @ptrFromInt(@intFromPtr(p) - 8)).*;
    return .{ .base = base, .total = @as(*usize, @ptrFromInt(base)).* };
}

test "seed: whole arena is one free block; invariants hold" {
    var ta = TestArena{};
    var h = ta.heap();
    try h.checkInvariants();
    try expectEqual(ta.buf.len, h.free_list.?.size);
    try expect(h.free_list.?.next == null);
}

test "alloc/free/coalesce: only truly adjacent blocks merge" {
    var ta = TestArena{};
    var h = ta.heap();
    const a = h.allocImpl(64, 8).?;
    const b = h.allocImpl(64, 8).?;
    const c = h.allocImpl(64, 8).?;
    try h.checkInvariants();

    // Free a and c: NOT adjacent (b is live between them) — must stay separate
    // blocks (plus the arena tail after c, which c's free DOES touch and merge).
    const ha = hdrOf(a);
    const hc = hdrOf(c);
    try h.insertFree(ha.base, ha.total);
    try h.insertFree(hc.base, hc.total);
    try h.checkInvariants();
    // Two blocks: [a] and [c..arena end] — a must NOT have merged across b.
    const first = h.free_list.?;
    try expectEqual(ha.base, @intFromPtr(first));
    try expectEqual(ha.total, first.size); // exactly a, nothing more
    const second = first.next.?;
    try expectEqual(hc.base, @intFromPtr(second));
    try expect(second.next == null); // c merged forward with the arena tail

    // Free b: adjacent to both — everything collapses back to one full block.
    const hb = hdrOf(b);
    try h.insertFree(hb.base, hb.total);
    try h.checkInvariants();
    try expectEqual(ta.buf.len, h.free_list.?.size);
    try expect(h.free_list.?.next == null);
}

test "double free is detected loudly (error, kernel panics on it)" {
    var ta = TestArena{};
    var h = ta.heap();
    const p = h.allocImpl(64, 8).?;
    const hp = hdrOf(p);
    try h.insertFree(hp.base, hp.total);
    try h.checkInvariants();
    // Second free of the same block: its base now sits inside (at the start of)
    // a free block, so the prev-overlap guard fires.
    try expectError(error.OverlapPrev, h.insertFree(hp.base, hp.total));
    try h.checkInvariants(); // guard rejected BEFORE mutating the list
}

test "overlapping free is rejected in both directions" {
    var ta = TestArena{};
    var h = ta.heap();
    const a = h.allocImpl(64, 8).?;
    _ = h.allocImpl(64, 8).?; // keep a live block after a
    const ha = hdrOf(a);

    // Overlap with next: a span reaching INTO the free arena tail.
    // (a is at the arena start, so the free tail is the `cur` after it.)
    try expectError(error.OverlapNext, h.insertFree(ha.base, ta.buf.len));
    try h.checkInvariants();

    // Overlap with prev: free a legitimately, then free a range starting inside it.
    try h.insertFree(ha.base, ha.total);
    try expectError(error.OverlapPrev, h.insertFree(ha.base + 16, 32));
    try h.checkInvariants();
}

test "first-fit split behavior at the MIN_SPLIT boundary" {
    var ta = TestArena{};
    var h = ta.heap();
    const arena = ta.buf.len;

    // Leftover exactly MIN_SPLIT: block splits, remainder is a MIN_SPLIT free block.
    // used = HEADER + n (n a 16-multiple, a=8 keeps payload at base+HEADER).
    {
        const n = arena - FreeListHeap.MIN_SPLIT - FreeListHeap.HEADER;
        const p = h.allocImpl(n, 8).?;
        try h.checkInvariants();
        try expectEqual(arena - FreeListHeap.MIN_SPLIT, hdrOf(p).total);
        try expectEqual(@as(usize, FreeListHeap.MIN_SPLIT), h.free_list.?.size);
        const hp = hdrOf(p);
        try h.insertFree(hp.base, hp.total);
        try h.checkInvariants();
    }

    // Leftover one 16-step below MIN_SPLIT: whole block consumed (no fragment),
    // and the stored total reflects the FULL block so free returns all of it.
    {
        const n = arena - (FreeListHeap.MIN_SPLIT - 16) - FreeListHeap.HEADER;
        const p = h.allocImpl(n, 8).?;
        try h.checkInvariants();
        try expectEqual(arena, hdrOf(p).total); // consumed the whole block
        try expect(h.free_list == null);
        const hp = hdrOf(p);
        try h.insertFree(hp.base, hp.total);
        try h.checkInvariants();
        try expectEqual(arena, h.free_list.?.size);
    }
}

test "size overflow is rejected cleanly (null), not wrapped" {
    var ta = TestArena{};
    var h = ta.heap();
    // Would wrap `used` to a tiny value without the arena cap.
    try expect(h.allocImpl(std.math.maxInt(usize) - 8, 8) == null);
    try expect(h.allocImpl(ta.buf.len + 1, 8) == null); // arena cap itself
    try h.checkInvariants();
    try expectEqual(ta.buf.len, h.free_list.?.size); // nothing consumed
}

test "alignment guarantees: payload honors requested power-of-two alignment" {
    var ta = TestArena{};
    var h = ta.heap();
    inline for ([_]usize{ 8, 16, 32, 64, 128 }) |a| {
        const p = h.allocImpl(24, a).?;
        try expectEqual(@as(usize, 0), @intFromPtr(p) % a);
        try h.checkInvariants();
    }
}

test "exhaustion returns null and the heap stays intact" {
    var ta = TestArena{};
    var h = ta.heap();
    var ptrs: [64]?[*]u8 = @splat(null);
    var count: usize = 0;
    while (count < ptrs.len) : (count += 1) {
        ptrs[count] = h.allocImpl(256, 8) orelse break;
        try h.checkInvariants();
    }
    try expect(count > 0); // some allocations succeeded before exhaustion
    try expect(h.allocImpl(256, 8) == null); // exhausted: clean null
    try h.checkInvariants(); // ... and no corruption
    // Free everything (out of order) — must coalesce back to one full block.
    var i = count;
    while (i > 0) {
        i -= 1;
        const idx = if (i % 2 == 0) i else count - 1 - i / 2; // mixed order
        if (ptrs[idx]) |p| {
            ptrs[idx] = null;
            const hp = hdrOf(p);
            try h.insertFree(hp.base, hp.total);
            try h.checkInvariants();
        }
    }
    // Any survivors of the mixed-order walk.
    for (&ptrs) |*slot| if (slot.*) |p| {
        slot.* = null;
        const hp = hdrOf(p);
        try h.insertFree(hp.base, hp.total);
        try h.checkInvariants();
    };
    try expectEqual(ta.buf.len, h.free_list.?.size);
    try expect(h.free_list.?.next == null);
}

test "interleaved alloc/free stress: invariants + disjointness + conservation" {
    var ta = TestArena{};
    var h = ta.heap();
    const arena_base = @intFromPtr(&ta.buf);

    var prng = std.Random.DefaultPrng.init(0x6b75646f73); // fixed seed: deterministic run
    const rnd = prng.random();

    const Live = struct { p: [*]u8, n: usize };
    var live: [48]?Live = @splat(null);
    var nlive: usize = 0;

    var op: usize = 0;
    while (op < 2000) : (op += 1) {
        const do_free = nlive > 0 and (nlive >= live.len or rnd.boolean());
        if (do_free) {
            // Free a random live allocation.
            var pick = rnd.uintLessThan(usize, nlive);
            for (&live) |*slot| {
                if (slot.*) |l| {
                    if (pick == 0) {
                        const hp = hdrOf(l.p);
                        try h.insertFree(hp.base, hp.total);
                        slot.* = null;
                        nlive -= 1;
                        break;
                    }
                    pick -= 1;
                }
            }
        } else {
            const n = rnd.intRangeAtMost(usize, 1, 200);
            const a = @as(usize, 8) << rnd.uintLessThan(u3, 4); // 8..64
            if (h.allocImpl(n, a)) |p| {
                try expectEqual(@as(usize, 0), @intFromPtr(p) % a);
                for (&live) |*slot| if (slot.* == null) {
                    slot.* = .{ .p = p, .n = n };
                    nlive += 1;
                    break;
                };
            }
        }

        // Free-list invariants after EVERY op.
        try h.checkInvariants();

        // Live payloads are pairwise disjoint and inside the arena; the sum of
        // free block sizes + live block totals is exactly the arena (conservation).
        var total: usize = 0;
        var cur = h.free_list;
        while (cur) |c| : (cur = c.next) total += c.size;
        for (&live, 0..) |sa, ia| if (sa) |la| {
            const s0 = @intFromPtr(la.p);
            try expect(s0 >= arena_base and s0 + la.n <= arena_base + ta.buf.len);
            total += hdrOf(la.p).total;
            for (live[ia + 1 ..]) |sb| if (sb) |lb| {
                const s1 = @intFromPtr(lb.p);
                try expect(s0 + la.n <= s1 or s1 + lb.n <= s0);
            };
        };
        try expectEqual(ta.buf.len, total);
    }
}

test "stats: a fresh arena is one free block, all of it available" {
    var arena = TestArena{};
    var h = arena.heap();
    const s = h.stats();
    try expectEqual(arena.buf.len, s.arena);
    try expectEqual(arena.buf.len, s.free);
    try expectEqual(@as(usize, 0), s.used);
    try expectEqual(arena.buf.len, s.largest);
    try expectEqual(@as(usize, 1), s.free_blocks);
}

test "stats: an allocation moves bytes from free to used, headers included" {
    var arena = TestArena{};
    var h = arena.heap();
    const p = h.allocImpl(256, 8) orelse return error.TestUnexpectedResult;
    const s = h.stats();
    try expect(s.used >= 256); // payload plus its header
    try expectEqual(arena.buf.len, s.free + s.used);
    try expect(s.free < arena.buf.len);
    _ = p;
}

test "stats: fragmentation shows as many blocks with a small largest" {
    var arena = TestArena{};
    var h = arena.heap();
    // Three live allocations with gaps freed between them: the free list can
    // hold plenty of bytes and still not satisfy a large request.
    const a = h.allocImpl(512, 8) orelse return error.TestUnexpectedResult;
    const b = h.allocImpl(512, 8) orelse return error.TestUnexpectedResult;
    const c = h.allocImpl(512, 8) orelse return error.TestUnexpectedResult;
    const d = h.allocImpl(512, 8) orelse return error.TestUnexpectedResult;
    const ha = hdrOf(a);
    const hc = hdrOf(c);
    try h.insertFree(ha.base, ha.total);
    try h.insertFree(hc.base, hc.total);
    const s = h.stats();
    try expect(s.free_blocks >= 3); // the two holes plus the tail
    try expect(s.largest < s.free); // no single block holds all the free bytes
    _ = b;
    _ = d;
}

test "stats: freeing everything returns the arena to one whole block" {
    var arena = TestArena{};
    var h = arena.heap();
    const p = h.allocImpl(1024, 8) orelse return error.TestUnexpectedResult;
    const hp = hdrOf(p);
    try h.insertFree(hp.base, hp.total);
    const s = h.stats();
    try expectEqual(@as(usize, 1), s.free_blocks);
    try expectEqual(arena.buf.len, s.largest);
    try expectEqual(@as(usize, 0), s.used);
}
