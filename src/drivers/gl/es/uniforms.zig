//! State -> the constant buffer the shaders read.
//!
//! Everything the key (shaderkey.zig) did NOT specialize on has to reach the shader as
//! data, and this is where it becomes bytes. Matrices, lights, material, fog, clip
//! planes, and — the reason the design is shaped this way — the texture environment,
//! compiled to a bytecode the fragment shader interprets rather than to a program.
//!
//! ## This file IS the ABI
//!
//! The byte layout below is a contract with the shader sources, and the compiler checks
//! neither side of it. A disagreement here does not fail to build: it renders garbage,
//! or renders correctly until someone adds a field. So the offsets are named constants,
//! the packing is one function, and the tests below pin the exact bytes. When the
//! shader sources land, their layout include is generated from these constants — one
//! fact, one home.
//!
//! ## Compaction
//!
//! GL numbers lights 0..7 sparsely: a program may enable only GL_LIGHT7. The shader has
//! an unrolled loop over `key.lights` slots, so light 7 must arrive in slot 0. The
//! compaction is shaderkey.zig's `enabledLights`, and both files use it — they cannot
//! disagree about which light is which.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.12 (lighting), §3.7.12 (texture
//! environment).

const std = @import("std");
const idraw = @import("idraw");
pub const limits = @import("limits.zig");
pub const matrix = @import("matrix.zig");
const shaderkey = @import("shaderkey.zig");
pub const state = @import("state.zig");

const Context = state.Context;
const Mat4 = matrix.Mat4;

/// GL's clip convention is not the hardware's, and this is the one place that is true.
///
/// glFrustum puts y up and depth in [-1, 1]; the rasterizer wants y down and depth in
/// [0, 1]. Rather than teach the projection code two conventions — where an application
/// could read the wrong one back with glGetFloatv(GL_PROJECTION_MATRIX) — the whole
/// difference is one matrix applied at the lowering:
///
///     x' = x,  y' = -y,  z' = (z + w) / 2,  w' = w
///
/// Column-major, so the halving sits at m[10] and the bias at m[14].
pub const CLIP_CORRECTION = Mat4{
    1, 0,  0,   0,
    0, -1, 0,   0,
    0, 0,  0.5, 0,
    0, 0,  0.5, 1,
};

// ── the layout ───────────────────────────────────────────────────────────────
//
// The field offsets are defined ONCE, on the seam (`idraw.uniform`), because three
// parties decode this image and must agree: this writer, the compiled shaders, and the
// software backend. They are re-exported here so this file reads its own field positions
// from that shared definition. The PRIVATE sub-offsets below — a light's and a texture
// environment's internal fields — are this writer's own business and stay here.

pub const OFF_MVP = idraw.uniform.OFF_MVP;
pub const OFF_MODELVIEW = idraw.uniform.OFF_MODELVIEW;
pub const OFF_NORMAL_MATRIX = idraw.uniform.OFF_NORMAL_MATRIX;
pub const OFF_TEX_MATRIX = idraw.uniform.OFF_TEX_MATRIX;
pub const OFF_MATERIAL = idraw.uniform.OFF_MATERIAL;
pub const OFF_LIGHT_MODEL_AMBIENT = idraw.uniform.OFF_LIGHT_MODEL_AMBIENT;
pub const OFF_FOG_COLOR = idraw.uniform.OFF_FOG_COLOR;
pub const OFF_FOG_PARAMS = idraw.uniform.OFF_FOG_PARAMS;
pub const OFF_MISC = idraw.uniform.OFF_MISC;
pub const OFF_CLIP_PLANES = idraw.uniform.OFF_CLIP_PLANES;
pub const OFF_LIGHTS = idraw.uniform.OFF_LIGHTS;
pub const OFF_TEXENV = idraw.uniform.OFF_TEXENV;
pub const LIGHT_STRIDE = idraw.uniform.LIGHT_STRIDE;
pub const TEXENV_STRIDE = idraw.uniform.TEXENV_STRIDE;
pub const SIZE = idraw.uniform.SIZE;

const LIGHT_AMBIENT: usize = 0x00;
pub const LIGHT_DIFFUSE: usize = 0x10;
const LIGHT_SPECULAR: usize = 0x20;
const LIGHT_POSITION: usize = 0x30; // eye space; w = 0 directional, 1 positional
pub const LIGHT_SPOT_DIR: usize = 0x40; // xyz = direction, w = cos(cutoff)
const LIGHT_ATTEN: usize = 0x50; // constant, linear, quadratic, spot_exponent

const TEXENV_COLOR: usize = 0x00;
pub const TEXENV_WORDS: usize = 0x10;

// ── writers ──────────────────────────────────────────────────────────────────

fn putF32(buf: []u8, off: usize, v: f32) void {
    std.mem.writeInt(u32, buf[off..][0..4], @bitCast(v), .little);
}

fn putU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

fn putVec4(buf: []u8, off: usize, v: [4]f32) void {
    for (v, 0..) |x, i| putF32(buf, off + i * 4, x);
}

fn putMat4(buf: []u8, off: usize, m: Mat4) void {
    for (m, 0..) |x, i| putF32(buf, off + i * 4, x);
}

/// A mat3 in three vec4s — the upper-left 3x3 of a column-major mat4, each column
/// padded to four floats.
fn putMat3(buf: []u8, off: usize, m: Mat4) void {
    for (0..3) |col| {
        for (0..3) |row| putF32(buf, off + col * 16 + row * 4, m[col * 4 + row]);
        putF32(buf, off + col * 16 + 12, 0);
    }
}

// ── the texture-environment bytecode ─────────────────────────────────────────
//
// The whole reason this API is interpreted rather than compiled. Four words carry a
// state space of 906 million per unit; the fragment shader decodes them.

/// Word 0: which function.
fn envWord0(e: state.TexEnv) u32 {
    const mode: u32 = @intFromEnum(e.mode);
    const crgb: u32 = @intFromEnum(e.combine_rgb);
    const calpha: u32 = @intFromEnum(e.combine_alpha);
    return mode | (crgb << 3) | (calpha << 7);
}

/// Word 1: where the three arguments come from — three 2-bit sources per side.
fn envWord1(e: state.TexEnv) u32 {
    var w: u32 = 0;
    for (e.src_rgb, 0..) |s, i| w |= @as(u32, @intFromEnum(s)) << @intCast(i * 2);
    for (e.src_alpha, 0..) |s, i| w |= @as(u32, @intFromEnum(s)) << @intCast(6 + i * 2);
    return w;
}

/// Word 2: how each argument is read. RGB operands need two bits; alpha operands only
/// one, because an alpha operand can only read alpha.
fn envWord2(e: state.TexEnv) u32 {
    var w: u32 = 0;
    for (e.operand_rgb, 0..) |o, i| w |= @as(u32, @intFromEnum(o)) << @intCast(i * 2);
    for (e.operand_alpha, 0..) |o, i| w |= @as(u32, @intFromEnum(o)) << @intCast(6 + i);
    return w;
}

/// Word 3: the scales. Only 1, 2 and 4 are legal, so each is two bits of shift rather
/// than a float the shader would have to multiply by.
fn envWord3(e: state.TexEnv) u32 {
    return scaleShift(e.rgb_scale) | (scaleShift(e.alpha_scale) << 2);
}

pub fn scaleShift(v: f32) u32 {
    return if (v == 4.0) 2 else if (v == 2.0) 1 else 0;
}

// ── packing ──────────────────────────────────────────────────────────────────

/// Write the whole constant image for the state as it stands. `buf` must be at least
/// SIZE bytes; the caller owns it, and it is reused every frame rather than allocated.
pub fn pack(g: *const Context, buf: []u8) void {
    std.debug.assert(buf.len >= SIZE);
    @memset(buf[0..SIZE], 0);

    const mv = g.modelview.top();
    const proj = g.projection.top();

    // The shader gets one product; there is no reason to make it multiply per vertex,
    // and the clip correction rides along for free rather than costing a second pass.
    putMat4(buf, OFF_MVP, matrix.mul(CLIP_CORRECTION, matrix.mul(proj, mv)));
    putMat4(buf, OFF_MODELVIEW, mv);
    // Normals need the inverse transpose in general. Under a rotation with uniform
    // scale — which is what a modelview stack built from glRotate/glTranslate/glScale
    // with equal scales is — the upper-left 3x3 suffices, and the shader renormalizes.
    // GL_NORMALIZE and GL_RESCALE_NORMAL exist precisely because the standard does not
    // promise more than this either.
    putMat3(buf, OFF_NORMAL_MATRIX, mv);

    for (0..limits.MAX_TEXTURE_UNITS) |u|
        putMat4(buf, OFF_TEX_MATRIX + u * 64, g.texture_matrix[u].top());

    const m = g.material_front;
    putVec4(buf, OFF_MATERIAL + 0x00, m.ambient);
    putVec4(buf, OFF_MATERIAL + 0x10, m.diffuse);
    putVec4(buf, OFF_MATERIAL + 0x20, m.specular);
    putVec4(buf, OFF_MATERIAL + 0x30, m.emission);
    putVec4(buf, OFF_MATERIAL + 0x40, .{ m.shininess, 0, 0, 0 });

    putVec4(buf, OFF_LIGHT_MODEL_AMBIENT, g.light_model_ambient);

    putVec4(buf, OFF_FOG_COLOR, g.fog.color);
    // The linear mode's shader wants 1/(end-start), and computing it here keeps a
    // divide out of every fragment. An empty range would divide by zero; the standard
    // does not say what it means, so we hand over zero and let the fog be uniform.
    const span = g.fog.end - g.fog.start;
    const inv_span: f32 = if (span != 0) 1.0 / span else 0;
    putVec4(buf, OFF_FOG_PARAMS, .{ g.fog.density, g.fog.start, g.fog.end, inv_span });

    // misc.z: the OES_point_sprite COORD_REPLACE mask, bit i = the unit in the
    // shader's PACKED slot i (contributingUnits order — the same compaction the
    // samplers use, so shader and mask cannot disagree about which unit is which).
    // Ordinary programs never read the lane; only a sprite draw's fragment does.
    var cr_units: [limits.MAX_TEXTURE_UNITS]u8 = undefined;
    const cr_n = shaderkey.contributingUnits(g, &cr_units);
    var cr_mask: u32 = 0;
    for (cr_units[0..cr_n], 0..) |gl_unit, slot| {
        if (g.texenv[gl_unit].coord_replace) cr_mask |= @as(u32, 1) << @intCast(slot);
    }
    putVec4(buf, OFF_MISC, .{ g.alpha_ref, g.point_size, @floatFromInt(cr_mask), 0 });

    for (0..limits.MAX_CLIP_PLANES) |i|
        putVec4(buf, OFF_CLIP_PLANES + i * 16, g.clip_plane[i]);

    // Lights, compacted: the shader's slot 0 is the first ENABLED light, not light 0.
    var idx: [limits.MAX_LIGHTS]u8 = undefined;
    const n = shaderkey.enabledLights(g, &idx);
    for (idx[0..n], 0..) |src, slot| {
        const l = g.lights[src];
        const base = OFF_LIGHTS + slot * LIGHT_STRIDE;
        putVec4(buf, base + LIGHT_AMBIENT, l.ambient);
        putVec4(buf, base + LIGHT_DIFFUSE, l.diffuse);
        putVec4(buf, base + LIGHT_SPECULAR, l.specular);
        putVec4(buf, base + LIGHT_POSITION, l.position);
        // The cutoff reaches the shader as its cosine: the shader compares a dot
        // product, and an inverse cosine per fragment would be absurd. 180 degrees means
        // "not a spotlight", and cos(180) = -1 compares true against every direction,
        // so the not-a-spotlight case needs no branch at all.
        const cutoff_cos: f32 = if (l.spot_cutoff == 180) -1.0 else @cos(l.spot_cutoff * std.math.pi / 180.0);
        putVec4(buf, base + LIGHT_SPOT_DIR, .{ l.spot_direction[0], l.spot_direction[1], l.spot_direction[2], cutoff_cos });
        putVec4(buf, base + LIGHT_ATTEN, .{
            l.constant_attenuation,
            l.linear_attenuation,
            l.quadratic_attenuation,
            l.spot_exponent,
        });
    }

    // Texture environments, compacted the same way.
    var units: [limits.MAX_TEXTURE_UNITS]u8 = undefined;
    const nu = shaderkey.contributingUnits(g, &units);
    for (units[0..nu], 0..) |src, slot| {
        const e = g.texenv[src];
        const base = OFF_TEXENV + slot * TEXENV_STRIDE;
        putVec4(buf, base + TEXENV_COLOR, e.color);
        putU32(buf, base + TEXENV_WORDS + 0, envWord0(e));
        putU32(buf, base + TEXENV_WORDS + 4, envWord1(e));
        putU32(buf, base + TEXENV_WORDS + 8, envWord2(e));
        putU32(buf, base + TEXENV_WORDS + 12, envWord3(e));
    }
}
