//! Texture objects and their images.
//!
//! Texture names behave like buffer names (see objects.zig): generated, then made real
//! by binding. The images are the interesting part.
//!
//! **The standard's external formats are wider than any sampler's.** An application may
//! hand over RGB565, RGBA4444, RGBA5551, luminance, alpha, or — via the mandatory
//! OES_compressed_paletted_texture — an index plus a palette. The silicon samples none
//! of those directly. So every upload is expanded on the CPU into one of the handful of
//! formats `idraw.TexFormat` names, and the sampler only ever sees those.
//!
//! **Format and internalformat must MATCH.** Desktop GL converts between them; ES 1.1
//! removed that, and requires them to be identical. It is a GL_INVALID_OPERATION
//! otherwise — a rule that catches a real class of porting bug.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §3.7; the glTexImage2D and
//! glCompressedTexImage2D reference pages.

const std = @import("std");
const idraw = @import("idraw");
pub const enums = @import("enums.zig");
const limits = @import("limits.zig");
const state = @import("state.zig");
const unpack = @import("unpack.zig");

pub const GLenum = enums.GLenum;
const GLint = enums.GLint;
const GLuint = enums.GLuint;
const GLsizei = enums.GLsizei;
const GLboolean = enums.GLboolean;
const Context = state.Context;

fn target2dOk(g: *Context, target: GLenum) bool {
    if (target != enums.GL_TEXTURE_2D) {
        g.recordError(.invalid_enum);
        return false;
    }
    return true;
}

pub fn genTextures(g: *Context, n: GLsizei, textures: [*]GLuint) void {
    if (n < 0) return g.recordError(.invalid_value);
    g.textures.gen(@intCast(n), textures) catch g.recordError(.out_of_memory);
}

pub fn deleteTextures(g: *Context, n: GLsizei, textures: [*]const GLuint) void {
    if (n < 0) return g.recordError(.invalid_value);
    for (textures[0..@intCast(n)]) |name| {
        if (name == 0) continue;
        // A deleted texture must be unbound from every unit that holds it — the
        // standard says the binding reverts to the default texture, zero.
        for (&g.texture_binding) |*b| {
            if (b.* == name) b.* = 0;
        }
        if (g.textures.deviceHandle(name)) |h| g.dev.textureDestroy(h);
        g.textures.delete(name);
    }
}

pub fn bindTexture(g: *Context, target: GLenum, texture: GLuint) void {
    if (!target2dOk(g, target)) return;
    if (texture != 0) g.textures.ensureNamed(texture) catch return g.recordError(.out_of_memory);
    g.texture_binding[g.active_texture] = texture;
}

pub fn isTexture(g: *Context, texture: GLuint) GLboolean {
    return if (g.textures.isObject(texture)) enums.GL_TRUE else enums.GL_FALSE;
}

pub const externalPixelSize = unpack.sourcePixelSize;
pub const storedFormat = unpack.storedFormat;

pub fn texImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    internalformat: GLint,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
    format: GLenum,
    type_token: GLenum,
    pixels: ?*const anyopaque,
) void {
    if (!target2dOk(g, target)) return;
    if (level < 0 or level >= limits.MAX_MIP_LEVELS) return g.recordError(.invalid_value);
    if (width < 0 or height < 0) return g.recordError(.invalid_value);
    if (border != 0) return g.recordError(.invalid_value); // ES has no texture borders
    if (width > g.dev_limits.max_texture_size or height > g.dev_limits.max_texture_size)
        return g.recordError(.invalid_value);
    if (externalPixelSize(format, type_token) == null) return g.recordError(.invalid_enum);
    // ES 1.1 removed desktop GL's format conversion: these must be the same token.
    if (@as(GLenum, @intCast(internalformat)) != format) return g.recordError(.invalid_operation);
    if (storedFormat(format) == null) return g.recordError(.invalid_enum);
    const name = g.texture_binding[g.active_texture];
    if (name == 0) return g.recordError(.invalid_operation);
    if (level != 0) return; // mip levels beyond the base land with GENERATE_MIPMAP

    const sf = storedFormat(format).?;
    const n = unpack.expandedSize(@intCast(width), @intCast(height), format).?;
    const buf = g.alloc.alloc(u8, n) catch return g.recordError(.out_of_memory);
    defer g.alloc.free(buf);

    if (pixels) |p| {
        const px = unpack.sourcePixelSize(format, type_token).?;
        const src_len = unpack.sourceRowStride(@intCast(width), px, g.unpack_alignment) * @as(usize, @intCast(height));
        const src = @as([*]const u8, @ptrCast(p))[0..src_len];
        unpack.expand(buf, src, @intCast(width), @intCast(height), format, type_token, g.unpack_alignment) catch
            return g.recordError(.invalid_operation);
    } else {
        // A null pointer means "make the storage, leave the pixels undefined". Zero is
        // a defensible undefined: a texture of garbage VRAM would be worse.
        @memset(buf, 0);
    }

    // glTexImage2D REPLACES the image, so any previous storage goes first.
    if (g.textures.deviceHandle(name)) |old| g.dev.textureDestroy(old);
    const h = g.dev.textureCreate(.{
        .format = sf,
        .levels = &.{.{ .w = @intCast(width), .h = @intCast(height), .pixels = buf }},
    }) catch return g.recordError(.out_of_memory);
    g.textures.setDeviceHandle(name, h, n, .static);
}

pub fn texSubImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    xoffset: GLint,
    yoffset: GLint,
    width: GLsizei,
    height: GLsizei,
    format: GLenum,
    type_token: GLenum,
    pixels: ?*const anyopaque,
) void {
    if (!target2dOk(g, target)) return;
    if (level < 0 or level >= limits.MAX_MIP_LEVELS) return g.recordError(.invalid_value);
    if (width < 0 or height < 0 or xoffset < 0 or yoffset < 0) return g.recordError(.invalid_value);
    if (externalPixelSize(format, type_token) == null) return g.recordError(.invalid_enum);
    const name = g.texture_binding[g.active_texture];
    if (name == 0) return g.recordError(.invalid_operation);
    const h = g.textures.deviceHandle(name) orelse return g.recordError(.invalid_operation);

    const n = unpack.expandedSize(@intCast(width), @intCast(height), format).?;
    const buf = g.alloc.alloc(u8, n) catch return g.recordError(.out_of_memory);
    defer g.alloc.free(buf);
    const p = pixels orelse return;
    const px = unpack.sourcePixelSize(format, type_token).?;
    const src_len = unpack.sourceRowStride(@intCast(width), px, g.unpack_alignment) * @as(usize, @intCast(height));
    unpack.expand(buf, @as([*]const u8, @ptrCast(p))[0..src_len], @intCast(width), @intCast(height), format, type_token, g.unpack_alignment) catch
        return g.recordError(.invalid_operation);

    g.dev.textureUpdate(h, @intCast(level), .{
        .x = xoffset,
        .y = yoffset,
        .w = @intCast(width),
        .h = @intCast(height),
    }, buf) catch return g.recordError(.invalid_value);
}

pub fn compressedTexImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    internalformat: GLenum,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
    imageSize: GLsizei,
    data: ?*const anyopaque,
) void {
    if (!target2dOk(g, target)) return;
    if (level < 0 or width < 0 or height < 0 or imageSize < 0) return g.recordError(.invalid_value);
    if (border != 0) return g.recordError(.invalid_value);
    const p = unpack.paletted(internalformat) orelse return g.recordError(.invalid_enum);
    const name = g.texture_binding[g.active_texture];
    if (name == 0) return g.recordError(.invalid_operation);

    // A paletted blob carries the palette AND every mip level at once, so `level` here
    // is negative-or-zero by convention: the standard says a single call supplies
    // |level|+1 levels. We take the base and let GENERATE_MIPMAP handle the rest.
    if (level != 0) return;

    const want = unpack.palettedSize(p, @intCast(width), @intCast(height), 1) orelse
        return g.recordError(.invalid_enum);
    if (@as(usize, @intCast(imageSize)) < want) return g.recordError(.invalid_value);
    const src = @as([*]const u8, @ptrCast(data orelse return g.recordError(.invalid_value)))[0..@intCast(imageSize)];

    const sf = storedFormat(p.entry_format).?;
    const n = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * unpack.bytesPerStoredPixel(sf);
    const buf = g.alloc.alloc(u8, n) catch return g.recordError(.out_of_memory);
    defer g.alloc.free(buf);
    unpack.expandPaletted(buf, src, p, @intCast(width), @intCast(height), 0, @intCast(width), @intCast(height)) catch
        return g.recordError(.invalid_value);

    if (g.textures.deviceHandle(name)) |old| g.dev.textureDestroy(old);
    const h = g.dev.textureCreate(.{
        .format = sf,
        .levels = &.{.{ .w = @intCast(width), .h = @intCast(height), .pixels = buf }},
    }) catch return g.recordError(.out_of_memory);
    g.textures.setDeviceHandle(name, h, n, .static);
}

pub fn compressedTexSubImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    xoffset: GLint,
    yoffset: GLint,
    width: GLsizei,
    height: GLsizei,
    format: GLenum,
    imageSize: GLsizei,
    data: ?*const anyopaque,
) void {
    _ = level;
    _ = xoffset;
    _ = yoffset;
    _ = width;
    _ = height;
    _ = imageSize;
    _ = data;
    if (!target2dOk(g, target)) return;
    // The standard allows no sub-image update of a paletted texture at all: the palette
    // is shared by the whole image, so a partial update is not expressible.
    if (isPalettedFormat(format)) return g.recordError(.invalid_operation);
    g.recordError(.invalid_enum);
}

/// The ten formats OES_compressed_paletted_texture defines — 4- and 8-bit indices into
/// a palette of each of the five external formats.
pub fn isPalettedFormat(f: GLenum) bool {
    return unpack.paletted(f) != null;
}

pub fn copyTexImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    internalformat: GLenum,
    x: GLint,
    y: GLint,
    width: GLsizei,
    height: GLsizei,
    border: GLint,
) void {
    _ = x;
    _ = y;
    if (!target2dOk(g, target)) return;
    if (level < 0 or width < 0 or height < 0) return g.recordError(.invalid_value);
    if (border != 0) return g.recordError(.invalid_value);
    if (storedFormat(internalformat) == null) return g.recordError(.invalid_enum);
    // Needs the framebuffer-to-texture copy path (the copy engine); lands with readback.
}

pub fn copyTexSubImage2D(
    g: *Context,
    target: GLenum,
    level: GLint,
    xoffset: GLint,
    yoffset: GLint,
    x: GLint,
    y: GLint,
    width: GLsizei,
    height: GLsizei,
) void {
    _ = x;
    _ = y;
    if (!target2dOk(g, target)) return;
    if (level < 0 or width < 0 or height < 0 or xoffset < 0 or yoffset < 0)
        return g.recordError(.invalid_value);
}
