//! Model loading — a `.glb` file becomes GL objects a window can draw.
//!
//! Load chain: vfs.read → glb.parse (geometry) → png/jpeg.decode (base-colour texture,
//! if any) → GL buffers and a texture. Host-tested end to end against the real seed
//! assets through DrawSim (test/ui/assets/modelcache_test.zig); the kernel adds only the stack it
//! runs on.
//!
//! Everything after the load is the GPU's: the buffers and the texture live in VRAM, and
//! a frame reads them there. The CPU work below happens ONCE per model, at load — a
//! `.glb` is a file, and somebody has to turn a file into vertices.
//!
//! ## No shared cache
//!
//! Each window loads its own copy: **buffer and texture objects belong to a context**,
//! and every window has its own. Sharing across contexts is what EGL's share groups are
//! for, and ES 1.1 has no such thing. A model is a few hundred kilobytes.
//!
//! ## Indices are 32-bit
//!
//! glb.zig lays out every index as u32, and gles advertises OES_element_index_uint
//! (RND-004), so the element buffer uploads and draws as GL_UNSIGNED_INT with no
//! narrowing. A model past MAX_VERTS is still rejected loudly — that limit is an
//! allocation guard, not an index-width ceiling.

const std = @import("std");
const vfs = @import("vfs");
const gles = @import("gles");
const kgl = @import("kgl"); // the 2D toolkit — owns GL image upload
const ilog = @import("ilog");
pub const glb = @import("glb.zig");
/// PNG decode, re-exported: this module IS the asset pipeline's public
/// surface, and the wallpaper loader decodes through the same decoder the
/// model textures use.
pub const png = @import("png.zig");
/// JPEG decode, re-exported alongside png: callers that sniff a byte stream
/// reach both decoders through this one module, so png.zig/jpeg.zig stay a
/// single instance owned here rather than being pulled into a second module's
/// graph by a relative import.
pub const jpeg = @import("jpeg.zig");

/// Every load failure logs its reason (ilog seam — host-safe): a bad model shows an
/// in-window placeholder, which is PIXELS — without a log record the failure is
/// invisible to netdebug/bootlog and undiagnosable after the fact.
fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return ilog.puts("modelcache: (log overflow)\n");
    ilog.puts(s);
}

/// The most vertices a model may have. gles advertises OES_element_index_uint
/// (RND-004), so the index is 32-bit; this is an allocation guard against a
/// malformed or absurd file, not an index-width limit. The densest corpus asset (MetalRoughSpheres) is ~256k verts, so this
/// clears it with headroom while still bounding a runaway VBO.
pub const MAX_VERTS: usize = 1 << 20;

/// What glb.zig lays out, and what the vertex pointers below describe: position, texture
/// coordinate and normal, interleaved.
pub const STRIDE: gles.GLsizei = 32;
const OFF_POS: usize = 0;
const OFF_UV: usize = 12;
const OFF_NORMAL: usize = 20;

pub const Error = error{
    ModelMissing,
    ModelUnknownExtension,
    ModelTooManyVerts,
    ModelUploadFailed,
};

/// One drawable span of a model's index buffer with its own material — the GL
/// side of a glTF primitive (glb.Submesh). `tex` is 0 for a flat-white submesh.
pub const Sub = struct {
    first: gles.GLsizei, // first index (elements) into the shared IBO
    count: gles.GLsizei,
    tex: gles.GLuint, // 0 = untextured (flat white)
    blend: bool, // glTF alphaMode BLEND/MASK (spec R36)
    /// The glTF material maps (APP-011), texture names by gles.MatMap slot.
    /// All zero on the base-colour-only path. A submesh whose material carries
    /// ANY map gets all four materialized — absent ones synthesized as 1×1
    /// neutral texels from the material's factors — so the shading path never
    /// special-cases a hole.
    maps: [MAT_SLOTS]gles.GLuint = .{0} ** MAT_SLOTS,
};

/// gles.MatMap.COUNT, locally named: the material-map slots a submesh carries.
const MAT_SLOTS: usize = gles.MatMap.COUNT;

/// The glMaterialMapKUDOS selector for each gles.MatMap slot, in slot order.
const MAP_SELECTORS = [MAT_SLOTS]gles.GLenum{
    gles.GL_METAL_ROUGH_MAP_KUDOS,
    gles.GL_NORMAL_MAP_KUDOS,
    gles.GL_OCCLUSION_MAP_KUDOS,
    gles.GL_EMISSIVE_MAP_KUDOS,
};

/// The most submeshes one model may carry. Real assets stay well under this;
/// MetalRoughSpheres (the densest in the corpus) has under 100.
pub const MAX_SUBS: usize = 256;

/// One model, as GL objects in one context. Every field is owned by the context it was
/// loaded into and dies with it.
pub const Model = struct {
    vbo: gles.GLuint,
    ibo: gles.GLuint,
    cbo: gles.GLuint = 0, // per-vertex COLOR_0 array (RGBA8), 0 = none (no vertex tint)
    subs: [MAX_SUBS]Sub = undefined,
    sub_count: usize = 0,

    /// Bind this model's arrays and draw every submesh with its own material.
    /// Opaque submeshes first, then blended ones (depth writes off) so a
    /// translucent primitive composites over the opaque geometry behind it —
    /// the glTF ordering that makes AlphaBlendModeTest read correctly (R36).
    pub fn draw(self: Model, g: *gles.Context) void {
        gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, self.vbo);
        gles.bindBuffer(g, gles.GL_ELEMENT_ARRAY_BUFFER, self.ibo);

        gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
        gles.vertexPointer(g, 3, gles.GL_FLOAT, STRIDE, @ptrFromInt(OFF_POS));
        gles.enableClientState(g, gles.GL_NORMAL_ARRAY);
        gles.normalPointer(g, gles.GL_FLOAT, STRIDE, @ptrFromInt(OFF_NORMAL));
        gles.enableClientState(g, gles.GL_TEXTURE_COORD_ARRAY);
        gles.texCoordPointer(g, 2, gles.GL_FLOAT, STRIDE, @ptrFromInt(OFF_UV));

        // Per-vertex COLOR_0 (a SEPARATE tightly-packed RGBA8 array), when the
        // model carries it — modulates the material like glTF vertex colours
        // (VertexColorTest). Disabled otherwise so a prior model's colour array
        // never bleeds in (the fixed-function default colour is opaque white).
        if (self.cbo != 0) {
            gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, self.cbo);
            gles.enableClientState(g, gles.GL_COLOR_ARRAY);
            gles.colorPointer(g, 4, gles.GL_UNSIGNED_BYTE, 0, @ptrFromInt(0));
        } else {
            gles.disableClientState(g, gles.GL_COLOR_ARRAY);
        }

        self.drawPass(g, false); // opaque
        // Blended pass: straight-alpha blend, depth writes off so a translucent
        // surface does not occlude what is behind it, depth TEST still on.
        var any_blend = false;
        for (self.subs[0..self.sub_count]) |s| {
            if (s.blend) any_blend = true;
        }
        if (any_blend) {
            // Premultiplied-over (GL_ONE / GL_ONE_MINUS_SRC_ALPHA): the shader
            // outputs premultiplied colour for the translucent pass, so this is
            // straight-alpha-over of the un-premultiplied colour — and it is the
            // one blend the GPU path grounds (spec APP-010). Depth writes off so
            // a translucent surface does not occlude what is behind it.
            gles.enable(g, gles.GL_BLEND);
            gles.blendFunc(g, gles.GL_ONE, gles.GL_ONE_MINUS_SRC_ALPHA);
            gles.depthMask(g, 0);
            self.drawPass(g, true);
            gles.depthMask(g, 1);
            gles.disable(g, gles.GL_BLEND);
        }

        // The material maps are sticky context state (GL_KUDOS_material_maps):
        // clear every slot so the desktop's 2D draws that follow carry no model
        // material — the same hygiene as the client-state disables above.
        for (MAP_SELECTORS) |sel| gles.materialMap(g, sel, 0);
    }

    /// Draw the submeshes whose blend flag matches `blended`, binding each
    /// one's texture and material maps. The index offset is in BYTES (4 per
    /// u32 index).
    fn drawPass(self: Model, g: *gles.Context, blended: bool) void {
        for (self.subs[0..self.sub_count]) |s| {
            if (s.blend != blended) continue;
            if (s.tex != 0) {
                gles.enable(g, gles.GL_TEXTURE_2D);
                gles.bindTexture(g, gles.GL_TEXTURE_2D, s.tex);
            } else {
                gles.disable(g, gles.GL_TEXTURE_2D);
            }
            // Binding zero clears a slot, so a maps-less submesh resets the
            // sticky state a mapped predecessor left behind.
            for (MAP_SELECTORS, s.maps) |sel, h| gles.materialMap(g, sel, h);
            gles.drawElements(g, gles.GL_TRIANGLES, s.count, gles.GL_UNSIGNED_INT, @ptrFromInt(@as(usize, @intCast(s.first)) * 4));
        }
    }

    /// Give the objects back. The context would free them at teardown anyway, but a
    /// window that closes should not make its VRAM wait for that.
    pub fn deinit(self: Model, g: *gles.Context) void {
        var b = [_]gles.GLuint{ self.vbo, self.ibo };
        gles.deleteBuffers(g, 2, &b);
        if (self.cbo != 0) {
            var cb = [_]gles.GLuint{self.cbo};
            gles.deleteBuffers(g, 1, &cb);
        }
        // Each distinct texture object is freed once. Submeshes may share a
        // texture (same material), and a material-map slot may reuse another
        // submesh's upload, so every handle is checked against all that were
        // freed before it — base colour and maps alike.
        for (self.subs[0..self.sub_count], 0..) |s, i| {
            for (0..1 + MAT_SLOTS) |j| {
                const h = handleAt(s, j);
                if (h == 0) continue;
                var seen = false;
                for (self.subs[0 .. i + 1], 0..) |prev, pi| {
                    const jend: usize = if (pi == i) j else 1 + MAT_SLOTS;
                    for (0..jend) |pj| {
                        if (handleAt(prev, pj) == h) seen = true;
                    }
                }
                if (seen) continue;
                var t = [_]gles.GLuint{h};
                gles.deleteTextures(g, 1, &t);
            }
        }
    }

    /// Flatten a submesh's texture handles for the release scan: slot 0 is the
    /// base colour, slots 1.. are the material maps in gles.MatMap order.
    fn handleAt(s: Sub, j: usize) gles.GLuint {
        return if (j == 0) s.tex else s.maps[j - 1];
    }
};

/// Load `name` (a normalized absolute VFS path) into `g`'s objects.
///
/// Parse and upload run on the CALLER's stack — the app calls this from core 0's draw()
/// only, once per window.
pub fn load(a: std.mem.Allocator, g: *gles.Context, name: []const u8) Error!Model {
    if (!supportedName(name)) return Error.ModelUnknownExtension;
    // vfs.read returns the volume's SINGLE-SLOT buffer — valid only until the
    // next read on that volume (fat.zig header). glb.parse then borrows texture
    // bytes straight out of it and we hold them through parse + PNG/JPEG decode +
    // VRAM upload (tens of ms). Any other read on the same volume in that window
    // — another `show`, `cat`, the AI console reading AI.CFG — would free the slot
    // under us: a use-after-free into the GPU upload. Copy into memory we own
    // FIRST, honoring fat's "copy immediately" contract.
    // Loud load bracket: PBR-mapped models decode megapixels and push tens of
    // MiB to VRAM on this call — the start/done pair puts the cost on the
    // trace, where the netdebug timeline prices it.
    logf("modelcache: {s} loading\n", .{name});
    // GL errors are STICKY: an error someone recorded frames ago would surface
    // at this load's first check and frame an innocent upload. Drain it here,
    // loudly — a non-zero value at entry is somebody else's bug, named as such.
    const stale = gles.getError(g);
    if (stale != gles.GL_NO_ERROR) logf("modelcache: STALE glError 0x{x} at load entry (recorded before this load)\n", .{stale});
    const borrowed = vfs.read(name) orelse {
        logf("modelcache: {s} MISSING\n", .{name});
        return Error.ModelMissing;
    };
    const blob = a.dupe(u8, borrowed) catch return Error.ModelMissing;
    defer a.free(blob);
    const out = glb.parse(a, blob) catch |err| {
        logf("modelcache: {s} parse FAILED: {s}\n", .{ name, @errorName(err) });
        return Error.ModelMissing;
    };
    defer out.deinit(a);

    const vert_count = out.verts.len / 32;
    if (vert_count > MAX_VERTS) {
        logf("modelcache: {s} has {d} verts, past the {d}-vertex allocation guard\n", .{ name, vert_count, MAX_VERTS });
        return Error.ModelTooManyVerts;
    }

    if (out.submeshes.len > MAX_SUBS) {
        logf("modelcache: {s} has {d} submeshes, past the {d} cap\n", .{ name, out.submeshes.len, MAX_SUBS });
        return Error.ModelUploadFailed;
    }

    var m = Model{ .vbo = 0, .ibo = 0 };
    errdefer m.deinit(g);

    var bufs = [_]gles.GLuint{ 0, 0 };
    gles.genBuffers(g, 2, &bufs);
    m.vbo = bufs[0];
    m.ibo = bufs[1];

    gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, m.vbo);
    gles.bufferData(g, gles.GL_ARRAY_BUFFER, @intCast(out.verts.len), out.verts.ptr, gles.GL_STATIC_DRAW);

    // Upload glb's 32-bit indices as-is: gles advertises OES_element_index_uint
    // (RND-004), so the element buffer is drawn with GL_UNSIGNED_INT and no
    // narrowing is needed (out.indices is already index_count u32, little-endian).
    gles.bindBuffer(g, gles.GL_ELEMENT_ARRAY_BUFFER, m.ibo);
    gles.bufferData(g, gles.GL_ELEMENT_ARRAY_BUFFER, @intCast(out.indices.len), out.indices.ptr, gles.GL_STATIC_DRAW);

    // Per-vertex COLOR_0 (glTF vertex colours): its own tightly-packed RGBA8
    // buffer, uploaded only when the model carries it — the untinted common case
    // adds no buffer and leaves the vertex format untouched.
    if (out.colors) |cols| {
        var cbuf = [_]gles.GLuint{0};
        gles.genBuffers(g, 1, &cbuf);
        m.cbo = cbuf[0];
        gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, m.cbo);
        gles.bufferData(g, gles.GL_ARRAY_BUFFER, @intCast(cols.len), cols.ptr, gles.GL_STATIC_DRAW);
    }

    // One GL submesh per glTF primitive, each with its own material texture
    // uploaded once. Submeshes sharing a base-colour image reuse the texture
    // (dedup by the borrowed byte slice, so a 5-sphere-material file is 5
    // textures, not 5×primitives).
    for (out.submeshes, 0..) |sm, i| {
        var tex: gles.GLuint = 0;
        if (sm.tex) |tex_bytes| {
            // Reuse an earlier submesh's texture if it decoded the same bytes —
            // AND baked the same base-colour factor: a shared image under
            // different factors bakes to different pixels (the maps path makes
            // the same distinction).
            tex = for (out.submeshes[0..i], 0..) |prev, pi| {
                if (prev.tex) |pb| {
                    if (pb.ptr == tex_bytes.ptr and pb.len == tex_bytes.len and prev.base_color == sm.base_color) break m.subs[pi].tex;
                }
            } else blk: {
                const img = switch (sm.tex_mime) {
                    .png => png.decode(a, tex_bytes) catch {
                        logf("modelcache: base PNG decode FAILED ({d} bytes)\n", .{tex_bytes.len});
                        return Error.ModelUploadFailed;
                    },
                    .jpeg => jpeg.decode(a, tex_bytes) catch {
                        logf("modelcache: base JPEG decode FAILED ({d} bytes)\n", .{tex_bytes.len});
                        return Error.ModelUploadFailed;
                    },
                };
                defer img.deinit(a);
                // glTF base colour is factor × texture (bakeBaseColor is a
                // no-op for the white factor).
                bakeBaseColor(img.bgra, sm.base_color);
                break :blk try uploadImage(g, @intCast(img.w), @intCast(img.h), img.bgra);
            };
        } else if (sm.base_color != 0xFFFF_FFFF) {
            // Untextured non-white base colour → a 2×2 solid the same path samples.
            var solid: [4]u32 = .{ sm.base_color, sm.base_color, sm.base_color, sm.base_color };
            tex = try uploadImage(g, 2, 2, std.mem.sliceAsBytes(solid[0..]));
        }
        // The material maps (APP-011): a submesh whose material carries ANY of
        // the four enters the maps path with all four materialized — absent
        // ones synthesized from the material's factors — so the shading path
        // never special-cases a hole. Factor-only materials (no maps at all)
        // stay on the base-colour path unchanged. The sub is recorded FIRST and
        // each map handle lands in it as produced, so a failure mid-way leaves
        // every created texture where errdefer's deinit can free it.
        m.subs[i] = .{ .first = @intCast(sm.index_offset), .count = @intCast(sm.index_count), .tex = tex, .blend = sm.blend };
        m.sub_count = i + 1;
        if (hasAnyMap(sm)) {
            for (0..MAT_SLOTS) |slot| m.subs[i].maps[slot] = try mapTexture(a, g, out.submeshes, &m, i, slot);
        }
    }

    if (gles.getError(g) != gles.GL_NO_ERROR) return Error.ModelUploadFailed;
    logf("modelcache: {s} loaded ({d} verts, {d} submeshes)\n", .{ name, vert_count, m.sub_count });
    return m;
}

/// Upload a decoded image.
///
/// The decoders produce BGRA, and kgl.uploadImage takes exactly that
/// (GL_BGRA_EXT, spec RND-008) — stored verbatim, sampled true-colour. (This
/// path once mislabeled the bytes GL_RGBA on a double-swap theory; every
/// decoded texture rendered with red and blue exchanged, on both backends —
/// the render oracle caught it by the Duck turning cyan.)
/// Image upload lives in kgl (one home for it); this wrapper adds the
/// GL-error check this module's error set expects, and rebinds the wrap mode
/// to GL_REPEAT: kgl clamps for its UI images, but a glTF sampler defaults
/// to repeat, and models depend on it (some models' V coordinates run
/// 1..2 — clamping pins every sample to the atlas edge; the GPU backend's
/// samplers already repeat-wrap, so this keeps the soft mirror in step).
fn uploadImage(g: *gles.Context, w: gles.GLsizei, h: gles.GLsizei, bgra: []const u8) Error!gles.GLuint {
    const t = kgl.uploadImage(g, @intCast(w), @intCast(h), bgra);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, gles.GL_REPEAT);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, gles.GL_REPEAT);
    const e = gles.getError(g);
    if (e != gles.GL_NO_ERROR) {
        // Name the failing stage: which upload, how big, which GL error — the
        // one line that tells VRAM-heap, staging-OOM and protocol bugs apart.
        logf("modelcache: upload {d}x{d} FAILED (glError 0x{x})\n", .{ w, h, e });
        return Error.ModelUploadFailed;
    }
    return t;
}

/// Does this submesh's material carry any of the four maps? Deciding gate for
/// the maps path — factor-only materials stay on the base-colour path.
fn hasAnyMap(sm: glb.Submesh) bool {
    for (0..MAT_SLOTS) |slot| {
        if (locatedMap(sm, slot) != null) return true;
    }
    return false;
}

/// The located image for one gles.MatMap slot of a glTF submesh, or null when
/// the material omits that map.
fn locatedMap(sm: glb.Submesh, slot: usize) ?glb.LocatedTex {
    return switch (@as(gles.MatMap, @enumFromInt(slot))) {
        .metal_rough => sm.metallic_roughness_map,
        .normal => sm.normal_map,
        .occlusion => sm.occlusion_map,
        .emissive => sm.emissive_map,
    };
}

/// One material-map texture for submesh `i`, slot `slot`: a previous submesh's
/// upload when the same image bakes to the same pixels, else a fresh decode +
/// factor bake + upload. An absent map synthesizes the material's 1×1 neutral
/// texel, so the maps path never has a hole (APP-011).
fn mapTexture(a: std.mem.Allocator, g: *gles.Context, subs: []const glb.Submesh, m: *Model, i: usize, slot: usize) Error!gles.GLuint {
    const sm = subs[i];
    const located = locatedMap(sm, slot) orelse {
        var texel = neutralTexel(sm, slot);
        return try uploadImage(g, 1, 1, texel[0..]);
    };
    // Reuse an earlier submesh's upload only when it decoded the same bytes AND
    // baked them with the same factors — a shared image under different factors
    // is a different texture.
    for (subs[0..i], 0..) |prev, pi| {
        const pl = locatedMap(prev, slot) orelse continue;
        if (pl.bytes.ptr != located.bytes.ptr or pl.bytes.len != located.bytes.len) continue;
        const same_bake = switch (@as(gles.MatMap, @enumFromInt(slot))) {
            .metal_rough => prev.metallic == sm.metallic and prev.roughness == sm.roughness,
            .emissive => prev.emissive[0] == sm.emissive[0] and prev.emissive[1] == sm.emissive[1] and prev.emissive[2] == sm.emissive[2],
            .normal, .occlusion => true,
        };
        if (same_bake and m.subs[pi].maps[slot] != 0) return m.subs[pi].maps[slot];
    }
    const img = switch (located.mime) {
        .png => png.decode(a, located.bytes) catch {
            logf("modelcache: map slot {d} PNG decode FAILED ({d} bytes)\n", .{ slot, located.bytes.len });
            return Error.ModelUploadFailed;
        },
        .jpeg => jpeg.decode(a, located.bytes) catch {
            logf("modelcache: map slot {d} JPEG decode FAILED ({d} bytes)\n", .{ slot, located.bytes.len });
            return Error.ModelUploadFailed;
        },
    };
    defer img.deinit(a);
    switch (@as(gles.MatMap, @enumFromInt(slot))) {
        .metal_rough => bakeMetalRough(img.bgra, sm.metallic, sm.roughness),
        .emissive => bakeEmissive(img.bgra, sm.emissive),
        .normal, .occlusion => {},
    }
    return try uploadImage(g, @intCast(img.w), @intCast(img.h), img.bgra);
}

/// Multiply the metallic (B) and roughness (G) channels of a decoded BGRA
/// metallic-roughness image by the material's factors, in place. glTF defines
/// the sampled value as factor × texel; both are constant per material, so the
/// product is baked once at load and the shader samples it directly — no
/// factor uniforms exist anywhere downstream.
pub fn bakeMetalRough(bgra: []u8, metallic: f32, roughness: f32) void {
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) {
        bgra[i] = glb.f2u8(@as(f32, @floatFromInt(bgra[i])) / 255.0 * metallic); // B = metallic
        bgra[i + 1] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 1])) / 255.0 * roughness); // G = roughness
    }
}

/// Multiply a decoded BGRA base-colour image by the material's baseColorFactor
/// (packed 0xAARRGGBB), in place — glTF defines base colour as factor × texel,
/// and the factor is constant per material, so the product bakes once at load
/// exactly as bakeMetalRough's does. All four channels scale: the factor's
/// alpha participates in the material's alpha mode.
pub fn bakeBaseColor(bgra: []u8, base_color: u32) void {
    if (base_color == 0xFFFF_FFFF) return; // white × texel = texel
    const fb: f32 = @floatFromInt(base_color & 0xFF);
    const fg: f32 = @floatFromInt((base_color >> 8) & 0xFF);
    const fr: f32 = @floatFromInt((base_color >> 16) & 0xFF);
    const fa: f32 = @floatFromInt((base_color >> 24) & 0xFF);
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) {
        bgra[i] = glb.f2u8(@as(f32, @floatFromInt(bgra[i])) / 255.0 * fb / 255.0); // B
        bgra[i + 1] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 1])) / 255.0 * fg / 255.0); // G
        bgra[i + 2] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 2])) / 255.0 * fr / 255.0); // R
        bgra[i + 3] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 3])) / 255.0 * fa / 255.0); // A
    }
}

/// Multiply a decoded BGRA emissive image by the material's emissiveFactor
/// (linear RGB), in place — the same bake-at-load reasoning as bakeMetalRough.
pub fn bakeEmissive(bgra: []u8, factor: [3]f32) void {
    var i: usize = 0;
    while (i < bgra.len) : (i += 4) {
        bgra[i] = glb.f2u8(@as(f32, @floatFromInt(bgra[i])) / 255.0 * factor[2]); // B
        bgra[i + 1] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 1])) / 255.0 * factor[1]); // G
        bgra[i + 2] = glb.f2u8(@as(f32, @floatFromInt(bgra[i + 2])) / 255.0 * factor[0]); // R
    }
}

/// The 1×1 BGRA texel standing in for an absent map: the factors themselves for
/// metal-rough and emissive (glTF: no texture means the factor alone), the
/// identity for normal (flat +Z) and occlusion (unoccluded).
pub fn neutralTexel(sm: glb.Submesh, slot: usize) [4]u8 {
    return switch (@as(gles.MatMap, @enumFromInt(slot))) {
        .metal_rough => .{ glb.f2u8(sm.metallic), glb.f2u8(sm.roughness), 255, 255 },
        .normal => .{ 255, 128, 128, 255 }, // BGRA of RGB (0.5, 0.5, 1.0)
        .occlusion => .{ 255, 255, 255, 255 },
        .emissive => .{ glb.f2u8(sm.emissive[2]), glb.f2u8(sm.emissive[1]), glb.f2u8(sm.emissive[0]), 255 },
    };
}

/// Extension gate for the `show` command (single owner of the format list):
/// binary .glb and JSON .gltf (glTF-Embedded, base64 data URIs).
pub fn supportedName(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".glb") or std.mem.endsWith(u8, name, ".gltf");
}
