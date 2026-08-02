//! Host tests of src/drivers/gl/ada/tex.zig.

const std = @import("std");
const tex = @import("tex");
const handle = tex.handle;
const ticBlBgra8 = tex.ticBlBgra8;
const ticBlZf32 = tex.ticBlZf32;
const ticPitchBgra8 = tex.ticPitchBgra8;
const tscLinearWrap = tex.tscLinearWrap;
const tscShadow = tex.tscShadow;

test "ticPitchBgra8 known values" {
    const t = ticPitchBgra8(0x0170_0000, 256, 256, 1024);
    try std.testing.expectEqual(@as(u32, 0x54e24908), t[0]);
    try std.testing.expectEqual(@as(u32, 0x01700000), t[1]);
    try std.testing.expectEqual(@as(u32, 2 << 21), t[2]); // VA<4GiB, version 2
    try std.testing.expectEqual(@as(u32, (1024 >> 5) | (0x7 << 16)), t[3]);
    try std.testing.expectEqual(@as(u32, 255 | (7 << 23) | (1 << 27) | (7 << 29)), t[4]);
    try std.testing.expectEqual(@as(u32, 255 | (1 << 31)), t[5]);
    try std.testing.expectEqual(@as(u32, (2 << 23) | (1 << 25)), t[6]);
    try std.testing.expectEqual(@as(u32, 0), t[7]);
}

test "block-linear TIC variants" {
    const z = ticBlZf32(0x1800_0000, 1024, 1024, 5);
    try std.testing.expectEqual(@as(u32, 0x701003af), z[0]); // 0x2f|7<<7|2<<19|7<<28
    try std.testing.expectEqual(@as(u32, 0x18000000), z[1]);
    try std.testing.expectEqual(@as(u32, 3 << 21), z[2]);
    try std.testing.expectEqual(@as(u32, (5 << 3) | (7 << 16)), z[3]);
    const c = ticBlBgra8(0x1a00_0000, 1024, 1024, 5);
    try std.testing.expectEqual(@as(u32, 0x54e24908), c[0]);
    try std.testing.expectEqual(@as(u32, 0x1a000000), c[1]);
    const s = tscShadow();
    try std.testing.expectEqual(@as(u32, 2 | (2 << 3) | (2 << 6) | (1 << 9) | (3 << 10) | (1 << 13)), s[0]);
}

test "tsc + handle" {
    const s = tscLinearWrap();
    try std.testing.expectEqual(@as(u32, 0x2000), s[0]);
    try std.testing.expectEqual(@as(u32, 0x62), s[1]);
    try std.testing.expectEqual(@as(u32, 0x00300005), handle(5, 3));
}
