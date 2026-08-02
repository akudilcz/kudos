//! Host tests of src/kernel/virt/e820.zig.

const std = @import("std");
const e820 = @import("e820");
const expectEqual = std.testing.expectEqual;

test "forRam builds two usable regions around the legacy hole" {
    var buf: [8]e820.Entry = undefined;
    const map = e820.forRam(128 * 1024 * 1024, &buf);
    try expectEqual(@as(usize, 2), map.len);

    try expectEqual(@as(u64, 0), map[0].addr);
    try expectEqual(e820.LOW_RAM_TOP, map[0].size);
    try expectEqual(e820.E820_RAM, map[0].typ);

    try expectEqual(e820.HIGH_RAM_BASE, map[1].addr);
    // The high region must reach exactly the top of RAM — asserted as a property,
    // not by re-deriving the implementation's size expression.
    try expectEqual(@as(u64, 128 * 1024 * 1024), map[1].addr + map[1].size);
    try expectEqual(e820.E820_RAM, map[1].typ);
}

test "forRam leaves the legacy 1 MiB hole between the two regions" {
    var buf: [8]e820.Entry = undefined;
    const map = e820.forRam(64 * 1024 * 1024, &buf);
    // The first region ends below where the second begins: the hole is omitted.
    try std.testing.expect(map[0].addr + map[0].size < map[1].addr);
    try expectEqual(e820.LOW_RAM_TOP, map[0].addr + map[0].size);
    try expectEqual(e820.HIGH_RAM_BASE, map[1].addr);
}

test "RAM below the high base yields one low region, no phantom high entry" {
    var buf: [8]e820.Entry = undefined;
    const map = e820.forRam(e820.HIGH_RAM_BASE / 2, &buf);
    try expectEqual(@as(usize, 1), map.len);
    try expectEqual(@as(u64, 0), map[0].addr);
    try expectEqual(e820.E820_RAM, map[0].typ);
}
