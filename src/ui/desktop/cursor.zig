//! The software mouse pointer: a baked arrow bitmap for machines whose
//! scanout has no hardware cursor plane (`iaccel.Accel.cursor` null — the
//! software-display path). There the pointer must be pixels in the composed
//! frame, so the desktop draws this image at the cursor position each frame;
//! `ui/desktop/input.zig` already repaints on every pointer sample in that
//! mode.
//!
//! The bitmap is baked, not drawn with painter primitives: an arrow is two
//! polygons the 2D toolkit has no primitive for, and baking once at init keeps
//! the per-frame cost at one textured quad. The shape is the classic arrow —
//! white body over a one-pixel black outline so it reads on any background —
//! rasterised here by supersampled polygon coverage: a pure function of
//! nothing, so the exact texels are host-testable.

/// Bitmap dimensions in pixels. The image is drawn 1:1, never scaled.
pub const W: u32 = 16;
pub const H: u32 = 22;
/// The hotspot — the screen position the arrow points at — is the bitmap's
/// top-left texel: draw the image at exactly the cursor position.
pub const HOT_X: u32 = 0;
pub const HOT_Y: u32 = 0;

/// The arrow silhouette: vertex-first outline of the classic pointer, hotspot
/// at the origin, left edge vertical, notched tail. Closed implicitly
/// (last vertex joins the first).
const ARROW = [_][2]f32{
    .{ 0.0, 0.0 },
    .{ 0.0, 15.0 },
    .{ 3.6, 11.8 },
    .{ 6.0, 17.2 },
    .{ 8.2, 16.3 },
    .{ 5.8, 10.9 },
    .{ 10.8, 10.9 },
};

/// Subsamples per pixel axis: 4x4 grid = 16 coverage samples per texel, enough
/// that the antialiased edge steps in 1/16ths of full alpha.
const SUBSAMPLES = 4;

/// Even-odd point-in-polygon test against ARROW (ray cast toward +x).
fn insideArrow(px: f32, py: f32) bool {
    var hit = false;
    var j: usize = ARROW.len - 1;
    for (ARROW, 0..) |v, i| {
        const u = ARROW[j];
        if ((v[1] > py) != (u[1] > py)) {
            const cross_x = v[0] + (py - v[1]) / (u[1] - v[1]) * (u[0] - v[0]);
            if (px < cross_x) hit = !hit;
        }
        j = i;
    }
    return hit;
}

/// Supersampled coverage of the arrow silhouette for the texel at (x, y).
fn coverage(x: u32, y: u32) f32 {
    var inside: u32 = 0;
    var sy: u32 = 0;
    while (sy < SUBSAMPLES) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < SUBSAMPLES) : (sx += 1) {
            const fx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / SUBSAMPLES;
            const fy = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / SUBSAMPLES;
            if (insideArrow(fx, fy)) inside += 1;
        }
    }
    return @as(f32, @floatFromInt(inside)) / (SUBSAMPLES * SUBSAMPLES);
}

/// Bake the pointer image: BGRA texels (kgl.uploadImage's native layout,
/// spec RND-008), straight alpha. The white body is the arrow's own coverage;
/// the black outline is the body dilated by one texel in every direction, so
/// each texel blends white-over-black by how much body it holds.
pub fn bake() [W * H * 4]u8 {
    var cov: [W * H]f32 = undefined;
    for (0..H) |y| for (0..W) |x| {
        cov[y * W + x] = coverage(@intCast(x), @intCast(y));
    };

    var out: [W * H * 4]u8 = undefined;
    for (0..H) |y| for (0..W) |x| {
        const body = cov[y * W + x];
        // Dilate: the outline alpha is the strongest coverage in the 3x3
        // neighbourhood, so a one-texel black rim surrounds the body.
        var rim: f32 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx = @as(i32, @intCast(x)) + dx;
                const ny = @as(i32, @intCast(y)) + dy;
                if (nx < 0 or ny < 0 or nx >= W or ny >= H) continue;
                rim = @max(rim, cov[@as(usize, @intCast(ny)) * W + @as(usize, @intCast(nx))]);
            }
        }
        // White where the body covers, black for the rest of the rim; the
        // texel's grey level is the white fraction of its total coverage.
        const grey: u8 = if (rim > 0) @intFromFloat(@round(body / rim * 255.0)) else 0;
        const a: u8 = @intFromFloat(@round(rim * 255.0));
        const i = (y * W + x) * 4;
        out[i + 0] = grey; // B
        out[i + 1] = grey; // G
        out[i + 2] = grey; // R
        out[i + 3] = a;
    };
    return out;
}
