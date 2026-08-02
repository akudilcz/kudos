//! Pre-built SM89 shader blobs: upload + lookup. The blobs are produced
//! offline by scripts/shaders/build.sh and embedded via shaders/manifest.zig
//! (generated). Upload image layout: 128-B SPHv4 at a 0x80-aligned VA, code
//! right after; SET_PIPELINE_PROGRAM_ADDRESS points at the SPH.

const std = @import("std");
const log = @import("../../gpu/base/log.zig").gpu;
const gsp = @import("../../gpu/gsp/gsp.zig");
const vram = @import("../../gpu/core/vram.zig");
const gmmu = @import("../../gpu/core/gmmu.zig");
pub const manifest = @import("../shaders/manifest.zig");

pub const Error = error{ShaderUploadTooBig} || gmmu.Error || error{VramOutOfMemory};

/// Compile-time index of a shader by name — @compileError on a typo.
pub fn index(comptime name: []const u8) usize {
    inline for (manifest.shaders, 0..) |s, i| {
        if (comptime std.mem.eql(u8, s.name, name)) return i;
    }
    @compileError("unknown shader: " ++ name);
}

/// All blobs uploaded to VRAM, mapped at VA_GR_SHADERS. sph_va[i] is what
/// SET_PIPELINE_PROGRAM_ADDRESS gets for manifest.shaders[i].
pub const Uploaded = struct {
    sph_va: [manifest.shaders.len]u64,

    pub fn va(self: *const Uploaded, comptime name: []const u8) u64 {
        return self.sph_va[index(name)];
    }
    pub fn gprs(comptime name: []const u8) u32 {
        return manifest.shaders[index(name)].num_gprs;
    }

    /// The SPH VA and register count for a shader named at RUNTIME — the form the
    /// draw path needs, because the variant it draws with is computed from a
    /// `ShaderKey` (ada/variant.zig) and is not known when this file is compiled.
    /// Null when no blob has that name, which a caller must treat as a draw it
    /// cannot serve rather than an address it may emit: `variant.zig`'s host test
    /// proves every reachable key resolves to a present blob, so a miss here means
    /// the key was out of range, and emitting a stale VA would render garbage.
    pub fn find(self: *const Uploaded, name: []const u8) ?struct { va: u64, gprs: u32 } {
        for (manifest.shaders, 0..) |s, i| {
            if (std.mem.eql(u8, s.name, name)) return .{ .va = self.sph_va[i], .gprs = s.num_gprs };
        }
        return null;
    }
};

/// PRAMIN-write every shader image into one VRAM allocation and map it.
/// Layout: per shader, align cursor to 0x80, then SPH(128) + code.
pub fn upload(g: gsp.Gsp, valloc: *vram.Allocator, mmu: *gmmu.Gmmu) Error!Uploaded {
    var total: u64 = 0;
    for (manifest.shaders) |s| {
        total = std.mem.alignForward(u64, total, 0x80);
        total += s.sph.len + s.code.len;
    }
    const bytes = std.mem.alignForward(u64, total, 0x1000);
    if (bytes > 0x100000) return error.ShaderUploadTooBig; // VA window is 1 MiB
    const phys = try valloc.alloc(bytes, 0x1000);
    try mmu.mapVram(gmmu.VA_GR_SHADERS, phys, bytes);

    var up = Uploaded{ .sph_va = undefined };
    var cursor: u64 = 0;
    for (manifest.shaders, 0..) |s, i| {
        cursor = std.mem.alignForward(u64, cursor, 0x80);
        up.sph_va[i] = gmmu.VA_GR_SHADERS + cursor;
        vram.writeBytes(g.regs, phys + cursor, s.sph);
        vram.writeBytes(g.regs, phys + cursor + s.sph.len, s.code);
        cursor += s.sph.len + s.code.len;
        log("gl.shaders: {s} @va 0x{x} ({} B code, {} gprs)\n", .{ s.name, up.sph_va[i], s.code.len, s.num_gprs });
    }
    return up;
}
