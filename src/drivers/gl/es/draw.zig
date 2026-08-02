//! glDrawArrays and glDrawElements — where all the state finally means something.
//!
//! Every other file in this module writes down what an application asked for. This one
//! turns the accumulated answer into a draw: it picks the program (shaderkey), packs the
//! constants (uniforms), builds the pipeline (pipeline), resolves where each attribute's
//! bytes live, and hands the lot to the device.
//!
//! ## Two paths, and the fast one is the common one
//!
//! An array whose data is already in a buffer object, in a format the fetcher decodes,
//! is drawn **in place** — no copy, no per-frame work. That is what a buffer object is
//! for, and it is what a model viewer hits every frame.
//!
//! Everything else is **staged**: gathered into one scratch buffer, converted if it is
//! GL_FIXED, uploaded once, drawn from there. Two things land here — client-side arrays
//! (the application kept its data in its own memory, which the GPU cannot read) and
//! GL_FIXED (16.16 is a format no fetcher decodes). Staging is per draw, so it is the
//! slow path by construction; the scratch grows and is reused, so the steady state
//! allocates nothing even for an application that never learned about buffer objects.
//!
//! ## Drawing nothing is not an error
//!
//! With GL_VERTEX_ARRAY disabled there are no vertices, and the standard's answer is
//! that nothing is drawn — not that something is wrong. Several checks below end in a
//! silent return for exactly that reason.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.8; the glDrawArrays and
//! glDrawElements reference pages.

const std = @import("std");
const idraw = @import("idraw");
const attrib = @import("attrib.zig");
pub const enums = @import("enums.zig");
const fixed = @import("fixed.zig");
const pipeline = @import("pipeline.zig");
pub const state = @import("state.zig");
const uniforms = @import("uniforms.zig");

pub const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLsizei = enums.GLsizei;
const Context = state.Context;

pub fn mapPrim(v: GLenum) ?idraw.Prim {
    return switch (v) {
        enums.GL_POINTS => .points,
        enums.GL_LINES => .lines,
        enums.GL_LINE_LOOP => .line_loop,
        enums.GL_LINE_STRIP => .line_strip,
        enums.GL_TRIANGLES => .triangles,
        enums.GL_TRIANGLE_STRIP => .triangle_strip,
        enums.GL_TRIANGLE_FAN => .triangle_fan,
        else => null,
    };
}

/// Core ES 1.1 indices are 8- or 16-bit; GL_UNSIGNED_INT (32-bit) arrives with the
/// OES_element_index_uint extension, which gles advertises (RND-004) so a model may
/// exceed the 65,536 vertices a 16-bit index reaches. The idraw layer beneath already
/// carries all three widths.
pub fn mapIndexType(v: GLenum) ?idraw.IndexType {
    return switch (v) {
        enums.GL_UNSIGNED_BYTE => .u8,
        enums.GL_UNSIGNED_SHORT => .u16,
        enums.GL_UNSIGNED_INT => .u32,
        else => null,
    };
}

pub fn indexSize(t: idraw.IndexType) usize {
    return switch (t) {
        .u8 => 1,
        .u16 => 2,
        .u32 => 4,
    };
}

/// A GL array "pointer" is a byte OFFSET when a buffer is bound, and an address when
/// one is not. Same field, two meanings, decided by the binding captured with it.
pub fn offsetOf(a: state.ArrayPointer) usize {
    return @intFromPtr(a.ptr orelse @as([*]const u8, @ptrFromInt(1)) - 1);
}

/// Does this array have to be staged, or can the GPU read it where it lies?
pub fn mustStage(a: state.ArrayPointer) bool {
    return a.buffer == 0 or attrib.needsWidening(a.type);
}

/// How many bytes staging one array of `count` elements needs.
pub fn stagedSize(a: state.ArrayPointer, count: u32) usize {
    return @as(usize, attrib.stagedElementSize(a.size, a.type)) * count;
}

/// Where an array's bytes are readable from the CPU: a buffer object's shadow, or the
/// application's own memory.
fn sourceBytes(g: *Context, a: state.ArrayPointer, first: u32, count: u32) ?[]const u8 {
    const span = @as(usize, a.stride) * (first + count);
    if (a.buffer != 0) {
        const rec = g.buffers.record(a.buffer) orelse return null;
        const off = offsetOf(a);
        if (off + span > rec.shadow.len) return null; // the draw runs off the buffer
        return rec.shadow[off..];
    }
    const p = a.ptr orelse return null;
    // Client memory has no length we can know. The draw's own bounds are the contract,
    // and reading past what the application allocated is its bug to make, not ours to
    // detect — the standard says as much.
    return p[0..span];
}

/// Gather `count` elements into `dst`, tightly packed, widening GL_FIXED on the way.
pub fn gather(dst: []u8, src: []const u8, a: state.ArrayPointer, first: u32, count: u32) void {
    const elem = attrib.stagedElementSize(a.size, a.type);
    for (0..count) |i| {
        const s = src[(first + i) * a.stride ..];
        const d = dst[i * elem ..];
        if (a.type == .fixed) {
            for (0..a.size) |c| {
                const raw = std.mem.readInt(i32, s[c * 4 ..][0..4], .little);
                std.mem.writeInt(u32, d[c * 4 ..][0..4], @bitCast(fixed.toFloat(raw)), .little);
            }
        } else {
            @memcpy(d[0..elem], s[0..elem]);
        }
    }
}

/// Build the attribute set for a draw covering vertices [first, first+count).
///
/// Null when the draw cannot proceed — no positions, or an array whose bytes we cannot
/// reach. Both mean "draw nothing", which is what the standard asks for.
///
/// Staged bytes are APPENDED to the frame's staging stream, never written over an
/// earlier draw's: a device may defer every draw to one submit at the end of the frame,
/// so each draw's data must survive until then, distinguished by the offsets carried in
/// the draw itself.
fn resolveAttribs(g: *Context, first: u32, count: u32) ?[idraw.AttribSlot.COUNT]idraw.Attrib {
    var out: [idraw.AttribSlot.COUNT]idraw.Attrib = .{.disabled} ** idraw.AttribSlot.COUNT;

    // Without positions there is no geometry. Not an error: just nothing.
    if (!g.arrays[@intFromEnum(idraw.AttribSlot.position)].enabled) return null;

    var need: usize = 0;
    for (g.arrays) |a| {
        if (a.enabled and mustStage(a)) need += stagedSize(a, count);
    }
    var base: u32 = 0;
    if (need != 0) {
        g.reserveStaging(need) catch {
            g.recordError(.out_of_memory);
            return null;
        };
        const room = g.ensureStagingRoom(need) orelse return null;
        base = room.base;
    }

    var at: usize = 0;
    for (g.arrays, 0..) |a, i| {
        const slot: idraw.AttribSlot = @enumFromInt(i);
        if (!a.enabled) {
            // A disabled array is not an absent attribute: every vertex still has this
            // value, and it is whatever glColor4f/glNormal3f last set.
            out[i] = switch (slot) {
                .position => return null,
                .color => .{ .constant = g.color },
                .normal => .{ .constant = .{ g.normal[0], g.normal[1], g.normal[2], 0 } },
                .texcoord0 => .{ .constant = g.texcoord[0] },
                .texcoord1 => .{ .constant = g.texcoord[1] },
                .point_size => .{ .constant = .{ g.point_size, 0, 0, 0 } },
            };
            continue;
        }

        const r = attrib.resolve(slot, a.size, a.type) orelse return null;
        if (!mustStage(a)) {
            // The fast path: the data is already where the GPU wants it, in a format it
            // decodes. Fold `first` into the offset and draw it in place.
            const h = g.buffers.deviceHandle(a.buffer) orelse return null;
            out[i] = .{ .array = .{
                .buffer = h,
                .offset = @intCast(offsetOf(a) + first * a.stride),
                .stride = a.stride,
                .format = r.native,
            } };
            continue;
        }

        const src = sourceBytes(g, a, first, count) orelse return null;
        const size = stagedSize(a, count);
        gather(g.staging[at..][0..size], src, a, first, count);
        out[i] = .{
            .array = .{
                .buffer = g.staging_buf.?,
                .offset = @intCast(base + at),
                .stride = attrib.stagedElementSize(a.size, a.type), // gathered tightly
                .format = switch (r) {
                    .native, .widen => |f| f,
                },
            },
        };
        at += size;
    }

    if (at != 0) {
        g.dev.bufferUpdate(g.staging_buf.?, base, g.staging[0..at]) catch {
            g.recordError(.out_of_memory);
            return null;
        };
        g.staging_used = base + at;
    }
    return out;
}

/// Pack the constants, build the pipeline, issue the draw.
fn issue(g: *Context, d: idraw.Draw) void {
    // Call-scoped: the device takes what it needs before draw() returns, so a frame with
    // a thousand draws reuses this one stack slot a thousand times.
    var image: [uniforms.SIZE]u8 = undefined;
    uniforms.pack(g, &image);
    const p = pipeline.build(g, &image, d.prim);
    g.target.draw(&p, &d) catch |e| switch (e) {
        // The device ran out of room to record the draw. The standard permits
        // OUT_OF_MEMORY from any command, and blocking would stall the compositor that
        // called us.
        idraw.Error.DrawOutOfResources => g.recordError(.out_of_memory),
        else => g.recordError(.invalid_operation),
    };
}

pub fn drawArrays(g: *Context, mode: GLenum, first: GLint, count: GLsizei) void {
    const prim = mapPrim(mode) orelse return g.recordError(.invalid_enum);
    if (count < 0 or first < 0) return g.recordError(.invalid_value);
    if (count == 0) return;

    const attribs = resolveAttribs(g, @intCast(first), @intCast(count)) orelse return;
    issue(g, .{
        .prim = prim,
        .attribs = attribs,
        // The gather already skipped to `first`, and an in-place array had it folded
        // into its offset — so by here every attribute starts at element zero.
        .first = 0,
        .count = @intCast(count),
        .index = null,
    });
}

pub fn drawElements(g: *Context, mode: GLenum, count: GLsizei, type_token: GLenum, indices: ?*const anyopaque) void {
    const prim = mapPrim(mode) orelse return g.recordError(.invalid_enum);
    const it = mapIndexType(type_token) orelse return g.recordError(.invalid_enum);
    if (count < 0) return g.recordError(.invalid_value);
    if (count == 0) return;

    // An indexed draw may reach any vertex, so a staged array has to carry the whole
    // range the indices could name. The only way to know it is to read them.
    const hi = highestIndex(g, @intCast(count), it, indices) orelse return;
    const attribs = resolveAttribs(g, 0, hi + 1) orelse return;

    const n = @as(usize, @intCast(count)) * indexSize(it);
    const ib = g.element_array_buffer;

    if (ib != 0) {
        const h = g.buffers.deviceHandle(ib) orelse return g.recordError(.invalid_operation);
        issue(g, .{ .prim = prim, .attribs = attribs, .first = 0, .count = @intCast(count), .index = .{
            .buffer = h,
            .offset = @intCast(if (indices) |p| @intFromPtr(p) else 0),
            .type = it,
        } });
        return;
    }

    // Client-side indices: the GPU cannot read the application's memory, so they are
    // appended to the same frame staging stream as gathered arrays (and survive to the
    // end of the frame for the same reason — a device may defer the draw).
    const p = indices orelse return;
    const src = @as([*]const u8, @ptrCast(p))[0..n];
    const room = g.ensureStagingRoom(n) orelse return;
    g.dev.bufferUpdate(room.h, room.base, src) catch return g.recordError(.out_of_memory);
    g.staging_used = room.base + n;
    issue(g, .{ .prim = prim, .attribs = attribs, .first = 0, .count = @intCast(count), .index = .{
        .buffer = room.h,
        .offset = room.base,
        .type = it,
    } });
}

/// The largest index a draw will use, so the staged arrays know how far to reach. Null
/// when the indices cannot be read at all.
pub fn highestIndex(g: *Context, count: u32, it: idraw.IndexType, indices: ?*const anyopaque) ?u32 {
    const n: usize = count;
    const src: []const u8 = if (g.element_array_buffer != 0) blk: {
        const rec = g.buffers.record(g.element_array_buffer) orelse return null;
        const off: usize = if (indices) |p| @intFromPtr(p) else 0;
        if (off + n * indexSize(it) > rec.shadow.len) return null;
        break :blk rec.shadow[off..];
    } else blk: {
        const p = indices orelse return null;
        break :blk @as([*]const u8, @ptrCast(p))[0 .. n * indexSize(it)];
    };

    var hi: u32 = 0;
    for (0..n) |i| {
        const v: u32 = switch (it) {
            .u8 => src[i],
            .u16 => std.mem.readInt(u16, src[i * 2 ..][0..2], .little),
            .u32 => std.mem.readInt(u32, src[i * 4 ..][0..4], .little),
        };
        if (v > hi) hi = v;
    }
    return hi;
}
