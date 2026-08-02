//! Buffer objects — glGenBuffers and friends.
//!
//! A buffer object is GPU-owned memory an application fills once and draws from many
//! times, instead of handing us a pointer into its own memory on every draw. ES 1.1 has
//! two binding points, and they are not interchangeable: GL_ARRAY_BUFFER is where
//! vertex attributes come from, GL_ELEMENT_ARRAY_BUFFER is where indices come from.
//!
//! **Names are not handles.** `glGenBuffers` hands out *names* — integers reserved for
//! the application — and the object itself does not exist until the name is first
//! bound. So a name can be bound, and only then does it become a real device buffer.
//! That indirection is why this module keeps a table rather than passing the device's
//! handles straight through.
//!
//! Zero is reserved forever: binding zero means "no buffer", not "buffer number zero".
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.9; the glBindBuffer and
//! glBufferData reference pages.

const std = @import("std");
const idraw = @import("idraw");
const enums = @import("enums.zig");
const objects = @import("objects.zig");
const state = @import("state.zig");

const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLuint = enums.GLuint;
const GLsizei = enums.GLsizei;
const GLboolean = enums.GLboolean;
const GLintptr = enums.GLintptr;
const GLsizeiptr = enums.GLsizeiptr;
const Context = state.Context;

/// Which binding point a target token names.
fn bindingFor(g: *Context, target: GLenum) ?*GLuint {
    return switch (target) {
        enums.GL_ARRAY_BUFFER => &g.array_buffer,
        enums.GL_ELEMENT_ARRAY_BUFFER => &g.element_array_buffer,
        else => {
            g.recordError(.invalid_enum);
            return null;
        },
    };
}

pub fn genBuffers(g: *Context, n: GLsizei, buffers: [*]GLuint) void {
    if (n < 0) return g.recordError(.invalid_value);
    g.buffers.gen(@intCast(n), buffers) catch g.recordError(.out_of_memory);
}

pub fn deleteBuffers(g: *Context, n: GLsizei, buffers: [*]const GLuint) void {
    if (n < 0) return g.recordError(.invalid_value);
    for (buffers[0..@intCast(n)]) |name| {
        if (name == 0) continue; // deleting zero is silently ignored, per the standard
        // The standard requires a deleted buffer to be unbound from every binding point
        // it currently occupies — as if glBindBuffer(target, 0) had been called. Miss
        // this and the next draw reads a buffer that no longer exists.
        if (g.array_buffer == name) g.array_buffer = 0;
        if (g.element_array_buffer == name) g.element_array_buffer = 0;
        if (g.buffers.deviceHandle(name)) |h| g.dev.bufferDestroy(h);
        if (g.buffers.record(name)) |rec| {
            if (rec.shadow.len != 0) g.alloc.free(rec.shadow);
        }
        g.buffers.delete(name);
    }
}

pub fn bindBuffer(g: *Context, target: GLenum, buffer: GLuint) void {
    const binding = bindingFor(g, target) orelse return;
    if (buffer != 0) g.buffers.ensureNamed(buffer) catch return g.recordError(.out_of_memory);
    binding.* = buffer;
}

pub fn isBuffer(g: *Context, buffer: GLuint) GLboolean {
    // Only a name that has actually been BOUND is a buffer; a name merely generated is
    // not one yet, which is the distinction glIsBuffer exists to expose.
    return if (g.buffers.isObject(buffer)) enums.GL_TRUE else enums.GL_FALSE;
}

pub fn bufferData(g: *Context, target: GLenum, size: GLsizeiptr, data: ?*const anyopaque, usage: GLenum) void {
    const binding = bindingFor(g, target) orelse return;
    if (size < 0) return g.recordError(.invalid_value);
    const name = binding.*;
    if (name == 0) return g.recordError(.invalid_operation); // nothing bound

    const u: idraw.Usage = switch (usage) {
        enums.GL_STATIC_DRAW => .static,
        enums.GL_DYNAMIC_DRAW => .dynamic,
        else => return g.recordError(.invalid_enum),
    };

    const bytes: []const u8 = if (data) |p|
        @as([*]const u8, @ptrCast(p))[0..@intCast(size)]
    else
        &.{};

    // glBufferData REPLACES the store, so an existing one is released first.
    if (g.buffers.deviceHandle(name)) |old| g.dev.bufferDestroy(old);
    const h = g.dev.bufferCreate(bytes, u) catch return g.recordError(.out_of_memory);
    g.buffers.setDeviceHandle(name, h, @intCast(size), u);

    // Keep a copy. The GPU's is unreadable, and an array of GL_FIXED living in this
    // buffer has to be widened on the CPU before any fetcher can decode it — so
    // without this, a legal ES program simply could not be drawn.
    const rec = g.buffers.record(name).?;
    if (rec.shadow.len != 0) g.alloc.free(rec.shadow);
    rec.shadow = g.alloc.alloc(u8, bytes.len) catch {
        rec.shadow = &.{};
        return g.recordError(.out_of_memory);
    };
    @memcpy(rec.shadow, bytes);
}

pub fn bufferSubData(g: *Context, target: GLenum, offset: GLintptr, size: GLsizeiptr, data: ?*const anyopaque) void {
    const binding = bindingFor(g, target) orelse return;
    if (size < 0 or offset < 0) return g.recordError(.invalid_value);
    const name = binding.*;
    if (name == 0) return g.recordError(.invalid_operation);
    const rec = g.buffers.record(name) orelse return g.recordError(.invalid_operation);
    if (@as(usize, @intCast(offset)) + @as(usize, @intCast(size)) > rec.size)
        return g.recordError(.invalid_value); // an update may not grow the store
    const p = data orelse return;
    const bytes = @as([*]const u8, @ptrCast(p))[0..@intCast(size)];
    const h = rec.handle orelse return g.recordError(.invalid_operation);
    g.dev.bufferUpdate(h, @intCast(offset), bytes) catch return g.recordError(.out_of_memory);
    // The shadow has to track the store, or a later GL_FIXED draw widens stale data.
    const off: usize = @intCast(offset);
    if (off + bytes.len <= rec.shadow.len) @memcpy(rec.shadow[off..][0..bytes.len], bytes);
}

pub fn getBufferParameteriv(g: *Context, target: GLenum, pname: GLenum, params: [*]GLint) void {
    const binding = bindingFor(g, target) orelse return;
    const name = binding.*;
    if (name == 0) return g.recordError(.invalid_operation);
    const rec = g.buffers.record(name) orelse return g.recordError(.invalid_operation);
    switch (pname) {
        enums.GL_BUFFER_SIZE => params[0] = @intCast(rec.size),
        enums.GL_BUFFER_USAGE => params[0] = @intCast(switch (rec.usage) {
            .static => enums.GL_STATIC_DRAW,
            .dynamic => enums.GL_DYNAMIC_DRAW,
        }),
        else => g.recordError(.invalid_enum),
    }
}
