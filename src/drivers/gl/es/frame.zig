//! glReadPixels and glPixelStorei — the pixel path.
//!
//! `glReadPixels` is the only call in this API that makes the CPU wait for the GPU: the
//! specification defines it to hand the application pixels, so there is nowhere else
//! for them to come from. Everything else here is fire-and-forget.
//!
//! The standard guarantees exactly one format/type pair always works —
//! RGBA/UNSIGNED_BYTE — and requires the implementation to name one more it prefers,
//! which is what OES_read_format (mandatory) is for; ours is queried through
//! glGetIntegerv(GL_IMPLEMENTATION_COLOR_READ_FORMAT_OES).
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §4.3; the glReadPixels page.

const std = @import("std");
pub const idraw = @import("idraw");
pub const enums = @import("enums.zig");
pub const state = @import("state.zig");
pub const unpack = @import("unpack.zig");

pub const GLenum = enums.GLenum;
pub const GLint = enums.GLint;
const GLsizei = enums.GLsizei;
const Context = state.Context;

/// glPixelStorei: ES 1.1 has exactly two of desktop GL's many pixel-store parameters,
/// and each takes only a power of two up to 8.
pub fn pixelStorei(g: *Context, pname: GLenum, param: GLint) void {
    const ok = param == 1 or param == 2 or param == 4 or param == 8;
    if (!ok) return g.recordError(.invalid_value);
    switch (pname) {
        enums.GL_PACK_ALIGNMENT => g.pack_alignment = @intCast(param),
        enums.GL_UNPACK_ALIGNMENT => g.unpack_alignment = @intCast(param),
        else => g.recordError(.invalid_enum),
    }
}

pub fn readPixels(
    g: *Context,
    x: GLint,
    y: GLint,
    width: GLsizei,
    height: GLsizei,
    format: GLenum,
    type_token: GLenum,
    pixels: ?*anyopaque,
) void {
    if (width < 0 or height < 0) return g.recordError(.invalid_value);
    // The always-supported pair, plus the one OES_read_format names: BGRA is the
    // framebuffer's native layout (RND-008), so it reads back without a swizzle.
    const fmt: idraw.ReadFormat = if (format == enums.GL_RGBA and type_token == enums.GL_UNSIGNED_BYTE)
        .rgba8
    else if (format == unpack.GL_BGRA_EXT and type_token == enums.GL_UNSIGNED_BYTE)
        .bgra8
    else
        return g.recordError(.invalid_enum);
    const p = pixels orelse return;
    const n = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const dst = @as([*]u8, @ptrCast(p))[0..n];
    g.target.readPixels(.{ .x = x, .y = y, .w = @intCast(width), .h = @intCast(height) }, fmt, dst) catch {
        g.recordError(.out_of_memory);
    };
}
