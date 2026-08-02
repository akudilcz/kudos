//! Host tests of src/kernel/virt/virtio/virtq.zig — above all the security
//! boundary: no guest-programmed address, length, or index may ever reach
//! outside the guest-RAM slice.

const std = @import("std");
const virtq = @import("virtq");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;

// A queue laid out in fake guest RAM: descriptor table, avail ring, used ring,
// and data pages at fixed guest-physical addresses.
const DESC_GPA: u64 = 0x1000;
const AVAIL_GPA: u64 = 0x2000;
const USED_GPA: u64 = 0x3000;
const DATA_GPA: u64 = 0x4000;
const QSIZE: u16 = 8;

const Fixture = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,

    fn queue(self: *Fixture) virtq.Virtq {
        return .{
            .mem = &self.ram,
            .size = QSIZE,
            .desc_gpa = DESC_GPA,
            .avail_gpa = AVAIL_GPA,
            .used_gpa = USED_GPA,
            .ready = true,
        };
    }

    /// Write descriptor `i` the way a driver would: little-endian fields.
    fn setDesc(self: *Fixture, i: u16, d: virtq.Desc) void {
        const base: usize = @intCast(DESC_GPA + @as(u64, i) * 16);
        std.mem.writeInt(u64, self.ram[base..][0..8], d.addr, .little);
        std.mem.writeInt(u32, self.ram[base + 8 ..][0..4], d.len, .little);
        std.mem.writeInt(u16, self.ram[base + 12 ..][0..2], d.flags, .little);
        std.mem.writeInt(u16, self.ram[base + 14 ..][0..2], d.next, .little);
    }

    /// Put `head` into avail.ring[slot] and publish `idx`.
    fn setAvail(self: *Fixture, slot: u16, head: u16, idx: u16) void {
        const ring: usize = @intCast(AVAIL_GPA + 4 + @as(u64, slot) * 2);
        std.mem.writeInt(u16, self.ram[ring..][0..2], head, .little);
        std.mem.writeInt(u16, self.ram[@intCast(AVAIL_GPA + 2)..][0..2], idx, .little);
    }

    fn usedIdx(self: *const Fixture) u16 {
        return std.mem.readInt(u16, self.ram[@intCast(USED_GPA + 2)..][0..2], .little);
    }

    fn usedElem(self: *const Fixture, slot: u16) struct { id: u32, len: u32 } {
        const base: usize = @intCast(USED_GPA + 4 + @as(u64, slot) * 8);
        return .{
            .id = std.mem.readInt(u32, self.ram[base..][0..4], .little),
            .len = std.mem.readInt(u32, self.ram[base + 4 ..][0..4], .little),
        };
    }
};

test "popAvail: NotReady before the transport flips ready" {
    var f = Fixture{};
    var q = f.queue();
    q.ready = false;
    try expectError(virtq.Error.NotReady, q.popAvail());
}

test "popAvail: empty queue yields null" {
    var f = Fixture{};
    var q = f.queue();
    try expectEqual(@as(?u16, null), try q.popAvail());
}

test "popAvail: heads come back in ring order" {
    var f = Fixture{};
    var q = f.queue();
    f.setAvail(0, 3, 1);
    f.setAvail(1, 5, 2);
    try expectEqual(@as(?u16, 3), try q.popAvail());
    try expectEqual(@as(?u16, 5), try q.popAvail());
    try expectEqual(@as(?u16, null), try q.popAvail());
}

test "popAvail: ring slot and u16 idx both wrap around" {
    var f = Fixture{};
    var q = f.queue();
    // Pretend the queue has been running for a long time: last_avail sits just
    // below the u16 wrap, so the next slots are QSIZE-2, QSIZE-1, 0, ...
    q.last_avail = 0xFFFE;
    f.setAvail((0xFFFE % QSIZE), 1, 0xFFFF);
    f.setAvail((0xFFFF % QSIZE), 2, 0x0000); // idx wraps past 0xFFFF
    f.setAvail(0, 4, 0x0001);
    try expectEqual(@as(?u16, 1), try q.popAvail());
    try expectEqual(@as(?u16, 2), try q.popAvail());
    try expectEqual(@as(?u16, 4), try q.popAvail());
    try expectEqual(@as(?u16, null), try q.popAvail());
}

test "popAvail: a head outside the table is BadIndex" {
    var f = Fixture{};
    var q = f.queue();
    f.setAvail(0, QSIZE, 1);
    try expectError(virtq.Error.BadIndex, q.popAvail());
}

test "popAvail: an out-of-RAM avail ring is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    q.avail_gpa = RAM_LEN - 2; // avail.flags fits; avail.idx at offset 2 crosses the end
    std.mem.writeInt(u16, f.ram[RAM_LEN - 2 ..][0..2], 0, .little); // flags
    try expectError(virtq.Error.AddrOutOfBounds, q.popAvail());
}

test "popAvail: a misaligned avail ring is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    q.avail_gpa = AVAIL_GPA + 1;
    try expectError(virtq.Error.AddrOutOfBounds, q.popAvail());
}

test "descAt: fields round-trip little-endian" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(2, .{ .addr = 0x1122334455667788, .len = 0xA0B0C0D0, .flags = virtq.F_WRITE, .next = 7 });
    const d = try q.descAt(2);
    try expectEqual(@as(u64, 0x1122334455667788), d.addr);
    try expectEqual(@as(u32, 0xA0B0C0D0), d.len);
    try expectEqual(virtq.F_WRITE, d.flags);
    try expectEqual(@as(u16, 7), d.next);
}

test "descAt: index past the queue size is BadIndex" {
    var f = Fixture{};
    var q = f.queue();
    try expectError(virtq.Error.BadIndex, q.descAt(QSIZE));
}

test "descAt: a table whose tail crosses the end of RAM is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    q.desc_gpa = RAM_LEN - 8; // descriptor 0 needs 16 bytes
    try expectError(virtq.Error.AddrOutOfBounds, q.descAt(0));
}

test "descAt: a table base near u64 max cannot wrap back into RAM" {
    var f = Fixture{};
    var q = f.queue();
    q.desc_gpa = std.math.maxInt(u64) - 8; // desc 1 sits at base+16, past the wrap
    try expectError(virtq.Error.AddrOutOfBounds, q.descAt(1));
}

test "segment: a valid descriptor maps to the exact RAM window" {
    var f = Fixture{};
    var q = f.queue();
    f.ram[@intCast(DATA_GPA)] = 0xAB;
    f.ram[@intCast(DATA_GPA + 3)] = 0xCD;
    const s = try q.segment(.{ .addr = DATA_GPA, .len = 4, .flags = 0, .next = 0 });
    try expectEqual(@as(usize, 4), s.len);
    try expectEqual(@as(u8, 0xAB), s[0]);
    try expectEqual(@as(u8, 0xCD), s[3]);
}

// VIRT-012: every guest-supplied descriptor is bounds-checked against guest
// RAM — past the end, crossing it, absurd length, or wrapping u64.
test "segment: addr past RAM is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    try expectError(virtq.Error.AddrOutOfBounds, q.segment(.{ .addr = RAM_LEN, .len = 1, .flags = 0, .next = 0 }));
}

test "segment: addr+len crossing the end of RAM is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    try expectError(virtq.Error.AddrOutOfBounds, q.segment(.{ .addr = RAM_LEN - 4, .len = 5, .flags = 0, .next = 0 }));
}

test "segment: a huge len is AddrOutOfBounds" {
    var f = Fixture{};
    var q = f.queue();
    try expectError(virtq.Error.AddrOutOfBounds, q.segment(.{ .addr = DATA_GPA, .len = 0xFFFF_FFFF, .flags = 0, .next = 0 }));
}

test "segment: addr near u64 max cannot wrap back into RAM" {
    var f = Fixture{};
    var q = f.queue();
    try expectError(virtq.Error.AddrOutOfBounds, q.segment(.{ .addr = std.math.maxInt(u64) - 2, .len = 8, .flags = 0, .next = 0 }));
}

test "chain: F_NEXT walks a 3-descriptor chain in order, then ends" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(1, .{ .addr = DATA_GPA, .len = 16, .flags = virtq.F_NEXT, .next = 4 });
    f.setDesc(4, .{ .addr = DATA_GPA + 16, .len = 16, .flags = virtq.F_NEXT, .next = 2 });
    f.setDesc(2, .{ .addr = DATA_GPA + 32, .len = 16, .flags = virtq.F_WRITE, .next = 0 });
    var it = virtq.chain(&q, 1);
    try expectEqual(@as(u64, DATA_GPA), (try it.next()).?.addr);
    try expectEqual(@as(u64, DATA_GPA + 16), (try it.next()).?.addr);
    const last = (try it.next()).?;
    try expectEqual(@as(u64, DATA_GPA + 32), last.addr);
    try expectEqual(virtq.F_WRITE, last.flags);
    try expectEqual(@as(?virtq.Desc, null), try it.next());
}

test "chain: a self-looping descriptor is ChainTooLong, not a hang" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(0, .{ .addr = DATA_GPA, .len = 4, .flags = virtq.F_NEXT, .next = 0 });
    var it = virtq.chain(&q, 0);
    var hops: u32 = 0;
    const err = while (true) {
        const d = it.next() catch |e| break e;
        if (d == null) break virtq.Error.BadIndex; // chain must not terminate
        hops += 1;
        try expect(hops <= QSIZE); // cap engaged before looping forever
    };
    try expectEqual(virtq.Error.ChainTooLong, err);
    try expectEqual(@as(u32, QSIZE), hops);
}

test "chain: a two-descriptor cycle is ChainTooLong" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(3, .{ .addr = DATA_GPA, .len = 4, .flags = virtq.F_NEXT, .next = 6 });
    f.setDesc(6, .{ .addr = DATA_GPA, .len = 4, .flags = virtq.F_NEXT, .next = 3 });
    var it = virtq.chain(&q, 3);
    var i: u32 = 0;
    while (i < QSIZE) : (i += 1) _ = try it.next();
    try expectError(virtq.Error.ChainTooLong, it.next());
}

test "chain: a full-queue-length straight chain is legal" {
    var f = Fixture{};
    var q = f.queue();
    var i: u16 = 0;
    while (i < QSIZE) : (i += 1) {
        const flags: u16 = if (i + 1 < QSIZE) virtq.F_NEXT else 0;
        f.setDesc(i, .{ .addr = DATA_GPA + i, .len = 1, .flags = flags, .next = i + 1 });
    }
    var it = virtq.chain(&q, 0);
    var n: u32 = 0;
    while (try it.next()) |_| n += 1;
    try expectEqual(@as(u32, QSIZE), n);
}

test "chain: F_NEXT to an index past the table is BadIndex" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(0, .{ .addr = DATA_GPA, .len = 4, .flags = virtq.F_NEXT, .next = QSIZE });
    var it = virtq.chain(&q, 0);
    _ = try it.next();
    try expectError(virtq.Error.BadIndex, it.next());
}

test "chain: an indirect descriptor is rejected (feature never negotiated)" {
    var f = Fixture{};
    var q = f.queue();
    f.setDesc(0, .{ .addr = DATA_GPA, .len = 16, .flags = virtq.F_INDIRECT, .next = 0 });
    var it = virtq.chain(&q, 0);
    try expectError(virtq.Error.Unsupported, it.next());
}

test "pushUsed: writes the element then advances used.idx" {
    var f = Fixture{};
    var q = f.queue();
    q.pushUsed(5, 128);
    try expectEqual(@as(u16, 1), f.usedIdx());
    try expectEqual(@as(u32, 5), f.usedElem(0).id);
    try expectEqual(@as(u32, 128), f.usedElem(0).len);
    q.pushUsed(2, 64);
    try expectEqual(@as(u16, 2), f.usedIdx());
    try expectEqual(@as(u32, 2), f.usedElem(1).id);
    try expectEqual(@as(u32, 64), f.usedElem(1).len);
}

test "pushUsed: ring slot wraps at the queue size" {
    var f = Fixture{};
    var q = f.queue();
    var i: u32 = 0;
    while (i < QSIZE + 1) : (i += 1) q.pushUsed(@intCast(i % QSIZE), i);
    try expectEqual(@as(u16, QSIZE + 1), f.usedIdx());
    try expectEqual(@as(u32, QSIZE), f.usedElem(0).len); // slot 0 overwritten by push #9
}

test "pushUsed: an out-of-RAM used ring drops and counts, touching nothing" {
    var f = Fixture{};
    var q = f.queue();
    q.used_gpa = RAM_LEN - 4; // idx fits, ring[0] would cross the end
    const before = f.ram;
    q.pushUsed(1, 4);
    try expectEqual(@as(u64, 1), q.dropped_used);
    try expect(std.mem.eql(u8, &before, &f.ram)); // no partial write escaped
}

test "pushUsed: a misaligned used ring drops and counts" {
    var f = Fixture{};
    var q = f.queue();
    q.used_gpa = USED_GPA + 2;
    q.pushUsed(1, 4);
    try expectEqual(@as(u64, 1), q.dropped_used);
    try expectEqual(@as(u16, 0), f.usedIdx());
}
