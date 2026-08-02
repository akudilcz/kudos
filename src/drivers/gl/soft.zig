//! Soft — the IDraw contract implemented in software, on the CPU, producing real pixels.
//!
//! kudos is GPU-only OpenGL hardware acceleration: on a real machine the desktop renders
//! only on the RTX 4090 (`opengl.zig`), and Soft is NOT in the boot/kernel path. It exists
//! as the HOST-TEST implementation of the `idraw` seam — the second interchangeable device
//! behind `gles` that lets the whole `gles → kgl → idraw` pipeline be exercised on a
//! laptop with no hardware.
//!
//! It decodes the SAME packed uniform image (`es/uniforms.zig`) the 216 compiled shader
//! variants decode, and evaluates the SAME fixed-function pipeline — lighting, the
//! texture environment, per-fragment operations — so a window it draws looks like the
//! window the 4090 draws, not merely something plausible. That makes it a second
//! independent reading of the specification the host tests diff against the shaders (a
//! wrong matrix or a mis-decoded COMBINE argument becomes a visibly wrong picture, on a
//! laptop, in milliseconds — see test/raster_test, test/gles_test, test/desktop_shot).
//!
//! Two implementations is what earns `idraw` its vtable. The mid-draw `pump` hook below
//! is inert now (nothing installs it) — it was the boot path's input-keep-alive; a test
//! fixture has no input to keep alive.
//!
//! ## Conventions
//!
//! Everything below the contract is the framebuffer's: y down from the top, depth in
//! [0, 1] — `gles` already applied the clip correction, so this rasterizer reads what
//! the hardware would read, not what GL wrote. Each context owns a top-down BGRA8 buffer
//! (its window's mirror); the compositor reads it back exactly as it reads a GPU mirror.
//!
//! ## Where the time goes
//!
//! A frame here is millions of fragments evaluated one at a time, so the shape of the
//! pixel loop is part of the design and not an afterthought. Three rules hold it:
//!
//!   * **Decode once per draw, never per fragment.** `Shade` below is the pipeline
//!     read into plain values. It exists because the loop writes bytes into the colour
//!     buffer and nothing proves to a compiler that those writes miss the `Pipeline`
//!     it was handed — so every state field read inside the loop would be re-loaded
//!     after every pixel written.
//!   * **Solve for the span, don't test the box.** A triangle's edges are planes over
//!     window space; intersecting them gives the covered run of each row directly, so
//!     a thin or diagonal triangle costs its own area rather than its bounding box.
//!   * **No transcendental in a fragment.** The sRGB transfer function has a
//!     256-value domain going in and a 256-value range coming out, so both directions
//!     are tables (`srgb`). A `pow` per channel per pixel is what separates a
//!     physically-based frame that takes milliseconds from one that takes a second.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.12 (lighting), §3.5 (polygon
//! rasterization), §3.7.12 (texture environment), §4.1 (per-fragment operations).

const std = @import("std");
const idraw = @import("idraw");
/// The uniform-image byte layout — the contract shared with `gles` and the shaders, so
/// this backend decodes the packed constants at exactly the offsets they were written to.
const uniforms = idraw.uniform;

pub const MAX_TEX = 32;
pub const MAX_BUF = 32;
/// Light slots the uniform image carries, derived from the contract's own layout
/// rather than restated: the lights occupy everything between their offset and the
/// texture environments that follow them.
const MAX_LIGHTS: usize = (uniforms.OFF_TEXENV - uniforms.OFF_LIGHTS) / uniforms.LIGHT_STRIDE;
// How many triangles rasterise between platform pumps (Soft.pump). Small enough
// that a dense mesh pumps every few milliseconds of work; large enough that the
// indirect call is invisible next to a triangle's raster cost.
const PUMP_TRIS: u32 = 256;
// Row cadence for the same pump inside ONE triangle's fill: a screen-sized quad
// is a single pair of triangles, and without a row-level pump it blocks input
// draining for its whole multi-megapixel fill.
const PUMP_ROWS: i32 = 64;
/// Transformed vertices kept between triangles of one draw. A strip, a fan and any
/// indexed mesh name most vertices more than once — a closed mesh names each about
/// six times — and the vertex stage is a matrix multiply and a lighting equation
/// whose answer cannot change within a draw. Direct-mapped on the element index, so
/// a hit costs one comparison and a miss costs what it always did.
const VERTEX_CACHE: u32 = 32;

const Buffer = struct {
    alive: bool = false,
    data: []u8 = &.{},
};

const Texture = struct {
    alive: bool = false,
    format: idraw.TexFormat = .bgra8,
    w: u32 = 0,
    h: u32 = 0,
    px: []u8 = &.{},
};

fn f32At(b: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, b[off..][0..4], .little));
}
fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}
fn vec4At(b: []const u8, off: usize) [4]f32 {
    return .{ f32At(b, off), f32At(b, off + 4), f32At(b, off + 8), f32At(b, off + 12) };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn norm3(v: [3]f32) [3]f32 {
    const l2 = dot3(v, v);
    if (l2 == 0) return .{ 0, 0, 0 };
    const inv = 1.0 / @sqrt(l2);
    return .{ v[0] * inv, v[1] * inv, v[2] * inv };
}
fn sat(v: f32) f32 {
    return if (v < 0) 0 else if (v > 1) 1 else v;
}
/// x⁵, as four multiplies. The Fresnel-Schlick exponent is an integer, and a
/// general `pow` for it costs a fragment more than the whole reflectance model
/// around it.
fn pow5(x: f32) f32 {
    const x2 = x * x;
    return x2 * x2 * x;
}

fn px8(v: f32) u8 {
    return @intFromFloat(@round(sat(v) * 255.0));
}

/// Each byte as its channel fraction, `b / 255`.
///
/// A table and not a divide: 1/255 has no exact binary form, so the compiler may
/// not turn the division into a multiply, and a textured fragment does four of them
/// per texel plus four more to read the destination back for blending. The values
/// are the same ones the division produces — this is the identical quotient,
/// precomputed.
const byte_fraction: [256]f32 = blk: {
    var t: [256]f32 = undefined;
    for (&t, 0..) |*e, i| e.* = @as(f32, @floatFromInt(i)) / 255.0;
    break :blk t;
};

/// Pack straight RGBA floats into one framebuffer word. The buffer is BGRA8 in
/// memory order, so on a little-endian machine blue is the low byte.
///
/// One vector, because this is the last thing every fragment in a frame does and
/// the four channels are the same three operations each. Lane by lane it is
/// `px8`: clamp, scale, round to nearest — so the byte is the one the scalar form
/// produces.
fn packBgra(c: [4]f32) u32 {
    const V = @Vector(4, f32);
    const bgra = V{ c[2], c[1], c[0], c[3] };
    const clamped = @min(@max(bgra, @as(V, @splat(0.0))), @as(V, @splat(1.0)));
    const bytes: @Vector(4, u8) = @intFromFloat(@round(clamped * @as(V, @splat(255.0))));
    return @bitCast(bytes);
}

// ── the sRGB transfer function, as tables ────────────────────────────────────

/// sRGB (IEC 61966-2-1) in both directions, tabulated at compile time.
///
/// The physically-based fragment crosses this curve six times — three texel channels
/// decoded on the way in, three linear channels encoded on the way out — and a `pow`
/// each way is what makes a software PBR fragment cost more than everything else in
/// the pipeline combined. Neither direction needs one, because neither domain is
/// continuous where it matters:
///
///   * Decoding starts from a texel channel, which is one of 256 bytes. The table of
///     their linear intensities is not an approximation of the curve — for the inputs
///     that exist, it IS the curve.
///   * Encoding ends at a framebuffer byte, which is one of 256 values. What a
///     fragment needs is therefore not the curve but the 255 linear intensities at
///     which the rounded byte steps, and finding which side of them a value falls on
///     answers exactly what evaluating and rounding the curve would have answered.
const srgb = struct {
    /// Linear intensity of each encoded byte.
    const decode_byte: [256]f32 = blk: {
        @setEvalBranchQuota(100_000);
        var t: [256]f32 = undefined;
        for (&t, 0..) |*e, i| e.* = @floatCast(toLinear(@as(f64, @floatFromInt(i)) / 255.0));
        break :blk t;
    };

    /// `step[k]` is the lowest linear intensity that encodes to byte `k`; entry 0 is
    /// unused because every non-negative value clears it.
    const step: [256]f32 = blk: {
        @setEvalBranchQuota(100_000);
        var t: [256]f32 = undefined;
        t[0] = 0;
        for (t[1..], 1..) |*e, k| e.* = @floatCast(toLinear((@as(f64, @floatFromInt(k)) - 0.5) / 255.0));
        break :blk t;
    };

    /// A lower bound on the byte for a linear value, bucketed uniformly over [0, 1].
    /// The true byte is between this bucket's entry and the next one's, which turns
    /// the search over `step` into a walk of a few entries — usually none.
    const GUESS_BUCKETS: usize = 4096;
    const guess: [GUESS_BUCKETS + 1]u8 = blk: {
        @setEvalBranchQuota(100_000);
        var t: [GUESS_BUCKETS + 1]u8 = undefined;
        // Both the buckets and `step` ascend, so one shared walk fills the table.
        var k: usize = 0;
        for (&t, 0..) |*e, i| {
            const x: f32 = @as(f32, @floatFromInt(i)) / @as(f32, GUESS_BUCKETS);
            while (k < 255 and step[k + 1] <= x) k += 1;
            e.* = @intCast(k);
        }
        break :blk t;
    };

    /// Encoded fraction → linear intensity. Used to build the tables, and by the one
    /// caller that still needs the curve itself.
    fn toLinear(c: f64) f64 {
        return if (c <= 0.04045) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
    }

    /// Linear intensity → encoded fraction. The direct curve, for a fragment whose
    /// value still has arithmetic ahead of it and so cannot go straight to a byte.
    fn toEncoded(c: f32) f32 {
        return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
    }

    /// The framebuffer byte a linear intensity encodes to — what `px8(toEncoded(x))`
    /// answers, without the transcendental in between.
    fn encodeByte(x: f32) u8 {
        const c = sat(x);
        var k: usize = guess[@intFromFloat(c * @as(f32, GUESS_BUCKETS))];
        while (k < 255 and step[k + 1] <= c) k += 1;
        return @intCast(k);
    }
};

// ── one draw's state, read out of the pipeline ───────────────────────────────

/// A texture unit resolved to the pixels it will actually read.
///
/// The pipeline names a texture by handle; every fragment that samples it would
/// otherwise re-walk the device's table, re-check the liveness flag and re-convert
/// the dimensions to floats. None of that can change during a draw.
const Sampler = struct {
    px: []const u8,
    w: u32,
    h: u32,
    fw: f32,
    fh: f32,
    stride: usize,
    format: idraw.TexFormat,
    wrap_s: idraw.WrapMode,
    wrap_t: idraw.WrapMode,
    /// The texel this sampler always reads, when the coordinate cannot change the
    /// answer. Two cases reach it: a unit that is BOUND but whose texture is not
    /// usable, which reads opaque white — the identity of the default environment,
    /// so an incomplete texture leaves the fragment it would have coloured alone
    /// rather than blacking it out (distinct from an ABSENT unit, which contributes
    /// nothing at all) — and a 1x1 texture, which glTF materials use wherever a
    /// constant factor stands in for a map. Both make the wrap, the scale and the
    /// address arithmetic dead work.
    fixed: ?@Vector(4, u8),

    fn resolve(dev: *const Soft, unit: ?idraw.Unit) ?Sampler {
        const u = unit orelse return null;
        const usable = u.texture != 0 and u.texture <= MAX_TEX and
            dev.textures[u.texture - 1].alive and dev.textures[u.texture - 1].w != 0;
        if (!usable) return Sampler{
            .px = &.{},
            .w = 0,
            .h = 0,
            .fw = 0,
            .fh = 0,
            .stride = 0,
            .format = .bgra8,
            .wrap_s = u.wrap_s,
            .wrap_t = u.wrap_t,
            .fixed = .{ 255, 255, 255, 255 },
        };
        const t = dev.textures[u.texture - 1];
        var s = Sampler{
            .px = t.px,
            .w = t.w,
            .h = t.h,
            .fw = @floatFromInt(t.w),
            .fh = @floatFromInt(t.h),
            .stride = bytesPer(t.format),
            .format = t.format,
            .wrap_s = u.wrap_s,
            .wrap_t = u.wrap_t,
            .fixed = null,
        };
        if (t.w == 1 and t.h == 1) s.fixed = s.decodeTexel(0);
        return s;
    }

    fn bytesPer(f: idraw.TexFormat) usize {
        return switch (f) {
            .bgra8 => 4,
            .luminance_alpha8 => 2,
            .luminance8, .alpha8 => 1,
        };
    }

    fn wrap(v: f32, m: idraw.WrapMode) f32 {
        return switch (m) {
            .repeat => v - @floor(v),
            .clamp_to_edge => sat(v),
        };
    }

    /// The texel's own bytes at a coordinate.
    ///
    /// Nearest only: linear would need four taps and this exists to check the
    /// ARITHMETIC of the environment, not the filter.
    fn texel(s: *const Sampler, uv: [2]f32) @Vector(4, u8) {
        if (s.fixed) |f| return f;
        const x = @min(s.w - 1, @as(u32, @intFromFloat(@max(0.0, wrap(uv[0], s.wrap_s) * s.fw))));
        const y = @min(s.h - 1, @as(u32, @intFromFloat(@max(0.0, wrap(uv[1], s.wrap_t) * s.fh))));
        return s.decodeTexel(@as(usize, y) * s.w + x);
    }

    /// Texel number `n` of the level, in the sampler's own channel order.
    ///
    /// A vector, not four bytes: the caller turns it straight into channel
    /// fractions, and returning an array sends it through the stack so each channel
    /// comes back out with a byte load that has to wait on the store.
    fn decodeTexel(s: *const Sampler, n: usize) @Vector(4, u8) {
        const p = s.px[n * s.stride ..];
        return switch (s.format) {
            .bgra8 => .{ p[2], p[1], p[0], p[3] },
            // Luminance replicates into rgb with alpha 1; alpha is the mirror image.
            .luminance8 => .{ p[0], p[0], p[0], 255 },
            .alpha8 => .{ 0, 0, 0, p[0] },
            .luminance_alpha8 => .{ p[0], p[0], p[0], p[1] },
        };
    }

    /// The texel as the fixed-function pipeline sees it: channel fractions.
    ///
    /// Four lanes at once. The divide is the arithmetic the specification asks for
    /// and each lane rounds exactly as the scalar quotient does — what the vector
    /// buys is the four separate conversions collapsing into one instruction, on
    /// the hottest line in a textured frame.
    fn sample(s: *const Sampler, uv: [2]f32) [4]f32 {
        const f: @Vector(4, f32) = @floatFromInt(s.texel(uv));
        return f / @as(@Vector(4, f32), @splat(255.0));
    }

    /// The texel with its colour channels decoded out of sRGB — how base-colour and
    /// emissive maps are authored, and what the lighting math needs. Alpha is a
    /// coverage fraction, never an intensity, so it is not decoded.
    fn sampleSrgb(s: *const Sampler, uv: [2]f32) [4]f32 {
        const t = s.texel(uv);
        return .{
            srgb.decode_byte[t[0]],
            srgb.decode_byte[t[1]],
            srgb.decode_byte[t[2]],
            byte_fraction[t[3]],
        };
    }
};

/// What an UNBOUND material-map slot samples: the map's neutral identity
/// (idraw.MatMap — metal-rough white, normal flat +Z, occlusion white, emissive
/// black), so a partial binding shades correctly rather than being refused or
/// silently ignored.
fn matMapIdentity(slot: idraw.MatMap) [4]f32 {
    return switch (slot) {
        .metal_rough, .occlusion => .{ 1, 1, 1, 1 },
        .normal => .{ 0.5, 0.5, 1, 1 },
        .emissive => .{ 0, 0, 0, 1 },
    };
}

/// One texture unit's environment, decoded from the packed bytecode.
///
/// The bytecode is `gles`'s answer to a combiner space too large to enumerate as
/// shader variants (906 million states for one unit). What a fragment needs from it
/// is a handful of small integers; re-extracting them from four words for every pixel
/// is the same answer computed a million times.
const TexEnv = struct {
    constant: [4]f32,
    mode: u32,
    combine_rgb: u32,
    combine_alpha: u32,
    src_rgb: [3]u32,
    src_alpha: [3]u32,
    op_rgb: [3]u32,
    op_alpha: [3]u32,
    rgb_scale: f32,
    alpha_scale: f32,

    fn decode(u: []const u8, slot: usize) TexEnv {
        const base = uniforms.OFF_TEXENV + slot * uniforms.TEXENV_STRIDE;
        const w0 = u32At(u, base + 0x10);
        const w1 = u32At(u, base + 0x14);
        const w2 = u32At(u, base + 0x18);
        const w3 = u32At(u, base + 0x1C);
        var e = TexEnv{
            .constant = vec4At(u, base),
            .mode = w0 & 7,
            .combine_rgb = (w0 >> 3) & 0xF,
            .combine_alpha = (w0 >> 7) & 7,
            .src_rgb = undefined,
            .src_alpha = undefined,
            .op_rgb = undefined,
            .op_alpha = undefined,
            // The scales arrive as shifts: 1, 2, 4.
            .rgb_scale = @floatFromInt(@as(u32, 1) << @intCast(w3 & 3)),
            .alpha_scale = @floatFromInt(@as(u32, 1) << @intCast((w3 >> 2) & 3)),
        };
        for (0..3) |i| {
            e.src_rgb[i] = (w1 >> @intCast(i * 2)) & 3;
            e.src_alpha[i] = (w1 >> @intCast(6 + i * 2)) & 3;
            e.op_rgb[i] = (w2 >> @intCast(i * 2)) & 3;
            e.op_alpha[i] = (w2 >> @intCast(6 + i)) & 1;
        }
        return e;
    }

    fn pick(src: u32, texel: [4]f32, constant: [4]f32, primary: [4]f32, prev: [4]f32) [4]f32 {
        return switch (src) {
            0 => texel,
            1 => constant,
            2 => primary,
            else => prev,
        };
    }

    /// Evaluate the environment for one unit. This IS the shader's job, written once
    /// here and once in GLSL, from the same tables.
    fn eval(e: *const TexEnv, prev: [4]f32, primary: [4]f32, texel: [4]f32) [4]f32 {
        // The five non-COMBINE functions (§3.7.12, table 3.16). Each is one
        // elementwise expression over the four channels — the alpha channel differs
        // only in which of them it takes, so it is written afterwards rather than
        // splitting the arithmetic in three.
        const V = @Vector(4, f32);
        const p: V = prev;
        const t: V = texel;
        const one: V = @splat(1.0);
        switch (e.mode) {
            0 => return texel, // REPLACE
            1 => return p * t, // MODULATE
            2 => { // DECAL: the texel's alpha blends its rgb over prev, alpha untouched
                const a: V = @splat(texel[3]);
                var out: [4]f32 = p * (one - a) + t * a;
                out[3] = prev[3];
                return out;
            },
            3 => { // BLEND: the texel picks between prev and the constant
                var out: [4]f32 = p * (one - t) + @as(V, e.constant) * t;
                out[3] = prev[3] * texel[3];
                return out;
            },
            4 => { // ADD
                var out: [4]f32 = @min(@max(p + t, @as(V, @splat(0.0))), one);
                out[3] = prev[3] * texel[3];
                return out;
            },
            else => {},
        }

        var arg_rgb: [3][3]f32 = undefined;
        var arg_a: [3]f32 = undefined;
        for (0..3) |i| {
            const s_rgb = pick(e.src_rgb[i], texel, e.constant, primary, prev);
            const s_a = pick(e.src_alpha[i], texel, e.constant, primary, prev);
            arg_rgb[i] = switch (e.op_rgb[i]) {
                0 => .{ s_rgb[0], s_rgb[1], s_rgb[2] },
                1 => .{ 1 - s_rgb[0], 1 - s_rgb[1], 1 - s_rgb[2] },
                2 => .{ s_rgb[3], s_rgb[3], s_rgb[3] },
                else => .{ 1 - s_rgb[3], 1 - s_rgb[3], 1 - s_rgb[3] },
            };
            arg_a[i] = if (e.op_alpha[i] == 0) s_a[3] else 1 - s_a[3];
        }

        var rgb: [3]f32 = undefined;
        switch (e.combine_rgb) {
            0 => rgb = arg_rgb[0], // REPLACE
            1 => for (0..3) |k| {
                rgb[k] = arg_rgb[0][k] * arg_rgb[1][k];
            }, // MODULATE
            2 => for (0..3) |k| {
                rgb[k] = arg_rgb[0][k] + arg_rgb[1][k];
            }, // ADD
            3 => for (0..3) |k| {
                rgb[k] = arg_rgb[0][k] + arg_rgb[1][k] - 0.5;
            }, // ADD_SIGNED
            4 => for (0..3) |k| {
                rgb[k] = arg_rgb[0][k] * arg_rgb[2][k] + arg_rgb[1][k] * (1 - arg_rgb[2][k]);
            }, // INTERPOLATE
            5 => for (0..3) |k| {
                rgb[k] = arg_rgb[0][k] - arg_rgb[1][k];
            }, // SUBTRACT
            else => { // DOT3_RGB / DOT3_RGBA: one scalar into every channel
                var d: f32 = 0;
                for (0..3) |k| d += (arg_rgb[0][k] - 0.5) * (arg_rgb[1][k] - 0.5);
                d *= 4;
                rgb = .{ d, d, d };
            },
        }

        var alpha: f32 = switch (e.combine_alpha) {
            0 => arg_a[0],
            1 => arg_a[0] * arg_a[1],
            2 => arg_a[0] + arg_a[1],
            3 => arg_a[0] + arg_a[1] - 0.5,
            4 => arg_a[0] * arg_a[2] + arg_a[1] * (1 - arg_a[2]),
            else => arg_a[0] - arg_a[1],
        };
        // DOT3_RGBA puts its scalar in alpha too, and the alpha combiner is ignored.
        if (e.combine_rgb == 7) alpha = rgb[0];

        return .{
            sat(rgb[0] * e.rgb_scale),
            sat(rgb[1] * e.rgb_scale),
            sat(rgb[2] * e.rgb_scale),
            sat(alpha * e.alpha_scale),
        };
    }
};

/// One light's parameters, decoded out of the uniform image.
const Light = struct {
    ambient: [4]f32,
    diffuse: [4]f32,
    specular: [4]f32,
    position: [4]f32,
};

/// The surface's reflectance, decoded out of the uniform image.
const Material = struct {
    ambient: [4]f32,
    diffuse: [4]f32,
    specular: [4]f32,
    emission: [4]f32,
    shininess: f32,
};

/// One draw's pipeline state, decoded into plain values.
///
/// The pixel loop writes bytes into the colour buffer, and nothing proves to a
/// compiler that those writes cannot land on the `Pipeline` the draw was handed — so
/// every state field the loop reads would be re-loaded from memory after every pixel
/// it writes, and every packed word re-decoded. Reading the state once, here, is what
/// lets the loop hold it in registers.
const Shade = struct {
    lit: bool,
    /// Any material map bound → the draw shades the physically-based path
    /// (GL_KUDOS_material_maps, spec RND-005) instead of the per-vertex
    /// fixed-function equation.
    pbr: bool,
    unit_count: usize,
    unit: [idraw.MAX_UNITS]?Sampler,
    env: [idraw.MAX_UNITS]TexEnv,
    map: [idraw.MatMap.COUNT]?Sampler,
    map_default: [idraw.MatMap.COUNT][4]f32,

    lights: usize,
    light: [MAX_LIGHTS]Light,
    /// Light slot 0's direction when it is DIRECTIONAL — the position is then the
    /// direction and is the same for every fragment in the draw, so normalising it
    /// per fragment costs a square root and a divide to reproduce a constant. Null
    /// when the light is positional, where the direction genuinely varies.
    light0_dir: ?[3]f32,
    material: Material,
    scene_ambient: [4]f32,

    viewport: idraw.Rect,
    scissor: ?idraw.Rect,
    depth_range: [2]f32,
    cull: ?idraw.CullFace,
    front_ccw: bool,

    depth_test: bool,
    depth_func: idraw.CompareFunc,
    depth_write: bool,
    alpha_test: ?idraw.AlphaTest,
    blend: idraw.Blend,
    mask: [4]bool,
    /// Every channel writable — the case where a fragment is one word, not four
    /// masked bytes.
    mask_all: bool,

    fn decode(dev: *const Soft, p: *const idraw.Pipeline) Shade {
        const u = p.uniforms;
        var s = Shade{
            .lit = p.key.lights > 0,
            .pbr = false,
            .unit_count = p.key.units,
            .unit = undefined,
            .env = undefined,
            .map = undefined,
            .map_default = undefined,
            .lights = p.key.lights,
            .light = undefined,
            .light0_dir = null,
            .material = .{
                .ambient = vec4At(u, uniforms.OFF_MATERIAL + 0x00),
                .diffuse = vec4At(u, uniforms.OFF_MATERIAL + 0x10),
                .specular = vec4At(u, uniforms.OFF_MATERIAL + 0x20),
                .emission = vec4At(u, uniforms.OFF_MATERIAL + 0x30),
                .shininess = f32At(u, uniforms.OFF_MATERIAL + 0x40),
            },
            .scene_ambient = vec4At(u, uniforms.OFF_LIGHT_MODEL_AMBIENT),
            .viewport = p.viewport,
            .scissor = p.scissor,
            .depth_range = p.depth_range,
            .cull = p.raster.cull,
            .front_ccw = p.raster.front_face == .ccw,
            .depth_test = p.depth.test_enable,
            .depth_func = p.depth.func,
            .depth_write = p.depth.write,
            .alpha_test = p.alpha_test,
            .blend = p.blend,
            .mask = p.color_mask,
            .mask_all = p.color_mask[0] and p.color_mask[1] and p.color_mask[2] and p.color_mask[3],
        };
        for (0..idraw.MAX_UNITS) |i| {
            s.unit[i] = Sampler.resolve(dev, p.units[i]);
            s.env[i] = TexEnv.decode(u, i);
        }
        for (0..idraw.MatMap.COUNT) |i| {
            const slot: idraw.MatMap = @enumFromInt(i);
            s.map[i] = Sampler.resolve(dev, p.mat_maps[i]);
            s.map_default[i] = matMapIdentity(slot);
            if (p.mat_maps[i] != null) s.pbr = true;
        }
        s.pbr = s.pbr and s.lit;
        for (0..s.lights) |i| {
            const base = uniforms.OFF_LIGHTS + i * uniforms.LIGHT_STRIDE;
            s.light[i] = .{
                .ambient = vec4At(u, base + 0x00),
                .diffuse = vec4At(u, base + 0x10),
                .specular = vec4At(u, base + 0x20),
                .position = vec4At(u, base + 0x30),
            };
        }
        if (s.lights > 0 and s.light[0].position[3] == 0) {
            const lp = s.light[0].position;
            s.light0_dir = norm3(.{ lp[0], lp[1], lp[2] });
        }
        return s;
    }

    /// Sample one material-map slot, or its neutral identity when unbound.
    fn mapSample(s: *const Shade, slot: idraw.MatMap, uv: [2]f32) [4]f32 {
        const i = @intFromEnum(slot);
        const smp = s.map[i] orelse return s.map_default[i];
        return smp.sample(uv);
    }

    /// The same slot with its colour channels decoded out of sRGB.
    fn mapSampleSrgb(s: *const Shade, slot: idraw.MatMap, uv: [2]f32) [4]f32 {
        const i = @intFromEnum(slot);
        const smp = s.map[i] orelse return s.map_default[i];
        return smp.sampleSrgb(uv);
    }
};

/// One vertex, after the fetch and the transform.
const Vertex = struct {
    clip: [4]f32, // after the mvp
    eye: [3]f32, // after the modelview, for lighting
    normal: [3]f32,
    color: [4]f32,
    uv: [2][2]f32,
};

pub const SoftCtx = struct {
    in_use: bool = false,
    dst: idraw.Dst = undefined,
    recording: bool = false,
    landed: bool = false,

    w: u32 = 0,
    h: u32 = 0,
    /// BGRA8, rows top-down — the framebuffer's own layout. Word-aligned so a clear
    /// and an unmasked fragment write move one pixel at a time rather than four
    /// bytes.
    color: []align(4) u8 = &.{},
    depth: []f32 = &.{},

    /// The union of every clipped raster/clear bbox shaded THIS frame — what
    /// `deliver` copies out. Row-exact delivery is what keeps a small-damage
    /// frame cheap end to end: the destination can be UNCACHEABLE scanout
    /// memory, where copying the whole screen costs more than shading the
    /// damage did. Reset empty (x0 > x1) each beginFrame.
    dirty_x0: i32 = 0,
    dirty_y0: i32 = 0,
    dirty_x1: i32 = 0,
    dirty_y1: i32 = 0,

    draws: u32 = 0,
    dev: *Soft = undefined,

    pub fn iface(self: *SoftCtx) idraw.IDrawCtx {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = idraw.IDrawCtx.VTable{
        .beginFrame = beginFrame,
        .clear = clear,
        .draw = draw,
        .readPixels = readPixels,
        .endFrame = endFrame,
        .frameReady = frameReady,
        .discard = discard,
    };

    fn cast(c: *anyopaque) *SoftCtx {
        return @ptrCast(@alignCast(c));
    }

    /// The colour buffer addressed one pixel at a time.
    fn words(self: *SoftCtx) []u32 {
        return std.mem.bytesAsSlice(u32, self.color);
    }

    fn beginFrame(c: *anyopaque, w: u32, h: u32) idraw.Error!void {
        const self = cast(c);
        if (w == 0 or h == 0 or w > idraw.MAX_W or h > idraw.MAX_H) return idraw.Error.DrawBadViewport;
        const n = @as(usize, w) * h;
        if (self.color.len != n * 4) {
            self.dev.alloc.free(self.color);
            self.dev.alloc.free(self.depth);
            self.color = self.dev.alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4), n * 4) catch return idraw.Error.DrawOutOfResources;
            self.depth = self.dev.alloc.alloc(f32, n) catch return idraw.Error.DrawOutOfResources;
        }
        self.w = w;
        self.h = h;
        self.recording = true;
        self.landed = false;
        // Empty dirty box: nothing shaded yet this frame.
        self.dirty_x0 = @intCast(w);
        self.dirty_y0 = @intCast(h);
        self.dirty_x1 = 0;
        self.dirty_y1 = 0;
        return;
    }

    /// Union a shaded (clipped) bbox into this frame's dirty box.
    fn markShaded(self: *SoftCtx, x0: i32, y0: i32, x1: i32, y1: i32) void {
        if (x1 <= x0 or y1 <= y0) return;
        self.dirty_x0 = @min(self.dirty_x0, x0);
        self.dirty_y0 = @min(self.dirty_y0, y0);
        self.dirty_x1 = @max(self.dirty_x1, x1);
        self.dirty_y1 = @max(self.dirty_y1, y1);
    }

    /// The framebuffer rectangle a box intersects, clipped to it. Empty when
    /// `x1 <= x0` or `y1 <= y0`.
    fn clipBox(self: *SoftCtx, box: idraw.Rect) [4]i32 {
        return .{
            @max(0, box.x),
            @max(0, box.y),
            @min(@as(i32, @intCast(self.w)), box.x +| @as(i32, @intCast(box.w))),
            @min(@as(i32, @intCast(self.h)), box.y +| @as(i32, @intCast(box.h))),
        };
    }

    fn clear(c: *anyopaque, m: idraw.ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?idraw.Rect) idraw.Error!void {
        _ = stencil;
        const self = cast(c);
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        const box = self.clipBox(sc orelse idraw.Rect{ .x = 0, .y = 0, .w = self.w, .h = self.h });
        if (box[2] <= box[0] or box[3] <= box[1]) return;
        if (m.color) self.markShaded(box[0], box[1], box[2], box[3]);

        // A clear writes one value over a rectangle, which is a fill and not a loop
        // over pixels: a full-screen one is the largest single write in a frame, and
        // spelling it as a fill is what keeps it off the frame's critical path.
        const word = packBgra(color);
        const span: usize = @intCast(box[2] - box[0]);
        const cw = self.words();
        var y: usize = @intCast(box[1]);
        while (y < @as(usize, @intCast(box[3]))) : (y += 1) {
            const row = y * self.w + @as(usize, @intCast(box[0]));
            if (m.color) @memset(cw[row..][0..span], word);
            if (m.depth) @memset(self.depth[row..][0..span], depth);
        }
    }

    fn endFrame(c: *anyopaque) idraw.Error!void {
        const self = cast(c);
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        self.recording = false;
        self.landed = true;
        self.deliver();
        return;
    }

    /// Copy the finished frame into the window surface the `Dst` addresses, so the
    /// compositor shows it directly — the CPU mirror, in place of the GPU's VRAM one. The
    /// backend renders into its own tight buffer and blits here rather than rasterizing
    /// straight into the surface, so the rasterizer stays stride-agnostic. `win_base == 0`
    /// (host tests, which read `color` back themselves) makes this a no-op.
    ///
    /// Only the frame's SHADED bbox is copied: everything outside it is
    /// pixel-identical to what the surface already shows (the buffer persists
    /// across frames), and the surface can be uncacheable scanout memory where
    /// a whole-screen copy costs milliseconds a small frame never spent
    /// shading. It also keeps the host's dirty tracking honest — QEMU re-scans
    /// only pages that really changed.
    fn deliver(self: *SoftCtx) void {
        if (self.dst.win_base == 0) return;
        if (self.dirty_x1 <= self.dirty_x0 or self.dirty_y1 <= self.dirty_y0) return;
        const surf: [*]u8 = @ptrFromInt(self.dst.win_base);
        const stride = self.dst.stride_px;
        const x0: usize = @intCast(self.dirty_x0);
        const span_bytes = (@as(usize, @intCast(self.dirty_x1)) - x0) * 4;
        var y: u32 = @intCast(self.dirty_y0);
        while (y < @as(u32, @intCast(self.dirty_y1))) : (y += 1) {
            const dy = self.dst.off_y + y;
            const drow = (@as(usize, dy) * stride + self.dst.off_x + x0) * 4;
            const srow = (@as(usize, y) * self.w + x0) * 4;
            @memcpy(surf[drow..][0..span_bytes], self.color[srow..][0..span_bytes]);
        }
    }
    fn frameReady(c: *anyopaque) bool {
        return cast(c).landed;
    }
    fn discard(c: *anyopaque) void {
        const self = cast(c);
        self.recording = false;
        self.landed = false;
    }

    fn readPixels(c: *anyopaque, r: idraw.Rect, fmt: idraw.ReadFormat, dst: []u8) idraw.Error!void {
        const self = cast(c);
        const n = @as(usize, r.w) * r.h * 4;
        if (dst.len < n) return idraw.Error.DrawBadViewport;
        for (0..r.h) |yy| {
            const sy = @as(i32, @intCast(yy)) + r.y;
            const drow = yy * r.w * 4;
            if (sy < 0 or sy >= self.h) {
                @memset(dst[drow..][0 .. @as(usize, r.w) * 4], 0);
                continue;
            }
            // The run of this row that lies inside the framebuffer; everything to
            // either side of it reads as zero.
            const lo: usize = @min(r.w, @as(usize, @intCast(@max(0, -r.x))));
            const hi: usize = @intCast(@max(0, @min(@as(i32, @intCast(r.w)), @as(i32, @intCast(self.w)) -| r.x)));
            if (lo > 0) @memset(dst[drow..][0 .. lo * 4], 0);
            if (hi < r.w) @memset(dst[drow + hi * 4 ..][0 .. (r.w - hi) * 4], 0);
            if (hi <= lo) continue;
            const src = (@as(usize, @intCast(sy)) * self.w + @as(usize, @intCast(r.x + @as(i32, @intCast(lo))))) * 4;
            switch (fmt) {
                .bgra8 => @memcpy(dst[drow + lo * 4 ..][0 .. (hi - lo) * 4], self.color[src..][0 .. (hi - lo) * 4]),
                .rgba8 => for (lo..hi) |xx| {
                    const d = drow + xx * 4;
                    const s = src + (xx - lo) * 4;
                    dst[d + 0] = self.color[s + 2];
                    dst[d + 1] = self.color[s + 1];
                    dst[d + 2] = self.color[s + 0];
                    dst[d + 3] = self.color[s + 3];
                },
            }
        }
    }

    // ── the pipeline ─────────────────────────────────────────────────────────

    fn draw(c: *anyopaque, p: *const idraw.Pipeline, d: *const idraw.Draw) idraw.Error!void {
        const self = cast(c);
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        self.draws += 1;
        if (d.prim != .triangles and d.prim != .triangle_strip and d.prim != .triangle_fan) return; // only filled prims here

        const st = Shade.decode(self.dev, p);
        var cache = VertexCache{};

        const n = d.count;
        var i: u32 = 0;
        var tris: u32 = 0;
        while (i + 3 <= n) : (i += if (d.prim == .triangles) 3 else 1) {
            // A fan pivots every triangle on element 0 (the centre); a strip and a
            // triangle list walk forward. Getting this wrong renders a fan as a ribbon
            // of thin perimeter slivers — the interior never fills.
            const first = if (d.prim == .triangle_fan) 0 else i;
            const a = cache.vertex(self, &st, p, d, self.elem(d, first));
            const b = cache.vertex(self, &st, p, d, self.elem(d, i + 1));
            const cc = cache.vertex(self, &st, p, d, self.elem(d, i + 2));
            self.triangle(&st, a, b, cc);
            // A large mesh (a lit model is thousands of triangles) rasterises for
            // longer than the platform's input buffering survives — let the host
            // drain its rings mid-draw. Proven need, not caution: one software
            // teapot frame outlasts the emulated keyboard's whole 16-event queue,
            // and the dropped keys were the boot suite's command tails.
            tris += 1;
            if (tris % PUMP_TRIS == 0) {
                if (self.dev.pump) |pu| pu();
            }
        }
    }

    /// The vertex index for element `i` — through the index buffer when there is one.
    fn elem(self: *SoftCtx, d: *const idraw.Draw, i: u32) u32 {
        const ix = d.index orelse return d.first + i;
        const buf = self.dev.buffers[ix.buffer - 1].data;
        return switch (ix.type) {
            .u8 => buf[ix.offset + i],
            .u16 => std.mem.readInt(u16, buf[ix.offset + i * 2 ..][0..2], .little),
            .u32 => std.mem.readInt(u32, buf[ix.offset + i * 4 ..][0..4], .little),
        };
    }

    fn fetch(self: *SoftCtx, a: idraw.Attrib, v: u32) [4]f32 {
        return switch (a) {
            .disabled => .{ 0, 0, 0, 1 },
            .constant => |k| k,
            .array => |arr| blk: {
                const buf = self.dev.buffers[arr.buffer - 1].data;
                const at = arr.offset + v * arr.stride;
                break :blk decode(buf[at..], arr.format);
            },
        };
    }

    /// The one place that knows what each vertex format MEANS — the same distinction
    /// attrib.zig makes: a normal's bytes normalize, a position's do not.
    fn decode(s: []const u8, f: idraw.AttribFormat) [4]f32 {
        const i8v = struct {
            fn g(b: []const u8, i: usize) f32 {
                return @floatFromInt(@as(i8, @bitCast(b[i])));
            }
        };
        const i16v = struct {
            fn g(b: []const u8, i: usize) f32 {
                return @floatFromInt(std.mem.readInt(i16, b[i * 2 ..][0..2], .little));
            }
        };
        return switch (f) {
            .f32x1 => .{ f32At(s, 0), 0, 0, 1 },
            .f32x2 => .{ f32At(s, 0), f32At(s, 4), 0, 1 },
            .f32x3 => .{ f32At(s, 0), f32At(s, 4), f32At(s, 8), 1 },
            .f32x4 => .{ f32At(s, 0), f32At(s, 4), f32At(s, 8), f32At(s, 12) },
            .i8x2 => .{ i8v.g(s, 0), i8v.g(s, 1), 0, 1 },
            .i8x3 => .{ i8v.g(s, 0), i8v.g(s, 1), i8v.g(s, 2), 1 },
            .i8x4 => .{ i8v.g(s, 0), i8v.g(s, 1), i8v.g(s, 2), i8v.g(s, 3) },
            .i16x2 => .{ i16v.g(s, 0), i16v.g(s, 1), 0, 1 },
            .i16x3 => .{ i16v.g(s, 0), i16v.g(s, 1), i16v.g(s, 2), 1 },
            .i16x4 => .{ i16v.g(s, 0), i16v.g(s, 1), i16v.g(s, 2), i16v.g(s, 3) },
            // Normalized: 255 is 1.0, 127 is 1.0. NOT the raw integer.
            .u8x4_unorm => .{
                byte_fraction[s[0]],
                byte_fraction[s[1]],
                byte_fraction[s[2]],
                byte_fraction[s[3]],
            },
            .i8x3_snorm => .{
                @max(-1.0, i8v.g(s, 0) / 127.0),
                @max(-1.0, i8v.g(s, 1) / 127.0),
                @max(-1.0, i8v.g(s, 2) / 127.0),
                1,
            },
            .i16x3_snorm => .{
                @max(-1.0, i16v.g(s, 0) / 32767.0),
                @max(-1.0, i16v.g(s, 1) / 32767.0),
                @max(-1.0, i16v.g(s, 2) / 32767.0),
                1,
            },
        };
    }

    fn mulMat(u: []const u8, off: usize, v: [4]f32) [4]f32 {
        var r: [4]f32 = .{ 0, 0, 0, 0 };
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |col| s += f32At(u, off + (col * 4 + row) * 4) * v[col];
            r[row] = s;
        }
        return r;
    }

    /// The vertex stage: fetch, transform, light.
    fn vertex(self: *SoftCtx, st: *const Shade, p: *const idraw.Pipeline, d: *const idraw.Draw, v: u32) Vertex {
        const u = p.uniforms;
        const pos = self.fetch(d.attribs[@intFromEnum(idraw.AttribSlot.position)], v);
        const nrm = self.fetch(d.attribs[@intFromEnum(idraw.AttribSlot.normal)], v);
        const col = self.fetch(d.attribs[@intFromEnum(idraw.AttribSlot.color)], v);
        const uv0 = self.fetch(d.attribs[@intFromEnum(idraw.AttribSlot.texcoord0)], v);
        const uv1 = self.fetch(d.attribs[@intFromEnum(idraw.AttribSlot.texcoord1)], v);

        const clip = mulMat(u, uniforms.OFF_MVP, pos);
        const eye4 = mulMat(u, uniforms.OFF_MODELVIEW, pos);

        // The normal matrix is a mat3 in three vec4s.
        var n: [3]f32 = .{ 0, 0, 0 };
        for (0..3) |row| {
            var acc: f32 = 0;
            for (0..3) |k| acc += f32At(u, uniforms.OFF_NORMAL_MATRIX + (k * 16) + row * 4) * nrm[k];
            n[row] = acc;
        }
        n = norm3(n);

        var out = Vertex{
            .clip = clip,
            .eye = .{ eye4[0], eye4[1], eye4[2] },
            .normal = n,
            .color = col,
            .uv = .{ .{ uv0[0], uv0[1] }, .{ uv1[0], uv1[1] } },
        };
        if (st.lit) out.color = light(st, out);
        return out;
    }

    /// The lighting equation, per vertex, over the compacted light slots.
    fn light(st: *const Shade, v: Vertex) [4]f32 {
        const m = st.material;
        var out: [3]f32 = .{
            m.emission[0] + st.scene_ambient[0] * m.ambient[0],
            m.emission[1] + st.scene_ambient[1] * m.ambient[1],
            m.emission[2] + st.scene_ambient[2] * m.ambient[2],
        };

        const eye_dir = norm3(.{ -v.eye[0], -v.eye[1], -v.eye[2] });
        for (st.light[0..st.lights]) |l| {
            // w = 0 is directional: the position IS the direction, and there is no
            // attenuation. w = 1 is positional.
            const ldir = if (l.position[3] == 0)
                norm3(.{ l.position[0], l.position[1], l.position[2] })
            else
                norm3(.{ l.position[0] - v.eye[0], l.position[1] - v.eye[1], l.position[2] - v.eye[2] });

            const ndotl = @max(0.0, dot3(v.normal, ldir));
            for (0..3) |k| out[k] += l.ambient[k] * m.ambient[k] + l.diffuse[k] * m.diffuse[k] * ndotl;

            if (ndotl > 0 and m.shininess > 0) {
                // Blinn-Phong: the halfway vector, not the reflection — which is what
                // the standard specifies for its specular term.
                const h = norm3(.{ ldir[0] + eye_dir[0], ldir[1] + eye_dir[1], ldir[2] + eye_dir[2] });
                const s = std.math.pow(f32, @max(0.0, dot3(v.normal, h)), m.shininess);
                for (0..3) |k| out[k] += l.specular[k] * m.specular[k] * s;
            }
        }
        return .{ sat(out[0]), sat(out[1]), sat(out[2]), m.diffuse[3] };
    }

    // ── rasterization ────────────────────────────────────────────────────────

    /// The per-triangle tangent frame (T, B) from eye-space positions and
    /// texcoord0 — the CPU twin of the derivative-based frame f_pbr.frag
    /// builds on the card. Null when the UV mapping is degenerate; the caller
    /// then shades with the interpolated normal alone.
    fn tangentFrame(a: Vertex, b: Vertex, c: Vertex) ?[2][3]f32 {
        const e1 = [3]f32{ b.eye[0] - a.eye[0], b.eye[1] - a.eye[1], b.eye[2] - a.eye[2] };
        const e2 = [3]f32{ c.eye[0] - a.eye[0], c.eye[1] - a.eye[1], c.eye[2] - a.eye[2] };
        const d1 = [2]f32{ b.uv[0][0] - a.uv[0][0], b.uv[0][1] - a.uv[0][1] };
        const d2 = [2]f32{ c.uv[0][0] - a.uv[0][0], c.uv[0][1] - a.uv[0][1] };
        const det = d1[0] * d2[1] - d2[0] * d1[1];
        if (@abs(det) < 1e-12) return null;
        const r = 1.0 / det;
        const t = norm3(.{
            r * (e1[0] * d2[1] - e2[0] * d1[1]),
            r * (e1[1] * d2[1] - e2[1] * d1[1]),
            r * (e1[2] * d2[1] - e2[2] * d1[1]),
        });
        const bt = norm3(.{
            r * (e2[0] * d1[0] - e1[0] * d2[0]),
            r * (e2[1] * d1[0] - e1[1] * d2[0]),
            r * (e2[2] * d1[0] - e1[2] * d2[0]),
        });
        return .{ t, bt };
    }

    /// The analytic environment the physically-based path shades under — a
    /// stand-in for the image-based lighting the published glTF renderings
    /// use, cheap enough to evaluate per fragment with no environment
    /// texture. ONE hemispheric radiance field (sky above, ground below,
    /// about the light axis) serves both lobes: sampled at the normal it is
    /// the diffuse irradiance, sampled at the view reflection it is what a
    /// smooth surface mirrors — so a visor facing the horizon goes dark
    /// while the dome above it catches sky. Tuned so the glTF sample models sit
    /// within their published-render thresholds (render_oracle: MetalRoughSpheres).
    const ENV_SKY = [3]f32{ 0.80, 0.62, 0.40 };
    const ENV_GROUND = [3]f32{ 0.30, 0.22, 0.13 };
    const ENV_EXPOSURE: f32 = 0.85;

    /// The ACES filmic tone map (Narkowicz's rational fit): rolls highlights
    /// off smoothly where a bare clamp would clip them to flat white.
    fn acesTonemap(x: f32) f32 {
        return sat((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
    }

    /// The same curve across the three colour channels at once. Each lane rounds
    /// exactly as the scalar does; what the vector saves is two of the three
    /// divides, which a rational fit makes the dearest part of the fragment's tail.
    fn acesTonemap3(x: @Vector(4, f32)) @Vector(4, f32) {
        const num = x * (@as(@Vector(4, f32), @splat(2.51)) * x + @as(@Vector(4, f32), @splat(0.03)));
        const den = x * (@as(@Vector(4, f32), @splat(2.43)) * x + @as(@Vector(4, f32), @splat(0.59))) +
            @as(@Vector(4, f32), @splat(0.14));
        const q = num / den;
        return @min(@max(q, @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(1)));
    }

    // ── four fragments at a time ─────────────────────────────────────────────
    //
    // The physically-based fragment is mostly three-component vector algebra —
    // normalise, dot, normalise again — and a machine register holds four floats,
    // not three. Evaluating one fragment leaves a lane idle and spends a whole
    // instruction on each scalar step; evaluating FOUR fragments with one lane each
    // fills the register and turns every scalar step into a quarter of one. The
    // lanes here are PIXELS, not channels.
    //
    // Everything below mirrors the scalar functions operation for operation, so a
    // lane rounds exactly as the single-fragment path does.

    const V = @Vector(4, f32);

    fn splat(x: f32) V {
        return @splat(x);
    }

    fn dot3v(a: [3]V, b: [3]V) V {
        return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    }

    /// `norm3` per lane, including its answer for a zero-length vector.
    fn norm3v(v: [3]V) [3]V {
        const l2 = dot3v(v, v);
        const inv = splat(1.0) / @sqrt(l2);
        const zero = splat(0.0);
        const live = l2 != zero;
        return .{
            @select(f32, live, v[0] * inv, zero),
            @select(f32, live, v[1] * inv, zero),
            @select(f32, live, v[2] * inv, zero),
        };
    }

    /// Four fragments' worth of one texture unit, as channel vectors.
    ///
    /// The address arithmetic stays per lane — a gather is a gather, and nothing in
    /// the instruction set makes four independent texel fetches one operation — but
    /// the coordinates arrive and the channels leave in vector form, so this is the
    /// only place the four fragments come apart.
    fn sample4(s: *const Sampler, uv: [2]V, comptime srgb_decode: bool) [4]V {
        var out: [4]V = undefined;
        inline for (0..4) |ln| {
            const t = if (srgb_decode)
                s.sampleSrgb(.{ uv[0][ln], uv[1][ln] })
            else
                s.sample(.{ uv[0][ln], uv[1][ln] });
            inline for (0..4) |c| out[c][ln] = t[c];
        }
        return out;
    }

    /// `Shade.mapSample` for four fragments; an unbound slot is its identity in
    /// every lane and costs no gather at all.
    fn mapSample4(st: *const Shade, slot: idraw.MatMap, uv: [2]V, comptime srgb_decode: bool) [4]V {
        const i = @intFromEnum(slot);
        const smp = st.map[i] orelse {
            const d = st.map_default[i];
            return .{ splat(d[0]), splat(d[1]), splat(d[2]), splat(d[3]) };
        };
        return sample4(&smp, uv, srgb_decode);
    }

    /// `pbrFragment` for four fragments, in linear light. Returns the three colour
    /// channels and alpha, each a lane per fragment.
    fn pbrFragment4(st: *const Shade, in_n: [3]V, eyep: [3]V, uv: [2]V, tan: ?[2][3]f32) [4]V {
        const base = if (st.unit[0]) |smp|
            sample4(&smp, uv, true)
        else
            [4]V{ splat(1), splat(1), splat(1), splat(1) };
        const mr = mapSample4(st, .metal_rough, uv, false);
        const ao = mapSample4(st, .occlusion, uv, false)[0];
        const em = mapSample4(st, .emissive, uv, true);
        const rough = @max(splat(0.05), mr[1]);
        const metallic = mr[2];

        var n = norm3v(in_n);
        if (tan) |tb| {
            const nt = mapSample4(st, .normal, uv, false);
            const two = splat(2.0);
            const one_s = splat(1.0);
            const ts = [3]V{ nt[0] * two - one_s, nt[1] * two - one_s, nt[2] * two - one_s };
            n = norm3v(.{
                splat(tb[0][0]) * ts[0] + splat(tb[1][0]) * ts[1] + n[0] * ts[2],
                splat(tb[0][1]) * ts[0] + splat(tb[1][1]) * ts[1] + n[1] * ts[2],
                splat(tb[0][2]) * ts[0] + splat(tb[1][2]) * ts[1] + n[2] * ts[2],
            });
        }

        const l = st.light[0];
        const ldir: [3]V = if (st.light0_dir) |d|
            .{ splat(d[0]), splat(d[1]), splat(d[2]) }
        else
            norm3v(.{ splat(l.position[0]) - eyep[0], splat(l.position[1]) - eyep[1], splat(l.position[2]) - eyep[2] });
        const vdir = norm3v(.{ -eyep[0], -eyep[1], -eyep[2] });
        const h = norm3v(.{ ldir[0] + vdir[0], ldir[1] + vdir[1], ldir[2] + vdir[2] });

        const zero = splat(0.0);
        const one = splat(1.0);
        const ndotl = @max(zero, dot3v(n, ldir));
        const ndotv = @max(splat(1e-4), dot3v(n, vdir));
        const ndoth = @max(zero, dot3v(n, h));
        const vdoth = @max(zero, dot3v(vdir, h));

        const alpha = rough * rough;
        const a2 = alpha * alpha;
        const dterm = ndoth * ndoth * (a2 - one) + one;
        const ndf = a2 / @max(splat(std.math.pi) * dterm * dterm, splat(1e-7));
        const k = (rough + one) * (rough + one) / splat(8.0);
        const geom = (ndotv / (ndotv * (one - k) + k)) * (ndotl / (ndotl * (one - k) + k));
        const f1 = pow5v(one - vdoth);
        const fv = pow5v(one - ndotv);
        const hemi = splat(0.5) * dot3v(n, ldir) + splat(0.5);
        const rdir = [3]V{
            splat(2.0) * ndotv * n[0] - vdir[0],
            splat(2.0) * ndotv * n[1] - vdir[1],
            splat(2.0) * ndotv * n[2] - vdir[2],
        };
        const rhemi = splat(0.5) * dot3v(rdir, ldir) + splat(0.5);
        const inv_pi = splat(1.0 / std.math.pi);
        const spec_denom = one / @max(splat(4.0) * ndotv * ndotl, splat(1e-4));
        const not_met = one - metallic;

        var out: [4]V = undefined;
        out[3] = base[3];
        inline for (0..3) |c| {
            const albedo = base[c];
            const f0 = splat(0.04) * not_met + albedo * metallic;
            const fr = f0 + (one - f0) * f1;
            const spec = ndf * geom * fr * spec_denom;
            const kd = (one - fr) * not_met;
            const diffuse = kd * albedo * inv_pi;
            const direct = (diffuse + spec) * splat(l.diffuse[c]) * ndotl;
            const sky = splat(ENV_SKY[c]);
            const gnd = splat(ENV_GROUND[c]);
            const irr = gnd + (sky - gnd) * hemi;
            const irr_r = gnd + (sky - gnd) * rhemi;
            const irr_spec = irr_r + (irr - irr_r) * rough;
            const f90 = @max(one - rough, f0);
            const fenv = f0 + (f90 - f0) * fv;
            const env = (irr * albedo * not_met + irr_spec * fenv) * ao;
            out[c] = (direct + env) * splat(ENV_EXPOSURE) + em[c];
        }
        return out;
    }

    fn pow5v(x: V) V {
        const x2 = x * x;
        return x2 * x2 * x;
    }

    /// The physically-based fragment: glTF metallic-roughness Cook-Torrance
    /// (GGX + Smith + Fresnel-Schlick), one direct light plus the analytic
    /// environment (ENV_*), occlusion gating the environment terms, emissive
    /// added last, ACES-tonemapped and sRGB-encoded. Written once here and
    /// once in f_pbr.frag from the same equations, so the host suite pins
    /// the arithmetic the card runs. Factors are already baked into the map
    /// texels (modelcache), so every input is a plain sample.
    fn pbrFragment(st: *const Shade, in_n: [3]f32, eyep: [3]f32, uv: [2]f32, tan: ?[2][3]f32) [4]f32 {
        // Base colour and emissive are authored sRGB and decoded to linear; the
        // metal-rough, occlusion and normal maps carry measurements, not colour.
        const base = if (st.unit[0]) |smp| smp.sampleSrgb(uv) else [4]f32{ 1, 1, 1, 1 };
        const mr = st.mapSample(.metal_rough, uv);
        const ao = st.mapSample(.occlusion, uv)[0];
        const em = st.mapSampleSrgb(.emissive, uv);
        const rough = @max(0.05, mr[1]); // G = roughness, clamped off the mirror singularity
        const metallic = mr[2]; // B = metallic

        var n = norm3(in_n);
        if (tan) |tb| {
            const nt = st.mapSample(.normal, uv);
            const ts = [3]f32{ nt[0] * 2 - 1, nt[1] * 2 - 1, nt[2] * 2 - 1 };
            n = norm3(.{
                tb[0][0] * ts[0] + tb[1][0] * ts[1] + n[0] * ts[2],
                tb[0][1] * ts[0] + tb[1][1] * ts[1] + n[1] * ts[2],
                tb[0][2] * ts[0] + tb[1][2] * ts[1] + n[2] * ts[2],
            });
        }

        // Light slot 0, compacted (uniforms.zig): diffuse is the light colour.
        const l = st.light[0];
        const ldir = st.light0_dir orelse
            norm3(.{ l.position[0] - eyep[0], l.position[1] - eyep[1], l.position[2] - eyep[2] });
        const vdir = norm3(.{ -eyep[0], -eyep[1], -eyep[2] });
        const h = norm3(.{ ldir[0] + vdir[0], ldir[1] + vdir[1], ldir[2] + vdir[2] });

        const ndotl = @max(0.0, dot3(n, ldir));
        const ndotv = @max(1e-4, dot3(n, vdir));
        const ndoth = @max(0.0, dot3(n, h));
        const vdoth = @max(0.0, dot3(vdir, h));

        // GGX normal distribution, Schlick-GGX geometry, Fresnel-Schlick.
        const alpha = rough * rough;
        const a2 = alpha * alpha;
        const dterm = ndoth * ndoth * (a2 - 1.0) + 1.0;
        const ndf = a2 / @max(std.math.pi * dterm * dterm, 1e-7);
        const k = (rough + 1.0) * (rough + 1.0) / 8.0; // direct-lighting remap
        const geom = (ndotv / (ndotv * (1.0 - k) + k)) * (ndotl / (ndotl * (1.0 - k) + k));
        const f1 = pow5(1.0 - vdoth);
        const fv = pow5(1.0 - ndotv); // env Fresnel, view angle
        // Hemispheric radiance axis = the light axis, so the "sky" tracks the
        // scene's lamp in both this and f_pbr.frag's coordinate space. The
        // diffuse lobe samples the hemisphere at the normal; the specular
        // lobe samples it at the view reflection, widening toward the
        // diffuse answer as roughness spreads the lobe.
        const hemi = 0.5 * dot3(n, ldir) + 0.5;
        const rdir = [3]f32{
            2.0 * ndotv * n[0] - vdir[0],
            2.0 * ndotv * n[1] - vdir[1],
            2.0 * ndotv * n[2] - vdir[2],
        };
        const rhemi = 0.5 * dot3(rdir, ldir) + 0.5;
        const inv_pi = 1.0 / std.math.pi;
        const spec_denom = 1.0 / @max(4.0 * ndotv * ndotl, 1e-4);

        // The three colour channels evaluate together. Every term above this point
        // is a scalar the channels share, so the reflectance model is the same
        // sequence of operations three lanes wide — and lane by lane it rounds
        // exactly as the scalar form does, because the order is unchanged.
        const albedo = V{ base[0], base[1], base[2], 0 };
        const one: V = @splat(1.0);
        const met: V = @splat(metallic);
        const not_met = one - met;
        const sky = V{ ENV_SKY[0], ENV_SKY[1], ENV_SKY[2], 0 };
        const gnd = V{ ENV_GROUND[0], ENV_GROUND[1], ENV_GROUND[2], 0 };

        const f0 = @as(V, @splat(0.04)) * not_met + albedo * met;
        const fr = f0 + (one - f0) * @as(V, @splat(f1));
        const spec = @as(V, @splat(ndf * geom)) * fr * @as(V, @splat(spec_denom));
        // Energy conservation: the non-specular fraction diffuses (metals: none).
        const kd = (one - fr) * not_met;
        const diffuse = kd * albedo * @as(V, @splat(inv_pi));
        const direct = (diffuse + spec) * V{ l.diffuse[0], l.diffuse[1], l.diffuse[2], 0 } *
            @as(V, @splat(ndotl));
        // The analytic environment: irradiance × albedo on the diffuse half, the
        // reflected radiance Fresnel-weighted on the specular half, occlusion
        // gating both.
        const irr = gnd + (sky - gnd) * @as(V, @splat(hemi));
        const irr_r = gnd + (sky - gnd) * @as(V, @splat(rhemi));
        const irr_spec = irr_r + (irr - irr_r) * @as(V, @splat(rough));
        const f90 = @max(@as(V, @splat(1.0 - rough)), f0); // rough surfaces lose grazing sheen
        const fenv = f0 + (f90 - f0) * @as(V, @splat(fv));
        const env = (irr * albedo * not_met + irr_spec * fenv) * @as(V, @splat(ao));
        // Emissive is the surface's own radiance — the camera exposure scales the
        // scene light around it, not the glow itself.
        const lit = (direct + env) * @as(V, @splat(ENV_EXPOSURE)) +
            V{ em[0], em[1], em[2], 0 };
        return .{ lit[0], lit[1], lit[2], base[3] };
    }

    /// A triangle's three edge functions and its interpolants, as planes over window
    /// space.
    ///
    /// An edge function is linear in (x, y), so it is `ex·x + ey·y + c`; normalising
    /// each by the signed area makes its value the barycentric weight outright. Two
    /// multiplies and two adds evaluate one, against a cross product and a divide for
    /// the textbook form — and because the value is linear, the covered run of a row
    /// can be solved for instead of searched.
    ///
    /// The planes are stated relative to vertex `a`, which keeps every coefficient the
    /// size of the triangle rather than the size of the screen: the constant terms are
    /// products of coordinates, and letting those grow to screen scale spends the
    /// mantissa that the edge test needs near the edge.
    const Edges = struct {
        ox: f32,
        oy: f32,
        ex: [3]f32,
        ey: [3]f32,
        ec: [3]f32,
        /// 1/w per vertex, for the perspective divide.
        inv_w: [3]f32,
        /// All three vertices share a w — an orthographic or 2D draw, where the
        /// screen-space weights already are the correct ones and the per-fragment
        /// divide is not merely cheap but unnecessary.
        affine: bool,

        fn setup(sa: [4]f32, sb: [4]f32, sc: [4]f32, inv_area: f32) Edges {
            const bx = sb[0] - sa[0];
            const by = sb[1] - sa[1];
            const cx = sc[0] - sa[0];
            const cy = sc[1] - sa[1];
            const e = Edges{
                .ox = sa[0],
                .oy = sa[1],
                // edge(A, B, P) = (A.y - B.y)·P.x + (B.x - A.x)·P.y + (A.x·B.y - A.y·B.x),
                // with A and B taken from the pair opposite each vertex.
                .ex = .{ (by - cy) * inv_area, cy * inv_area, -by * inv_area },
                .ey = .{ (cx - bx) * inv_area, -cx * inv_area, bx * inv_area },
                .ec = .{ (bx * cy - by * cx) * inv_area, 0, 0 },
                .inv_w = .{ 1.0 / sa[3], 1.0 / sb[3], 1.0 / sc[3] },
                .affine = sa[3] == sb[3] and sb[3] == sc[3],
            };
            return e;
        }

        /// The half-open run of columns in row `py` (already in plane space) that can
        /// be covered, clipped to [x0, x1).
        ///
        /// Each edge is a line in x whose crossing point the row's constants give
        /// directly. Solving in f64 keeps the crossing accurate to far below a pixel
        /// whatever the geometry, and the result is still widened by a column on each
        /// side — the caller settles the boundary with the same exact test it would
        /// have applied to every column, so this narrows the work without owning the
        /// coverage decision.
        fn span(e: *const Edges, row: [3]f32, x0: i32, x1: i32) [2]i32 {
            var lo: f64 = -1e9;
            var hi: f64 = 1e9;
            for (0..3) |i| {
                const kx: f64 = e.ex[i];
                const r: f64 = row[i];
                if (kx > 0) {
                    lo = @max(lo, -r / kx);
                } else if (kx < 0) {
                    hi = @min(hi, -r / kx);
                } else if (r < 0) {
                    return .{ x0, x0 }; // the row lies wholly outside this edge
                }
            }
            if (lo > hi) return .{ x0, x0 };
            // Plane space back to columns: px = x + 0.5 - ox.
            const shift: f64 = @as(f64, e.ox) - 0.5;
            const first: f64 = @floor(lo + shift) - 1;
            const last: f64 = @ceil(hi + shift) + 2;
            const s = if (first <= @as(f64, @floatFromInt(x0))) x0 else @as(i32, @intFromFloat(@min(first, @as(f64, @floatFromInt(x1)))));
            const en = if (last >= @as(f64, @floatFromInt(x1))) x1 else @as(i32, @intFromFloat(@max(last, @as(f64, @floatFromInt(x0)))));
            return .{ s, @max(s, en) };
        }
    };

    /// A triangle's attributes, as the value at vertex `a` plus the two edge deltas.
    ///
    /// Interpolating as `a + k₁·(b−a) + k₂·(c−a)` instead of `k₀·a + k₁·b + k₂·c` is
    /// the same quantity with one multiply less per channel, and it is EXACT when all
    /// three vertices agree: the weights are only approximately a partition of unity,
    /// so the symmetric form returns a constant attribute scaled by 1±2⁻²³ — enough to
    /// land a flat colour on the wrong side of a rounding tie and change its byte
    /// across the diagonal of a quad drawn as two triangles. Most of the desktop is
    /// flat-shaded quads, so that case has to come back exactly.
    const Interp = struct {
        z: [3]f32,
        col: [3][4]f32,
        /// The three vertices carry the same colour, so the interpolation is a
        /// constant. Most of the desktop is flat-shaded quads, and interpolating a
        /// constant a million times is the single most repeated piece of arithmetic
        /// in a 2D frame.
        flat_color: bool,
        tex: [idraw.MAX_UNITS][3][2]f32,
        nrm: [3][3]f32,
        eyep: [3][3]f32,

        fn setup(sa: [4]f32, sb: [4]f32, sc: [4]f32, a: Vertex, b: Vertex, c: Vertex) Interp {
            var it: Interp = undefined;
            it.z = .{ sa[2], sb[2] - sa[2], sc[2] - sa[2] };
            for (0..4) |k| it.col[0][k] = a.color[k];
            for (0..4) |k| it.col[1][k] = b.color[k] - a.color[k];
            for (0..4) |k| it.col[2][k] = c.color[k] - a.color[k];
            it.flat_color = true;
            for (0..4) |k| {
                if (it.col[1][k] != 0 or it.col[2][k] != 0) it.flat_color = false;
            }
            for (0..idraw.MAX_UNITS) |u| {
                for (0..2) |k| it.tex[u][0][k] = a.uv[u][k];
                for (0..2) |k| it.tex[u][1][k] = b.uv[u][k] - a.uv[u][k];
                for (0..2) |k| it.tex[u][2][k] = c.uv[u][k] - a.uv[u][k];
            }
            for (0..3) |k| it.nrm[0][k] = a.normal[k];
            for (0..3) |k| it.nrm[1][k] = b.normal[k] - a.normal[k];
            for (0..3) |k| it.nrm[2][k] = c.normal[k] - a.normal[k];
            for (0..3) |k| it.eyep[0][k] = a.eye[k];
            for (0..3) |k| it.eyep[1][k] = b.eye[k] - a.eye[k];
            for (0..3) |k| it.eyep[2][k] = c.eye[k] - a.eye[k];
            return it;
        }

        fn depth(it: *const Interp, k1: f32, k2: f32) f32 {
            return it.z[0] + k1 * it.z[1] + k2 * it.z[2];
        }
        fn color(it: *const Interp, k1: f32, k2: f32) [4]f32 {
            var out: [4]f32 = undefined;
            for (0..4) |k| out[k] = it.col[0][k] + k1 * it.col[1][k] + k2 * it.col[2][k];
            return out;
        }
        fn uv(it: *const Interp, slot: usize, k1: f32, k2: f32) [2]f32 {
            const t = &it.tex[slot];
            return .{
                t[0][0] + k1 * t[1][0] + k2 * t[2][0],
                t[0][1] + k1 * t[1][1] + k2 * t[2][1],
            };
        }
        fn normal(it: *const Interp, k1: f32, k2: f32) [3]f32 {
            var out: [3]f32 = undefined;
            for (0..3) |k| out[k] = it.nrm[0][k] + k1 * it.nrm[1][k] + k2 * it.nrm[2][k];
            return out;
        }
        fn eye(it: *const Interp, k1: f32, k2: f32) [3]f32 {
            var out: [3]f32 = undefined;
            for (0..3) |k| out[k] = it.eyep[0][k] + k1 * it.eyep[1][k] + k2 * it.eyep[2][k];
            return out;
        }
    };

    /// Whether the column at plane coordinate `px` is inside all three edges — the
    /// coverage test, in the form the run scan needs it. The general loop spells the
    /// same expression inline because it keeps the three weights it computes.
    fn inside(e: *const Edges, row: [3]f32, px: f32) bool {
        return @min(
            e.ex[0] * px + row[0],
            @min(e.ex[1] * px + row[1], e.ex[2] * px + row[2]),
        ) >= 0;
    }

    /// What a triangle's fragments have in common, when they have everything in
    /// common.
    const ConstFragment = union(enum) {
        /// Something in the fragment depends on where it is; shade each one.
        varies,
        /// Constant, and the alpha test rejects it — so it rejects all of them.
        discarded,
        /// Constant: this is the framebuffer word every covered pixel takes.
        word: u32,
    };

    /// Decide whether every fragment of a triangle writes the same bytes.
    ///
    /// It does when the colour is the same at all three vertices and nothing after
    /// it consults the fragment's position: no texture unit (a texel varies with
    /// the coordinate), no material maps, and no blending (the destination varies).
    /// The DEPTH TEST disqualifies it too, and less obviously: the fragment would
    /// still be one value, but whether it reaches the framebuffer is then decided
    /// per pixel, and the caller writes the run in one go rather than pixel by
    /// pixel. This mirrors the tail of the pixel loop exactly — the same lit-alpha
    /// rule and the same alpha test — because it stands in for it, and a fast path
    /// that disagrees with the slow one is a bug that only shows on some draws.
    fn constantFragment(st: *const Shade, attr: *const Interp) ConstFragment {
        if (!attr.flat_color or st.pbr or st.blend.enable or !st.mask_all) return .varies;
        if (st.depth_test) return .varies;
        for (0..st.unit_count) |slot| {
            if (st.unit[slot] != null) return .varies;
        }
        var frag = attr.col[0];
        // A LIT opaque fragment forces alpha 1 (spec APP-010); the blended case
        // cannot reach here, so this is the whole of that rule.
        if (st.lit) frag[3] = 1;
        if (st.alpha_test) |at| {
            if (!depthPasses(at.func, frag[3], at.ref)) return .discarded;
        }
        return .{ .word = packBgra(frag) };
    }

    /// Shade one row's covered run through the physically-based path, four
    /// fragments per step.
    ///
    /// The batch is always four wide even where fewer than four fragments remain:
    /// the spare lanes repeat the run's last column, so every address the batch
    /// touches is one the run already owns, and the store loop writes only the
    /// fragments that are really there. That costs a little arithmetic on the last
    /// step of a row and buys not having a second copy of the shading.
    fn pbrRow(
        self: *SoftCtx,
        st: *const Shade,
        e: *const Edges,
        attr: *const Interp,
        tangent: ?[2][3]f32,
        row: [3]f32,
        base_i: usize,
        lo: i32,
        hi: i32,
    ) void {
        var x = lo;
        while (x < hi) : (x += 4) {
            const active: usize = @intCast(@min(@as(i32, 4), hi - x));
            var pxv: V = undefined;
            inline for (0..4) |ln| {
                const col = x + @as(i32, @intCast(@min(ln, active - 1)));
                pxv[ln] = @as(f32, @floatFromInt(col)) + 0.5 - e.ox;
            }

            const b0 = splat(e.ex[0]) * pxv + splat(row[0]);
            const b1 = splat(e.ex[1]) * pxv + splat(row[1]);
            const b2 = splat(e.ex[2]) * pxv + splat(row[2]);
            const z = splat(attr.z[0]) + b1 * splat(attr.z[1]) + b2 * splat(attr.z[2]);

            var k1 = b1;
            var k2 = b2;
            if (!e.affine) {
                const q0 = b0 * splat(e.inv_w[0]);
                const q1 = b1 * splat(e.inv_w[1]);
                const q2 = b2 * splat(e.inv_w[2]);
                const inv_sum = splat(1.0) / (q0 + q1 + q2);
                k1 = q1 * inv_sum;
                k2 = q2 * inv_sum;
            }

            var nrm: [3]V = undefined;
            var eyep: [3]V = undefined;
            inline for (0..3) |j| {
                nrm[j] = splat(attr.nrm[0][j]) + k1 * splat(attr.nrm[1][j]) + k2 * splat(attr.nrm[2][j]);
                eyep[j] = splat(attr.eyep[0][j]) + k1 * splat(attr.eyep[1][j]) + k2 * splat(attr.eyep[2][j]);
            }
            const t0 = &attr.tex[0];
            const uv = [2]V{
                splat(t0[0][0]) + k1 * splat(t0[1][0]) + k2 * splat(t0[2][0]),
                splat(t0[0][1]) + k1 * splat(t0[1][1]) + k2 * splat(t0[2][1]),
            };

            const lit = pbrFragment4(st, nrm, eyep, uv, tangent);
            // Runtime lane indexing of a @Vector left the language in Zig 0.16;
            // land the lanes in arrays once, then index those.
            const tr: [4]f32 = acesTonemap4(lit[0]);
            const tg: [4]f32 = acesTonemap4(lit[1]);
            const tb: [4]f32 = acesTonemap4(lit[2]);
            const za: [4]f32 = z;

            for (0..active) |ln| {
                const i = base_i + @as(usize, @intCast(x)) + ln;
                if (st.depth_test and !depthPasses(st.depth_func, za[ln], self.depth[i])) continue;
                self.words()[i] = @as(u32, 255) << 24 |
                    @as(u32, srgb.encodeByte(tr[ln])) << 16 |
                    @as(u32, srgb.encodeByte(tg[ln])) << 8 |
                    @as(u32, srgb.encodeByte(tb[ln]));
                if (st.depth_write) self.depth[i] = za[ln];
            }
        }
    }

    /// The ACES curve across four fragments.
    fn acesTonemap4(x: V) V {
        const num = x * (splat(2.51) * x + splat(0.03));
        const den = x * (splat(2.43) * x + splat(0.59)) + splat(0.14);
        return @min(@max(num / den, splat(0.0)), splat(1.0));
    }

    fn triangle(self: *SoftCtx, st: *const Shade, a: Vertex, b: Vertex, c: Vertex) void {
        // Anything behind the eye is dropped whole rather than clipped: this is a
        // reference for the arithmetic, and a test that needs clipping can avoid it.
        if (a.clip[3] <= 0 or b.clip[3] <= 0 or c.clip[3] <= 0) return;

        const sa = toScreen(st, a);
        const sb = toScreen(st, b);
        const sc = toScreen(st, c);

        const area = edge(sa, sb, sc);
        if (area == 0) return;
        // Front face: the winding, in window coordinates. y is down here, which flips
        // the sign of every cross product relative to GL's convention.
        const is_front = if (st.front_ccw) area < 0 else area > 0;
        if (st.cull) |cull| {
            switch (cull) {
                .front_and_back => return,
                .front => if (is_front) return,
                .back => if (!is_front) return,
            }
        }

        const vp = st.viewport;
        var x0 = @max(@as(i32, 0), @max(vp.x, @as(i32, @intFromFloat(@floor(@min(sa[0], @min(sb[0], sc[0])))))));
        var x1 = @min(@as(i32, @intCast(self.w)), @min(vp.x + @as(i32, @intCast(vp.w)), @as(i32, @intFromFloat(@ceil(@max(sa[0], @max(sb[0], sc[0]))))) + 1));
        var y0 = @max(@as(i32, 0), @max(vp.y, @as(i32, @intFromFloat(@floor(@min(sa[1], @min(sb[1], sc[1])))))));
        var y1 = @min(@as(i32, @intCast(self.h)), @min(vp.y + @as(i32, @intCast(vp.h)), @as(i32, @intFromFloat(@ceil(@max(sa[1], @max(sb[1], sc[1]))))) + 1));
        // The scissor clips the raster bbox BEFORE any pixel is shaded, which is what
        // makes it a performance boundary and not just a correctness one: a frame
        // scissored to a keystroke's damage shades that damage, not the screen.
        if (st.scissor) |scr| {
            x0 = @max(x0, scr.x);
            y0 = @max(y0, scr.y);
            x1 = @min(x1, scr.x +| @as(i32, @intCast(scr.w)));
            y1 = @min(y1, scr.y +| @as(i32, @intCast(scr.h)));
        }
        if (x1 <= x0 or y1 <= y0) return;
        self.markShaded(x0, y0, x1, y1);

        // The physically-based maps path (GL_KUDOS_material_maps): lit draws with
        // any map bound shade per-fragment; the tangent frame is per-triangle,
        // computed once here and only when a normal map will consume it.
        const tangent: ?[2][3]f32 = if (st.pbr and st.map[@intFromEnum(idraw.MatMap.normal)] != null)
            tangentFrame(a, b, c)
        else
            null;

        const e = Edges.setup(sa, sb, sc, 1.0 / area);
        const attr = Interp.setup(sa, sb, sc, a, b, c);
        const const_word: ?u32 = switch (constantFragment(st, &attr)) {
            .discarded => return, // the alpha test rejects every fragment alike
            .varies => null,
            .word => |w| w,
        };
        // The four-wide physically-based path writes straight to the framebuffer
        // word, so it stands in for the general loop only where nothing else in the
        // tail has an opinion: no blending, every channel writable, no alpha test.
        // A translucent or masked model still shades one fragment at a time.
        const pbr_wide = st.pbr and !st.blend.enable and st.mask_all and st.alpha_test == null;
        const pump = self.dev.pump;

        var y = y0;
        while (y < y1) : (y += 1) {
            // A screen-sized triangle (the wallpaper or a frosted body quad) shades
            // millions of pixels in one call — far past what the per-triangle pump in
            // draw() can break up. Pump on a row cadence too, so even ONE giant
            // triangle keeps the platform's input draining while it fills.
            if (@rem(y - y0, PUMP_ROWS) == PUMP_ROWS - 1) {
                if (pump) |pu| pu();
            }
            const py = @as(f32, @floatFromInt(y)) + 0.5 - e.oy;
            const row = [3]f32{
                e.ey[0] * py + e.ec[0],
                e.ey[1] * py + e.ec[1],
                e.ey[2] * py + e.ec[2],
            };
            // The span BOUNDS the work; it does not decide coverage. It is
            // deliberately loose by a column or two, and the per-fragment edge test
            // below settles the boundary — so there is exactly one definition of
            // "covered" in the rasteriser, and a scan of the whole bounding box
            // would shade precisely the same pixels for a few more comparisons.
            const run = e.span(row, x0, x1);
            const xs = run[0];
            const xe = run[1];
            if (xs >= xe) continue;

            var x = xs;
            var px = @as(f32, @floatFromInt(xs)) + 0.5 - e.ox;
            const base_i = @as(usize, @intCast(y)) * self.w;

            // The physically-based path shades the row four fragments at a time. It
            // needs the covered run first, so that every lane of a batch is a
            // fragment that exists — found with the same edge test the general loop
            // applies, so the pixels are the same ones.
            if (pbr_wide) {
                while (x < xe and !inside(&e, row, px)) : ({
                    x += 1;
                    px += 1.0;
                }) {}
                const lo = x;
                while (x < xe and inside(&e, row, px)) : ({
                    x += 1;
                    px += 1.0;
                }) {}
                self.pbrRow(st, &e, &attr, tangent, row, base_i, lo, x);
                continue;
            }

            // A triangle is convex, so the columns it covers in one row are a single
            // run — and when the fragment cannot vary, that run is one value written
            // over a range. Finding its two ends costs the edge test that the general
            // loop pays anyway, and what it saves is the whole body. The test itself
            // is unchanged, so the pixels are the ones the general path would pick.
            if (const_word) |w| {
                while (x < xe and !inside(&e, row, px)) : ({
                    x += 1;
                    px += 1.0;
                }) {}
                const lo = x;
                while (x < xe and inside(&e, row, px)) : ({
                    x += 1;
                    px += 1.0;
                }) {}
                if (x > lo) {
                    @memset(self.words()[base_i + @as(usize, @intCast(lo)) ..][0..@intCast(x - lo)], w);
                    if (st.depth_write) {
                        var dx = lo;
                        var dpx = @as(f32, @floatFromInt(lo)) + 0.5 - e.ox;
                        while (dx < x) : ({
                            dx += 1;
                            dpx += 1.0;
                        }) {
                            const b1 = e.ex[1] * dpx + row[1];
                            const b2 = e.ex[2] * dpx + row[2];
                            self.depth[base_i + @as(usize, @intCast(dx))] = attr.depth(b1, b2);
                        }
                    }
                }
                continue;
            }

            while (x < xe) : ({
                x += 1;
                px += 1.0;
            }) {
                const b0 = e.ex[0] * px + row[0];
                const b1 = e.ex[1] * px + row[1];
                const b2 = e.ex[2] * px + row[2];
                // THE coverage test: inside all three edges. One comparison, because
                // the smallest weight decides it.
                if (@min(b0, @min(b1, b2)) < 0) continue;

                // Depth interpolates in WINDOW space, from the screen-space weights.
                const z = attr.depth(b1, b2);
                const i = base_i + @as(usize, @intCast(x));
                if (st.depth_test and !depthPasses(st.depth_func, z, self.depth[i])) continue;

                // Perspective-correct interpolation: the barycentric weights are in
                // screen space, and everything but position varies linearly in CLIP
                // space. Divide by w, interpolate, divide back. When all three
                // vertices share a w — an orthographic or 2D draw, which is most of
                // the desktop — the screen-space weights already ARE the answer.
                var k1 = b1;
                var k2 = b2;
                if (!e.affine) {
                    const q0 = b0 * e.inv_w[0];
                    const q1 = b1 * e.inv_w[1];
                    const q2 = b2 * e.inv_w[2];
                    const inv_sum = 1.0 / (q0 + q1 + q2);
                    k1 = q1 * inv_sum;
                    k2 = q2 * inv_sum;
                }

                var frag = if (attr.flat_color) attr.col[0] else attr.color(k1, k2);
                var linear = false;
                if (st.pbr) {
                    // The maps path replaces the vertex-lit colour and the texenv
                    // chain wholesale: normal, eye position and texcoord0 are
                    // interpolated to the fragment and shaded there.
                    frag = pbrFragment(st, attr.normal(k1, k2), attr.eye(k1, k2), attr.uv(0, k1, k2), tangent);
                    linear = true;
                } else {
                    const primary = frag;
                    for (0..st.unit_count) |slot| {
                        const smp = st.unit[slot] orelse continue;
                        frag = st.env[slot].eval(frag, primary, smp.sample(attr.uv(slot, k1, k2)));
                    }
                }

                // A physically-based fragment leaves the shader as radiance, and the
                // framebuffer holds sRGB. When nothing follows the encode, the
                // destination is one of 256 bytes and the tone curve is a threshold
                // search (srgb.encodeByte) rather than a transcendental; a blended
                // draw needs the encoded value itself, because the blend equation is
                // defined on what the framebuffer holds.
                const fuse = linear and !st.blend.enable and st.mask_all;
                if (linear and !fuse) {
                    const tone = acesTonemap3(.{ frag[0], frag[1], frag[2], 0 });
                    inline for (0..3) |ch| frag[ch] = srgb.toEncoded(tone[ch]);
                }

                // Alpha mode for a LIT (model) fragment (spec APP-010), mirroring
                // f_tex_blinnphong / f_pbr: the translucent pass outputs
                // premultiplied colour so premultiplied-over (the one grounded GPU
                // blend) yields straight-alpha-over; an opaque model fragment
                // forces alpha 1 so the compositor shows it solid. The unlit 2D
                // compositor already premultiplies its own surfaces — leave it.
                if (st.lit) {
                    if (st.blend.enable) {
                        frag[0] *= frag[3];
                        frag[1] *= frag[3];
                        frag[2] *= frag[3];
                    } else {
                        frag[3] = 1;
                    }
                }

                if (st.alpha_test) |at| {
                    if (!depthPasses(at.func, frag[3], at.ref)) continue;
                }

                if (fuse) {
                    const tone = acesTonemap3(.{ frag[0], frag[1], frag[2], 0 });
                    self.words()[i] = @as(u32, 255) << 24 |
                        @as(u32, srgb.encodeByte(tone[0])) << 16 |
                        @as(u32, srgb.encodeByte(tone[1])) << 8 |
                        @as(u32, srgb.encodeByte(tone[2]));
                    if (st.depth_write) self.depth[i] = z;
                    continue;
                }

                if (st.blend.enable) {
                    // The destination arrives as one word and converts four lanes at
                    // a time; the equation and its clamp are the same operations on
                    // all four channels, so they are one expression.
                    const stored: @Vector(4, u8) = @bitCast(self.words()[i]);
                    const df32: V = @as(V, @floatFromInt(stored)) / @as(V, @splat(255.0));
                    const dst = V{ df32[2], df32[1], df32[0], df32[3] }; // BGRA word to RGBA
                    const src: V = frag;
                    const blended = src * factor(st.blend.src, src, dst) +
                        dst * factor(st.blend.dst, src, dst);
                    frag = @min(@max(blended, @as(V, @splat(0.0))), @as(V, @splat(1.0)));
                }

                if (st.mask_all) {
                    self.words()[i] = packBgra(frag);
                } else {
                    if (st.mask[0]) self.color[i * 4 + 2] = px8(frag[0]);
                    if (st.mask[1]) self.color[i * 4 + 1] = px8(frag[1]);
                    if (st.mask[2]) self.color[i * 4 + 0] = px8(frag[2]);
                    if (st.mask[3]) self.color[i * 4 + 3] = px8(frag[3]);
                }
                if (st.depth_write) self.depth[i] = z;
            }
        }
    }

    /// Clip space -> window space, honouring the viewport and the depth range.
    fn toScreen(st: *const Shade, v: Vertex) [4]f32 {
        const iw = 1.0 / v.clip[3];
        const ndc = [3]f32{ v.clip[0] * iw, v.clip[1] * iw, v.clip[2] * iw };
        const vp = st.viewport;
        return .{
            @as(f32, @floatFromInt(vp.x)) + (ndc[0] * 0.5 + 0.5) * @as(f32, @floatFromInt(vp.w)),
            @as(f32, @floatFromInt(vp.y)) + (ndc[1] * 0.5 + 0.5) * @as(f32, @floatFromInt(vp.h)),
            st.depth_range[0] + ndc[2] * (st.depth_range[1] - st.depth_range[0]),
            v.clip[3],
        };
    }

    fn edge(a: [4]f32, b: [4]f32, c: [4]f32) f32 {
        return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    }

    fn depthPasses(f: idraw.CompareFunc, src: f32, dst: f32) bool {
        return switch (f) {
            .never => false,
            .less => src < dst,
            .equal => src == dst,
            .lequal => src <= dst,
            .greater => src > dst,
            .notequal => src != dst,
            .gequal => src >= dst,
            .always => true,
        };
    }

    fn factor(f: idraw.BlendFactor, src: @Vector(4, f32), dst: @Vector(4, f32)) @Vector(4, f32) {
        const one: V = @splat(1.0);
        return switch (f) {
            .zero => @splat(0.0),
            .one => one,
            .src_color => src,
            .one_minus_src_color => one - src,
            .dst_color => dst,
            .one_minus_dst_color => one - dst,
            .src_alpha => @splat(src[3]),
            .one_minus_src_alpha => @splat(1 - src[3]),
            .dst_alpha => @splat(dst[3]),
            .one_minus_dst_alpha => @splat(1 - dst[3]),
            .src_alpha_saturate => blk: {
                const s = @min(src[3], 1 - dst[3]);
                break :blk V{ s, s, s, 1 };
            },
        };
    }

    /// The picture, as a PPM. This is the point of the whole file: a thing you can look
    /// at, or diff against a golden.
    pub fn writePpm(self: *SoftCtx, w: anytype) !void {
        try w.print("P6\n{d} {d}\n255\n", .{ self.w, self.h });
        for (0..@as(usize, self.w) * self.h) |i| {
            try w.writeByte(self.color[i * 4 + 2]); // R
            try w.writeByte(self.color[i * 4 + 1]); // G
            try w.writeByte(self.color[i * 4 + 0]); // B
        }
    }

    /// The pixel at (x, y), as BGRA — for a test that wants one fact rather than a
    /// picture.
    pub fn pixel(self: *SoftCtx, x: u32, y: u32) [4]u8 {
        const i = (y * self.w + x) * 4;
        return .{ self.color[i], self.color[i + 1], self.color[i + 2], self.color[i + 3] };
    }
};

/// Transformed vertices held for the length of one draw.
///
/// The vertex stage is a pure function of the element index within a draw, and a
/// strip, a fan and every indexed mesh name most indices more than once. Direct
/// mapped: a hit is one comparison, a miss costs exactly what no cache costs.
const VertexCache = struct {
    tag: [VERTEX_CACHE]u32 = .{0} ** VERTEX_CACHE,
    live: [VERTEX_CACHE]bool = .{false} ** VERTEX_CACHE,
    val: [VERTEX_CACHE]Vertex = undefined,

    fn vertex(self: *VertexCache, ctx: *SoftCtx, st: *const Shade, p: *const idraw.Pipeline, d: *const idraw.Draw, v: u32) Vertex {
        const slot = v % VERTEX_CACHE;
        if (self.live[slot] and self.tag[slot] == v) return self.val[slot];
        const out = ctx.vertex(st, p, d, v);
        self.tag[slot] = v;
        self.live[slot] = true;
        self.val[slot] = out;
        return out;
    }
};

pub const Soft = struct {
    alloc: std.mem.Allocator,
    buffers: [MAX_BUF]Buffer = .{Buffer{}} ** MAX_BUF,
    textures: [MAX_TEX]Texture = .{Texture{}} ** MAX_TEX,
    pool: [idraw.MAX_CTX]SoftCtx = .{SoftCtx{}} ** idraw.MAX_CTX,
    // The platform's mid-draw pump, installed by main (same hook the desktop's
    // between-windows yield uses): called every PUMP_TRIS triangles so USB/NIC
    // rings keep draining while a long software draw runs. Null = no pumping
    // (host tests; a platform that doesn't need it).
    pump: ?*const fn () void = null,

    limits_val: idraw.Limits = .{
        .max_texture_size = 4096,
        .texture_units = idraw.MAX_UNITS,
        // One sample: this rasterizer has no multisampling, and the standard permits an
        // implementation to say so.
        .samples = 1,
        .subpixel_bits = 8,
    },

    pub fn deinit(self: *Soft) void {
        for (&self.buffers) |*b| if (b.data.len != 0) self.alloc.free(b.data);
        for (&self.textures) |*t| if (t.px.len != 0) self.alloc.free(t.px);
        for (&self.pool) |*c| {
            if (c.color.len != 0) self.alloc.free(c.color);
            if (c.depth.len != 0) self.alloc.free(c.depth);
        }
    }

    pub fn iface(self: *Soft) idraw.IDraw {
        // Frames land in the window surface (see SoftCtx.deliver), not a GPU mirror.
        return .{ .ctx = self, .vtable = &vtable, .delivers_in_place = true };
    }

    const vtable = idraw.IDraw.VTable{
        .bufferCreate = bufferCreate,
        .bufferUpdate = bufferUpdate,
        .bufferDestroy = bufferDestroy,
        .textureCreate = textureCreate,
        .textureUpdate = textureUpdate,
        .textureDestroy = textureDestroy,
        .limits = limits,
        .acquire = acquire,
        .release = release,
    };

    fn cast(c: *anyopaque) *Soft {
        return @ptrCast(@alignCast(c));
    }

    fn bufferCreate(c: *anyopaque, bytes: []const u8, usage: idraw.Usage) idraw.Error!idraw.BufferHandle {
        _ = usage;
        const self = cast(c);
        for (&self.buffers, 0..) |*b, i| {
            if (b.alive) continue;
            b.* = .{ .alive = true, .data = self.alloc.alloc(u8, bytes.len) catch return idraw.Error.DrawOutOfResources };
            @memcpy(b.data, bytes);
            return @intCast(i + 1);
        }
        return idraw.Error.DrawOutOfResources;
    }

    fn bufferUpdate(c: *anyopaque, h: idraw.BufferHandle, off: u32, bytes: []const u8) idraw.Error!void {
        const self = cast(c);
        if (h == 0 or h > MAX_BUF or !self.buffers[h - 1].alive) return idraw.Error.DrawBadBuffer;
        const b = &self.buffers[h - 1];
        if (off + bytes.len > b.data.len) return idraw.Error.DrawBadBuffer;
        @memcpy(b.data[off..][0..bytes.len], bytes);
    }

    fn bufferDestroy(c: *anyopaque, h: idraw.BufferHandle) void {
        const self = cast(c);
        if (h == 0 or h > MAX_BUF or !self.buffers[h - 1].alive) return;
        self.alloc.free(self.buffers[h - 1].data);
        self.buffers[h - 1] = .{};
    }

    fn textureCreate(c: *anyopaque, d: idraw.TexDesc) idraw.Error!idraw.TextureHandle {
        const self = cast(c);
        if (d.levels.len == 0) return idraw.Error.DrawBadTexture;
        const l0 = d.levels[0];
        for (&self.textures, 0..) |*t, i| {
            if (t.alive) continue;
            t.* = .{
                .alive = true,
                .format = d.format,
                .w = l0.w,
                .h = l0.h,
                .px = self.alloc.alloc(u8, l0.pixels.len) catch return idraw.Error.DrawOutOfResources,
            };
            @memcpy(t.px, l0.pixels);
            return @intCast(i + 1);
        }
        return idraw.Error.DrawOutOfResources;
    }

    fn textureUpdate(c: *anyopaque, h: idraw.TextureHandle, level: u32, r: idraw.Rect, px: []const u8) idraw.Error!void {
        _ = level;
        _ = r;
        _ = px;
        const self = cast(c);
        if (h == 0 or h > MAX_TEX or !self.textures[h - 1].alive) return idraw.Error.DrawBadTexture;
    }

    fn textureDestroy(c: *anyopaque, h: idraw.TextureHandle) void {
        const self = cast(c);
        if (h == 0 or h > MAX_TEX or !self.textures[h - 1].alive) return;
        self.alloc.free(self.textures[h - 1].px);
        self.textures[h - 1] = .{};
    }

    fn limits(c: *anyopaque) idraw.Limits {
        return cast(c).limits_val;
    }

    fn acquire(c: *anyopaque, dst: idraw.Dst) ?idraw.IDrawCtx {
        const self = cast(c);
        for (&self.pool) |*ctx| {
            if (ctx.in_use) continue;
            ctx.* = .{ .in_use = true, .dst = dst, .dev = self };
            return ctx.iface();
        }
        return null;
    }

    fn release(c: *anyopaque, ctx: idraw.IDrawCtx) void {
        _ = c;
        const s: *SoftCtx = @ptrCast(@alignCast(ctx.ctx));
        s.in_use = false;
    }
};
