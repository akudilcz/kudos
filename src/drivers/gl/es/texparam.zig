//! Per-texture sampler state — glTexParameter and its readback.
//!
//! Wrap and filter belong to the texture OBJECT, not the unit: two units sampling one
//! texture cannot filter it differently. That is an ES 1.1 fact with no sampler objects
//! to escape it.
//!
//! GL_GENERATE_MIPMAP is the odd one: it is not a sampler setting at all but a
//! standing instruction to rebuild the mip chain whenever level 0 changes.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §3.7.4; the glTexParameter page.

const std = @import("std");
const idraw = @import("idraw");
pub const enums = @import("enums.zig");
const fixed = @import("fixed.zig");
const state = @import("state.zig");

const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLfloat = enums.GLfloat;
const GLfixed = enums.GLfixed;
const Context = state.Context;

/// Per-object sampler state, with the standard's initial values.
///
/// Bit-packed into 16 bits so it fits the object table's `aux` word: a texture's sampler
/// state belongs to the texture, and this is how it rides along without a second table.
pub const Sampler = packed struct(u16) {
    wrap_s: idraw.WrapMode = .repeat,
    wrap_t: idraw.WrapMode = .repeat,
    /// The initial minification filter is NEAREST_MIPMAP_LINEAR — which means a texture
    /// with no mip chain is INCOMPLETE until the application says otherwise. The single
    /// most common "why is my texture white" in all of GL.
    min_filter: MinFilter = .nearest_mipmap_linear,
    mag_filter: idraw.Filter = .linear,
    generate_mipmap: bool = false,
    _pad: u7 = 0,

    pub const MinFilter = enum(u3) {
        nearest,
        linear,
        nearest_mipmap_nearest,
        linear_mipmap_nearest,
        nearest_mipmap_linear,
        linear_mipmap_linear,

        /// Does this filter read more than level 0?
        pub fn usesMipmaps(self: MinFilter) bool {
            return switch (self) {
                .nearest, .linear => false,
                else => true,
            };
        }
    };
};

/// ES 1.1 has exactly two wrap modes. Desktop GL's GL_CLAMP and GL_MIRRORED_REPEAT are
/// not among them, and neither is even spelled by a token in this API.
fn mapWrap(v: GLenum) ?idraw.WrapMode {
    return switch (v) {
        enums.GL_REPEAT => .repeat,
        enums.GL_CLAMP_TO_EDGE => .clamp_to_edge,
        else => null,
    };
}

pub fn mapMin(v: GLenum) ?Sampler.MinFilter {
    return switch (v) {
        enums.GL_NEAREST => .nearest,
        enums.GL_LINEAR => .linear,
        enums.GL_NEAREST_MIPMAP_NEAREST => .nearest_mipmap_nearest,
        enums.GL_LINEAR_MIPMAP_NEAREST => .linear_mipmap_nearest,
        enums.GL_NEAREST_MIPMAP_LINEAR => .nearest_mipmap_linear,
        enums.GL_LINEAR_MIPMAP_LINEAR => .linear_mipmap_linear,
        else => null,
    };
}

/// Magnification has no mipmap forms: there is no level above level 0 to blend with.
pub fn mapMag(v: GLenum) ?idraw.Filter {
    return switch (v) {
        enums.GL_NEAREST => .nearest,
        enums.GL_LINEAR => .linear,
        else => null,
    };
}

fn setParam(g: *Context, target: GLenum, pname: GLenum, v: GLenum) void {
    if (target != enums.GL_TEXTURE_2D) return g.recordError(.invalid_enum);
    const name = g.texture_binding[g.active_texture];
    if (name == 0) return; // the default texture: nothing to parameterize
    const rec = g.textures.record(name) orelse return;
    var s: Sampler = @bitCast(@as(u16, @truncate(rec.aux)));
    switch (pname) {
        enums.GL_TEXTURE_WRAP_S => s.wrap_s = mapWrap(v) orelse return g.recordError(.invalid_enum),
        enums.GL_TEXTURE_WRAP_T => s.wrap_t = mapWrap(v) orelse return g.recordError(.invalid_enum),
        enums.GL_TEXTURE_MIN_FILTER => s.min_filter = mapMin(v) orelse return g.recordError(.invalid_enum),
        enums.GL_TEXTURE_MAG_FILTER => s.mag_filter = mapMag(v) orelse return g.recordError(.invalid_enum),
        enums.GL_GENERATE_MIPMAP => s.generate_mipmap = v != 0,
        else => return g.recordError(.invalid_enum),
    }
    rec.aux = @as(u16, @bitCast(s));
}

pub fn texParameteri(g: *Context, target: GLenum, pname: GLenum, param: GLint) void {
    setParam(g, target, pname, @bitCast(param));
}
pub fn texParameterf(g: *Context, target: GLenum, pname: GLenum, param: GLfloat) void {
    setParam(g, target, pname, @intFromFloat(param));
}
pub fn texParameterx(g: *Context, target: GLenum, pname: GLenum, param: GLfixed) void {
    // A token converts to fixed-point WITHOUT scaling (spec §2.3), so this is not a
    // 16.16 value and must not be divided by 65536.
    setParam(g, target, pname, @bitCast(param));
}
pub fn texParameteriv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLint) void {
    texParameteri(g, target, pname, params[0]);
}
pub fn texParameterfv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLfloat) void {
    texParameterf(g, target, pname, params[0]);
}
pub fn texParameterxv(g: *Context, target: GLenum, pname: GLenum, params: [*]const GLfixed) void {
    texParameterx(g, target, pname, params[0]);
}

fn getParam(g: *Context, target: GLenum, pname: GLenum) ?GLenum {
    if (target != enums.GL_TEXTURE_2D) {
        g.recordError(.invalid_enum);
        return null;
    }
    const name = g.texture_binding[g.active_texture];
    const s: Sampler = if (name == 0) .{} else blk: {
        const rec = g.textures.record(name) orelse break :blk Sampler{};
        break :blk @bitCast(@as(u16, @truncate(rec.aux)));
    };
    return switch (pname) {
        enums.GL_TEXTURE_WRAP_S => switch (s.wrap_s) {
            .repeat => enums.GL_REPEAT,
            .clamp_to_edge => enums.GL_CLAMP_TO_EDGE,
        },
        enums.GL_TEXTURE_WRAP_T => switch (s.wrap_t) {
            .repeat => enums.GL_REPEAT,
            .clamp_to_edge => enums.GL_CLAMP_TO_EDGE,
        },
        enums.GL_TEXTURE_MIN_FILTER => switch (s.min_filter) {
            .nearest => enums.GL_NEAREST,
            .linear => enums.GL_LINEAR,
            .nearest_mipmap_nearest => enums.GL_NEAREST_MIPMAP_NEAREST,
            .linear_mipmap_nearest => enums.GL_LINEAR_MIPMAP_NEAREST,
            .nearest_mipmap_linear => enums.GL_NEAREST_MIPMAP_LINEAR,
            .linear_mipmap_linear => enums.GL_LINEAR_MIPMAP_LINEAR,
        },
        enums.GL_TEXTURE_MAG_FILTER => switch (s.mag_filter) {
            .nearest => enums.GL_NEAREST,
            .linear => enums.GL_LINEAR,
        },
        enums.GL_GENERATE_MIPMAP => if (s.generate_mipmap) enums.GL_TRUE else enums.GL_FALSE,
        else => {
            g.recordError(.invalid_enum);
            return null;
        },
    };
}

pub fn getTexParameteriv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLint) void {
    params[0] = @bitCast(getParam(g, target, pname) orelse return);
}
pub fn getTexParameterfv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLfloat) void {
    params[0] = @floatFromInt(getParam(g, target, pname) orelse return);
}
pub fn getTexParameterxv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLfixed) void {
    params[0] = @bitCast(getParam(g, target, pname) orelse return);
}
