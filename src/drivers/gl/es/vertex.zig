//! The vertex array pointers — glVertexPointer and its four siblings.
//!
//! Each names where one attribute's values live: how many components, of what type, how
//! far apart, starting where. Two rules are easy to miss and both are load-bearing:
//!
//! **The buffer binding is captured NOW.** Whatever is bound to GL_ARRAY_BUFFER at the
//! moment the pointer is set is the buffer this array reads from, forever after.
//! Rebinding later does not move it. When nothing is bound, `pointer` is an address in
//! the application's own memory and we must copy from it at draw time.
//!
//! **A stride of 0 does not mean zero.** It means "tightly packed", and the real stride
//! is then size × sizeof(type). Resolving it here means nothing downstream has to know
//! the shorthand exists.
//!
//! Each entry point accepts only the sizes and types the standard allows for it, and
//! they differ per attribute: a normal is always 3 components, a colour always 4, and
//! neither accepts the other's set.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.8; the glVertexPointer,
//! glNormalPointer, glColorPointer and glTexCoordPointer reference pages.

const std = @import("std");
pub const idraw = @import("idraw");
pub const enums = @import("enums.zig");
pub const state = @import("state.zig");

pub const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLsizei = enums.GLsizei;
const Context = state.Context;
const DataType = state.ArrayPointer.DataType;

fn mapType(v: GLenum) ?DataType {
    return switch (v) {
        enums.GL_BYTE => .byte,
        enums.GL_UNSIGNED_BYTE => .ubyte,
        enums.GL_SHORT => .short,
        enums.GL_UNSIGNED_SHORT => .ushort,
        enums.GL_FIXED => .fixed,
        enums.GL_FLOAT => .float,
        else => null,
    };
}

pub fn typeSize(t: DataType) u32 {
    return switch (t) {
        .byte, .ubyte => 1,
        .short, .ushort => 2,
        .fixed, .float => 4,
    };
}

/// The shared body: validate, resolve the packed stride, capture the binding.
fn setPointer(
    g: *Context,
    slot: idraw.AttribSlot,
    size: u32,
    type_token: GLenum,
    stride: GLsizei,
    ptr: ?*const anyopaque,
    allowed_types: []const DataType,
) void {
    if (stride < 0) return g.recordError(.invalid_value);
    const t = mapType(type_token) orelse return g.recordError(.invalid_enum);
    for (allowed_types) |a| {
        if (a == t) break;
    } else return g.recordError(.invalid_enum);

    const packed_stride = size * typeSize(t);
    g.arrays[@intFromEnum(slot)] = .{
        .enabled = g.arrays[@intFromEnum(slot)].enabled, // enable state is glEnableClientState's
        .size = size,
        .type = t,
        .stride = if (stride == 0) packed_stride else @intCast(stride),
        .ptr = @ptrCast(@alignCast(ptr)),
        .buffer = g.array_buffer, // captured now, not at draw time
    };
}

/// Positions: 2, 3 or 4 components. Never 1 — a vertex with only an x is not a thing
/// the standard admits.
pub fn vertexPointer(g: *Context, size: GLint, type_token: GLenum, stride: GLsizei, ptr: ?*const anyopaque) void {
    if (size < 2 or size > 4) return g.recordError(.invalid_value);
    setPointer(g, .position, @intCast(size), type_token, stride, ptr, &.{ .byte, .short, .fixed, .float });
}

/// Normals: always 3 components, so there is no size argument at all.
pub fn normalPointer(g: *Context, type_token: GLenum, stride: GLsizei, ptr: ?*const anyopaque) void {
    setPointer(g, .normal, 3, type_token, stride, ptr, &.{ .byte, .short, .fixed, .float });
}

/// Colours: always 4 components, and only unsigned bytes, fixed or floats — a signed
/// byte colour is not in the standard's set.
pub fn colorPointer(g: *Context, size: GLint, type_token: GLenum, stride: GLsizei, ptr: ?*const anyopaque) void {
    if (size != 4) return g.recordError(.invalid_value);
    setPointer(g, .color, 4, type_token, stride, ptr, &.{ .ubyte, .fixed, .float });
}

pub fn texCoordPointer(g: *Context, size: GLint, type_token: GLenum, stride: GLsizei, ptr: ?*const anyopaque) void {
    if (size < 2 or size > 4) return g.recordError(.invalid_value);
    const slot: idraw.AttribSlot = if (g.client_active_texture == 0) .texcoord0 else .texcoord1;
    setPointer(g, slot, @intCast(size), type_token, stride, ptr, &.{ .byte, .short, .fixed, .float });
}

/// OES_point_size_array: one size per point. Always 1 component, and float or fixed
/// only.
pub fn pointSizePointerOES(g: *Context, type_token: GLenum, stride: GLsizei, ptr: ?*const anyopaque) void {
    setPointer(g, .point_size, 1, type_token, stride, ptr, &.{ .fixed, .float });
}
