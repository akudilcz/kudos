//! Host tests of src/drivers/gl/es/uniforms.zig.

const std = @import("std");
const uniforms = @import("uniforms");
const LIGHT_DIFFUSE = uniforms.LIGHT_DIFFUSE;
const LIGHT_SPOT_DIR = uniforms.LIGHT_SPOT_DIR;
const LIGHT_STRIDE = uniforms.LIGHT_STRIDE;
const OFF_CLIP_PLANES = uniforms.OFF_CLIP_PLANES;
const OFF_FOG_COLOR = uniforms.OFF_FOG_COLOR;
const OFF_FOG_PARAMS = uniforms.OFF_FOG_PARAMS;
const OFF_LIGHTS = uniforms.OFF_LIGHTS;
const OFF_LIGHT_MODEL_AMBIENT = uniforms.OFF_LIGHT_MODEL_AMBIENT;
const OFF_MATERIAL = uniforms.OFF_MATERIAL;
const OFF_MISC = uniforms.OFF_MISC;
const OFF_MODELVIEW = uniforms.OFF_MODELVIEW;
const OFF_MVP = uniforms.OFF_MVP;
const OFF_NORMAL_MATRIX = uniforms.OFF_NORMAL_MATRIX;
const OFF_TEXENV = uniforms.OFF_TEXENV;
const OFF_TEX_MATRIX = uniforms.OFF_TEX_MATRIX;
const SIZE = uniforms.SIZE;
const TEXENV_STRIDE = uniforms.TEXENV_STRIDE;
const TEXENV_WORDS = uniforms.TEXENV_WORDS;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const limits = uniforms.limits;
const matrix = uniforms.matrix;
const pack = uniforms.pack;
const scaleShift = uniforms.scaleShift;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() uniforms.state.Context {
    return uniforms.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

fn readF32(buf: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}
fn readU32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}

/// Pack the whole uniform block and read the MVP matrix back out of it.
fn packedMvp(g: *uniforms.state.Context, buf: []u8) [16]f32 {
    uniforms.pack(g, buf);
    var mvp: [16]f32 = undefined;
    for (&mvp, 0..) |*x, i| x.* = readF32(buf, OFF_MVP + i * 4);
    return mvp;
}

test "the layout has no overlaps and every offset is vector-aligned" {
    // A silent overlap here renders garbage rather than failing, so it is worth an
    // arithmetic check rather than trust.
    const regions = [_]struct { off: usize, size: usize }{
        .{ .off = OFF_MVP, .size = 64 },
        .{ .off = OFF_MODELVIEW, .size = 64 },
        .{ .off = OFF_NORMAL_MATRIX, .size = 48 },
        .{ .off = OFF_TEX_MATRIX, .size = limits.MAX_TEXTURE_UNITS * 64 },
        .{ .off = OFF_MATERIAL, .size = 80 },
        .{ .off = OFF_LIGHT_MODEL_AMBIENT, .size = 16 },
        .{ .off = OFF_FOG_COLOR, .size = 16 },
        .{ .off = OFF_FOG_PARAMS, .size = 16 },
        .{ .off = OFF_MISC, .size = 16 },
        .{ .off = OFF_CLIP_PLANES, .size = limits.MAX_CLIP_PLANES * 16 },
        .{ .off = OFF_LIGHTS, .size = limits.MAX_LIGHTS * LIGHT_STRIDE },
        .{ .off = OFF_TEXENV, .size = limits.MAX_TEXTURE_UNITS * TEXENV_STRIDE },
    };
    for (regions) |r| try expectEqual(@as(usize, 0), r.off % 16);
    for (regions, 0..) |a, i| {
        for (regions[i + 1 ..]) |b| {
            const overlap = a.off < b.off + b.size and b.off < a.off + a.size;
            try expect(!overlap);
        }
    }
    for (regions) |r| try expect(r.off + r.size <= SIZE);
}

test "the mvp is projection * modelview, in that order" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.projection.set(matrix.scaling(2, 2, 2));
    g.modelview.set(matrix.translation(1, 0, 0));
    const mvp = packedMvp(&g, &buf);
    // Applying it to the origin must translate THEN scale: (1,0,0) -> (2,0,0). The
    // other order would give (1,0,0), and the model would sit in the wrong place.
    try std.testing.expectApproxEqAbs(@as(f32, 2), matrix.mulPoint(mvp, .{ 0, 0, 0 })[0], 1e-5);
}

test "the mvp arrives in the HARDWARE's clip convention, not GL's" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.projection.set(matrix.frustum(-1, 1, -1, 1, 1, 100).?);
    const mvp = packedMvp(&g, &buf);

    // GL's frustum puts the near plane at depth -1. The hardware wants 0.
    const near = matrix.mulPoint(mvp, .{ 0, 0, -1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), near[2] / near[3], 1e-4);
    const far = matrix.mulPoint(mvp, .{ 0, 0, -100 });
    try std.testing.expectApproxEqAbs(@as(f32, 1), far[2] / far[3], 1e-4);

    // And y is flipped: what GL puts above the axis, the rasterizer puts below.
    const up = matrix.mulPoint(mvp, .{ 0, 0.5, -2 });
    try std.testing.expect(up[1] / up[3] < 0);
}

test "the clip correction leaves x alone" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.projection.set(matrix.frustum(-1, 1, -1, 1, 1, 100).?);
    const mvp = packedMvp(&g, &buf);
    const right = matrix.mulPoint(mvp, .{ 0.5, 0, -2 });
    try std.testing.expect(right[0] / right[3] > 0); // still to the right
}

test "a mat3 occupies three vec4s, with the padding zeroed" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.modelview.set(.{ 1, 2, 3, 99, 4, 5, 6, 99, 7, 8, 9, 99, 99, 99, 99, 99 });
    pack(&g, &buf);
    // Column 0 is (1,2,3), then a pad.
    try expectEqual(@as(f32, 1), readF32(&buf, OFF_NORMAL_MATRIX + 0));
    try expectEqual(@as(f32, 3), readF32(&buf, OFF_NORMAL_MATRIX + 8));
    try expectEqual(@as(f32, 0), readF32(&buf, OFF_NORMAL_MATRIX + 12)); // pad, not 99
    // Column 1 starts 16 bytes in, not 12.
    try expectEqual(@as(f32, 4), readF32(&buf, OFF_NORMAL_MATRIX + 16));
    try expectEqual(@as(f32, 9), readF32(&buf, OFF_NORMAL_MATRIX + 40));
}

test "lights are compacted: light 7 alone lands in slot 0" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.caps.lighting = true;
    g.caps.light[7] = true;
    g.lights[7].diffuse = .{ 0.25, 0.5, 0.75, 1 };
    pack(&g, &buf);
    // Slot 0 holds light 7's parameters — the shader's loop starts at zero.
    try expectEqual(@as(f32, 0.25), readF32(&buf, OFF_LIGHTS + LIGHT_DIFFUSE + 0));
    try expectEqual(@as(f32, 0.75), readF32(&buf, OFF_LIGHTS + LIGHT_DIFFUSE + 8));
}

test "a disabled light is not packed at all" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.caps.lighting = true;
    g.caps.light[0] = true;
    g.lights[0].diffuse = .{ 1, 1, 1, 1 };
    g.lights[1].diffuse = .{ 0.5, 0.5, 0.5, 1 }; // enabled? no
    pack(&g, &buf);
    try expectEqual(@as(f32, 1), readF32(&buf, OFF_LIGHTS + LIGHT_DIFFUSE));
    // Slot 1 is untouched zero, not light 1's data.
    try expectEqual(@as(f32, 0), readF32(&buf, OFF_LIGHTS + LIGHT_STRIDE + LIGHT_DIFFUSE));
}

test "the spot cutoff arrives as a cosine, and 180 degrees becomes -1" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.caps.lighting = true;
    g.caps.light[0] = true;

    // The default, 180: not a spotlight. cos(180) = -1 compares true against every
    // direction, so the shader needs no branch for it.
    pack(&g, &buf);
    try expectEqual(@as(f32, -1), readF32(&buf, OFF_LIGHTS + LIGHT_SPOT_DIR + 12));

    g.lights[0].spot_cutoff = 60;
    pack(&g, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), readF32(&buf, OFF_LIGHTS + LIGHT_SPOT_DIR + 12), 1e-6);
}

test "linear fog gets 1/(end-start) precomputed, and an empty range does not divide by zero" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    g.fog.start = 10;
    g.fog.end = 20;
    pack(&g, &buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), readF32(&buf, OFF_FOG_PARAMS + 12), 1e-6);

    g.fog.end = 10; // an empty range
    pack(&g, &buf);
    const v = readF32(&buf, OFF_FOG_PARAMS + 12);
    try expectEqual(@as(f32, 0), v);
    try expect(v == v); // and not a NaN
}

test "the COMBINE bytecode round-trips every field" {
    var g = testContext();
    var buf: [SIZE]u8 = undefined;
    // A unit contributes only once its texture has an image — bind it the way
    // glBindTexture + glTexImage2D would, or the environment is not packed at all.
    g.caps.texture_2d[0] = true;
    g.texture_binding[0] = 1;
    g.textures.ensureNamed(1) catch unreachable;
    g.textures.setDeviceHandle(1, 42, 4, .static);
    g.texenv[0] = .{
        .mode = .combine,
        .combine_rgb = .dot3_rgba,
        .combine_alpha = .subtract,
        .src_rgb = .{ .previous, .constant, .texture },
        .src_alpha = .{ .constant, .texture, .primary_color },
        .operand_rgb = .{ .one_minus_src_alpha, .src_color, .src_alpha },
        .operand_alpha = .{ .one_minus_src_alpha, .src_alpha, .one_minus_src_alpha },
        .rgb_scale = 4,
        .alpha_scale = 2,
    };
    pack(&g, &buf);
    const b = OFF_TEXENV + TEXENV_WORDS;

    const w0 = readU32(&buf, b + 0);
    try expectEqual(@as(u32, 5), w0 & 7); // combine
    try expectEqual(@as(u32, 7), (w0 >> 3) & 0xF); // dot3_rgba
    try expectEqual(@as(u32, 5), (w0 >> 7) & 7); // subtract

    const w1 = readU32(&buf, b + 4);
    try expectEqual(@as(u32, 3), w1 & 3); // src_rgb[0] = previous
    try expectEqual(@as(u32, 1), (w1 >> 2) & 3); // src_rgb[1] = constant
    try expectEqual(@as(u32, 0), (w1 >> 4) & 3); // src_rgb[2] = texture
    try expectEqual(@as(u32, 1), (w1 >> 6) & 3); // src_alpha[0] = constant

    const w2 = readU32(&buf, b + 8);
    try expectEqual(@as(u32, 3), w2 & 3); // operand_rgb[0] = one_minus_src_alpha
    try expectEqual(@as(u32, 1), (w2 >> 6) & 1); // operand_alpha[0] = one_minus_src_alpha

    const w3 = readU32(&buf, b + 12);
    try expectEqual(@as(u32, 2), w3 & 3); // rgb_scale 4 -> shift 2
    try expectEqual(@as(u32, 1), (w3 >> 2) & 3); // alpha_scale 2 -> shift 1
}

test "the scales become shifts, so the shader shifts instead of multiplying" {
    try expectEqual(@as(u32, 0), scaleShift(1.0));
    try expectEqual(@as(u32, 1), scaleShift(2.0));
    try expectEqual(@as(u32, 2), scaleShift(4.0));
}

test "packing is deterministic and leaves nothing uninitialised" {
    var g = testContext();
    var a: [SIZE]u8 = undefined;
    var b: [SIZE]u8 = undefined;
    @memset(&a, 0xAA);
    @memset(&b, 0x55); // different garbage in each
    pack(&g, &a);
    pack(&g, &b);
    // Every byte is written, so two different starting states converge exactly. Miss
    // one and this test sees the 0xAA.
    try std.testing.expectEqualSlices(u8, &a, &b);
}
