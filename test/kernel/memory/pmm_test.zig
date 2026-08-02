//! Host tests of src/kernel/memory/pmm.zig.

const std = @import("std");
const pmm = @import("testroot").kernel.pmm;
const FrameBitmap = pmm.FrameBitmap;
const FS = pmm.FRAME_SIZE;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// These drive FrameBitmap over a few bytes of storage with a hand-built memory
// map (no multiboot2 needed) — the exact code the kernel runs over the 2 MiB
// .bss planes.

/// 32-frame test bitmap (4 bytes per plane), all frames initially used.
const TestPmm = struct {
    bm: [4]u8 = undefined,
    rs: [4]u8 = undefined,
    fn init(self: *TestPmm) FrameBitmap {
        return FrameBitmap.init(&self.bm, &self.rs);
    }
};

/// 256-frame test bitmap (32 bytes per plane) — big enough to exercise the
/// byte-skip path in `nextFree` (multiple whole 0xFF bytes to jump over), not
/// just the single-byte TestPmm above.
const BigTestPmm = struct {
    bm: [32]u8 = undefined,
    rs: [32]u8 = undefined,
    fn init(self: *BigTestPmm) FrameBitmap {
        return FrameBitmap.init(&self.bm, &self.rs);
    }
};

test "init: everything used, nothing reserved, counters zero" {
    var tp = TestPmm{};
    var s = tp.init();
    try expectEqual(@as(usize, 32), s.maxFrames());
    try expectEqual(@as(usize, 0), s.free_frames);
    try expectEqual(@as(usize, 0), s.avail_frames);
    var f: usize = 0;
    while (f < 32) : (f += 1) {
        try expect(s.isUsed(f));
        try expect(!s.isReserved(f));
    }
}

test "freeAvailableRange: whole frames only, limit respected, overlap deduped" {
    var tp = TestPmm{};
    var s = tp.init();
    // Unaligned entry [100, 100 + 3*FS): start rounds up to FS, end rounds down
    // to 3*FS → only frames 1 and 2 fit wholly inside; the partial frames at
    // either end (0 and 3) stay used.
    s.freeAvailableRange(100, 3 * FS, 32 * FS);
    try expectEqual(@as(usize, 2), s.free_frames);
    try expectEqual(@as(usize, 2), s.avail_frames);
    try expect(s.isUsed(0) and !s.isUsed(1) and !s.isUsed(2) and s.isUsed(3));

    // Overlapping second entry over the same frames must NOT double-count.
    s.freeAvailableRange(FS, 2 * FS, 32 * FS);
    try expectEqual(@as(usize, 2), s.free_frames);
    try expectEqual(@as(usize, 2), s.avail_frames);

    // A range crossing the mapped limit frees only below it.
    s.freeAvailableRange(8 * FS, 8 * FS, 12 * FS); // frames 8..15 offered, limit at 12
    try expectEqual(@as(usize, 6), s.free_frames); // +frames 8..11 only
    try expect(!s.isUsed(11) and s.isUsed(12));
}

test "reserve idempotence: double-reserve does not double-count" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 32 * FS, 32 * FS); // all 32 available
    try expectEqual(@as(usize, 32), s.free_frames);

    s.reserve(2 * FS, 4 * FS); // frames 2,3
    try expectEqual(@as(usize, 30), s.free_frames);
    try expect(s.isReserved(2) and s.isReserved(3) and !s.isReserved(4));

    // Reserve the same span again: setUsed's isUsed guard keeps the count exact.
    s.reserve(2 * FS, 4 * FS);
    try expectEqual(@as(usize, 30), s.free_frames);

    // Partial-frame span reserves every OVERLAPPING frame (down/up alignment).
    s.reserve(5 * FS + 1, 6 * FS + 1); // touches frames 5 and 6
    try expectEqual(@as(usize, 28), s.free_frames);
    try expect(s.isReserved(5) and s.isReserved(6));

    // avail_frames is a discovery count — reserve does not un-discover.
    try expectEqual(@as(usize, 32), s.avail_frames);
}

test "alloc: never returns a reserved frame (synthetic map with holes)" {
    var tp = TestPmm{};
    var s = tp.init();
    // Map: [0,8) and [12,20) available; reserve holes at 2,3 and 14.
    s.freeAvailableRange(0, 8 * FS, 32 * FS);
    s.freeAvailableRange(12 * FS, 8 * FS, 32 * FS);
    s.reserve(2 * FS, 4 * FS);
    s.reserve(14 * FS, 15 * FS);
    const expected_free = s.free_frames; // 16 - 3
    try expectEqual(@as(usize, 13), expected_free);

    // Drain the allocator completely: exactly expected_free frames come out,
    // none reserved, all distinct.
    var seen = [_]bool{false} ** 32;
    var got: usize = 0;
    while (s.alloc()) |addr| : (got += 1) {
        const f = addr / FS;
        try expect(!s.isReserved(f));
        try expect(!seen[f]);
        seen[f] = true;
    }
    try expectEqual(expected_free, got);
    try expectEqual(@as(usize, 0), s.free_frames);
}

test "allocContiguous: first-fit run scan + skip math at run breaks" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 32 * FS, 32 * FS);
    // Break runs at frames 1 and 3: a 2-frame request must skip past both
    // broken runs (f=0 breaks at 1 → f=2; f=2 breaks at 3 → f=4) and land at 4.
    s.reserve(1 * FS, 2 * FS);
    s.reserve(3 * FS, 4 * FS);
    const a = s.allocContiguous(2).?;
    try expectEqual(@as(usize, 4 * FS), a);
    try expect(s.isUsed(4) and s.isUsed(5));

    // First-fit: a 1-frame request takes the earliest free frame (0), not the
    // area after the previous run.
    try expectEqual(@as(usize, 0), s.allocContiguous(1).?);

    // n == 0 is rejected.
    try expect(s.allocContiguous(0) == null);
}

test "nextFree byte-skip: alloc finds a free bit past several whole-used bytes" {
    var tp = BigTestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 256 * FS, 256 * FS); // everything free
    // Reserve everything except frame 130: frames 0..129 solid (16+ whole 0xFF
    // bytes) so nextFree must skip them via the byte check, not fall back to
    // bit-by-bit (still correct either way; this proves the fast path lands on
    // the right frame, not just "some" free frame), then 131..256 also solid.
    s.reserve(0, 130 * FS);
    s.reserve(131 * FS, 256 * FS);
    try expectEqual(@as(usize, 1), s.free_frames); // only frame 130 is free
    const addr = s.alloc().?;
    try expectEqual(@as(usize, 130 * FS), addr);
    try expect(s.alloc() == null); // exhausted
}

test "nextFree byte-skip: mid-byte free bit is found, not skipped" {
    var tp = BigTestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 256 * FS, 256 * FS);
    // Reserve everything except frame 67 (byte 8, bit 3) — a free bit that is
    // NOT byte-aligned and not the first bit of its byte, to prove the
    // within-byte bit scan (not just the byte-level 0xFF check) is correct.
    s.reserve(0, 67 * FS);
    s.reserve(68 * FS, 256 * FS);
    try expectEqual(@as(usize, 1), s.free_frames);
    try expectEqual(@as(usize, 67 * FS), s.alloc().?);
}

test "allocContiguous: boundary frames and too-large requests" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 32 * FS, 32 * FS);
    s.reserve(0, 29 * FS); // only frames 29,30,31 free — a run ending AT the boundary
    try expectEqual(@as(usize, 29 * FS), s.allocContiguous(3).?);
    try expect(s.isUsed(29) and s.isUsed(30) and s.isUsed(31));
    try expectEqual(@as(usize, 0), s.free_frames);

    // A request that could only fit past the end returns null (no wrap, no scan
    // past the bitmap).
    var tp2 = TestPmm{};
    var s2 = tp2.init();
    s2.freeAvailableRange(30 * FS, 2 * FS, 32 * FS); // only frames 30,31 free
    try expect(s2.allocContiguous(3) == null);
    try expectEqual(@as(usize, 2), s2.free_frames); // scan claimed nothing
}

test "free: reserved and out-of-range frames are refused; no count inflation" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 8 * FS, 32 * FS);
    s.reserve(2 * FS, 3 * FS);
    try expectEqual(@as(usize, 7), s.free_frames);

    // Freeing a reserved frame is refused: still used, still reserved, count intact.
    s.free(2 * FS);
    try expect(s.isUsed(2) and s.isReserved(2));
    try expectEqual(@as(usize, 7), s.free_frames);

    // Freeing a never-allocated (already-free) frame does not inflate the count.
    s.free(5 * FS);
    try expectEqual(@as(usize, 7), s.free_frames);

    // Freeing past the bitmap is a bounded no-op (would index out of range otherwise).
    s.free(32 * FS);
    s.free(std.math.maxInt(usize) & ~(FS - 1));
    try expectEqual(@as(usize, 7), s.free_frames);

    // A legitimate alloc→free round-trip restores the count and pulls the hint back.
    const a = s.alloc().?;
    try expectEqual(@as(usize, 6), s.free_frames);
    s.free(a);
    try expectEqual(@as(usize, 7), s.free_frames);
    try expectEqual(a / FS, s.hint);
}

test "freeContiguous: run round-trip, reserved frames skipped, bad ranges bounded" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 16 * FS, 32 * FS);
    try expectEqual(@as(usize, 16), s.free_frames);

    // Round-trip a 4-frame run.
    const a = s.allocContiguous(4).?;
    try expectEqual(@as(usize, 12), s.free_frames);
    s.freeContiguous(a, 4);
    try expectEqual(@as(usize, 16), s.free_frames);

    // A stray freeContiguous spanning a reserved frame frees around it but never
    // un-reserves it (a real allocation can't span one — reserved reads as used).
    s.reserve(6 * FS, 7 * FS);
    try expectEqual(@as(usize, 15), s.free_frames);
    _ = s.allocContiguous(1); // consume frame 0 so counts move below
    const before = s.free_frames;
    s.freeContiguous(5 * FS, 3 * FS); // frames 5,6,7: 5,7 already free; 6 reserved
    try expect(s.isUsed(6) and s.isReserved(6));
    try expectEqual(before, s.free_frames); // nothing actually freed, count exact

    // Bad base/n combinations must not walk past the bitmap.
    s.freeContiguous(31 * FS, 2); // n crosses the end → refused whole
    s.freeContiguous(40 * FS, 1); // base out of range → refused
    try expectEqual(before, s.free_frames);
}

test "free_frames accounting is exact across a mixed sequence" {
    var tp = TestPmm{};
    var s = tp.init();
    s.freeAvailableRange(0, 24 * FS, 32 * FS);
    s.reserve(10 * FS, 12 * FS);
    var expected: usize = 22; // 24 available - 2 reserved
    try expectEqual(expected, s.free_frames);

    const a = s.alloc().?;
    const b = s.allocContiguous(5).?;
    const c = s.alloc().?;
    expected -= 7;
    try expectEqual(expected, s.free_frames);

    s.free(a);
    expected += 1;
    s.freeContiguous(b, 5);
    expected += 5;
    try expectEqual(expected, s.free_frames);

    s.free(a); // double free: idempotent, no inflation
    s.free(10 * FS); // reserved: refused
    try expectEqual(expected, s.free_frames);

    s.free(c);
    expected += 1;
    try expectEqual(expected, s.free_frames);
    try expectEqual(@as(usize, 22), expected); // everything is back
    // usedBytes-style identity: avail - free == frames currently held out.
    try expectEqual(@as(usize, 24 - 22), s.avail_frames - s.free_frames); // the 2 reserved
}
