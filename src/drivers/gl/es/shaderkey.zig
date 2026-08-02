//! State -> shader key: which compiled program a draw needs.
//!
//! There is no compiler on this machine — shaders are blobs built offline by Mesa's NAK
//! — so a draw must never discover it needs a program that does not exist. That makes
//! this file's whole job the same as its whole risk: the key it produces must ALWAYS be
//! one of the 216 that were built.
//!
//! It is therefore deliberately lossy. Anything that can be a uniform is one, and only
//! the four axes that change the shader's *instructions* survive into the key:
//!
//!   * light count — an unrolled loop, not a runtime bound
//!   * texture unit count — how many samplers are fetched
//!   * two-sided lighting — whether the normal flips for back faces
//!   * fog mode — different arithmetic per mode, not a different constant
//!
//! Everything else is data. Most importantly the texture environment, whose COMBINE
//! state alone has 906 million settings per unit and is interpreted from the constant
//! buffer instead.
//!
//! ## Canonicalization is the point
//!
//! Two different states that draw identically must produce the SAME key, or we build
//! programs nobody asks for and miss ones they do. So: lighting disabled means zero
//! lights regardless of which GL_LIGHTi bits are set; a texture unit that is disabled,
//! or enabled with nothing bound, does not count; two-sided lighting is meaningless
//! with no lights. Each of those is a real state an application reaches, and each folds
//! onto a key that already exists.

pub const idraw = @import("idraw");
pub const limits = @import("limits.zig");
pub const state = @import("state.zig");

const Context = state.Context;

/// How many lights this draw actually evaluates.
///
/// The standard has one master switch and eight individual ones. With GL_LIGHTING off,
/// the vertex colour passes through and no light is evaluated whatever the individual
/// bits say — so the count is zero, and the state folds onto the unlit program.
///
/// The count is the number ENABLED, not the highest index enabled: a program that
/// enables only GL_LIGHT7 gets the one-light program, and the packing (uniforms.zig)
/// compacts light 7's parameters into slot 0 to match.
fn lightCount(g: *const Context) u4 {
    if (!g.caps.lighting) return 0;
    var n: u4 = 0;
    for (g.caps.light) |on| {
        if (on) n += 1;
    }
    return n;
}

/// Does unit `i` contribute to the fragment?
///
/// Three things must hold, and the third is the one that bites. The unit must be
/// enabled; it must have a texture bound; and that texture must be COMPLETE — it must
/// actually have an image. The standard says an incomplete texture behaves as if
/// texturing were disabled for that unit, so a bound name that glTexImage2D has never
/// been called on contributes nothing.
///
/// This predicate is shared with the lowering (pipeline.zig) on purpose. It used not to
/// be: the key counted a bound-but-imageless unit while the pipeline could not produce a
/// binding for it, so the two disagreed and the device refused the draw. One fact, one
/// home.
pub fn unitContributes(g: *const Context, i: usize) bool {
    if (!g.caps.texture_2d[i]) return false;
    const name = g.texture_binding[i];
    if (name == 0) return false;
    const rec = g.textures.recordConst(name) orelse return false;
    return rec.handle != null;
}

/// How many texture units contribute.
///
/// Units are counted contiguously from zero. A program that enables unit 1 but not unit
/// 0 is legal and rare; the count is then still one, and the packing moves it down.
fn unitCount(g: *const Context) u2 {
    var n: u2 = 0;
    for (0..limits.MAX_TEXTURE_UNITS) |i| {
        if (unitContributes(g, i)) n += 1;
    }
    return n;
}

fn fogMode(g: *const Context) idraw.FogMode {
    if (!g.caps.fog) return .off;
    return g.fog.mode;
}

/// OES_point_sprite is live for a draw when the cap is on and at least one
/// contributing unit asks for COORD_REPLACE — a replace flag on a unit that
/// contributes nothing replaces nothing, and without it every unit samples its
/// interpolated coordinate, which the ordinary programs already do.
pub fn spriteActive(g: *const Context) bool {
    if (!g.caps.point_sprite) return false;
    for (0..limits.MAX_TEXTURE_UNITS) |i| {
        if (unitContributes(g, i) and g.texenv[i].coord_replace) return true;
    }
    return false;
}

/// The key for the state as it stands, drawing primitive `prim`. The primitive
/// matters only to OES_point_sprite: coordinate replacement exists for points
/// alone, so every other primitive keys exactly as before.
pub fn keyFor(g: *const Context, prim: idraw.Prim) idraw.ShaderKey {
    const lights = lightCount(g);
    const sprite = prim == .points and spriteActive(g);
    return .{
        .lights = lights,
        .units = unitCount(g),
        // Two-sided lighting decides whether back faces get a flipped normal. With no
        // lights there is no normal to flip, so it folds away — and a point sprite has
        // no back face to select (§2.12.1: points are always front-facing).
        .two_sided = g.light_model_two_side and lights > 0 and !sprite,
        .fog = fogMode(g),
        .sprite = sprite,
    };
}

/// The indices of the enabled lights, in order, compacted to the front — the map from
/// GL's sparse light numbering onto the shader's dense one. `uniforms.zig` packs by
/// this, so the two cannot disagree about which light is which.
pub fn enabledLights(g: *const Context, out: *[limits.MAX_LIGHTS]u8) u8 {
    if (!g.caps.lighting) return 0;
    var n: u8 = 0;
    for (g.caps.light, 0..) |on, i| {
        if (!on) continue;
        out[n] = @intCast(i);
        n += 1;
    }
    return n;
}

/// The indices of the contributing texture units, compacted the same way.
pub fn contributingUnits(g: *const Context, out: *[limits.MAX_TEXTURE_UNITS]u8) u8 {
    var n: u8 = 0;
    for (0..limits.MAX_TEXTURE_UNITS) |i| {
        if (unitContributes(g, i)) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}
