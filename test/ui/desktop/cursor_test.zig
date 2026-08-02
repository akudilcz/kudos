//! Host tests of src/ui/desktop/cursor.zig — the baked software mouse pointer.

const std = @import("std");
const cursor = @import("cursor");
const expect = std.testing.expect;

fn texel(px: []const u8, x: u32, y: u32) [4]u8 {
    const i = (@as(usize, y) * cursor.W + x) * 4;
    return .{ px[i], px[i + 1], px[i + 2], px[i + 3] };
}

test "the hotspot texel is opaque — the arrow points where the image is drawn" {
    const px = cursor.bake();
    try expect(cursor.HOT_X == 0 and cursor.HOT_Y == 0);
    try expect(texel(&px, 0, 0)[3] > 0);
}

test "the arrow interior is opaque white over a black outline" {
    const px = cursor.bake();
    // Deep inside the arrow head: full coverage, pure white.
    const body = texel(&px, 1, 3);
    try expect(body[3] == 255);
    try expect(body[0] == 255 and body[1] == 255 and body[2] == 255);
    // Somewhere the rim covers but the body does not: dark and visible.
    var found_outline = false;
    for (0..cursor.H) |y| for (0..cursor.W) |x| {
        const t = texel(&px, @intCast(x), @intCast(y));
        if (t[3] > 128 and t[0] < 64) found_outline = true;
    };
    try expect(found_outline);
}

test "the arrow fills a plausible share of its canvas and no more" {
    const px = cursor.bake();
    var opaque_count: usize = 0;
    for (0..cursor.H) |y| for (0..cursor.W) |x| {
        if (texel(&px, @intCast(x), @intCast(y))[3] > 128) opaque_count += 1;
    };
    // The silhouette plus its one-texel rim: well under the full canvas,
    // well over an empty one. A broken polygon test lands outside this band.
    try expect(opaque_count > 60);
    try expect(opaque_count < 220);
}

test "the canvas edges beyond the arrow stay fully transparent" {
    const px = cursor.bake();
    // Top-right and bottom-right corners are outside every dilated texel.
    try expect(texel(&px, cursor.W - 1, 0)[3] == 0);
    try expect(texel(&px, cursor.W - 1, cursor.H - 1)[3] == 0);
}
