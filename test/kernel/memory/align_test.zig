//! Host tests of src/kernel/memory/align.zig.

const std = @import("std");
const algn = @import("algn");
const down = algn.down;
const expectEqual = std.testing.expectEqual;
const up = algn.up;

test "up rounds to the next multiple; exact stays put" {
    try expectEqual(@as(usize, 0), up(0, 8));
    try expectEqual(@as(usize, 8), up(1, 8));
    try expectEqual(@as(usize, 8), up(8, 8)); // already aligned
    try expectEqual(@as(usize, 16), up(9, 8));
    try expectEqual(@as(usize, 0x1000), up(0x0FFF, 0x1000));
    try expectEqual(@as(usize, 0x1000), up(0x1000, 0x1000));
    try expectEqual(@as(usize, 0x2000), up(0x1001, 0x1000));
}

test "down rounds to the previous multiple; exact stays put" {
    try expectEqual(@as(usize, 0), down(7, 8));
    try expectEqual(@as(usize, 8), down(8, 8));
    try expectEqual(@as(usize, 8), down(15, 8));
    try expectEqual(@as(usize, 0x1000), down(0x1FFF, 0x1000));
    try expectEqual(@as(usize, 0x1000), down(0x1000, 0x1000));
}

test "up/down agree at alignment boundaries" {
    var x: usize = 0;
    while (x < 64) : (x += 1) {
        const u = up(x, 16);
        const d = down(x, 16);
        try std.testing.expect(d <= x and x <= u);
        try std.testing.expect(u - d <= 16);
        try expectEqual(@as(usize, 0), u % 16);
        try expectEqual(@as(usize, 0), d % 16);
    }
}
