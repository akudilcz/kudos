//! The texture environment — how a sampled texel combines with the colour that arrived.
//!
//! This is the state whose size decided the architecture. Its COMBINE mode alone has
//! 905,969,664 reachable settings per unit (8 RGB functions x 6 alpha functions x three
//! sources and three operands each side x two scale factors), so a compiled program per
//! setting is not merely expensive, it is impossible — two units squared is 8.2e17.
//! Hence: this state is compiled to a small bytecode the fragment shader INTERPRETS.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §3.7.12, tables 3.17-3.19.

const std = @import("std");
pub const enums = @import("enums.zig");
const fixed = @import("fixed.zig");
pub const state = @import("state.zig");

pub const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLfloat = enums.GLfloat;
const GLfixed = enums.GLfixed;
const Context = state.Context;
const TexEnv = state.TexEnv;

fn env(g: *Context) *TexEnv {
    return &g.texenv[g.active_texture];
}

fn setEnv(g: *Context, target: GLenum, pname: GLenum, v: GLenum) void {
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    const e = env(g);
    switch (pname) {
        enums.GL_TEXTURE_ENV_MODE => e.mode = switch (v) {
            enums.GL_REPLACE => .replace,
            enums.GL_MODULATE => .modulate,
            enums.GL_DECAL => .decal,
            enums.GL_BLEND => .blend,
            enums.GL_ADD => .add,
            enums.GL_COMBINE => .combine,
            else => return g.recordError(.invalid_enum),
        },
        enums.GL_COMBINE_RGB => e.combine_rgb = switch (v) {
            enums.GL_REPLACE => .replace,
            enums.GL_MODULATE => .modulate,
            enums.GL_ADD => .add,
            enums.GL_ADD_SIGNED => .add_signed,
            enums.GL_INTERPOLATE => .interpolate,
            enums.GL_SUBTRACT => .subtract,
            enums.GL_DOT3_RGB => .dot3_rgb,
            enums.GL_DOT3_RGBA => .dot3_rgba,
            else => return g.recordError(.invalid_enum),
        },
        // The alpha combiner has no DOT3: a dot product produces one scalar, and the
        // standard puts it in every channel from the RGB side.
        enums.GL_COMBINE_ALPHA => e.combine_alpha = switch (v) {
            enums.GL_REPLACE => .replace,
            enums.GL_MODULATE => .modulate,
            enums.GL_ADD => .add,
            enums.GL_ADD_SIGNED => .add_signed,
            enums.GL_INTERPOLATE => .interpolate,
            enums.GL_SUBTRACT => .subtract,
            else => return g.recordError(.invalid_enum),
        },
        enums.GL_SRC0_RGB, enums.GL_SRC1_RGB, enums.GL_SRC2_RGB => {
            const i = pname - enums.GL_SRC0_RGB;
            e.src_rgb[i] = mapSource(v) orelse return g.recordError(.invalid_enum);
        },
        enums.GL_SRC0_ALPHA, enums.GL_SRC1_ALPHA, enums.GL_SRC2_ALPHA => {
            const i = pname - enums.GL_SRC0_ALPHA;
            e.src_alpha[i] = mapSource(v) orelse return g.recordError(.invalid_enum);
        },
        enums.GL_OPERAND0_RGB, enums.GL_OPERAND1_RGB, enums.GL_OPERAND2_RGB => {
            const i = pname - enums.GL_OPERAND0_RGB;
            e.operand_rgb[i] = switch (v) {
                enums.GL_SRC_COLOR => .src_color,
                enums.GL_ONE_MINUS_SRC_COLOR => .one_minus_src_color,
                enums.GL_SRC_ALPHA => .src_alpha,
                enums.GL_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
                else => return g.recordError(.invalid_enum),
            };
        },
        // An alpha operand can only read alpha: there is no colour to take.
        enums.GL_OPERAND0_ALPHA, enums.GL_OPERAND1_ALPHA, enums.GL_OPERAND2_ALPHA => {
            const i = pname - enums.GL_OPERAND0_ALPHA;
            e.operand_alpha[i] = switch (v) {
                enums.GL_SRC_ALPHA => .src_alpha,
                enums.GL_ONE_MINUS_SRC_ALPHA => .one_minus_src_alpha,
                else => return g.recordError(.invalid_enum),
            };
        },
        else => g.recordError(.invalid_enum),
    }
}

fn mapSource(v: GLenum) ?TexEnv.Source {
    return switch (v) {
        enums.GL_TEXTURE => .texture,
        enums.GL_CONSTANT => .constant,
        enums.GL_PRIMARY_COLOR => .primary_color,
        enums.GL_PREVIOUS => .previous,
        else => null,
    };
}

/// The scales are the only float-valued environment parameters, and only 1, 2 and 4 are
/// legal — anything else is INVALID_VALUE, not a clamp.
fn setScale(g: *Context, pname: GLenum, v: GLfloat) bool {
    if (pname != enums.GL_RGB_SCALE and pname != enums.GL_ALPHA_SCALE) return false;
    if (v != 1.0 and v != 2.0 and v != 4.0) {
        g.recordError(.invalid_value);
        return true;
    }
    if (pname == enums.GL_RGB_SCALE) env(g).rgb_scale = v else env(g).alpha_scale = v;
    return true;
}

/// OES_point_sprite: the GL_POINT_SPRITE_OES target carries exactly one
/// parameter, the active unit's COORD_REPLACE flag; any other pname on it is
/// INVALID_ENUM. Returns true when it consumed the call (the target matched).
fn setPointSprite(g: *Context, target: GLenum, pname: GLenum, on: bool) bool {
    if (target != enums.GL_POINT_SPRITE_OES) return false;
    if (pname != enums.GL_COORD_REPLACE_OES) {
        g.recordError(.invalid_enum);
        return true;
    }
    env(g).coord_replace = on;
    return true;
}

pub fn texEnvf(g: *Context, target: GLenum, pname: GLenum, param: GLfloat) void {
    if (setPointSprite(g, target, pname, param != 0)) return;
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    if (setScale(g, pname, param)) return;
    setEnv(g, target, pname, @intFromFloat(param));
}
pub fn texEnvi(g: *Context, target: GLenum, pname: GLenum, param: GLint) void {
    if (setPointSprite(g, target, pname, param != 0)) return;
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    if (setScale(g, pname, @floatFromInt(param))) return;
    setEnv(g, target, pname, @bitCast(param));
}
pub fn texEnvx(g: *Context, target: GLenum, pname: GLenum, param: GLfixed) void {
    if (setPointSprite(g, target, pname, param != 0)) return;
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    // A scale IS a 16.16 number; a mode token is not (spec §2.3). Two different
    // conversions behind one entry point.
    if (pname == enums.GL_RGB_SCALE or pname == enums.GL_ALPHA_SCALE) {
        _ = setScale(g, pname, fixed.toFloat(param));
        return;
    }
    setEnv(g, target, pname, @bitCast(param));
}
pub fn texEnvfv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLfloat) void {
    if (pname == enums.GL_TEXTURE_ENV_COLOR) {
        if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
        env(g).color = .{ params[0], params[1], params[2], params[3] };
        return;
    }
    texEnvf(g, target, pname, params[0]);
}
pub fn texEnviv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLint) void {
    if (pname == enums.GL_TEXTURE_ENV_COLOR) {
        if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
        for (0..4) |i| env(g).color[i] = @floatFromInt(params[i]);
        return;
    }
    texEnvi(g, target, pname, params[0]);
}
pub fn texEnvxv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLfixed) void {
    if (pname == enums.GL_TEXTURE_ENV_COLOR) {
        if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
        for (0..4) |i| env(g).color[i] = fixed.toFloat(params[i]);
        return;
    }
    texEnvx(g, target, pname, params[0]);
}

fn getEnvToken(g: *Context, pname: GLenum) ?GLenum {
    const e = env(g);
    return switch (pname) {
        enums.GL_TEXTURE_ENV_MODE => switch (e.mode) {
            .replace => enums.GL_REPLACE,
            .modulate => enums.GL_MODULATE,
            .decal => enums.GL_DECAL,
            .blend => enums.GL_BLEND,
            .add => enums.GL_ADD,
            .combine => enums.GL_COMBINE,
        },
        else => {
            g.recordError(.invalid_enum);
            return null;
        },
    };
}

/// The GL_POINT_SPRITE_OES half of the glGetTexEnv queries, mirroring
/// setPointSprite: COORD_REPLACE reads back as 0 or 1, anything else on the
/// target is INVALID_ENUM. Returns null when the target is not point-sprite.
fn getPointSprite(g: *Context, target: GLenum, pname: GLenum) ?GLint {
    if (target != enums.GL_POINT_SPRITE_OES) return null;
    if (pname != enums.GL_COORD_REPLACE_OES) {
        g.recordError(.invalid_enum);
        return null;
    }
    return @intFromBool(env(g).coord_replace);
}

pub fn getTexEnviv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLint) void {
    if (target == enums.GL_POINT_SPRITE_OES) {
        params[0] = getPointSprite(g, target, pname) orelse return;
        return;
    }
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    params[0] = @bitCast(getEnvToken(g, pname) orelse return);
}
pub fn getTexEnvfv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLfloat) void {
    if (target == enums.GL_POINT_SPRITE_OES) {
        params[0] = @floatFromInt(getPointSprite(g, target, pname) orelse return);
        return;
    }
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    if (pname == enums.GL_TEXTURE_ENV_COLOR) {
        for (env(g).color, 0..) |v, i| params[i] = v;
        return;
    }
    params[0] = @floatFromInt(getEnvToken(g, pname) orelse return);
}
pub fn getTexEnvxv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLfixed) void {
    if (target == enums.GL_POINT_SPRITE_OES) {
        params[0] = fixed.fromInt(getPointSprite(g, target, pname) orelse return);
        return;
    }
    if (target != enums.GL_TEXTURE_ENV) return g.recordError(.invalid_enum);
    if (pname == enums.GL_TEXTURE_ENV_COLOR) {
        for (env(g).color, 0..) |v, i| params[i] = fixed.fromFloat(v);
        return;
    }
    params[0] = @bitCast(getEnvToken(g, pname) orelse return);
}
