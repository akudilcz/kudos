//! IRamdisk contract conformance (spec R69): one shared vector suite that
//! EVERY implementation of the iface/iramdisk.zig contract must pass — the
//! real in-RAM store (drivers/storage/ramdisk.zig) and the RamdiskSim fake
//! (test/support/ramdisk_sim.zig). Each is seeded with the same files, then handed to
//! `verify`, which exercises the whole read surface (count/get/at) and the
//! crc32 correctness the contract promises.

const std = @import("std");
const iramdisk = @import("iramdisk");
const ramdisk = @import("testroot").storage.ramdisk;
const RamdiskSim = @import("ramdisk_sim").RamdiskSim;

const Seed = struct { name: []const u8, data: []const u8 };
const SEEDS = [_]Seed{
    .{ .name = "a.txt", .data = "hello" },
    .{ .name = "b.bin", .data = "\x00\x01\x02\x03binary" },
    .{ .name = "empty", .data = "" },
};

/// The shared conformance vectors, run against any IRamdisk seeded with SEEDS.
fn verify(rd: iramdisk.IRamdisk) !void {
    // count reflects every seeded file.
    try std.testing.expectEqual(SEEDS.len, rd.count());

    // get returns the exact bytes for each name, and null for an absent name.
    for (SEEDS) |s| {
        const got = rd.get(s.name) orelse return error.MissingFile;
        try std.testing.expectEqualStrings(s.data, got);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), rd.get("nope"));

    // at(i) enumerates the files; each entry's crc32 must match its data
    // (the one numeric promise the contract makes), and every listed name is
    // gettable with identical bytes.
    var i: usize = 0;
    while (i < rd.count()) : (i += 1) {
        const e = rd.at(i);
        try std.testing.expectEqual(std.hash.Crc32.hash(e.data), e.crc32);
        const via_get = rd.get(e.name) orelse return error.ListedButNotGettable;
        try std.testing.expectEqualStrings(e.data, via_get);
    }
}

test "IRamdisk conformance: the REAL ramdisk store" {
    ramdisk.init(std.testing.allocator);
    defer ramdisk.deinit();
    for (SEEDS) |s| try ramdisk.put(s.name, s.data);
    try verify(ramdisk.fs());
}

test "IRamdisk conformance: the RamdiskSim FAKE" {
    var sim = RamdiskSim{};
    for (SEEDS, 0..) |s, gi| sim.add(s.name, s.data, @intCast(gi + 1));
    try verify(sim.fs());
}
