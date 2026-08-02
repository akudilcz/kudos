//! glbcheck — host-side model-corpus validator (`zig build glbcheck`).
//!
//! Runs every `.glb` under the given files/directories through the REAL kudos
//! loading stack — glb.parse (geometry: positions/normals/UVs interleaved into
//! the kGL 32-byte layout, index validation) and png.decode / jpeg.decode (the
//! base-color texture) — and prints one verdict row per model. This is the ground truth
//! for "which models on the USB stick can kudos load, with textures": the same
//! code paths the kernel runs, executed on the host against the mounted stick.
//!
//!   ./build/bin/glbcheck /run/media/andrew/KUDOSUSB/models /run/media/andrew/KUDOSUSB/scenes
//!
//! Verdict columns: bytes, vertex/index counts, texture (none / WxH decoded /
//! the decode error), and OK or the loud parse error name. Exit code 0 only if
//! every file parsed (texture failures count: a model whose texture cannot be
//! decoded renders untextured — report it, fail the run).

// Imported relatively (like modelcache.zig) rather than as named modules: png
// and jpeg share ONE png.zig instance that way — jpeg.zig re-exports png.Image
// via a relative import, and Zig forbids a file being both a named module and a
// relative import in the same graph (CLAUDE.md: a file belongs to one module).
const std = @import("std");
const glb = @import("glb.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");

/// Decode one located image to prove it, then free it — glbcheck only needs the
/// yes/no. Shared by the base-colour and the PBR-map (APP-011) vetting.
fn vetImage(a: std.mem.Allocator, bytes: []const u8, mime: glb.TexMime) !void {
    const img = switch (mime) {
        .png => try png.decode(a, bytes),
        .jpeg => try jpeg.decode(a, bytes),
    };
    img.deinit(a);
}

fn checkOne(io: std.Io, a: std.mem.Allocator, path: []const u8, w: anytype) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch |e| {
        try w.print("{s}: READ FAILED ({s})\n", .{ path, @errorName(e) });
        return false;
    };
    defer a.free(bytes);

    const base = std.fs.path.basename(path);
    const out = glb.parse(a, bytes) catch |e| {
        try w.print("{s: <28} {d: >9}B  PARSE FAIL: {s}\n", .{ base, bytes.len, @errorName(e) });
        return false;
    };
    defer out.deinit(a);

    // Decode every distinct base-colour texture across the submeshes: a check
    // proves both the parse and the embedded images, and the first texture's
    // dimensions summarise the material for the report line.
    var tex_desc_buf: [64]u8 = undefined;
    var tex_ok = true;
    var tex_desc: []const u8 = "untextured";
    var textured_subs: usize = 0;
    for (out.submeshes) |sm| {
        const tex_bytes = sm.tex orelse continue;
        textured_subs += 1;
        const img = (switch (sm.tex_mime) {
            .png => png.decode(a, tex_bytes),
            .jpeg => jpeg.decode(a, tex_bytes),
        }) catch |e| {
            tex_ok = false;
            tex_desc = std.fmt.bufPrint(&tex_desc_buf, "TEX FAIL: {s}", .{@errorName(e)}) catch "TEX FAIL";
            break;
        };
        defer img.deinit(a);
        if (textured_subs == 1) {
            const kind = switch (sm.tex_mime) {
                .png => "png",
                .jpeg => "jpg",
            };
            tex_desc = std.fmt.bufPrint(&tex_desc_buf, "{s} {d}x{d}", .{ kind, img.w, img.h }) catch "tex ?x?";
        }
    }

    // Decode-vet every PBR map beyond base colour (spec APP-011): a malformed
    // metallic-roughness / normal / occlusion / emissive image fails the run too,
    // even though ES 1.1 fixed-function does not yet shade them.
    if (tex_ok) {
        outer: for (out.submeshes) |sm| {
            for ([_]?glb.LocatedTex{ sm.metallic_roughness_map, sm.normal_map, sm.occlusion_map, sm.emissive_map }) |m| {
                const map = m orelse continue;
                vetImage(a, map.bytes, map.mime) catch |e| {
                    tex_ok = false;
                    tex_desc = std.fmt.bufPrint(&tex_desc_buf, "MAP FAIL: {s}", .{@errorName(e)}) catch "MAP FAIL";
                    break :outer;
                };
            }
        }
    }

    try w.print("{s: <28} {d: >9}B  verts={d: <8} idx={d: <8} subs={d: <3} {s: <18} {s}\n", .{
        base,                         bytes.len,
        out.vert_count,               out.index_count,
        out.submeshes.len,            tex_desc,
        if (tex_ok) "OK" else "FAIL",
    });
    return tex_ok;
}

fn walkDir(io: std.Io, a: std.mem.Allocator, dir_path: []const u8, list: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(ent.name, ".glb")) continue;
        const full = try std.fs.path.join(a, &.{ dir_path, ent.name });
        try list.append(a, full);
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &out_w.interface;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        try stdout.print("usage: glbcheck <file.glb | dir> ...\n", .{});
        try stdout.flush();
        std.process.exit(2);
    }

    var files: std.ArrayList([]const u8) = .empty;
    for (argv[1..]) |arg_ptr| {
        const arg = std.mem.span(arg_ptr);
        const st = std.Io.Dir.cwd().statFile(io, arg, .{}) catch {
            try stdout.print("{s}: not found\n", .{arg});
            try stdout.flush();
            std.process.exit(2);
        };
        switch (st.kind) {
            .directory => try walkDir(io, a, arg, &files),
            else => try files.append(a, try a.dupe(u8, arg)),
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var pass: usize = 0;
    var fail: usize = 0;
    for (files.items) |path| {
        if (try checkOne(io, a, path, stdout)) pass += 1 else fail += 1;
    }
    try stdout.print("\nglbcheck: {d} OK, {d} FAIL of {d} models\n", .{ pass, fail, pass + fail });
    try stdout.flush();
    if (fail != 0) std.process.exit(1);
}
