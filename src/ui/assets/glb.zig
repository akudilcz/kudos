//! GLB (glTF 2.0 binary) model loader — PURE module (std only), host-tested
//! (test/ui/assets/glb_test.zig). Parses a subset of glTF 2.0: the container
//! header + JSON/BIN chunks, then meshes[*].primitives[*] with
//! POSITION/NORMAL/TEXCOORD_0 + indices through accessors/bufferViews over the
//! BIN chunk, merged into ONE interleaved
//! vertex buffer in the kGL mesh layout (pos.xyz f32, uv f32x2, normal
//! f32x3 — stride 32, what iopengl.meshCreate uploads) plus u32 indices.
//!
//! The material's texture maps (materials → textures → images) are located but
//! NOT decoded here: each borrows the embedded image bytes and names its codec,
//! so the caller feeds them to png.zig or jpeg.zig — parsing and pixel
//! decoding stay separately testable. (Both PNG and JPEG are embedded in the
//! real corpus: CesiumMilkTruck's textures are JPEG.) Beyond the base colour,
//! the full glTF metallic-roughness map set is located (spec APP-011):
//! metallic-roughness, normal, occlusion, and emissive.
//!
//! Every field this loader reads is validated at its read site, with a distinct
//! error per failure class and no clamping or skipping: a file that fails must
//! name its defect, not render garbage. Spec-defined JSON defaults (byteOffset 0,
//! mode 4) are the ONE place absence is legal — each is applied explicitly at its
//! read site.

const std = @import("std");

pub const Error = error{
    GlbTruncated, // container/chunk smaller than its declared sizes
    GlbBadMagic, // not 'glTF'
    GlbBadVersion, // container version != 2
    GlbBadLength, // header length != file size
    GlbNoJson, // chunk 0 missing or not JSON
    GlbNoBin, // no BIN chunk (geometry cannot exist)
    GlbBadJson, // JSON chunk does not parse / wrong shape
    GlbNoMeshes, // no meshes/primitives with POSITION
    GlbBadMode, // primitive mode != 4 (TRIANGLES)
    GlbBadAccessor, // accessor type/componentType outside the subset
    GlbBadBufferView, // view/accessor range escapes the BIN chunk
    GlbBadBuffer, // accessor reaches a buffer other than 0 / a uri buffer
    GlbBadIndex, // an index >= its primitive's vertex count
    GlbTooFewVerts, // a primitive with < 3 vertices
    GlbBadImage, // texture image not embedded, or baseColorTexture.texCoord != 0
    GlbBadImageMime, // embedded image mimeType is neither PNG nor JPEG
    GlbBadDataUri, // a .gltf buffer uri is not a base64 data: URI we can decode
} || std.mem.Allocator.Error;

/// Which codec the located base-color texture uses; the caller dispatches to
/// png.zig or jpeg.zig (both yield the same BGRA8 Image).
pub const TexMime = enum { png, jpeg };

/// One drawable span of the merged index buffer with its own material — a
/// glTF primitive. The renderer binds this submesh's texture (or flat colour)
/// and blend mode, then draws `index_count` indices starting at `index_offset`.
pub const Submesh = struct {
    index_offset: u32, // first index (not bytes) into Out.indices
    index_count: u32,
    tex: ?[]const u8, // embedded base-colour image bytes, or null (untextured)
    tex_mime: TexMime, // codec for `tex` (undefined when tex == null)
    // baseColorFactor as packed 0xAARRGGBB (straight alpha). Opaque white by
    // default. With no texture it is the submesh's flat colour; with one it is
    // baked into the texels at upload (glTF: base colour = factor × texel).
    base_color: u32,
    /// glTF alphaMode BLEND/MASK asks for alpha blending (OPAQUE stays false).
    blend: bool,
    // glTF 2.0 metallic-roughness factors (pbrMetallicRoughness), extracted for
    // the physically-based shading path. Defaults are the glTF defaults (fully
    // metallic, fully rough) so a material that omits them reads as the spec
    // intends. `emissive` is the material's emissiveFactor (linear RGB).
    metallic: f32,
    roughness: f32,
    emissive: [3]f32,
    // The glTF PBR map images beyond base-colour (spec APP-011), each LOCATED
    // (borrowed bytes + codec) but NOT decoded here — the same split as `tex`.
    // null when the material omits that map. metallic-roughness lives under
    // pbrMetallicRoughness; the other three are material-level. All sample
    // TEXCOORD_0 only (a non-zero texCoord is a loud GlbBadImage).
    metallic_roughness_map: ?LocatedTex,
    normal_map: ?LocatedTex,
    occlusion_map: ?LocatedTex,
    emissive_map: ?LocatedTex,
};

/// Parsed model: the two GPU-ready blobs (owned by the caller's allocator)
/// plus the per-primitive submeshes that partition the index buffer, each
/// with its own (located-but-undecoded) base-colour material.
pub const Out = struct {
    verts: []u8, // vert_count * 32, interleaved (the kGL mesh layout)
    indices: []u8, // index_count * 4, u32 little-endian
    vert_count: u32,
    index_count: u32,
    submeshes: []Submesh, // owned by the caller's allocator
    // Per-vertex COLOR_0 as a SEPARATE array (vert_count * 4, RGBA8 straight),
    // null when no primitive carries vertex colours. Kept out of the interleaved
    // `verts` so a model without COLOR_0 (the in-kernel teapot/duck) has a
    // byte-identical vertex buffer — the renderer binds this as a second array
    // (GL_COLOR_ARRAY) only when present. Only FLOAT COLOR_0 (VertexColorTest) is
    // read; a normalized-integer COLOR_0 is skipped (rendered without it), never
    // an error, so no model that parsed before regresses.
    colors: ?[]u8,

    pub fn deinit(self: Out, a: std.mem.Allocator) void {
        a.free(self.verts);
        a.free(self.indices);
        a.free(self.submeshes);
        if (self.colors) |c| a.free(c);
    }
};

const STRIDE: u32 = 32;

// glTF componentType values.
const CT_U8: u64 = 5121;
const CT_U16: u64 = 5123;
const CT_U32: u64 = 5125;
const CT_F32: u64 = 5126;

/// The glTF 2.0 container magic 'glTF' (little-endian u32), the first four
/// bytes of every binary .glb. A file without it is treated as a JSON .gltf.
const GLB_MAGIC: u32 = 0x46546C67;

pub fn parse(a: std.mem.Allocator, bytes: []const u8) Error!Out {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ── container: binary (.glb) or JSON (.gltf) ─────────────────────────
    // A .glb opens with the 'glTF' magic + version + length, then JSON and BIN
    // chunks. A .gltf is the JSON document itself; its geometry buffer arrives
    // as buffers[0].uri — a base64 data: URI (the glTF-Embedded variant), which
    // the JSON path decodes here so the rest of the loader is container-blind.
    var json_bytes: []const u8 = undefined;
    var bin_opt: ?[]const u8 = null;
    const is_glb = bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == GLB_MAGIC;
    if (is_glb) {
        if (bytes.len < 12) return Error.GlbTruncated;
        if (std.mem.readInt(u32, bytes[4..8], .little) != 2) return Error.GlbBadVersion;
        if (std.mem.readInt(u32, bytes[8..12], .little) != bytes.len) return Error.GlbBadLength;

        var json_chunk: ?[]const u8 = null;
        var bin_chunk: ?[]const u8 = null;
        var off: usize = 12;
        var chunk_index: usize = 0;
        while (off < bytes.len) : (chunk_index += 1) {
            if (bytes.len - off < 8) return Error.GlbTruncated;
            const clen = std.mem.readInt(u32, bytes[off..][0..4], .little);
            const ctype = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
            if (bytes.len - off - 8 < clen) return Error.GlbTruncated;
            const data = bytes[off + 8 .. off + 8 + clen];
            if (chunk_index == 0) {
                if (ctype != 0x4E4F534A) return Error.GlbNoJson; // "JSON"
                json_chunk = data;
            } else if (ctype == 0x004E4942 and bin_chunk == null) { // "BIN\0"
                bin_chunk = data;
            } // spec: unknown chunk types are ignored
            off += 8 + clen;
        }
        json_bytes = json_chunk orelse return Error.GlbNoJson;
        bin_opt = bin_chunk orelse return Error.GlbNoBin;
    } else {
        json_bytes = bytes; // the whole file is the JSON document
    }

    // ── JSON tree (scratch arena: everything but the two output blobs) ───
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json_bytes, .{}) catch |e| switch (e) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.GlbBadJson,
    };
    const root = asObject(parsed) orelse return Error.GlbBadJson;

    // JSON (.gltf): the geometry buffer is buffers[0].uri, a base64 data: URI
    // (glTF-Embedded). Decode it into the arena so `bin` reads the same as a
    // .glb BIN chunk. External-file URIs are not resolvable in this pure module
    // (no VFS) — the caller supplies the embedded variant.
    const bin: []const u8 = bin_opt orelse blk: {
        const buffers = jArray(root, "buffers") orelse return Error.GlbNoBin;
        if (buffers.len == 0) return Error.GlbNoBin;
        const buf0 = asObject(buffers[0]) orelse return Error.GlbBadJson;
        const uri = jString(buf0, "uri") orelse return Error.GlbNoBin;
        break :blk try decodeDataUri(arena, uri);
    };

    const accessors = jArray(root, "accessors") orelse &.{};
    const buffer_views = jArray(root, "bufferViews") orelse &.{};
    const meshes = jArray(root, "meshes") orelse return Error.GlbNoMeshes;

    // ── first pass: primitives + totals ──────────────────────────────────
    const Prim = struct {
        pos: Acc,
        nrm: ?Acc,
        uv: ?Acc,
        col: ?Acc, // COLOR_0 (FLOAT VEC3/VEC4), null when absent/unsupported
        idx: ?Acc, // null = non-indexed (sequential triangles)
        vert_base: u32,
        index_base: u32,
        index_count: u32, // this primitive's index span (one submesh)
        material: ?u64, // this primitive's material index (glTF per-primitive)
        xform: Mat4, // node world transform baked into this primitive's verts
    };
    var prims = std.array_list.Managed(Prim).init(arena);
    var total_verts: u64 = 0;
    var total_indices: u64 = 0;
    var any_color = false; // any primitive carries a (float) COLOR_0

    // Walk the node hierarchy: each instance is a mesh placed at a world
    // transform (a mesh under several nodes appears several times).
    const instances = try buildInstances(arena, root, meshes.len);
    for (instances) |inst| {
        if (inst.mesh >= meshes.len) return Error.GlbBadJson;
        const mesh = asObject(meshes[inst.mesh]) orelse return Error.GlbBadJson;
        const mesh_prims = jArray(mesh, "primitives") orelse continue;
        for (mesh_prims) |prim_v| {
            const prim = asObject(prim_v) orelse return Error.GlbBadJson;
            const mode = (try jInt(prim, "mode")) orelse 4; // spec default: TRIANGLES
            if (mode != 4) return Error.GlbBadMode;
            const attrs = jObject(prim, "attributes") orelse return Error.GlbBadJson;

            const pos_idx = (try jInt(attrs, "POSITION")) orelse return Error.GlbNoMeshes;
            const pos = try resolveAccessor(accessors, buffer_views, bin, pos_idx, CT_F32, 3);
            if (pos.count < 3) return Error.GlbTooFewVerts;

            var nrm: ?Acc = null;
            if (try jInt(attrs, "NORMAL")) |ni| {
                nrm = try resolveAccessor(accessors, buffer_views, bin, ni, CT_F32, 3);
                if (nrm.?.count != pos.count) return Error.GlbBadAccessor;
            }
            var uv: ?Acc = null;
            if (try jInt(attrs, "TEXCOORD_0")) |ti| {
                uv = try resolveAccessor(accessors, buffer_views, bin, ti, CT_F32, 2);
                if (uv.?.count != pos.count) return Error.GlbBadAccessor;
            }
            var col: ?Acc = null;
            if (try jInt(attrs, "COLOR_0")) |ci| {
                col = try resolveColorAccessor(accessors, buffer_views, bin, ci, pos.count);
                if (col != null) any_color = true;
            }
            var idx: ?Acc = null;
            var prim_index_count: u64 = pos.count; // non-indexed: one per vert
            if (try jInt(prim, "indices")) |ii| {
                const acc = try resolveIndexAccessor(accessors, buffer_views, bin, ii);
                prim_index_count = acc.count;
                idx = acc;
            }
            // TRIANGLES: whole triangles only.
            if (prim_index_count % 3 != 0) return Error.GlbBadAccessor;

            try prims.append(.{
                .pos = pos,
                .nrm = nrm,
                .uv = uv,
                .col = col,
                .idx = idx,
                .vert_base = @intCast(total_verts),
                .index_base = @intCast(total_indices),
                .index_count = @intCast(prim_index_count),
                .material = try jInt(prim, "material"),
                .xform = inst.xform,
            });
            total_verts += pos.count;
            total_indices += prim_index_count;
        }
    }
    if (prims.items.len == 0) return Error.GlbNoMeshes;
    if (total_verts > std.math.maxInt(u32) or total_indices > std.math.maxInt(u32))
        return Error.GlbBadAccessor;

    // ── fill the merged interleaved buffers ──────────────────────────────
    const verts = try a.alloc(u8, @intCast(total_verts * STRIDE));
    errdefer a.free(verts);
    const indices = try a.alloc(u8, @intCast(total_indices * 4));
    errdefer a.free(indices);
    // A separate RGBA8 per-vertex colour array (COLOR_0), only when some primitive
    // carries it — kept out of `verts` so an untinted model's vertex buffer is
    // byte-identical. A colour-tinted model whose OTHER primitives omit COLOR_0
    // fills those verts opaque white (the glTF default).
    const colors: ?[]u8 = if (any_color) try a.alloc(u8, @intCast(total_verts * 4)) else null;
    errdefer if (colors) |c| a.free(c);

    for (prims.items) |p| {
        var i: u32 = 0;
        while (i < p.pos.count) : (i += 1) {
            const v = verts[(@as(usize, p.vert_base) + i) * STRIDE ..][0..STRIDE];
            // Bake the node world transform: positions through the full matrix,
            // normals through its 3x3 (glTF 2.0 node hierarchy).
            const wp = p.xform.point(p.pos.f32At(i, 0), p.pos.f32At(i, 1), p.pos.f32At(i, 2));
            writeF32(v[0..4], wp[0]);
            writeF32(v[4..8], wp[1]);
            writeF32(v[8..12], wp[2]);
            writeF32(v[12..16], if (p.uv) |u| u.f32At(i, 0) else 0.0);
            writeF32(v[16..20], if (p.uv) |u| u.f32At(i, 1) else 0.0);
            if (p.nrm) |n| {
                const wn = p.xform.dir(n.f32At(i, 0), n.f32At(i, 1), n.f32At(i, 2));
                writeF32(v[20..24], wn[0]);
                writeF32(v[24..28], wn[1]);
                writeF32(v[28..32], wn[2]);
            } else {
                writeF32(v[20..24], 0.0);
                writeF32(v[24..28], 0.0);
                writeF32(v[28..32], 0.0);
            }
            if (colors) |cbuf| {
                const cb = cbuf[(@as(usize, p.vert_base) + i) * 4 ..][0..4];
                if (p.col) |ca| {
                    cb[0] = f2u8(ca.f32At(i, 0));
                    cb[1] = f2u8(ca.f32At(i, 1));
                    cb[2] = f2u8(ca.f32At(i, 2));
                    cb[3] = if (ca.ncomp == 4) f2u8(ca.f32At(i, 3)) else 255;
                } else {
                    cb[0] = 255; // this primitive has no COLOR_0 — opaque white
                    cb[1] = 255;
                    cb[2] = 255;
                    cb[3] = 255;
                }
            }
        }
        const n_idx: u32 = if (p.idx) |acc| acc.count else p.pos.count;
        i = 0;
        while (i < n_idx) : (i += 1) {
            const raw: u32 = if (p.idx) |acc| acc.indexAt(i) else i;
            if (raw >= p.pos.count) return Error.GlbBadIndex;
            std.mem.writeInt(u32, indices[(@as(usize, p.index_base) + i) * 4 ..][0..4], p.vert_base + raw, .little);
        }
        // Missing normals ⇒ smooth per-vertex normals from this primitive's
        // own triangles (area-weighted face-normal accumulation; GLB verts
        // arrive exporter-deduped, so per-slot accumulation is the per-position
        // rule in practice).
        if (p.nrm == null) accumulateNormals(verts, indices, p.vert_base, p.pos.count, p.index_base, n_idx);
    }

    normalize(verts, @intCast(total_verts));

    // ── per-primitive materials: one submesh per primitive, each carrying its
    //    own base-colour texture (located, not decoded) OR flat factor and its
    //    blend mode. This is what lets a multi-material model (AlphaBlendMode-
    //    Test, TextureCoordinateTest) render each primitive correctly. ────────
    const submeshes = try a.alloc(Submesh, prims.items.len);
    errdefer a.free(submeshes);
    for (prims.items, 0..) |p, si| {
        var sm = Submesh{
            .index_offset = p.index_base,
            .index_count = p.index_count,
            .tex = null,
            .tex_mime = .png,
            .base_color = 0xFFFF_FFFF, // opaque white (glTF default; no material)
            .blend = false,
            .metallic = 1.0, // glTF metallicFactor default
            .roughness = 1.0, // glTF roughnessFactor default
            .emissive = .{ 0, 0, 0 }, // glTF emissiveFactor default
            .metallic_roughness_map = null,
            .normal_map = null,
            .occlusion_map = null,
            .emissive_map = null,
        };
        if (p.material) |mi| {
            if (try findBaseColorTex(root, bin, mi)) |located| {
                sm.tex = located.bytes;
                sm.tex_mime = located.mime;
            }
            // The factor applies with or without a texture: glTF base colour is
            // factor × texel, and the upload bakes the product at load.
            sm.base_color = try findBaseColorFactor(root, mi);
            sm.blend = findAlphaMode(root, mi);
            const pbr = findPbrFactors(root, mi);
            sm.metallic = pbr.metallic;
            sm.roughness = pbr.roughness;
            sm.emissive = pbr.emissive;
            sm.metallic_roughness_map = try findMaterialMap(root, bin, mi, "metallicRoughnessTexture", true);
            sm.normal_map = try findMaterialMap(root, bin, mi, "normalTexture", false);
            sm.occlusion_map = try findMaterialMap(root, bin, mi, "occlusionTexture", false);
            sm.emissive_map = try findMaterialMap(root, bin, mi, "emissiveTexture", false);
        }
        submeshes[si] = sm;
    }

    return .{
        .verts = verts,
        .indices = indices,
        .vert_count = @intCast(total_verts),
        .index_count = @intCast(total_indices),
        .submeshes = submeshes,
        .colors = colors,
    };
}

/// A glTF float colour channel (0..1, may exceed the range) to a straight 8-bit
/// value, rounded and clamped.
/// A [0,1] float to its rounded 8-bit channel value, saturating outside the
/// range. The one home for this conversion in the loader family — modelcache
/// bakes material factors with it too.
pub fn f2u8(x: f32) u8 {
    return @intFromFloat(@min(255.0, @max(0.0, x * 255.0 + 0.5)));
}

/// Decode a base64 `data:` URI (glTF-Embedded buffer) into arena bytes. Only
/// the base64 form is supported — `data:application/octet-stream;base64,AAAA…`
/// or `data:application/gltf-buffer;base64,…`; a plain-text or external-file
/// URI is a loud GlbBadDataUri (this pure module has no filesystem).
fn decodeDataUri(arena: std.mem.Allocator, uri: []const u8) Error![]const u8 {
    if (!std.mem.startsWith(u8, uri, "data:")) return Error.GlbBadDataUri;
    const comma = std.mem.indexOfScalar(u8, uri, ',') orelse return Error.GlbBadDataUri;
    const header = uri[0..comma];
    if (std.mem.indexOf(u8, header, ";base64") == null) return Error.GlbBadDataUri;
    const b64 = uri[comma + 1 ..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return Error.GlbBadDataUri;
    const out = try arena.alloc(u8, n);
    dec.decode(out, b64) catch return Error.GlbBadDataUri;
    return out;
}

// ── scene graph (glTF 2.0 node hierarchy + transforms) ───────────────────
//
// glTF places meshes in a node tree: `scenes[scene].nodes[]` are roots, each
// node carries a local transform (a `matrix`, or TRS `translation`/`rotation`/
// `scale`) and may reference a `mesh` and `children`. A mesh referenced by two
// nodes appears twice, at each node's world transform (SimpleMeshes). The
// walker below flattens the reachable tree into (mesh, world-matrix) instances;
// the geometry pass bakes each world matrix into that instance's vertices.

/// Column-major 4x4, glTF's matrix layout. Identity is the default local
/// transform (a node with neither `matrix` nor TRS).
const Mat4 = struct {
    m: [16]f32,

    const identity = Mat4{ .m = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };

    /// self * other (apply `other` first, then `self`).
    fn mul(self: Mat4, other: Mat4) Mat4 {
        var r: [16]f32 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) sum += self.m[k * 4 + row] * other.m[col * 4 + k];
                r[col * 4 + row] = sum;
            }
        }
        return .{ .m = r };
    }

    /// Transform a position (w=1): full 4x4 including translation.
    fn point(self: Mat4, x: f32, y: f32, z: f32) [3]f32 {
        return .{
            self.m[0] * x + self.m[4] * y + self.m[8] * z + self.m[12],
            self.m[1] * x + self.m[5] * y + self.m[9] * z + self.m[13],
            self.m[2] * x + self.m[6] * y + self.m[10] * z + self.m[14],
        };
    }

    /// Transform a direction (w=0): the upper 3x3, no translation. Correct for
    /// normals under rotation and uniform scale (the corpus case); a non-uniform
    /// scale would need the inverse-transpose, out of scope for this tier.
    fn dir(self: Mat4, x: f32, y: f32, z: f32) [3]f32 {
        return .{
            self.m[0] * x + self.m[4] * y + self.m[8] * z,
            self.m[1] * x + self.m[5] * y + self.m[9] * z,
            self.m[2] * x + self.m[6] * y + self.m[10] * z,
        };
    }
};

/// Compose a node's local transform from TRS (translation, rotation quaternion,
/// scale), the glTF default when no explicit `matrix` is given.
fn trsMatrix(t: [3]f32, q: [4]f32, s: [3]f32) Mat4 {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const xx = x * x;
    const yy = y * y;
    const zz = z * z;
    const xy = x * y;
    const xz = x * z;
    const yz = y * z;
    const wx = w * x;
    const wy = w * y;
    const wz = w * z;
    return .{ .m = .{
        (1 - 2 * (yy + zz)) * s[0], (2 * (xy + wz)) * s[0],     (2 * (xz - wy)) * s[0],     0,
        (2 * (xy - wz)) * s[1],     (1 - 2 * (xx + zz)) * s[1], (2 * (yz + wx)) * s[1],     0,
        (2 * (xz + wy)) * s[2],     (2 * (yz - wx)) * s[2],     (1 - 2 * (xx + yy)) * s[2], 0,
        t[0],                       t[1],                       t[2],                       1,
    } };
}

/// The local transform of node object `node`: an explicit `matrix` if present,
/// otherwise composed from TRS (each component defaulting to identity).
fn nodeLocal(node: std.json.ObjectMap) Mat4 {
    if (jArray(node, "matrix")) |mv| {
        if (mv.len == 16) {
            var m: [16]f32 = undefined;
            for (mv, 0..) |c, i| m[i] = @floatCast(jFloat(c) orelse return Mat4.identity);
            return .{ .m = m };
        }
    }
    var t = [3]f32{ 0, 0, 0 };
    var q = [4]f32{ 0, 0, 0, 1 };
    var s = [3]f32{ 1, 1, 1 };
    if (jArray(node, "translation")) |v| if (v.len == 3) for (v, 0..) |c, i| {
        t[i] = @floatCast(jFloat(c) orelse 0);
    };
    if (jArray(node, "rotation")) |v| if (v.len == 4) for (v, 0..) |c, i| {
        q[i] = @floatCast(jFloat(c) orelse if (i == 3) @as(f64, 1) else 0);
    };
    if (jArray(node, "scale")) |v| if (v.len == 3) for (v, 0..) |c, i| {
        s[i] = @floatCast(jFloat(c) orelse 1);
    };
    return trsMatrix(t, q, s);
}

/// One drawable placement: a mesh index and the world transform to bake into it.
const Instance = struct { mesh: u64, xform: Mat4 };

/// Depth cap on node recursion — well past any real asset, a guard against a
/// cyclic `children` graph (which glTF forbids but a malformed file could hold).
const MAX_NODE_DEPTH: u32 = 64;

/// Recurse node `ni`, accumulating `parent` into its world transform; append an
/// Instance for a mesh it references, then descend into children.
fn walkNode(nodes: []const std.json.Value, ni: u64, parent: Mat4, depth: u32, out: *std.array_list.Managed(Instance)) Error!void {
    if (depth > MAX_NODE_DEPTH or ni >= nodes.len) return;
    const node = asObject(nodes[ni]) orelse return Error.GlbBadJson;
    const world = parent.mul(nodeLocal(node));
    if (try jInt(node, "mesh")) |mesh_idx| {
        try out.append(.{ .mesh = mesh_idx, .xform = world });
    }
    if (jArray(node, "children")) |kids| {
        for (kids) |kv| {
            const ci = jFloat(kv) orelse continue;
            try walkNode(nodes, @intFromFloat(ci), world, depth + 1, out);
        }
    }
}

/// Flatten the scene graph into (mesh, world-matrix) instances. Falls back to
/// one identity instance per mesh when the file has no scene graph (older
/// single-mesh assets), preserving the pre-node-support behaviour.
fn buildInstances(arena: std.mem.Allocator, root: std.json.ObjectMap, mesh_count: usize) Error![]Instance {
    var out = std.array_list.Managed(Instance).init(arena);
    const nodes = jArray(root, "nodes") orelse &.{};
    if (nodes.len != 0) {
        const scene_idx: u64 = (try jInt(root, "scene")) orelse 0;
        const scenes = jArray(root, "scenes") orelse &.{};
        if (scene_idx < scenes.len) {
            const scene = asObject(scenes[scene_idx]) orelse return Error.GlbBadJson;
            if (jArray(scene, "nodes")) |roots| {
                for (roots) |rv| {
                    const ri = jFloat(rv) orelse continue;
                    try walkNode(nodes, @intFromFloat(ri), Mat4.identity, 0, &out);
                }
            }
        }
    }
    // No reachable mesh instances (no scene graph, or a scene with none): render
    // every mesh once at identity, as the loader did before node support.
    if (out.items.len == 0) {
        var mi: u64 = 0;
        while (mi < mesh_count) : (mi += 1) try out.append(.{ .mesh = mi, .xform = Mat4.identity });
    }
    return out.toOwnedSlice();
}

// ── accessors ────────────────────────────────────────────────────────────

/// A validated accessor: a base offset + stride over the BIN chunk. Every
/// element of every component is proven in-bounds at resolve time, so the
/// At() readers below need no per-read checks.
const Acc = struct {
    bin: []const u8,
    base: usize, // view.byteOffset + accessor.byteOffset
    stride: usize, // element-to-element distance
    comp: u64, // componentType
    ncomp: u32,
    count: u32,

    fn f32At(self: Acc, elem: u32, component: u32) f32 {
        const at = self.base + @as(usize, elem) * self.stride + @as(usize, component) * 4;
        return @bitCast(std.mem.readInt(u32, self.bin[at..][0..4], .little));
    }

    fn indexAt(self: Acc, elem: u32) u32 {
        const at = self.base + @as(usize, elem) * self.stride;
        return switch (self.comp) {
            CT_U8 => self.bin[at],
            CT_U16 => std.mem.readInt(u16, self.bin[at..][0..2], .little),
            CT_U32 => std.mem.readInt(u32, self.bin[at..][0..4], .little),
            else => unreachable, // resolveIndexAccessor admits only these
        };
    }
};

fn componentSize(comp: u64) usize {
    return switch (comp) {
        CT_U8 => 1,
        CT_U16 => 2,
        CT_U32, CT_F32 => 4,
        else => unreachable, // callers reject other componentTypes first
    };
}

fn resolveAccessor(
    accessors: []const std.json.Value,
    views: []const std.json.Value,
    bin: []const u8,
    index: u64,
    want_comp: u64,
    want_ncomp: u32,
) Error!Acc {
    const acc = try accessorAt(accessors, index);
    if (((try jInt(acc, "componentType")) orelse 0) != want_comp) return Error.GlbBadAccessor;
    if (typeComponents(acc) != want_ncomp) return Error.GlbBadAccessor;
    return finishAccessor(acc, views, bin, want_comp, want_ncomp);
}

fn resolveIndexAccessor(
    accessors: []const std.json.Value,
    views: []const std.json.Value,
    bin: []const u8,
    index: u64,
) Error!Acc {
    const acc = try accessorAt(accessors, index);
    const comp = (try jInt(acc, "componentType")) orelse 0;
    if (comp != CT_U8 and comp != CT_U16 and comp != CT_U32) return Error.GlbBadAccessor;
    if (typeComponents(acc) != 1) return Error.GlbBadAccessor;
    return finishAccessor(acc, views, bin, comp, 1);
}

/// Resolve a COLOR_0 accessor — VEC3 or VEC4, and (for now) only FLOAT: `f32At`
/// reads 4-byte components, so a normalized u8/u16 COLOR_0 would misread. Returns
/// null for an unsupported component type so the model renders WITHOUT vertex
/// colour rather than failing to parse (no model that parsed before regresses); a
/// vertex-count mismatch on a supported accessor is still a loud error.
fn resolveColorAccessor(
    accessors: []const std.json.Value,
    views: []const std.json.Value,
    bin: []const u8,
    index: u64,
    want_count: u32,
) Error!?Acc {
    const acc = try accessorAt(accessors, index);
    if (((try jInt(acc, "componentType")) orelse 0) != CT_F32) return null;
    const nc = typeComponents(acc);
    if (nc != 3 and nc != 4) return null;
    const a = try finishAccessor(acc, views, bin, CT_F32, nc);
    if (a.count != want_count) return Error.GlbBadAccessor;
    return a;
}

fn accessorAt(accessors: []const std.json.Value, index: u64) Error!std.json.ObjectMap {
    if (index >= accessors.len) return Error.GlbBadAccessor;
    return asObject(accessors[index]) orelse Error.GlbBadJson;
}

fn typeComponents(acc: std.json.ObjectMap) u32 {
    const t = jString(acc, "type") orelse return 0;
    if (std.mem.eql(u8, t, "SCALAR")) return 1;
    if (std.mem.eql(u8, t, "VEC2")) return 2;
    if (std.mem.eql(u8, t, "VEC3")) return 3;
    if (std.mem.eql(u8, t, "VEC4")) return 4; // COLOR_0 (RGBA); matrices stay outside
    return 0;
}

fn finishAccessor(
    acc: std.json.ObjectMap,
    views: []const std.json.Value,
    bin: []const u8,
    comp: u64,
    ncomp: u32,
) Error!Acc {
    const view_idx = (try jInt(acc, "bufferView")) orelse return Error.GlbBadAccessor;
    if (view_idx >= views.len) return Error.GlbBadBufferView;
    const view = asObject(views[view_idx]) orelse return Error.GlbBadJson;
    if (((try jInt(view, "buffer")) orelse return Error.GlbBadBufferView) != 0) return Error.GlbBadBuffer;

    const view_off: u64 = (try jInt(view, "byteOffset")) orelse 0; // spec default
    const view_len: u64 = (try jInt(view, "byteLength")) orelse return Error.GlbBadBufferView;
    if (view_off + view_len > bin.len) return Error.GlbBadBufferView;

    const elem_size: u64 = @as(u64, componentSize(comp)) * ncomp;
    const stride: u64 = (try jInt(view, "byteStride")) orelse elem_size; // spec: tight when absent
    // The glTF cap (4..252) bounds the span arithmetic below: an unchecked JSON
    // stride of ~2^64 wraps the span check clean past the BIN chunk.
    if (stride < elem_size or stride > 252) return Error.GlbBadBufferView;

    const acc_off: u64 = (try jInt(acc, "byteOffset")) orelse 0; // spec default
    const count_i: u64 = (try jInt(acc, "count")) orelse return Error.GlbBadAccessor;
    if (count_i == 0 or count_i > std.math.maxInt(u32)) return Error.GlbBadAccessor;
    if (acc_off > view_len) return Error.GlbBadBufferView;

    // Last element must end inside the view.
    // With stride ≤ 252 and count < 2^32 this cannot overflow u64.
    const span = acc_off + (count_i - 1) * stride + elem_size;
    if (span > view_len) return Error.GlbBadBufferView;

    return .{
        .bin = bin,
        .base = @intCast(view_off + acc_off),
        .stride = @intCast(stride),
        .comp = comp,
        .ncomp = ncomp,
        .count = @intCast(count_i),
    };
}

// ── geometry post-processing ─────────────────────────────────────────────

fn readF32(v: []const u8) f32 {
    return @bitCast(std.mem.readInt(u32, v[0..4], .little));
}
fn writeF32(v: *[4]u8, x: f32) void {
    std.mem.writeInt(u32, v, @bitCast(x), .little);
}

/// Smooth normals for one primitive's vertex range: accumulate unnormalized
/// (area-weighted) face normals into each referenced vertex, then normalize.
fn accumulateNormals(verts: []u8, indices: []const u8, vert_base: u32, vert_count: u32, index_base: u32, index_count: u32) void {
    var t: u32 = 0;
    while (t + 3 <= index_count) : (t += 3) {
        var p: [3][3]f32 = undefined;
        var vi: [3]u32 = undefined;
        for (0..3) |k| {
            vi[k] = std.mem.readInt(u32, indices[(@as(usize, index_base) + t + k) * 4 ..][0..4], .little);
            const v = verts[@as(usize, vi[k]) * STRIDE ..][0..STRIDE];
            p[k] = .{ readF32(v[0..4]), readF32(v[4..8]), readF32(v[8..12]) };
        }
        const u = .{ p[1][0] - p[0][0], p[1][1] - p[0][1], p[1][2] - p[0][2] };
        const w = .{ p[2][0] - p[0][0], p[2][1] - p[0][1], p[2][2] - p[0][2] };
        const fn_ = .{ u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0] };
        for (vi) |v_idx| {
            const v = verts[@as(usize, v_idx) * STRIDE ..][0..STRIDE];
            writeF32(v[20..24], readF32(v[20..24]) + fn_[0]);
            writeF32(v[24..28], readF32(v[24..28]) + fn_[1]);
            writeF32(v[28..32], readF32(v[28..32]) + fn_[2]);
        }
    }
    var i: u32 = 0;
    while (i < vert_count) : (i += 1) {
        const v = verts[(@as(usize, vert_base) + i) * STRIDE ..][0..STRIDE];
        const n = .{ readF32(v[20..24]), readF32(v[24..28]), readF32(v[28..32]) };
        const len = @sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
        if (len > 0) {
            writeF32(v[20..24], n[0] / len);
            writeF32(v[24..28], n[1] / len);
            writeF32(v[28..32], n[2] / len);
        }
    }
}

/// The display-box rule: center x/z,
/// base at y=-1, height 2 — so any source unit scale (and Duck's 0.01 node
/// scale, which v1 ignores) lands identically sized.
fn normalize(verts: []u8, vert_count: u32) void {
    var mn = [3]f32{ std.math.floatMax(f32), std.math.floatMax(f32), std.math.floatMax(f32) };
    var mx = [3]f32{ -std.math.floatMax(f32), -std.math.floatMax(f32), -std.math.floatMax(f32) };
    var i: u32 = 0;
    while (i < vert_count) : (i += 1) {
        const v = verts[@as(usize, i) * STRIDE ..][0..STRIDE];
        for (0..3) |k| {
            const x = readF32(v[k * 4 ..][0..4]);
            mn[k] = @min(mn[k], x);
            mx[k] = @max(mx[k], x);
        }
    }
    const cx = (mn[0] + mx[0]) / 2.0;
    const cz = (mn[2] + mx[2]) / 2.0;
    const height = @max(mx[1] - mn[1], 1e-9);
    const scale = 2.0 / height;
    i = 0;
    while (i < vert_count) : (i += 1) {
        const v = verts[@as(usize, i) * STRIDE ..][0..STRIDE];
        writeF32(v[0..4], (readF32(v[0..4]) - cx) * scale);
        writeF32(v[4..8], (readF32(v[4..8]) - mn[1]) * scale - 1.0);
        writeF32(v[8..12], (readF32(v[8..12]) - cz) * scale);
    }
}

// ── base-color texture walk ──────────────────────────────────────────────

pub const LocatedTex = struct { bytes: []const u8, mime: TexMime };

/// Resolve one glTF textureInfo (`{"index":N,"texCoord":T,...}`) to its embedded
/// image bytes + codec: textures[index].source → images[src] → bufferView → bin.
/// Only TEXCOORD_0 is sampled (a non-zero texCoord is GlbBadImage); a uri image
/// is GlbBadImage (.glb is self-contained); an alien mimeType is GlbBadImageMime.
/// Called only when the textureInfo exists — absence is the caller's decision.
fn locateTexImage(root: std.json.ObjectMap, bin: []const u8, tex_ref: std.json.ObjectMap) Error!LocatedTex {
    if (((try jInt(tex_ref, "texCoord")) orelse 0) != 0) return Error.GlbBadImage; // only TEXCOORD_0
    const tex_idx = (try jInt(tex_ref, "index")) orelse return Error.GlbBadJson;

    const textures = jArray(root, "textures") orelse return Error.GlbBadJson;
    if (tex_idx >= textures.len) return Error.GlbBadJson;
    const texture = asObject(textures[tex_idx]) orelse return Error.GlbBadJson;
    const img_idx = (try jInt(texture, "source")) orelse return Error.GlbBadImage;

    const images = jArray(root, "images") orelse return Error.GlbBadJson;
    if (img_idx >= images.len) return Error.GlbBadJson;
    const image = asObject(images[img_idx]) orelse return Error.GlbBadJson;
    if (image.get("uri") != null) return Error.GlbBadImage; // .glb is self-contained
    const mime_str = jString(image, "mimeType") orelse return Error.GlbBadImage;
    const mime: TexMime = if (std.mem.eql(u8, mime_str, "image/png"))
        .png
    else if (std.mem.eql(u8, mime_str, "image/jpeg"))
        .jpeg
    else
        return Error.GlbBadImageMime;

    const view_idx = (try jInt(image, "bufferView")) orelse return Error.GlbBadImage;
    const views = jArray(root, "bufferViews") orelse return Error.GlbBadJson;
    if (view_idx >= views.len) return Error.GlbBadBufferView;
    const view = asObject(views[view_idx]) orelse return Error.GlbBadJson;
    if (((try jInt(view, "buffer")) orelse return Error.GlbBadBufferView) != 0) return Error.GlbBadBuffer;
    const v_off: u64 = (try jInt(view, "byteOffset")) orelse 0;
    const v_len: u64 = (try jInt(view, "byteLength")) orelse return Error.GlbBadBufferView;
    if (v_off + v_len > bin.len) return Error.GlbBadBufferView;
    return .{ .bytes = bin[@intCast(v_off)..@intCast(v_off + v_len)], .mime = mime };
}

/// materials[mi].pbrMetallicRoughness.baseColorTexture → the located image, null
/// when the material has no base-color texture.
fn findBaseColorTex(root: std.json.ObjectMap, bin: []const u8, mi: u64) Error!?LocatedTex {
    const materials = jArray(root, "materials") orelse return Error.GlbBadJson;
    if (mi >= materials.len) return Error.GlbBadJson;
    const mat = asObject(materials[mi]) orelse return Error.GlbBadJson;
    const pbr = jObject(mat, "pbrMetallicRoughness") orelse return null;
    const bct = jObject(pbr, "baseColorTexture") orelse return null;
    return try locateTexImage(root, bin, bct);
}

/// Locate a named PBR map on material `mi` (spec APP-011). `in_pbr` selects the
/// container: true → materials[mi].pbrMetallicRoughness.<key> (metallicRoughness),
/// false → materials[mi].<key> (normal / occlusion / emissive). null when the
/// material — or its pbrMetallicRoughness block — omits the map.
fn findMaterialMap(root: std.json.ObjectMap, bin: []const u8, mi: u64, key: []const u8, in_pbr: bool) Error!?LocatedTex {
    const materials = jArray(root, "materials") orelse return null;
    if (mi >= materials.len) return null;
    const mat = asObject(materials[mi]) orelse return null;
    const container = if (in_pbr) (jObject(mat, "pbrMetallicRoughness") orelse return null) else mat;
    const ref = jObject(container, key) orelse return null;
    return try locateTexImage(root, bin, ref);
}

/// materials[mi].pbrMetallicRoughness.baseColorFactor (RGBA float, 0..1) packed
/// to BGRA8 (0xAARRGGBB, the surface/texture layout). Defaults to opaque white
/// when the field is absent — the glTF default. An untextured submesh renders
/// it flat; a textured one bakes it into the texels at upload.
/// materials[mi].alphaMode: "BLEND" and "MASK" render blended (spec R36);
/// "OPAQUE" or an absent field is the glTF default, opaque.
const PbrFactors = struct { metallic: f32, roughness: f32, emissive: [3]f32 };

/// The metallic-roughness + emissive factors of material `mi` (glTF PBR).
/// Missing fields fall back to the glTF defaults (metallic 1, roughness 1,
/// emissive 0), so a bare material reads exactly as the spec intends.
fn findPbrFactors(root: std.json.ObjectMap, mi: u64) PbrFactors {
    var out = PbrFactors{ .metallic = 1.0, .roughness = 1.0, .emissive = .{ 0, 0, 0 } };
    const materials = jArray(root, "materials") orelse return out;
    if (mi >= materials.len) return out;
    const mat = asObject(materials[mi]) orelse return out;
    if (jObject(mat, "pbrMetallicRoughness")) |pbr| {
        if (pbr.get("metallicFactor")) |v| {
            if (jFloat(v)) |f| out.metallic = @floatCast(f);
        }
        if (pbr.get("roughnessFactor")) |v| {
            if (jFloat(v)) |f| out.roughness = @floatCast(f);
        }
    }
    if (jArray(mat, "emissiveFactor")) |ef| {
        if (ef.len == 3) for (ef, 0..) |c, i| {
            out.emissive[i] = @floatCast(jFloat(c) orelse 0);
        };
    }
    return out;
}

fn findAlphaMode(root: std.json.ObjectMap, mi: u64) bool {
    const materials = jArray(root, "materials") orelse return false;
    if (mi >= materials.len) return false;
    const mat = asObject(materials[mi]) orelse return false;
    const v = mat.get("alphaMode") orelse return false;
    const mode = switch (v) {
        .string => |str| str,
        else => return false,
    };
    return std.mem.eql(u8, mode, "BLEND") or std.mem.eql(u8, mode, "MASK");
}

fn findBaseColorFactor(root: std.json.ObjectMap, mi: u64) Error!u32 {
    const materials = jArray(root, "materials") orelse return 0xFFFF_FFFF;
    if (mi >= materials.len) return 0xFFFF_FFFF;
    const mat = asObject(materials[mi]) orelse return 0xFFFF_FFFF;
    const pbr = jObject(mat, "pbrMetallicRoughness") orelse return 0xFFFF_FFFF;
    const factor = jArray(pbr, "baseColorFactor") orelse return 0xFFFF_FFFF;
    if (factor.len < 4) return 0xFFFF_FFFF;
    // glTF stores LINEAR color; the framebuffer/texture path is sRGB-ish 8-bit.
    // A cheap, good-enough gamma encode (^(1/2.2)) keeps mid-tones from looking
    // muddy — matching how a texture (already sRGB-encoded) would have looked.
    var ch: [4]u8 = undefined;
    for (0..4) |i| {
        const lin = jFloat(factor[i]) orelse 1.0;
        const clamped = @max(0.0, @min(1.0, lin));
        const enc = if (i == 3) clamped else std.math.pow(f64, clamped, 1.0 / 2.2); // alpha stays linear
        ch[i] = @intFromFloat(@round(enc * 255.0));
    }
    // Pack R,G,B,A → 0xAARRGGBB.
    return (@as(u32, ch[3]) << 24) | (@as(u32, ch[0]) << 16) | (@as(u32, ch[1]) << 8) | @as(u32, ch[2]);
}

// ── std.json.Value helpers ───────────────────────────────────────────────

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn jObject(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return asObject(o.get(key) orelse return null);
}

fn jArray(o: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    return switch (o.get(key) orelse return null) {
        .array => |arr| arr.items,
        else => null,
    };
}

fn jString(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Non-negative integer field; null when ABSENT, error when present but
/// malformed (a negative/typed-wrong value must name its defect, not
/// silently become a spec default).
fn jInt(o: std.json.ObjectMap, key: []const u8) Error!?u64 {
    return switch (o.get(key) orelse return null) {
        .integer => |i| if (i >= 0) @as(u64, @intCast(i)) else Error.GlbBadJson,
        else => Error.GlbBadJson,
    };
}

/// A JSON number as f64 (a color component may parse as .integer `1` or .float
/// `0.5`). Null for a non-number — the caller substitutes the glTF default.
fn jFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}
