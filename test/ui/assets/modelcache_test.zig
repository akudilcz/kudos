//! modelcache: the model viewer's WHOLE load chain — vfs.read → glb.parse →
//! png.decode → GL buffers and a texture — run on the host against the REAL seed assets,
//! through the real `gles` API, into DrawSim, with a fake /ramdisk mount.
//!
//! The kernel adds only the stack this runs on, so every logic bug in the chain is
//! catchable HERE and not on hardware. And it is the chain, not the parts: this is the
//! only test that puts a real 456 KB teapot through a real glTF parser into real GL
//! calls and asks what the device received.

const std = @import("std");
const modelcache = @import("modelcache");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const gles = @import("gles");
const idraw = @import("idraw");
const sim_mod = @import("draw_sim");

const ta = std.testing.allocator;

const TEAPOT = @embedFile("teapot_glb");
const DUCK = @embedFile("duck_glb");

/// The synthetic PBR-mapped model (APP-011), built at runtime by its test and
/// served by FakeFs as pbr.glb while set.
var pbr_glb: []const u8 = "";

// A fake /ramdisk mount serving the two real models + junk files.
const FakeFs = struct {
    fn read(_: *anyopaque, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "teapot.glb")) return TEAPOT;
        if (std.mem.eql(u8, path, "duck.glb")) return DUCK;
        if (std.mem.eql(u8, path, "pbr.glb") and pbr_glb.len > 0) return pbr_glb;
        if (std.mem.eql(u8, path, "broken.glb")) return "not a glb at all";
        if (std.mem.eql(u8, path, "notes.txt")) return "hello";
        return null;
    }
    fn list(_: *anyopaque, _: []const u8, _: ifilesys.ListFn, _: ?*anyopaque) ifilesys.Error!void {
        return ifilesys.Error.NotFound; // unused here
    }
    fn kind(c: *anyopaque, path: []const u8) ?ifilesys.Kind {
        if (path.len == 0) return .dir;
        return if (read(c, path) != null) .file else null;
    }
    // Read-only: the asset pipeline never writes through the VFS.
    const vtable = ifilesys.IFileSys.VTable{
        .read = read,
        .list = list,
        .kind = kind,
        .write = ifilesys.read_only.write,
        .remove = ifilesys.read_only.remove,
        .mkdir = ifilesys.read_only.mkdir,
        .rmdir = ifilesys.read_only.rmdir,
    };
    var ctx: u8 = 0;
    fn iface() ifilesys.IFileSys {
        return .{ .ctx = &ctx, .vtable = &vtable };
    }
};

/// Mount the fake /ramdisk, publish the device, and take a real GL context over it —
/// the same path the app takes.
fn setup(sim: *sim_mod.DrawSim) gles.Context {
    vfs.unmountAllForTest();
    vfs.mount("ramdisk", FakeFs.iface());
    idraw.device = sim.iface();
    var g = gles.createContext(ta, .{ .win_base = 0x1000, .stride_px = 640, .off_x = 0, .off_y = 0 }).?;
    gles.beginFrame(&g, 64, 64);
    return g;
}

fn teardown(g: *gles.Context) void {
    g.deinit();
    idraw.device = null;
}

// APP-007: a 3D model file is loaded from the file system and shown — vfs.read
// through glb.parse into real GL buffers; APP-009: its texture becomes a bound
// texture on the draw.
test "teapot.glb: the whole chain, into real GL buffers" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const m = try modelcache.load(ta, &g, "/ramdisk/teapot.glb");
    // A vertex buffer and an index buffer, both real device objects.
    try std.testing.expect(m.vbo != 0 and m.ibo != 0);
    try std.testing.expect(m.vbo != m.ibo);
    try std.testing.expectEqual(@as(u32, 2), sim.buffers_created);
    // The teapot has no texture and a white base colour, so it uploads none.
    try std.testing.expectEqual(@as(u32, 0), sim.textures_created);
    // The teapot is one untextured submesh (no texture object).
    try std.testing.expectEqual(@as(usize, 1), m.sub_count);
    try std.testing.expectEqual(@as(gles.GLuint, 0), m.subs[0].tex);
    // 47112 indices, per the file itself.
    try std.testing.expectEqual(@as(gles.GLsizei, 47112), m.subs[0].count);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}

test "duck.glb: the textured chain — PNG decoded and uploaded as a real texture" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const m = try modelcache.load(ta, &g, "/ramdisk/duck.glb");
    try std.testing.expect(m.subs[0].tex != 0);
    try std.testing.expectEqual(@as(u32, 1), sim.textures_created); // the 512x512 PNG
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));
}

test "a loaded model draws: the arrays reach the device from VRAM, not the CPU" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const m = try modelcache.load(ta, &g, "/ramdisk/duck.glb");
    m.draw(&g);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));

    const cs: *sim_mod.CtxSim = @ptrCast(@alignCast(g.target.ctx));
    const d = cs.last_draw.?;
    try std.testing.expect(d.prim == .triangles);
    try std.testing.expect(d.index != null);
    // 32-bit indices: gles advertises OES_element_index_uint (RND-004), so glb's u32
    // indices upload and draw as-is — no narrowing, and models past 65,536 verts render.
    try std.testing.expect(d.index.?.type == .u32);

    // Every array is drawn IN PLACE out of the model's own buffer — nothing was staged
    // through the CPU, which is the whole point of uploading it once.
    for ([_]idraw.AttribSlot{ .position, .normal, .texcoord0 }) |slot| {
        const a = d.attribs[@intFromEnum(slot)];
        try std.testing.expect(a == .array);
        try std.testing.expectEqual(g.buffers.deviceHandle(m.vbo).?, a.array.buffer);
        try std.testing.expectEqual(@as(u32, 32), a.array.stride); // the interleaved layout
    }
    try std.testing.expect(g.staging_buf == null); // nothing gathered, nothing copied

    // And the texture is bound on unit 0.
    try std.testing.expectEqual(@as(u2, 1), cs.last_pipeline.?.key.units);
}

test "the interleaved attributes land at the offsets glb wrote them to" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const m = try modelcache.load(ta, &g, "/ramdisk/teapot.glb");
    m.draw(&g);
    const cs: *sim_mod.CtxSim = @ptrCast(@alignCast(g.target.ctx));
    const d = cs.last_draw.?;
    // pos at 0, uv at 12, normal at 20 — the layout glb.zig produces. A disagreement
    // here renders a model with its normals as positions, which is spectacular.
    try std.testing.expectEqual(@as(u32, 0), d.attribs[@intFromEnum(idraw.AttribSlot.position)].array.offset);
    try std.testing.expectEqual(@as(u32, 12), d.attribs[@intFromEnum(idraw.AttribSlot.texcoord0)].array.offset);
    try std.testing.expectEqual(@as(u32, 20), d.attribs[@intFromEnum(idraw.AttribSlot.normal)].array.offset);
    try std.testing.expect(d.attribs[@intFromEnum(idraw.AttribSlot.position)].array.format == .f32x3);
    try std.testing.expect(d.attribs[@intFromEnum(idraw.AttribSlot.texcoord0)].array.format == .f32x2);
}

test "bad, missing and unsupported files fail loudly and upload nothing" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    try std.testing.expectError(modelcache.Error.ModelMissing, modelcache.load(ta, &g, "/ramdisk/broken.glb"));
    try std.testing.expectError(modelcache.Error.ModelMissing, modelcache.load(ta, &g, "/ramdisk/missing.glb"));
    try std.testing.expectError(modelcache.Error.ModelUnknownExtension, modelcache.load(ta, &g, "/ramdisk/notes.txt"));
    try std.testing.expectError(modelcache.Error.ModelUnknownExtension, modelcache.load(ta, &g, ""));
    try std.testing.expectEqual(@as(u32, 0), sim.textures_created);
}

test "a model's objects are freed with it" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const m = try modelcache.load(ta, &g, "/ramdisk/duck.glb");
    m.deinit(&g);
    try std.testing.expectEqual(@as(u32, 2), sim.buffers_destroyed);
    try std.testing.expectEqual(@as(u32, 1), sim.textures_destroyed);
    // The names are gone, so nothing can draw from them by accident.
    try std.testing.expectEqual(@as(gles.GLboolean, gles.GL_FALSE), gles.isBuffer(&g, m.vbo));
}

test "supportedName gates extensions" {
    try std.testing.expect(modelcache.supportedName("x.glb"));
    try std.testing.expect(!modelcache.supportedName("x.kmod"));
    try std.testing.expect(!modelcache.supportedName("x.txt"));
}

// ── the PBR material maps (GL_KUDOS_material_maps, spec APP-011) ─────────────

/// Append one PNG chunk: length, type, data, CRC over type+data.
fn pngChunk(out: *std.array_list.Managed(u8), typ: *const [4]u8, data: []const u8) !void {
    var lenb: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenb, @intCast(data.len), .big);
    try out.appendSlice(&lenb);
    try out.appendSlice(typ);
    try out.appendSlice(data);
    var crc = std.hash.Crc32.init();
    crc.update(typ);
    crc.update(data);
    var crcb: [4]u8 = undefined;
    std.mem.writeInt(u32, &crcb, crc.final(), .big);
    try out.appendSlice(&crcb);
}

/// A minimal valid 1×1 RGBA8 PNG — IHDR + one stored-deflate IDAT + IEND,
/// exactly 73 bytes (the synthetic glb's bufferView offsets rely on that).
fn png1x1(a: std.mem.Allocator, rgba: [4]u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });
    // 1×1, 8-bit, colour type 6 (RGBA), no interlace.
    const ihdr = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0 };
    try pngChunk(&out, "IHDR", &ihdr);
    // zlib with one stored block: filter byte 0 + the RGBA texel.
    const raw = [_]u8{ 0, rgba[0], rgba[1], rgba[2], rgba[3] };
    var idat = [_]u8{ 0x78, 0x01, 0x01, 5, 0, 250, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    @memcpy(idat[7..12], raw[0..]);
    std.mem.writeInt(u32, idat[12..16], std.hash.Adler32.hash(raw[0..]), .big);
    try pngChunk(&out, "IDAT", &idat);
    try pngChunk(&out, "IEND", &.{});
    return out.toOwnedSlice();
}

/// Wrap JSON + BIN chunks in a .glb container.
fn mkGlb(a: std.mem.Allocator, json: []const u8, bin: []const u8) ![]u8 {
    const jpad = (4 - json.len % 4) % 4;
    const bpad = (4 - bin.len % 4) % 4;
    var out = std.array_list.Managed(u8).init(a);
    errdefer out.deinit();
    const w32 = struct {
        fn f(o: *std.array_list.Managed(u8), v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(&b);
        }
    }.f;
    try w32(&out, 0x46546C67); // "glTF"
    try w32(&out, 2);
    try w32(&out, @intCast(12 + 8 + json.len + jpad + 8 + bin.len + bpad));
    try w32(&out, @intCast(json.len + jpad));
    try w32(&out, 0x4E4F534A); // "JSON"
    try out.appendSlice(json);
    try out.appendNTimes(' ', jpad);
    try w32(&out, @intCast(bin.len + bpad));
    try w32(&out, 0x004E4942); // "BIN\0"
    try out.appendSlice(bin);
    try out.appendNTimes(0, bpad);
    return out.toOwnedSlice();
}

// One triangle, one material carrying the base texture plus all four PBR maps,
// each image a 73-byte 1×1 PNG at a fixed bufferView offset.
const PBR_GLB_JSON =
    \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
    \\ "bufferViews":[
    \\  {"buffer":0,"byteOffset":0,"byteLength":36},
    \\  {"buffer":0,"byteOffset":36,"byteLength":73},
    \\  {"buffer":0,"byteOffset":109,"byteLength":73},
    \\  {"buffer":0,"byteOffset":182,"byteLength":73},
    \\  {"buffer":0,"byteOffset":255,"byteLength":73},
    \\  {"buffer":0,"byteOffset":328,"byteLength":73}],
    \\ "buffers":[{"byteLength":401}],
    \\ "materials":[{
    \\  "pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicRoughnessTexture":{"index":1}},
    \\  "normalTexture":{"index":2},"occlusionTexture":{"index":3},"emissiveTexture":{"index":4}}],
    \\ "textures":[{"source":0},{"source":1},{"source":2},{"source":3},{"source":4}],
    \\ "images":[
    \\  {"bufferView":1,"mimeType":"image/png"},
    \\  {"bufferView":2,"mimeType":"image/png"},
    \\  {"bufferView":3,"mimeType":"image/png"},
    \\  {"bufferView":4,"mimeType":"image/png"},
    \\  {"bufferView":5,"mimeType":"image/png"}]}
;

test "a PBR-mapped material materializes all four maps and binds them at draw (APP-011)" {
    var sim = sim_mod.DrawSim{};
    var g = setup(&sim);
    defer teardown(&g);

    const colors = [5][4]u8{
        .{ 255, 0, 0, 255 }, // base
        .{ 0, 200, 30, 255 }, // metal-rough
        .{ 128, 128, 255, 255 }, // normal
        .{ 255, 255, 255, 255 }, // occlusion
        .{ 20, 20, 20, 255 }, // emissive
    };
    var pngs: [5][]u8 = undefined;
    var made: usize = 0;
    defer for (pngs[0..made]) |p| ta.free(p);
    for (colors, 0..) |c, i| {
        pngs[i] = try png1x1(ta, c);
        made = i + 1;
        try std.testing.expectEqual(@as(usize, 73), pngs[i].len);
    }
    const pos = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };
    const bin = try std.mem.concat(ta, u8, &.{ std.mem.sliceAsBytes(pos[0..]), pngs[0], pngs[1], pngs[2], pngs[3], pngs[4] });
    defer ta.free(bin);
    const file = try mkGlb(ta, PBR_GLB_JSON, bin);
    defer ta.free(file);
    pbr_glb = file;
    defer pbr_glb = "";

    const m = try modelcache.load(ta, &g, "/ramdisk/pbr.glb");
    defer m.deinit(&g);
    // Base + four maps, each decoded and uploaded as its own texture object.
    try std.testing.expectEqual(@as(u32, 5), sim.textures_created);
    for (m.subs[0].maps) |h| try std.testing.expect(h != 0);

    // The draw hands every map to the device through the extension slots.
    m.draw(&g);
    const cs: *sim_mod.CtxSim = @ptrCast(@alignCast(g.target.ctx));
    for (cs.last_pipeline.?.mat_maps) |mm| try std.testing.expect(mm != null);
    try std.testing.expectEqual(@as(gles.GLenum, gles.GL_NO_ERROR), gles.getError(&g));

    // A maps-less model drawn after leaves no sticky material behind.
    const t = try modelcache.load(ta, &g, "/ramdisk/teapot.glb");
    defer t.deinit(&g);
    t.draw(&g);
    for (cs.last_pipeline.?.mat_maps) |mm| try std.testing.expect(mm == null);
}

test "bakeMetalRough scales the metallic (B) and roughness (G) channels only" {
    var px = [_]u8{ 255, 200, 7, 9 };
    modelcache.bakeMetalRough(px[0..], 0.5, 0.5);
    try std.testing.expectEqual([4]u8{ 128, 100, 7, 9 }, px);
}

test "bakeEmissive scales RGB by the emissiveFactor and leaves alpha" {
    var px = [_]u8{ 255, 255, 255, 77 }; // BGRA white
    modelcache.bakeEmissive(px[0..], .{ 1.0, 0.5, 0.0 });
    try std.testing.expectEqual([4]u8{ 0, 128, 255, 77 }, px);
}

test "neutralTexel: factors for metal-rough/emissive, identity for normal/occlusion" {
    const sm = modelcache.glb.Submesh{
        .index_offset = 0,
        .index_count = 0,
        .tex = null,
        .tex_mime = .png,
        .base_color = 0xFFFF_FFFF,
        .blend = false,
        .metallic = 0.25,
        .roughness = 0.75,
        .emissive = .{ 1.0, 0.5, 0.0 },
        .metallic_roughness_map = null,
        .normal_map = null,
        .occlusion_map = null,
        .emissive_map = null,
    };
    try std.testing.expectEqual([4]u8{ 64, 191, 255, 255 }, modelcache.neutralTexel(sm, 0));
    try std.testing.expectEqual([4]u8{ 255, 128, 128, 255 }, modelcache.neutralTexel(sm, 1));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, modelcache.neutralTexel(sm, 2));
    try std.testing.expectEqual([4]u8{ 0, 128, 255, 255 }, modelcache.neutralTexel(sm, 3));
}

test "bakeBaseColor multiplies all four channels; white is the identity" {
    var px = [_]u8{ 200, 100, 50, 255, 255, 255, 255, 128 };
    // 0xAARRGGBB: A=255, R=255, G=128, B=0 — B zeroes, G halves, R and A pass.
    modelcache.bakeBaseColor(px[0..], 0xFFFF_8000);
    try std.testing.expectEqual(@as(u8, 0), px[0]); // B x 0
    try std.testing.expectEqual(@as(u8, 50), px[1]); // G x 128/255
    try std.testing.expectEqual(@as(u8, 50), px[2]); // R x 1
    try std.testing.expectEqual(@as(u8, 255), px[3]); // A x 1
    try std.testing.expectEqual(@as(u8, 128), px[7]); // texel 2 alpha x factor A=1
    // White factor: untouched.
    var same = [_]u8{ 1, 2, 3, 4 };
    modelcache.bakeBaseColor(same[0..], 0xFFFF_FFFF);
    try std.testing.expectEqual([_]u8{ 1, 2, 3, 4 }, same);
}
