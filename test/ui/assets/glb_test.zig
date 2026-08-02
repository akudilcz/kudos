//! GLB parser tests (src/ui/assets/glb.zig).
//!
//! Two layers of proof:
//! 1. REAL files — the checked-in Khronos sample assets (test/ui/assets/fixtures/):
//!    exact vert/index counts, normalization bounds, index validity, texture
//!    extraction. Box.glb and BoxInterleaved.glb carry the SAME cube through
//!    two different accessor layouts (separate blocks in one strided view
//!    vs. truly interleaved), so their parsed output must be byte-identical
//!    — the strongest single check on the element-addressing math.
//! 2. SYNTHETIC files — a GLB builder crafts minimal valid and malformed
//!    containers to hit every error class and every index/attribute variant
//!    the fixtures cannot isolate.

const std = @import("std");
const glb = @import("glb");

const ta = std.testing.allocator;

test {
    std.testing.refAllDecls(glb);
}

// ── synthetic GLB builder ────────────────────────────────────────────────

/// Assemble a spec-shaped GLB: header + padded JSON chunk (+ padded BIN).
fn mkGlb(json: []const u8, bin: ?[]const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(ta);
    errdefer out.deinit();
    const le = struct {
        fn int(o: *std.array_list.Managed(u8), v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(&b);
        }
    };
    const json_pad = (4 - json.len % 4) % 4;
    var total: u32 = @intCast(12 + 8 + json.len + json_pad);
    var bin_pad: usize = 0;
    if (bin) |data| {
        bin_pad = (4 - data.len % 4) % 4;
        total += @intCast(8 + data.len + bin_pad);
    }
    try le.int(&out, 0x46546C67);
    try le.int(&out, 2);
    try le.int(&out, total);
    try le.int(&out, @intCast(json.len + json_pad));
    try le.int(&out, 0x4E4F534A);
    try out.appendSlice(json);
    try out.appendNTimes(' ', json_pad);
    if (bin) |data| {
        try le.int(&out, @intCast(data.len + bin_pad));
        try le.int(&out, 0x004E4942);
        try out.appendSlice(data);
        try out.appendNTimes(0, bin_pad);
    }
    return out.toOwnedSlice();
}

fn floatsLe(vals: []const f32) ![]u8 {
    const out = try ta.alloc(u8, vals.len * 4);
    for (vals, 0..) |v, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], @bitCast(v), .little);
    return out;
}

/// Parse a synthetic GLB built from `json` + `bin`, freeing the container.
/// (Only safe when the test does not inspect `tex`, which borrows it.)
fn parseGlb(json: []const u8, bin: ?[]const u8) glb.Error!glb.Out {
    const file = mkGlb(json, bin) catch return error.OutOfMemory;
    defer ta.free(file);
    return glb.parse(ta, file);
}

/// f32 slot `field` (0..7: pos xyz, uv st, normal xyz) of vertex `vert`.
fn vf(out: glb.Out, vert: u32, field: u32) f32 {
    const at = @as(usize, vert) * 32 + @as(usize, field) * 4;
    return @bitCast(std.mem.readInt(u32, out.verts[at..][0..4], .little));
}

fn idxAt(out: glb.Out, i: u32) u32 {
    return std.mem.readInt(u32, out.indices[@as(usize, i) * 4 ..][0..4], .little);
}

// The reference triangle: (0,0,0) (1,0,0) (0,1,0). After the display-box
// normalization (center x/z, base y=-1, height 2 ⇒ scale 2) the positions
// are exactly (-1,-1,0) (1,-1,0) (-1,1,0); the generated smooth normal is
// +Z for all three corners.
const TRI_POS = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 1, 0 };

fn expectReferenceTriangle(out: glb.Out) !void {
    try std.testing.expectEqual(@as(u32, 3), out.vert_count);
    try std.testing.expectEqual(@as(u32, 3), out.index_count);
    try std.testing.expectEqual(@as(usize, 96), out.verts.len);
    const want_pos = [3][3]f32{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ -1, 1, 0 } };
    for (want_pos, 0..) |p, v| {
        for (p, 0..) |x, k|
            try std.testing.expectApproxEqAbs(x, vf(out, @intCast(v), @intCast(k)), 1e-6);
        try std.testing.expectEqual(@as(f32, 0), vf(out, @intCast(v), 3)); // uv default
        try std.testing.expectEqual(@as(f32, 0), vf(out, @intCast(v), 4));
        try std.testing.expectApproxEqAbs(@as(f32, 0), vf(out, @intCast(v), 5), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 0), vf(out, @intCast(v), 6), 1e-6);
        try std.testing.expectApproxEqAbs(@as(f32, 1), vf(out, @intCast(v), 7), 1e-6); // +Z
    }
    for (0..3) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), idxAt(out, @intCast(i)));
}

// ── container-level errors ───────────────────────────────────────────────

test "container: too short / bad version / bad length; non-glTF magic falls to JSON" {
    // A 'glTF'-magic file too short for the 12-byte header is a truncated GLB.
    try std.testing.expectError(glb.Error.GlbTruncated, glb.parse(ta, "glTF"));
    var hdr: [12]u8 = undefined;
    // Without the 'glTF' magic the input is treated as a JSON .gltf document;
    // this garbage is not valid JSON, so it fails at the JSON parse.
    std.mem.writeInt(u32, hdr[0..4], 0x46546C68, .little); // not 'glTF'
    std.mem.writeInt(u32, hdr[4..8], 2, .little);
    std.mem.writeInt(u32, hdr[8..12], 12, .little);
    try std.testing.expectError(glb.Error.GlbBadJson, glb.parse(ta, &hdr));
    std.mem.writeInt(u32, hdr[0..4], 0x46546C67, .little);
    std.mem.writeInt(u32, hdr[4..8], 1, .little); // glTF 1.0 container
    try std.testing.expectError(glb.Error.GlbBadVersion, glb.parse(ta, &hdr));
    std.mem.writeInt(u32, hdr[4..8], 2, .little);
    std.mem.writeInt(u32, hdr[8..12], 999, .little); // length != file size
    try std.testing.expectError(glb.Error.GlbBadLength, glb.parse(ta, &hdr));
}

test "container: truncated chunk / first chunk not JSON / missing BIN" {
    // Chunk header declares 100 bytes but the file ends.
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0x46546C67, .little);
    std.mem.writeInt(u32, buf[4..8], 2, .little);
    std.mem.writeInt(u32, buf[8..12], 20, .little);
    std.mem.writeInt(u32, buf[12..16], 100, .little);
    std.mem.writeInt(u32, buf[16..20], 0x4E4F534A, .little);
    try std.testing.expectError(glb.Error.GlbTruncated, glb.parse(ta, &buf));
    // First chunk typed BIN.
    std.mem.writeInt(u32, buf[12..16], 0, .little);
    std.mem.writeInt(u32, buf[16..20], 0x004E4942, .little);
    try std.testing.expectError(glb.Error.GlbNoJson, glb.parse(ta, &buf));
    // Valid JSON chunk, no BIN chunk at all.
    const file = try mkGlb("{\"meshes\":[]}", null);
    defer ta.free(file);
    try std.testing.expectError(glb.Error.GlbNoBin, glb.parse(ta, file));
}

test "JSON-level errors: malformed / no meshes / no POSITION / empty prims" {
    try std.testing.expectError(glb.Error.GlbBadJson, parseGlb("{not json", "x"));
    try std.testing.expectError(glb.Error.GlbNoMeshes, parseGlb("{}", "x"));
    try std.testing.expectError(glb.Error.GlbNoMeshes, parseGlb("{\"meshes\":[]}", "x"));
    try std.testing.expectError(glb.Error.GlbNoMeshes, parseGlb(
        \\{"meshes":[{"primitives":[]}]}
    , "x"));
    try std.testing.expectError(glb.Error.GlbNoMeshes, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{}}]}]}
    , "x"));
}

// ── the minimal valid triangle, in every index flavor ────────────────────

test "non-indexed triangle: counts, sequential indices, normalize, smooth normals, uv default" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try expectReferenceTriangle(out);
    try std.testing.expectEqual(@as(?[]const u8, null), out.submeshes[0].tex);
}

fn indexedTriangleJson(comptime component_type: u32, comptime byte_len: u32) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1}}]}}],
        \\ "accessors":[
        \\  {{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}},
        \\  {{"bufferView":1,"componentType":{d},"count":3,"type":"SCALAR"}}],
        \\ "bufferViews":[
        \\  {{"buffer":0,"byteOffset":0,"byteLength":36}},
        \\  {{"buffer":0,"byteOffset":36,"byteLength":{d}}}],
        \\ "buffers":[{{"byteLength":{d}}}]}}
    , .{ component_type, byte_len, 36 + byte_len });
}

test "indexed triangle: u8 / u16 / u32 index accessors parse identically" {
    const pos = try floatsLe(&TRI_POS);
    defer ta.free(pos);

    inline for (.{
        .{ 5121, [_]u8{ 0, 1, 2 } },
        .{ 5123, [_]u8{ 0, 0, 1, 0, 2, 0 } },
        .{ 5125, [_]u8{ 0, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0 } },
    }) |case| {
        const idx_bytes = case[1];
        const bin = try std.mem.concat(ta, u8, &.{ pos, &idx_bytes });
        defer ta.free(bin);
        const out = try parseGlb(indexedTriangleJson(case[0], idx_bytes.len), bin);
        defer out.deinit(ta);
        try expectReferenceTriangle(out);
    }
}

test "supplied normals and uvs pass through verbatim (no V flip, no rescale)" {
    // Normals deliberately NON-unit (0,0,2): supplied normals must not be
    // touched (no re-normalization), only generated ones are unit-length.
    const bin = try floatsLe(&(TRI_POS ++
        [9]f32{ 0, 0, 2, 0, 0, 2, 0, 0, 2 } ++ // NORMAL
        [6]f32{ 0.25, 0.75, 0.5, 0.75, 0.25, 0.1 })); // TEXCOORD_0
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1,"TEXCOORD_0":2}}]}],
        \\ "accessors":[
        \\  {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\  {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        \\  {"bufferView":2,"componentType":5126,"count":3,"type":"VEC2"}],
        \\ "bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":36},
        \\  {"buffer":0,"byteOffset":36,"byteLength":36},
        \\  {"buffer":0,"byteOffset":72,"byteLength":24}],
        \\ "buffers":[{"byteLength":96}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(f32, 0.25), vf(out, 0, 3));
    try std.testing.expectEqual(@as(f32, 0.75), vf(out, 0, 4));
    try std.testing.expectEqual(@as(f32, 0.5), vf(out, 1, 3));
    try std.testing.expectEqual(@as(f32, 0.1), vf(out, 2, 4));
    for (0..3) |v| {
        try std.testing.expectEqual(@as(f32, 0), vf(out, @intCast(v), 5));
        try std.testing.expectEqual(@as(f32, 0), vf(out, @intCast(v), 6));
        try std.testing.expectEqual(@as(f32, 2), vf(out, @intCast(v), 7));
    }
}

test "COLOR_0 (VEC4 float) is read into a straight RGBA8 vertex-colour array" {
    // 3 verts: positions (VEC3) then colours (VEC4). Values chosen so f32->u8 is
    // exact: 1.0->255, 0.0->0, 0.5->128 (rounded). VertexColorTest is VEC4 float.
    const bin = try floatsLe(&(TRI_POS ++ [12]f32{
        1, 0, 0, 1, // red, opaque
        0, 1, 0, 1, // green, opaque
        0, 0, 1, 0.5, // blue, half alpha
    }));
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0,"COLOR_0":1}}]}],
        \\ "accessors":[
        \\  {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\  {"bufferView":1,"componentType":5126,"count":3,"type":"VEC4"}],
        \\ "bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":36},
        \\  {"buffer":0,"byteOffset":36,"byteLength":48}],
        \\ "buffers":[{"byteLength":84}]}
    , bin);
    defer out.deinit(ta);
    const c = out.colors orelse return error.NoColors;
    try std.testing.expectEqual(@as(usize, 12), c.len); // 3 verts * RGBA8
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, c[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, c[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 128 }, c[8..12]);
}

test "a model without COLOR_0 has no vertex-colour array (null, byte-identical vertex buffer)" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(?[]u8, null), out.colors);
}

test "multi-primitive merge: vertices appended, indices rebased" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[
        \\  {"primitives":[{"attributes":{"POSITION":0}}]},
        \\  {"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 6), out.vert_count);
    try std.testing.expectEqual(@as(u32, 6), out.index_count);
    for (0..6) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), idxAt(out, @intCast(i)));
    // Same source triangle ⇒ the two halves are identical after normalize.
    for (0..3) |v| for (0..8) |f| {
        try std.testing.expectEqual(vf(out, @intCast(v), @intCast(f)), vf(out, @intCast(v + 3), @intCast(f)));
    };
}

// ── accessor/bufferView validation errors ────────────────────────────────

test "accessor errors: wrong componentType/type, too few verts, zero count" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // POSITION as u16 → the subset demands f32.
    try std.testing.expectError(glb.Error.GlbBadAccessor, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5123,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin));
    // POSITION as VEC2.
    try std.testing.expectError(glb.Error.GlbBadAccessor, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC2"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin));
    // 2 verts < a triangle.
    try std.testing.expectError(glb.Error.GlbTooFewVerts, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin));
    // Signed-i16 indices are outside the subset.
    try std.testing.expectError(glb.Error.GlbBadAccessor, parseGlb(indexedTriangleJson(5122, 6), bin));
    // Accessor index out of range.
    try std.testing.expectError(glb.Error.GlbBadAccessor, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":7}}]}],
        \\ "accessors":[],"bufferViews":[],"buffers":[{"byteLength":36}]}
    , bin));
}

test "bufferView errors: view escapes BIN, accessor escapes view, wrong buffer, mode" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // View bigger than the BIN chunk.
    try std.testing.expectError(glb.Error.GlbBadBufferView, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":4000}],
        \\ "buffers":[{"byteLength":4000}]}
    , bin));
    // Accessor spans past its (valid) view: count 4 × 12 > 36.
    try std.testing.expectError(glb.Error.GlbBadBufferView, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin));
    // A second buffer: .glb geometry must live in buffer 0 (the BIN chunk).
    try std.testing.expectError(glb.Error.GlbBadBuffer, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":1,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36},{"byteLength":36,"uri":"x.bin"}]}
    , bin));
    // Non-triangle mode.
    try std.testing.expectError(glb.Error.GlbBadMode, parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"mode":1}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin));
}

test "an index referencing a vertex past its primitive is rejected" {
    const pos = try floatsLe(&TRI_POS);
    defer ta.free(pos);
    const bin = try std.mem.concat(ta, u8, &.{ pos, &[_]u8{ 0, 0, 1, 0, 3, 0 } }); // u16 idx 3 of 3 verts
    defer ta.free(bin);
    try std.testing.expectError(glb.Error.GlbBadIndex, parseGlb(indexedTriangleJson(5123, 6), bin));
}

// ── base-color texture walk ──────────────────────────────────────────────

const TEX_JSON_FMT =
    \\{{"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"material":0}}]}}],
    \\ "accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}}],
    \\ "bufferViews":[
    \\  {{"buffer":0,"byteOffset":0,"byteLength":36}},
    \\  {{"buffer":0,"byteOffset":36,"byteLength":4}}],
    \\ "buffers":[{{"byteLength":40}}],
    \\ "materials":[{{"pbrMetallicRoughness":{{"baseColorTexture":{{"index":0{s}}}}}}}],
    \\ "textures":[{{"source":0}}],
    \\ "images":[{{{s}}}]}}
;

fn texGlb(comptime bct_extra: []const u8, comptime image: []const u8) ![]u8 {
    const json = std.fmt.comptimePrint(TEX_JSON_FMT, .{ bct_extra, image });
    const pos = try floatsLe(&TRI_POS);
    defer ta.free(pos);
    const bin = try std.mem.concat(ta, u8, &.{ pos, "PNG!" });
    defer ta.free(bin);
    return mkGlb(json, bin);
}

test "embedded PNG base-color texture is located and sliced out of BIN" {
    const file = try texGlb("", "\"bufferView\":1,\"mimeType\":\"image/png\"");
    defer ta.free(file);
    const out = try glb.parse(ta, file);
    defer out.deinit(ta);
    try std.testing.expectEqualStrings("PNG!", out.submeshes[0].tex.?);
    try std.testing.expectEqual(glb.TexMime.png, out.submeshes[0].tex_mime);
}

test "embedded JPEG base-color texture is located with the jpeg mime" {
    const file = try texGlb("", "\"bufferView\":1,\"mimeType\":\"image/jpeg\"");
    defer ta.free(file);
    const out = try glb.parse(ta, file);
    defer out.deinit(ta);
    // JPEG is now decodable (jpeg.zig): located, not rejected. glb only slices
    // the bytes; the "PNG!" filler stands in for the embedded stream.
    try std.testing.expectEqualStrings("PNG!", out.submeshes[0].tex.?);
    try std.testing.expectEqual(glb.TexMime.jpeg, out.submeshes[0].tex_mime);
}

test "texture error taxonomy: alien mime, uri image, texCoord != 0" {
    inline for (.{
        .{ "", "\"bufferView\":1,\"mimeType\":\"image/bmp\"", glb.Error.GlbBadImageMime },
        .{ "", "\"uri\":\"duck.png\"", glb.Error.GlbBadImage },
        .{ ",\"texCoord\":1", "\"bufferView\":1,\"mimeType\":\"image/png\"", glb.Error.GlbBadImage },
    }) |case| {
        const file = try texGlb(case[0], case[1]);
        defer ta.free(file);
        try std.testing.expectError(case[2], glb.parse(ta, file));
    }
}

test "a material without baseColorTexture is untextured, not an error" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}],
        \\ "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(?[]const u8, null), out.submeshes[0].tex);
    // Red baseColorFactor [1,0,0,1] → packed BGRA 0xAARRGGBB = opaque red.
    // (1.0 gamma-encodes to 255, 0.0 to 0.)
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), out.submeshes[0].base_color);
}

test "baseColorFactor: absent material → opaque-white default (renders as before)" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), out.submeshes[0].base_color);
}

// ── the full glTF PBR map set (spec APP-011) ─────────────────────────────
// One material carrying all five maps, each pointing at its own bufferView with
// a distinct 4-byte marker so a mis-wired path shows as the wrong slice. The
// bytes stand in for real image streams — glb LOCATES, it does not decode.
const PBR_MAPS_JSON =
    \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
    \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
    \\ "bufferViews":[
    \\  {"buffer":0,"byteOffset":0,"byteLength":36},
    \\  {"buffer":0,"byteOffset":36,"byteLength":4},
    \\  {"buffer":0,"byteOffset":40,"byteLength":4},
    \\  {"buffer":0,"byteOffset":44,"byteLength":4},
    \\  {"buffer":0,"byteOffset":48,"byteLength":4},
    \\  {"buffer":0,"byteOffset":52,"byteLength":4}],
    \\ "buffers":[{"byteLength":56}],
    \\ "materials":[{
    \\  "pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicRoughnessTexture":{"index":1}},
    \\  "normalTexture":{"index":2},"occlusionTexture":{"index":3},"emissiveTexture":{"index":4}}],
    \\ "textures":[{"source":0},{"source":1},{"source":2},{"source":3},{"source":4}],
    \\ "images":[
    \\  {"bufferView":1,"mimeType":"image/png"},
    \\  {"bufferView":2,"mimeType":"image/jpeg"},
    \\  {"bufferView":3,"mimeType":"image/png"},
    \\  {"bufferView":4,"mimeType":"image/png"},
    \\  {"bufferView":5,"mimeType":"image/png"}]}
;

test "all glTF PBR maps are located: base-colour + metallic-roughness/normal/occlusion/emissive (APP-011)" {
    const pos = try floatsLe(&TRI_POS);
    defer ta.free(pos);
    const bin = try std.mem.concat(ta, u8, &.{ pos, "BASE", "MTRO", "NORM", "OCCL", "EMIS" });
    defer ta.free(bin);
    const file = try mkGlb(PBR_MAPS_JSON, bin);
    defer ta.free(file);
    const out = try glb.parse(ta, file);
    defer out.deinit(ta);
    const sm = out.submeshes[0];
    // Each map resolves to its own bufferView, so a swapped path is a wrong slice.
    try std.testing.expectEqualStrings("BASE", sm.tex.?);
    try std.testing.expectEqual(glb.TexMime.png, sm.tex_mime);
    try std.testing.expectEqualStrings("MTRO", sm.metallic_roughness_map.?.bytes);
    try std.testing.expectEqual(glb.TexMime.jpeg, sm.metallic_roughness_map.?.mime); // per-map codec
    try std.testing.expectEqualStrings("NORM", sm.normal_map.?.bytes);
    try std.testing.expectEqualStrings("OCCL", sm.occlusion_map.?.bytes);
    try std.testing.expectEqualStrings("EMIS", sm.emissive_map.?.bytes);
}

test "a base-colour-only material has no PBR maps (all four null)" {
    const file = try texGlb("", "\"bufferView\":1,\"mimeType\":\"image/png\"");
    defer ta.free(file);
    const out = try glb.parse(ta, file);
    defer out.deinit(ta);
    const sm = out.submeshes[0];
    try std.testing.expect(sm.metallic_roughness_map == null);
    try std.testing.expect(sm.normal_map == null);
    try std.testing.expect(sm.occlusion_map == null);
    try std.testing.expect(sm.emissive_map == null);
}

test "a PBR map obeys the same texture rules: normalTexture with texCoord != 0 is rejected" {
    // Proves the maps share base-colour's validation (locateTexImage): only
    // TEXCOORD_0 is sampled, whichever map references the texture.
    const pos = try floatsLe(&TRI_POS);
    defer ta.free(pos);
    const bin = try std.mem.concat(ta, u8, &.{ pos, "NORM" });
    defer ta.free(bin);
    const file = try mkGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":36},
        \\  {"buffer":0,"byteOffset":36,"byteLength":4}],
        \\ "buffers":[{"byteLength":40}],
        \\ "materials":[{"normalTexture":{"index":0,"texCoord":1}}],
        \\ "textures":[{"source":0}],
        \\ "images":[{"bufferView":1,"mimeType":"image/png"}]}
    , bin);
    defer ta.free(file);
    try std.testing.expectError(glb.Error.GlbBadImage, glb.parse(ta, file));
}

// ── real files: the Khronos fixtures ─────────────────────────────────────

fn expectNormalizedBounds(out: glb.Out) !void {
    var mn = [3]f32{ 1e30, 1e30, 1e30 };
    var mx = [3]f32{ -1e30, -1e30, -1e30 };
    var v: u32 = 0;
    while (v < out.vert_count) : (v += 1) {
        for (0..3) |k| {
            mn[k] = @min(mn[k], vf(out, v, @intCast(k)));
            mx[k] = @max(mx[k], vf(out, v, @intCast(k)));
        }
    }
    // Display-box rule: base at y=-1, top at y=+1, x/z centered on 0.
    try std.testing.expectApproxEqAbs(@as(f32, -1), mn[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), mx[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), mn[0] + mx[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), mn[2] + mx[2], 1e-4);
}

test "Box.glb: block-layout accessors — counts, bounds, red material has no texture" {
    const out = try glb.parse(ta, @embedFile("model_box"));
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 24), out.vert_count);
    try std.testing.expectEqual(@as(u32, 36), out.index_count);
    try std.testing.expectEqual(@as(?[]const u8, null), out.submeshes[0].tex);
    try expectNormalizedBounds(out);
    var i: u32 = 0;
    while (i < out.index_count) : (i += 1)
        try std.testing.expect(idxAt(out, i) < out.vert_count);
}

test "BoxInterleaved.glb parses byte-identically to Box.glb" {
    const a = try glb.parse(ta, @embedFile("model_box"));
    defer a.deinit(ta);
    const b = try glb.parse(ta, @embedFile("model_boxinterleaved"));
    defer b.deinit(ta);
    try std.testing.expectEqualSlices(u8, a.verts, b.verts);
    try std.testing.expectEqualSlices(u8, a.indices, b.indices);
}

test "Duck.glb: counts, bounds, valid indices, real UVs, embedded PNG" {
    const out = try glb.parse(ta, @embedFile("model_duck"));
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 2399), out.vert_count);
    try std.testing.expectEqual(@as(u32, 12636), out.index_count);
    try expectNormalizedBounds(out);
    var i: u32 = 0;
    while (i < out.index_count) : (i += 1)
        try std.testing.expect(idxAt(out, i) < out.vert_count);
    // The duck is textured: an embedded PNG (signature check) and at least
    // one non-zero UV.
    const png = out.submeshes[0].tex.?;
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, png[0..8]);
    var any_uv = false;
    var v: u32 = 0;
    while (v < out.vert_count) : (v += 1) {
        if (vf(out, v, 3) != 0 or vf(out, v, 4) != 0) any_uv = true;
    }
    try std.testing.expect(any_uv);
}

test "teapot.glb (the boot-window ramdisk seed) parses with the known geometry" {
    const out = try glb.parse(ta, @embedFile("teapot_glb")); // anonymous import (build.zig)
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 8334), out.vert_count);
    try std.testing.expectEqual(@as(u32, 47112), out.index_count);
    try std.testing.expectEqual(@as(?[]const u8, null), out.submeshes[0].tex); // white default
    try expectNormalizedBounds(out);
    var i: u32 = 0;
    while (i < out.index_count) : (i += 1)
        try std.testing.expect(idxAt(out, i) < out.vert_count);
}

// ── glTF 2.0 node hierarchy + transforms ──────────────────────────────────

test "node hierarchy: a mesh under two nodes is instanced twice, offset by the node translation" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // Same triangle placed by two scene nodes: one at the origin, one translated
    // +10 in x. The loader must emit six vertices (two placements) and bake the
    // translation, so after the fit-to-height normalization (uniform scale 2,
    // since the y span is 1) the two triangles' vertex-0 x differ by 10*2 = 20.
    const out = try parseGlb(
        \\{"scenes":[{"nodes":[0,1]}],
        \\ "nodes":[{"mesh":0},{"mesh":0,"translation":[10,0,0]}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(u32, 6), out.vert_count);
    try std.testing.expectEqual(@as(u32, 6), out.index_count);
    // Vertex 3 is the second placement's vertex 0.
    try std.testing.expectApproxEqAbs(@as(f32, 20), vf(out, 3, 0) - vf(out, 0, 0), 1e-4);
}

test "node transform: a 90-degree rotation about Z maps the triangle's edge direction" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // quaternion for +90 deg about Z = (0,0,sin45,cos45). It sends the edge
    // v0->v1 = +x into +y. Normalization is uniform, so the ROTATED shape's
    // v0->v1 edge must point along +y (its x component ~0, y component > 0).
    const out = try parseGlb(
        \\{"scenes":[{"nodes":[0]}],
        \\ "nodes":[{"mesh":0,"rotation":[0,0,0.70710678,0.70710678]}],
        \\ "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    const edge_x = vf(out, 1, 0) - vf(out, 0, 0);
    const edge_y = vf(out, 1, 1) - vf(out, 0, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0), edge_x, 1e-4); // +x rotated off the x axis
    try std.testing.expect(edge_y > 0.5); // now points +y
}

test "no scene graph: meshes render once at identity (back-compat)" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // A file with meshes but no nodes/scenes: the identity fallback must
    // reproduce the exact pre-node-support reference triangle.
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try expectReferenceTriangle(out);
}

// ── glTF 2.0 per-primitive materials ──────────────────────────────────────

test "per-primitive materials: two primitives, each its own submesh, texture, and blend" {
    // Two triangles in one mesh, materials 0 (untextured red, OPAQUE) and 1
    // (untextured, BLEND). Each must land in its own submesh with the right
    // index span, base colour, and blend flag.
    const bin = try floatsLe(&(TRI_POS ++ TRI_POS));
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[
        \\  {"attributes":{"POSITION":0},"material":0},
        \\  {"attributes":{"POSITION":1},"material":1}]}],
        \\ "accessors":[
        \\  {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        \\  {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[
        \\  {"buffer":0,"byteOffset":0,"byteLength":36},
        \\  {"buffer":0,"byteOffset":36,"byteLength":36}],
        \\ "buffers":[{"byteLength":72}],
        \\ "materials":[
        \\  {"pbrMetallicRoughness":{"baseColorFactor":[1,0,0,1]}},
        \\  {"alphaMode":"BLEND"}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectEqual(@as(usize, 2), out.submeshes.len);
    // Submesh 0: red opaque, indices 0..3.
    try std.testing.expectEqual(@as(u32, 0), out.submeshes[0].index_offset);
    try std.testing.expectEqual(@as(u32, 3), out.submeshes[0].index_count);
    try std.testing.expectEqual(@as(u32, 0xFFFF_0000), out.submeshes[0].base_color);
    try std.testing.expect(!out.submeshes[0].blend);
    // Submesh 1: blended, indices 3..6.
    try std.testing.expectEqual(@as(u32, 3), out.submeshes[1].index_offset);
    try std.testing.expectEqual(@as(u32, 3), out.submeshes[1].index_count);
    try std.testing.expect(out.submeshes[1].blend);
}

// ── glTF 2.0 JSON (.gltf) container with an embedded base64 buffer ─────────

test "JSON .gltf: a base64 data-URI buffer parses to the same reference triangle" {
    // The reference triangle as a .gltf document: buffers[0].uri is a base64
    // data URI of the 36 position bytes — the glTF-Embedded variant. It must
    // produce exactly what the equivalent .glb does.
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    var b64: [64]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const uri_data = enc.encode(&b64, bin);

    var json_buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(&json_buf,
        \\{{"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}}}}]}}],
        \\ "accessors":[{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}}],
        \\ "bufferViews":[{{"buffer":0,"byteOffset":0,"byteLength":36}}],
        \\ "buffers":[{{"byteLength":36,"uri":"data:application/octet-stream;base64,{s}"}}]}}
    , .{uri_data});

    const out = try glb.parse(ta, json); // no GLB magic → JSON path
    defer out.deinit(ta);
    try expectReferenceTriangle(out);
}

test "JSON .gltf: an external (non-data) buffer uri is rejected loudly" {
    const json =
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36,"uri":"geometry.bin"}]}
    ;
    try std.testing.expectError(glb.Error.GlbBadDataUri, glb.parse(ta, json));
}

test "PBR factors: metallic/roughness/emissive extracted per material with glTF defaults" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    // A material setting metallicFactor 0, roughnessFactor 0.4, emissive [1,0,0].
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}],
        \\ "materials":[{"pbrMetallicRoughness":{"metallicFactor":0.0,"roughnessFactor":0.4},"emissiveFactor":[1,0,0]}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.submeshes[0].metallic, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), out.submeshes[0].roughness, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.submeshes[0].emissive[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out.submeshes[0].emissive[1], 1e-6);
}

test "PBR factors: an absent material yields the glTF defaults (metallic 1, rough 1)" {
    const bin = try floatsLe(&TRI_POS);
    defer ta.free(bin);
    const out = try parseGlb(
        \\{"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        \\ "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
        \\ "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}],
        \\ "buffers":[{"byteLength":36}]}
    , bin);
    defer out.deinit(ta);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.submeshes[0].metallic, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.submeshes[0].roughness, 1e-6);
}

// ── glTF conformance corpus (Khronos glTF-Sample-Assets) ──────────────────
// The reference models spec R120–R122 name, parsed through the loader to prove
// the geometry + feature tiers load. Structural assertions (not pixels): counts
// and submesh partitioning. The full corpus (incl. the multi-MB
// MetalRoughSpheres) is vetted by `build/bin/glbcheck assets/models/*.glb`.

const CorpusCase = struct { bytes: []const u8, min_subs: usize, textured: bool };

test "conformance: geometry + feature tier models load with sane structure" {
    const cases = [_]struct { name: []const u8, c: CorpusCase }{
        // The geometry tier (TEST-005). Triangle/TriangleWithoutIndices/
        // SimpleMeshes ship upstream only as self-contained .gltf (JSON with a
        // data-URI buffer), so they also prove the JSON container and the
        // non-indexed draw path load through the same surface as the .glb models.
        .{ .name = "Triangle", .c = .{ .bytes = @embedFile("model_triangle"), .min_subs = 1, .textured = false } },
        .{ .name = "TriangleWithoutIndices", .c = .{ .bytes = @embedFile("model_trianglenoidx"), .min_subs = 1, .textured = false } },
        .{ .name = "SimpleMeshes", .c = .{ .bytes = @embedFile("model_simplemeshes"), .min_subs = 1, .textured = false } },
        .{ .name = "Box", .c = .{ .bytes = @embedFile("model_box"), .min_subs = 1, .textured = false } },
        .{ .name = "BoxInterleaved", .c = .{ .bytes = @embedFile("model_boxinterleaved"), .min_subs = 1, .textured = false } },
        .{ .name = "BoxTextured", .c = .{ .bytes = @embedFile("model_boxtextured"), .min_subs = 1, .textured = true } },
        .{ .name = "VertexColorTest", .c = .{ .bytes = @embedFile("model_vertexcolor"), .min_subs = 1, .textured = false } },
        .{ .name = "TextureCoordinateTest", .c = .{ .bytes = @embedFile("model_texcoord"), .min_subs = 1, .textured = false } },
        .{ .name = "OrientationTest", .c = .{ .bytes = @embedFile("model_orientation"), .min_subs = 1, .textured = false } },
        .{ .name = "AlphaBlendModeTest", .c = .{ .bytes = @embedFile("model_alphablend"), .min_subs = 1, .textured = true } },
    };
    for (cases) |case| {
        const out = glb.parse(ta, case.c.bytes) catch |e| {
            std.debug.print("conformance: {s} FAILED to parse: {s}\n", .{ case.name, @errorName(e) });
            return e;
        };
        defer out.deinit(ta);
        try std.testing.expect(out.vert_count >= 3);
        try std.testing.expect(out.index_count % 3 == 0);
        try std.testing.expect(out.submeshes.len >= case.c.min_subs);
        // Every submesh's index span lies within the merged index buffer.
        for (out.submeshes) |sm| {
            try std.testing.expect(sm.index_offset + sm.index_count <= out.index_count);
        }
        if (case.c.textured) {
            var any_tex = false;
            for (out.submeshes) |sm| {
                if (sm.tex != null) any_tex = true;
            }
            try std.testing.expect(any_tex);
        }
    }
}

test "conformance: AlphaBlendModeTest exercises the blend path (some submesh blends)" {
    const out = try glb.parse(ta, @embedFile("model_alphablend"));
    defer out.deinit(ta);
    var any_blend = false;
    for (out.submeshes) |sm| {
        if (sm.blend) any_blend = true;
    }
    try std.testing.expect(any_blend);
}
