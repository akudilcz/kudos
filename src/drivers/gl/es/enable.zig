//! glEnable / glDisable / glIsEnabled, and the client-array pair.
//!
//! Two separate switches that look like one. `glEnable` toggles *server* state — does
//! the pipeline light, fog, blend? `glEnableClientState` toggles whether an array is
//! read at all. They take disjoint token sets and confusing them is a classic bug, so
//! the standard makes each reject the other's tokens with GL_INVALID_ENUM.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.8, §6.2; the glEnable and
//! glEnableClientState reference pages.

const std = @import("std");
pub const idraw = @import("idraw");
pub const enums = @import("enums.zig");
pub const limits = @import("limits.zig");
pub const state = @import("state.zig");

pub const GLenum = enums.GLenum;
pub const GLboolean = enums.GLboolean;
const Context = state.Context;

/// Resolve a capability token to the bit it controls. Null means "not a capability",
/// which is GL_INVALID_ENUM.
fn capBit(g: *Context, cap: GLenum) ?*bool {
    // The indexed capabilities first: GL_LIGHTi and GL_CLIP_PLANEi are ranges, not
    // single tokens, and a light past our count is INVALID_ENUM rather than a clamp.
    if (cap >= enums.GL_LIGHT0 and cap < enums.GL_LIGHT0 + limits.MAX_LIGHTS)
        return &g.caps.light[cap - enums.GL_LIGHT0];
    if (cap >= enums.GL_CLIP_PLANE0 and cap < enums.GL_CLIP_PLANE0 + limits.MAX_CLIP_PLANES)
        return &g.caps.clip_plane[cap - enums.GL_CLIP_PLANE0];

    return switch (cap) {
        // GL_TEXTURE_2D is per-unit, and which unit is whatever glActiveTexture last
        // selected — the enable is not global, which surprises people.
        enums.GL_TEXTURE_2D => &g.caps.texture_2d[g.active_texture],
        enums.GL_LIGHTING => &g.caps.lighting,
        enums.GL_CULL_FACE => &g.caps.cull_face,
        enums.GL_FOG => &g.caps.fog,
        enums.GL_DEPTH_TEST => &g.caps.depth_test,
        enums.GL_STENCIL_TEST => &g.caps.stencil_test,
        enums.GL_SCISSOR_TEST => &g.caps.scissor_test,
        enums.GL_ALPHA_TEST => &g.caps.alpha_test,
        enums.GL_BLEND => &g.caps.blend,
        enums.GL_COLOR_LOGIC_OP => &g.caps.color_logic_op,
        enums.GL_DITHER => &g.caps.dither,
        enums.GL_NORMALIZE => &g.caps.normalize,
        enums.GL_RESCALE_NORMAL => &g.caps.rescale_normal,
        enums.GL_COLOR_MATERIAL => &g.caps.color_material,
        enums.GL_POLYGON_OFFSET_FILL => &g.caps.polygon_offset_fill,
        enums.GL_MULTISAMPLE => &g.caps.multisample,
        enums.GL_SAMPLE_ALPHA_TO_COVERAGE => &g.caps.sample_alpha_to_coverage,
        enums.GL_SAMPLE_ALPHA_TO_ONE => &g.caps.sample_alpha_to_one,
        enums.GL_SAMPLE_COVERAGE => &g.caps.sample_coverage,
        enums.GL_POINT_SMOOTH => &g.caps.point_smooth,
        enums.GL_LINE_SMOOTH => &g.caps.line_smooth,
        enums.GL_POINT_SPRITE_OES => &g.caps.point_sprite,
        else => null,
    };
}

pub fn enable(g: *Context, cap: GLenum) void {
    const bit = capBit(g, cap) orelse return g.recordError(.invalid_enum);
    bit.* = true;
}

pub fn disable(g: *Context, cap: GLenum) void {
    const bit = capBit(g, cap) orelse return g.recordError(.invalid_enum);
    bit.* = false;
}

pub fn isEnabled(g: *Context, cap: GLenum) GLboolean {
    const bit = capBit(g, cap) orelse {
        g.recordError(.invalid_enum);
        return enums.GL_FALSE;
    };
    return if (bit.*) enums.GL_TRUE else enums.GL_FALSE;
}

/// Resolve a client-array token to the array it controls. GL_TEXTURE_COORD_ARRAY names
/// whichever unit glClientActiveTexture selected — a *different* selector from the one
/// glEnable's GL_TEXTURE_2D uses, which is the sharpest edge in this corner of the API.
fn arraySlot(g: *Context, array: GLenum) ?*state.ArrayPointer {
    const slot: idraw.AttribSlot = switch (array) {
        enums.GL_VERTEX_ARRAY => .position,
        enums.GL_NORMAL_ARRAY => .normal,
        enums.GL_COLOR_ARRAY => .color,
        enums.GL_POINT_SIZE_ARRAY_OES => .point_size,
        enums.GL_TEXTURE_COORD_ARRAY => if (g.client_active_texture == 0) .texcoord0 else .texcoord1,
        else => return null,
    };
    return &g.arrays[@intFromEnum(slot)];
}

pub fn enableClientState(g: *Context, array: GLenum) void {
    const a = arraySlot(g, array) orelse return g.recordError(.invalid_enum);
    a.enabled = true;
}

pub fn disableClientState(g: *Context, array: GLenum) void {
    const a = arraySlot(g, array) orelse return g.recordError(.invalid_enum);
    a.enabled = false;
}
