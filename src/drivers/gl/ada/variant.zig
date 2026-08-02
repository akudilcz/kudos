//! Shader key -> the compiled program a draw needs.
//!
//! There is no compiler on this machine. Every program a draw can ask for was built
//! offline by Mesa's NAK and embedded in the image, so this file's whole job is to
//! guarantee the lookup never misses: a draw that needs a program which does not exist
//! has no fallback and no recovery, it just does not draw.
//!
//! That guarantee is a host test, not a hope. The tests below walk every reachable key
//! the `ShaderKey` struct can express and demand that each one's vertex and fragment
//! names are present in the generated manifest — the set the shader factory actually
//! built. A missing variant is a red test on a laptop rather than a black window on
//! lemon.
//!
//! ## The naming scheme IS the contract
//!
//! The name a key maps to is the name the shader factory writes. Both sides compute it
//! from the same rule, spelled once here:
//!
//!     v_l<lights>_u<units>[_2s]     vertex
//!     f_u<units>[_2s]_<fog>[_spr]   fragment
//!
//! so key{lights=2, units=1, two_sided=true, fog=exp} is `v_l2_u1_2s` and `f_u1_2s_exp`.
//!
//! ## Each stage names only what it can see
//!
//! Neither name carries the whole key, and the halves they drop are mirror images of
//! each other:
//!
//! - The vertex program does not branch on FOG. Fog is a fragment computation over an
//!   eye-space distance the vertex stage passes through regardless.
//! - The fragment program does not branch on LIGHTS. ES 1.1 lights per vertex (spec
//!   §2.12, figure 2.6): lighting has already become an interpolated colour before a
//!   fragment exists, so the stage cannot tell one light from eight.
//!
//! Two-sidedness reaches both, because the vertex computes a front and a back colour and
//! the fragment picks between them by facing.
//!
//! The sprite bit (OES_point_sprite) reaches only the fragment — coordinate replacement
//! happens where sampling does — and only combines with units >= 1 (nothing to replace
//! otherwise) and two_sided = false (a point is always front-facing), so it adds 8
//! fragment programs and no vertex ones.
//!
//! So 288 reachable keys resolve to 54 + 32 = 86 programs. Many keys share a fragment
//! program, and that is correct rather than a collision: keys differing only in light
//! count MUST land on the same fragment blob, because there is nothing in a fragment for
//! the light count to change.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.12.

const std = @import("std");
pub const idraw = @import("idraw");
pub const manifest = @import("manifest");

/// Every reachable combination the key can express: the plain fixed-function space,
/// plus the sprite keys (units 1..MAX, never two-sided). The number is not a target —
/// it is what `ShaderKey`'s fields multiply out to under `reachable`, and the test
/// below proves the two agree.
pub const COUNT: usize = 9 * 3 * 2 * 4 + 9 * 2 * 4;

/// Vertex programs are fog- and sprite-blind, so they are the plain space over
/// lights x units x two-sided.
pub const VERTEX_COUNT: usize = 9 * 3 * 2;

/// Fragment programs are light-blind: the plain set over units x two-sided x fog,
/// plus the sprite set over units 1..MAX x fog. The two counts do not multiply back
/// to COUNT and are not supposed to: a key selects one of each.
pub const FRAGMENT_COUNT: usize = 3 * 2 * 4 + 2 * 4;

/// What the offline build actually emits.
pub const BLOB_COUNT: usize = VERTEX_COUNT + FRAGMENT_COUNT;

/// The longest name either scheme produces: "v_l8_u2_2s" and "f_u2_exp2_spr".
pub const NAME_CAP: usize = 16;

fn fogSuffix(f: idraw.FogMode) []const u8 {
    return switch (f) {
        .off => "off",
        .linear => "lin",
        .exp => "exp",
        .exp2 => "exp2",
    };
}

/// The vertex program's name for `k`. Fog is not in it: the vertex stage passes eye-space
/// depth through whatever the mode, and the fragment stage decides what to do with it.
pub fn vertexName(k: idraw.ShaderKey, buf: *[NAME_CAP]u8) []const u8 {
    return std.fmt.bufPrint(buf, "v_l{d}_u{d}{s}", .{
        k.lights,
        k.units,
        if (k.two_sided) "_2s" else "",
    }) catch unreachable;
}

/// The fragment program's name for `k`. The light count is not in it: lighting happened
/// at the vertex, and what reaches here is one interpolated colour whatever produced it.
pub fn fragmentName(k: idraw.ShaderKey, buf: *[NAME_CAP]u8) []const u8 {
    return std.fmt.bufPrint(buf, "f_u{d}{s}_{s}{s}", .{
        k.units,
        if (k.two_sided) "_2s" else "",
        fogSuffix(k.fog),
        if (k.sprite) "_spr" else "",
    }) catch unreachable;
}

/// Is this key one the offline build produces a program for?
///
/// The struct can express keys the pipeline cannot reach — `lights` is four bits and
/// only nine values are legal, `units` is two bits and only three are, and `sprite`
/// demands a unit to replace and never a back face (es/shaderkey.zig keys it that way).
/// A key outside that is a bug above us, and the device would rather say so than index
/// past its table.
pub fn reachable(k: idraw.ShaderKey) bool {
    if (k.sprite and (k.units == 0 or k.two_sided)) return false;
    return k.lights <= 8 and k.units <= idraw.MAX_UNITS;
}
