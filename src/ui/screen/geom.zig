//! GPU-UI tessellation — the 2D vertex geometry the `gles` painter feeds to the
//! hardware. PURE (imports only std): given a rectangle and a radius it produces
//! the interleaved `f32` vertex positions for a quad, a rounded rectangle, or a
//! disc, written into a caller-owned buffer (no allocation). The painter binds
//! these as a client vertex array and issues one `glDrawArrays`.
//!
//! Why geometry and not a mask texture: the whole window manager is GPU-bound, and
//! ES 1.1 has no fragment shaders to sample a corner mask with. A rounded corner is
//! therefore a fan of triangles approximating the quarter-circle; the pipeline
//! renders 8× MSAA, so the tessellated edge is anti-aliased by the hardware for
//! free — no CPU rasterisation anywhere.
//!
//! Coordinates are screen space, y DOWN from the top-left, matching the painter's
//! `orthof(0, w, h, 0)`. Two floats per vertex, tightly packed.

const std = @import("std");

/// Segments per 90° corner arc. Eight is smooth at the radii window chrome uses
/// (8–20 px) and keeps a rounded rect at 4×8+2 = 34 vertices — one small draw.
pub const CORNER_SEGS: u32 = 8;

/// Floats a `roundedRect` of `segs` per corner writes: a centre, four arcs of
/// (segs+1) points, and one closing point, ×2 floats. Callers size a buffer with
/// this so the geometry never allocates.
pub fn roundedRectFloats(segs: u32) usize {
    return (1 + 4 * (segs + 1) + 1) * 2;
}

/// Floats a `disc` of `segs` perimeter points writes: centre + segs + close, ×2.
pub fn discFloats(segs: u32) usize {
    return (1 + segs + 1) * 2;
}

/// A quad as a TRIANGLE_STRIP: top-left, top-right, bottom-left, bottom-right.
/// Writes 8 floats (4 vertices). The painter draws it with `GL_TRIANGLE_STRIP`.
pub fn rectStrip(out: *[8]f32, x: f32, y: f32, w: f32, h: f32) void {
    out.* = .{
        x, y, // TL
        x + w, y, // TR
        x, y + h, // BL
        x + w, y + h, // BR
    };
}

/// A line segment from (x0,y0) to (x1,y1) of the given width, as a quad in
/// TRIANGLE_STRIP order (same convention as `rectStrip`): the two endpoints
/// each displaced ±width/2 along the segment's unit normal. Writes 8 floats
/// (4 vertices). A zero-length segment writes a degenerate (invisible) quad
/// rather than dividing by zero.
pub fn segmentQuad(out: *[8]f32, x0: f32, y0: f32, x1: f32, y1: f32, width: f32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) {
        out.* = .{ x0, y0, x0, y0, x0, y0, x0, y0 };
        return;
    }
    // Unit normal to the segment, scaled to half the width.
    const nx = -dy / len * (width * 0.5);
    const ny = dx / len * (width * 0.5);
    out.* = .{
        x0 + nx, y0 + ny, // start, +normal (strip "top-left")
        x1 + nx, y1 + ny, // end, +normal   (strip "top-right")
        x0 - nx, y0 - ny, // start, -normal (strip "bottom-left")
        x1 - nx, y1 - ny, // end, -normal   (strip "bottom-right")
    };
}

/// A rounded rectangle as a TRIANGLE_FAN: a centre vertex, then the perimeter
/// walked clockwise through four quarter-circle corners, then the first perimeter
/// point again to close. Returns the vertex COUNT (floats written = count*2).
///
/// `radius` is clamped to half the shorter side, so a fat radius degrades to a
/// stadium/circle instead of self-intersecting. `out` must hold at least
/// `roundedRectFloats(segs)` floats.
pub fn roundedRect(out: []f32, x: f32, y: f32, w: f32, h: f32, radius: f32, segs: u32) u32 {
    const r = @min(radius, @min(w, h) * 0.5);
    var n: usize = 0;
    // Centre of the fan.
    out[n] = x + w * 0.5;
    out[n + 1] = y + h * 0.5;
    n += 2;

    // The four arc centres, and the angle each corner's arc sweeps FROM, walking
    // the perimeter clockwise in screen space (y down): top-right, bottom-right,
    // bottom-left, top-left. Each sweeps +90°.
    const cx = [4]f32{ x + w - r, x + w - r, x + r, x + r };
    const cy = [4]f32{ y + r, y + h - r, y + h - r, y + r };
    const a0 = [4]f32{ -std.math.pi * 0.5, 0.0, std.math.pi * 0.5, std.math.pi };

    const first_i = n;
    for (0..4) |corner| {
        var s: u32 = 0;
        while (s <= segs) : (s += 1) {
            const t = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segs));
            const ang = a0[corner] + t * (std.math.pi * 0.5);
            out[n] = cx[corner] + r * @cos(ang);
            out[n + 1] = cy[corner] + r * @sin(ang);
            n += 2;
        }
    }
    // Close the fan back onto the first perimeter point.
    out[n] = out[first_i];
    out[n + 1] = out[first_i + 1];
    n += 2;

    return @intCast(n / 2);
}

/// A filled disc as a TRIANGLE_FAN: centre, `segs` perimeter points, then the
/// first perimeter point again to close. Returns the vertex count. `out` must hold
/// at least `discFloats(segs)` floats. Used for traffic-light buttons and dock
/// running-dots.
pub fn disc(out: []f32, cx: f32, cy: f32, r: f32, segs: u32) u32 {
    var n: usize = 0;
    out[n] = cx;
    out[n + 1] = cy;
    n += 2;
    const first_i = n;
    var s: u32 = 0;
    while (s < segs) : (s += 1) {
        const ang = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segs)) * (std.math.pi * 2.0);
        out[n] = cx + r * @cos(ang);
        out[n + 1] = cy + r * @sin(ang);
        n += 2;
    }
    out[n] = out[first_i];
    out[n + 1] = out[first_i + 1];
    n += 2;
    return @intCast(n / 2);
}
