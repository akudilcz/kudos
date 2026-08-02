//! Mouse cursor: a centered crosshair. '#' = black outline,
//! '.' = white core, ' ' = transparent. The cursor **hotspot is the centre** of
//! the bitmap (a crosshair points from its middle), so `draw` offsets the bitmap
//! by half its size — callers pass the pointer position, not the top-left.

const surface = @import("surface");
const Surface = surface.Surface;
const Color = surface.Color;

// 13x13 crosshair with a 1px gap at the centre. Each arm is a white core with a
// black border above/below (or left/right) so it stays visible on any colour.
const rows = [_][]const u8{
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
    "##### . #####",
    "..... . .....",
    "##### . #####",
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
    "     #.#     ",
};

pub const WIDTH = 13;
pub const HEIGHT = rows.len;
pub const HOT_X: i32 = WIDTH / 2; // centre column = hotspot
pub const HOT_Y: i32 = HEIGHT / 2; // centre row = hotspot

const BLACK: Color = 0x00000000;
const WHITE: Color = 0x00FFFFFF;

/// Render the crosshair into an n×n straight-alpha A8R8G8B8 buffer with a
/// fully transparent background — the image the HARDWARE cursor plane scans
/// out (the hardware cursor plane). The bitmap sits at the top-left;
/// the plane's hotspot fields carry (HOT_X, HOT_Y). `buf.len` must be n*n.
pub fn argb32(buf: []u32, n: usize) void {
    for (buf) |*p| p.* = 0x00000000; // transparent
    for (rows, 0..) |row, ry| {
        for (row, 0..) |c, rx| {
            const px: ?u32 = switch (c) {
                '#' => 0xFF000000, // opaque black
                '.' => 0xFFFFFFFF, // opaque white
                else => null,
            };
            if (px) |v| {
                if (rx < n and ry < n) buf[ry * n + rx] = v;
            }
        }
    }
}

/// Draw the crosshair centred on (px, py). Origin math is **signed**: the bitmap
/// extends left/up of the hotspot, so near an edge the origin can be negative;
/// each pixel is clipped (skipped if <0) rather than clamped, so the cross is
/// never shifted or wrapped to the far side of the screen.
pub fn draw(dst: Surface, px: i32, py: i32) void {
    const ox: i32 = px - HOT_X;
    const oy: i32 = py - HOT_Y;
    for (rows, 0..) |row, ry| {
        for (row, 0..) |c, rx| {
            const color: ?Color = switch (c) {
                '#' => BLACK,
                '.' => WHITE,
                else => null,
            };
            if (color) |col| {
                const x = ox + @as(i32, @intCast(rx));
                const y = oy + @as(i32, @intCast(ry));
                if (x >= 0 and y >= 0) dst.putPixel(@intCast(x), @intCast(y), col);
            }
        }
    }
}
