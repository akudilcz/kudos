//! Host tests of src/drivers/usb/trb.zig.

const std = @import("std");
const trb = @import("trb");
const BOUNDARY = trb.BOUNDARY;
const Span = trb.Span;
const Splitter = trb.Splitter;
const expectEqual = std.testing.expectEqual;
const spanCount = trb.spanCount;
const statusWord = trb.statusWord;
const tdSize = trb.tdSize;

test "regression: a 32 KiB buffer straddling a 64 KiB boundary splits in two" {
    // An unaligned 32 KiB buffer crosses a 64 KiB boundary whenever addr % 65536 > 32768
    // — i.e. it depends on where the linker happens to put it, so the fault appears and
    // disappears as unrelated code moves. QEMU DMAs it happily; the PCH does not.
    const addr: u64 = 0x1_9000; // 0x9000 into a 64 K page; 0x7000 left before the edge
    const len: u32 = 32 * 1024; // 0x8000 — overruns the edge by 0x1000

    var it = Splitter.init(addr, len);
    const a = it.next().?;
    try expectEqual(@as(u64, 0x1_9000), a.addr);
    try expectEqual(@as(u32, 0x7000), a.len); // truncated exactly at the boundary
    const b = it.next().?;
    try expectEqual(@as(u64, 0x2_0000), b.addr); // resumes ON the boundary
    try expectEqual(@as(u32, 0x1000), b.len);
    try expectEqual(@as(?Span, null), it.next());

    // No span may ever cross a boundary — the property, stated directly.
    for ([_]Span{ a, b }) |s| {
        try expectEqual(s.addr / BOUNDARY, (s.addr + s.len - 1) / BOUNDARY);
    }
    try expectEqual(@as(u32, 2), spanCount(addr, len));
}

test "a buffer that fits inside one 64 KiB page is a single span" {
    var it = Splitter.init(0x1_0100, 0x200);
    const s = it.next().?;
    try expectEqual(@as(u64, 0x1_0100), s.addr);
    try expectEqual(@as(u32, 0x200), s.len);
    try expectEqual(@as(?Span, null), it.next());
    try expectEqual(@as(u32, 1), spanCount(0x1_0100, 0x200));
}

test "a boundary-aligned buffer is not split early" {
    // addr & 0xFFFF == 0 must yield a FULL 64 KiB span, not a zero-length one —
    // the off-by-one that an `x % BOUNDARY` formulation invites.
    var it = Splitter.init(0x2_0000, 64 * 1024);
    const s = it.next().?;
    try expectEqual(@as(u64, 0x2_0000), s.addr);
    try expectEqual(@as(u32, 64 * 1024), s.len);
    try expectEqual(@as(?Span, null), it.next());
}

test "a buffer ending exactly on a boundary is one span" {
    var it = Splitter.init(0x1_8000, 32 * 1024); // ends at 0x2_0000 exactly
    const s = it.next().?;
    try expectEqual(@as(u32, 32 * 1024), s.len);
    try expectEqual(@as(?Span, null), it.next());
}

test "a buffer spanning several boundaries splits at each one" {
    const addr: u64 = 0x1_F000;
    const len: u32 = 3 * 64 * 1024; // crosses 0x2_0000, 0x3_0000, 0x4_0000
    var it = Splitter.init(addr, len);
    var total: u32 = 0;
    var n: u32 = 0;
    while (it.next()) |s| {
        try expectEqual(s.addr / BOUNDARY, (s.addr + s.len - 1) / BOUNDARY);
        total += s.len;
        n += 1;
    }
    try expectEqual(len, total); // every byte is carried exactly once
    try expectEqual(@as(u32, 4), n);
}

test "a zero-length transfer still needs one TRB" {
    var it = Splitter.init(0x1000, 0);
    const s = it.next().?;
    try expectEqual(@as(u32, 0), s.len);
    try expectEqual(@as(?Span, null), it.next());
    try expectEqual(@as(u32, 1), spanCount(0x1000, 0));
}

test "TD Size counts packets remaining after this TRB, saturating at 31" {
    try expectEqual(@as(u32, 0), tdSize(0, 512)); // last TRB of the TD
    try expectEqual(@as(u32, 1), tdSize(1, 512)); // a partial packet still counts
    try expectEqual(@as(u32, 1), tdSize(512, 512));
    try expectEqual(@as(u32, 2), tdSize(513, 512));
    try expectEqual(@as(u32, 31), tdSize(64 * 1024, 512)); // 128 packets -> clamped
    try expectEqual(@as(u32, 0), tdSize(4096, 0)); // no MPS: don't divide by zero
}

test "status word packs length and TD size into their fields" {
    try expectEqual(@as(u32, 0x7000), statusWord(0x7000, 0));
    try expectEqual(@as(u32, 0x7000 | (2 << 17)), statusWord(0x7000, 2));
    // TD Size is 5 bits and length is 17 — neither may bleed into the other.
    try expectEqual(@as(u32, 0x1FFFF | (31 << 17)), statusWord(0xFFFFF, 63));
}

test "regression: the wrap Link TRB carries CHAIN iff the pushed TRB is mid-TD" {
    const expect = std.testing.expect;
    // A last-TRB of its TD (no CHAIN) at the wrap: the Link must NOT chain, or the
    // controller would swallow the next TD's head.
    try expect(trb.linkControl(0, 0) & trb.CHAIN == 0);
    // A mid-TD (chained) TRB at the wrap: the Link MUST carry CHAIN, else the
    // straddling bulk TD is silently split — the real-hardware corruption bug.
    try expect(trb.linkControl(0, trb.CHAIN) & trb.CHAIN != 0);
    // Cycle bit and Link identity (type + toggle) are always present, both cycles.
    for ([_]u32{ 0, 1 }) |cyc| {
        const link = trb.linkControl(cyc, 0);
        try expectEqual(cyc, link & 1);
        try expect(link & trb.TOGGLE_CYCLE != 0);
        try expectEqual(trb.TYPE_LINK, (link >> 10) & 0x3F);
    }
}
