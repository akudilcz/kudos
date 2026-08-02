//! glGet — the state query, in four numeric flavours.
//!
//! One table, four readings. The standard defines each state variable with a type, and
//! then says every glGet flavour must answer for ALL of them, converting (§6.1.2):
//! a boolean read as an integer is 0 or 1; an integer read as a boolean is false only
//! if it is exactly zero; and a FLOAT read as an INTEGER is ROUNDED, not truncated —
//! which is why glGetIntegerv(GL_DEPTH_CLEAR_VALUE) on a default context returns 1.
//!
//! So the queries below produce a value of its natural type once, and the four entry
//! points convert. Writing four switches instead would be four places for one row to
//! drift.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §6.1.2, §6.2 (state tables).

const std = @import("std");
pub const enums = @import("enums.zig");
const fixed = @import("fixed.zig");
const limits = @import("limits.zig");
pub const matrix = @import("matrix.zig");
pub const state = @import("state.zig");
pub const unpack = @import("unpack.zig");

pub const GLenum = enums.GLenum;
pub const GLint = enums.GLint;
pub const GLboolean = enums.GLboolean;
pub const GLfloat = enums.GLfloat;
pub const GLfixed = enums.GLfixed;
const Context = state.Context;

/// A state variable's value in its natural type, plus how many components it has.
const Value = union(enum) {
    b: bool,
    i: GLint,
    f: GLfloat,
    v4: [4]GLfloat,
    v2: [2]GLfloat,
    m4: matrix.Mat4,
};

fn query(g: *Context, pname: GLenum) ?Value {
    return switch (pname) {
        // Implementation-dependent values. These come from the DEVICE, never from a
        // number written here, so glGet can never promise what the silicon will not do.
        enums.GL_MAX_TEXTURE_SIZE => .{ .i = @intCast(g.dev_limits.max_texture_size) },
        enums.GL_MAX_TEXTURE_UNITS => .{ .i = @intCast(g.dev_limits.texture_units) },
        enums.GL_SUBPIXEL_BITS => .{ .i = @intCast(g.dev_limits.subpixel_bits) },
        enums.GL_SAMPLES => .{ .i = @intCast(g.dev_limits.samples) },
        enums.GL_SAMPLE_BUFFERS => .{ .i = if (g.dev_limits.samples > 1) 1 else 0 },
        // These are ours: they size our arrays, so they cannot come from the device.
        enums.GL_MAX_LIGHTS => .{ .i = limits.MAX_LIGHTS },
        enums.GL_MAX_CLIP_PLANES => .{ .i = limits.MAX_CLIP_PLANES },
        enums.GL_MAX_MODELVIEW_STACK_DEPTH => .{ .i = limits.MAX_MODELVIEW_STACK_DEPTH },
        enums.GL_MAX_PROJECTION_STACK_DEPTH => .{ .i = limits.MAX_PROJECTION_STACK_DEPTH },
        enums.GL_MAX_TEXTURE_STACK_DEPTH => .{ .i = limits.MAX_TEXTURE_STACK_DEPTH },

        // Current state.
        enums.GL_CURRENT_COLOR => .{ .v4 = g.color },
        enums.GL_POINT_SIZE => .{ .f = g.point_size },
        enums.GL_LINE_WIDTH => .{ .f = g.line_width },
        enums.GL_DEPTH_CLEAR_VALUE => .{ .f = g.clear_depth },
        enums.GL_COLOR_CLEAR_VALUE => .{ .v4 = g.clear_color },
        enums.GL_STENCIL_CLEAR_VALUE => .{ .i = g.clear_stencil },
        enums.GL_DEPTH_RANGE => .{ .v2 = g.depth_range },
        enums.GL_MODELVIEW_MATRIX => .{ .m4 = g.modelview.top() },
        enums.GL_PROJECTION_MATRIX => .{ .m4 = g.projection.top() },
        enums.GL_TEXTURE_MATRIX => .{ .m4 = g.texture_matrix[g.active_texture].top() },
        enums.GL_MODELVIEW_STACK_DEPTH => .{ .i = @intCast(g.modelview.liveDepth()) },
        enums.GL_PROJECTION_STACK_DEPTH => .{ .i = @intCast(g.projection.liveDepth()) },
        enums.GL_TEXTURE_STACK_DEPTH => .{ .i = @intCast(g.texture_matrix[g.active_texture].liveDepth()) },
        enums.GL_DEPTH_WRITEMASK => .{ .b = g.depth_writemask },
        enums.GL_ARRAY_BUFFER_BINDING => .{ .i = @intCast(g.array_buffer) },
        enums.GL_ELEMENT_ARRAY_BUFFER_BINDING => .{ .i = @intCast(g.element_array_buffer) },
        enums.GL_TEXTURE_BINDING_2D => .{ .i = @intCast(g.texture_binding[g.active_texture]) },
        enums.GL_ACTIVE_TEXTURE => .{ .i = @intCast(enums.GL_TEXTURE0 + g.active_texture) },
        enums.GL_CLIENT_ACTIVE_TEXTURE => .{ .i = @intCast(enums.GL_TEXTURE0 + g.client_active_texture) },
        enums.GL_MATRIX_MODE => .{ .i = @intCast(@as(GLenum, switch (g.matrix_mode) {
            .modelview => enums.GL_MODELVIEW,
            .projection => enums.GL_PROJECTION,
            .texture => enums.GL_TEXTURE,
        })) },
        // OES_read_format, mandatory: the one pair besides RGBA/UNSIGNED_BYTE that this
        // implementation can deliver without converting — the framebuffer's native
        // blue-first layout (RND-008), read back without a per-texel channel swap.
        enums.GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES => .{ .i = @intCast(unpack.GL_BGRA_EXT) },
        enums.GL_IMPLEMENTATION_COLOR_READ_TYPE_OES => .{ .i = @intCast(enums.GL_UNSIGNED_BYTE) },
        else => {
            g.recordError(.invalid_enum);
            return null;
        },
    };
}

fn components(v: Value) usize {
    return switch (v) {
        .b, .i, .f => 1,
        .v2 => 2,
        .v4 => 4,
        .m4 => 16,
    };
}

fn asFloat(v: Value, i: usize) GLfloat {
    return switch (v) {
        .b => |x| if (x) 1 else 0,
        .i => |x| @floatFromInt(x),
        .f => |x| x,
        .v2 => |x| x[i],
        .v4 => |x| x[i],
        .m4 => |x| x[i],
    };
}

pub fn getBooleanv(g: *Context, pname: GLenum, params: [*]GLboolean) void {
    const v = query(g, pname) orelse return;
    // Any non-zero value is TRUE — the conversion is a test against zero, not a cast.
    for (0..components(v)) |i|
        params[i] = if (asFloat(v, i) != 0) enums.GL_TRUE else enums.GL_FALSE;
}

pub fn getIntegerv(g: *Context, pname: GLenum, params: [*]GLint) void {
    const v = query(g, pname) orelse return;
    for (0..components(v)) |i| params[i] = switch (v) {
        .i => |x| x,
        .b => |x| if (x) 1 else 0,
        // A float read as an integer ROUNDS. Truncating would make
        // glGetIntegerv(GL_DEPTH_CLEAR_VALUE) return 0 on a default context, where the
        // standard says 1.
        else => @intFromFloat(@round(asFloat(v, i))),
    };
}

pub fn getFloatv(g: *Context, pname: GLenum, params: [*]GLfloat) void {
    const v = query(g, pname) orelse return;
    for (0..components(v)) |i| params[i] = asFloat(v, i);
}

pub fn getFixedv(g: *Context, pname: GLenum, params: [*]GLfixed) void {
    const v = query(g, pname) orelse return;
    for (0..components(v)) |i| params[i] = switch (v) {
        // An enum converts to fixed-point WITHOUT scaling (§2.3): GL_MODELVIEW read as
        // a fixed is 0x1700, not 0x1700 * 65536.
        .i => |x| x,
        .b => |x| if (x) 1 else 0,
        else => fixed.fromFloat(asFloat(v, i)),
    };
}

/// glGetPointerv: where an array's data lives. Null for an array in a buffer object —
/// the pointer was an offset then, not an address.
pub fn getPointerv(g: *Context, pname: GLenum, params: [*]?*anyopaque) void {
    const idraw_mod = @import("idraw");
    const slot: idraw_mod.AttribSlot = switch (pname) {
        enums.GL_VERTEX_ARRAY_POINTER => .position,
        enums.GL_NORMAL_ARRAY_POINTER => .normal,
        enums.GL_COLOR_ARRAY_POINTER => .color,
        enums.GL_POINT_SIZE_ARRAY_POINTER_OES => .point_size,
        enums.GL_TEXTURE_COORD_ARRAY_POINTER => if (g.client_active_texture == 0) .texcoord0 else .texcoord1,
        else => return g.recordError(.invalid_enum),
    };
    params[0] = @ptrCast(@constCast(g.arrays[@intFromEnum(slot)].ptr));
}
