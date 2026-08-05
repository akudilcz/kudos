//! OpenGl — the real IDraw device on the RTX 4090's graphics (GR) engine
//! (contract: src/iface/idraw.zig). It renders the desktop the same way the software
//! backend (soft.zig) does — every window, its chrome, the dock, app content — except
//! the pixels are produced by the card instead of the CPU. The two are interchangeable
//! implementations of one seam; `gles` does not know which is under it.
//!
//! ## What it drives, and why that set
//!
//! The whole user interface reaches this through `gles`, and the 2D toolkit above `gles`
//! (kgl) speaks one small dialect: non-indexed triangles, three float attributes
//! (position, colour, texture coordinate), one texture sampled and MODULATED by the
//! vertex colour, composited with premultiplied-alpha blending. A flat fill samples a
//! 1x1 white texel, a glyph samples coverage, an image samples itself — one program
//! (`v_mvp_tex_col` + `f_tex_modulate`) serves all three.
//!
//! Everything the desktop draws is in that dialect, so that is what this file implements
//! completely. A draw outside it — lit 3D geometry, an indexed mesh, a non-triangle
//! primitive, a blend equation other than premultiplied-over — is REFUSED with
//! `DrawOutOfResources` rather than approximated: the window shows a placeholder, and no
//! guessed method stream reaches the engine. Those paths are the next increment (lit
//! geometry reuses the proven `f_tex_blinnphong`), gated behind the same hardware
//! validation as this one.
//!
//! ## The frame pipeline
//!
//! A context is one window's private frame pipeline. `endFrame` kicks the GR render from
//! the context's OWN pushbuffer, then queues a CE de-tile of the rendered rectangle into
//! the window's VRAM mirror (the surface the compositor samples), gated GPU-side on the
//! render's fence — render → de-tile happens entirely on the card, no CPU in the middle.
//! N contexts queue concurrently and none waits on another; the only per-frame CPU work
//! is method emission plus one fence poll. This machinery, and the pool/pump/mirror
//! plumbing around it, is the same the mesh device proved during bring-up.
//!
//! Anti-aliasing (DSK-009): the scene renders at 8x MSAA into the device's one shared
//! sample-extent scratch pair; endFrame then appends a resolve pass — a fullscreen
//! triangle averaging the 8 samples per pixel — into the context's own 1x block-linear
//! target, and the CE de-tile ships that resolved surface to the window's mirror.
//! Scene and resolve live in the same push, so the pair executes atomically per frame
//! even with the scratch shared across contexts.

const std = @import("std");
const log = @import("../gpu/base/log.zig").gpu;
const tsc = @import("../../kernel/cpu/tsc.zig");
const gsp = @import("../gpu/gsp/gsp.zig");
const fifo = @import("../gpu/core/fifo.zig");
const gmmu = @import("../gpu/core/gmmu.zig");
const vram = @import("../gpu/core/vram.zig");
const shim = @import("../gpu/base/shim.zig");
const ce = @import("../gpu/core/ce.zig");
const present = @import("../gpu/present/present.zig");
const counter = @import("../../kernel/debug/counter.zig");
const hostpush = @import("hostpush");
const idraw = @import("idraw");
const gr_mod = @import("engine/gr.zig");
const methods = @import("ada/methods.zig");
const shaders = @import("engine/shaders.zig");
const tex = @import("ada/tex.zig");
const til = @import("ada/til.zig");
const lower = @import("ada/lower.zig");

// Every context's target is panel-sized (the ultrawide): a window's viewport always
// equals its content size, so the projection centre sits at the window's middle and the
// de-tile copies exactly the drawn rectangle out.
const RT_W: u32 = idraw.MAX_W;
const RT_H: u32 = idraw.MAX_H;
const MAX_CTX: u32 = idraw.MAX_CTX;

/// The GR pushbuffer is many pages, not one: the compositor draws the whole desktop in a
/// single frame — wallpaper, every window's frame and content, the dock, and with the
/// heads-up display open its panels, traces and counter wall on top. Each 2D draw
/// records ~300 bytes of methods, so this budget is the frame's draw-call capacity:
/// 256 KiB holds several hundred draws, and it fills the whole
/// GL_CTX_GRPUSH_OFF..GL_CTX_GRSEM_OFF window, which is the hard bound on growing it.
/// A draw past the budget is refused and counted (gpu.draws_dropped), never silent.
const GR_PUSH_BYTES: u32 = 0x40000;

/// Where the shader programs bind. The vertex and pixel pipeline slots are fixed by the
/// class (methods.SLOT_VERTEX / SLOT_PIXEL). The bind groups are the mesa/NAK convention
/// the blobs were compiled against: cb0 (the push-constant block carrying the MVP) binds
/// to group 0 for the vertex stage and group 4 for the fragment stage; the texture-handle
/// descriptor cbuf binds to group 4 slot 1. This is the exact binding the proven textured
/// shaders used.
const CB_GROUP_VS: u32 = 0;
const CB_GROUP_FS: u32 = 4;
const TEX_DESC_SLOT: u32 = 1;
/// The MVP matrix lands in cb0 at the push-constant offset the shaders' `pc_layout.glsl`
/// fixes (0x28). Only the MVP is read by the 2D program, so only its 16 words are written.
const PC_MVP_OFFSET: u32 = 0x28;
/// The texture-handle descriptor cbuf sits inside the context's cb page, away from cb0.
const TEX_DESC_OFF: u64 = 0x800;

const MAX_BUF: usize = 64;
const MAX_TEX: usize = 64;
/// TIC pool slots: 0 is the built-in white default, 1 is the 8x MSAA scene surface the
/// resolve pass samples, and 2.. are `textureCreate`d images — one slot per
/// texture-table entry (slot i ↔ TIC TIC_USER_BASE+i, reused for life).
const TIC_WHITE: u32 = 0;

/// Descriptor byte offsets inside the TEX_DESC window for f_pbr's extra samplers
/// (GL_KUDOS_material_maps, spec RND-005): the metal-rough map rides binding 1 —
/// the 4-byte word after the base sampler — and normal/occlusion/emissive ride
/// bindings 3-5, which NVK lays out at bytes 32/36/40, past the 16-byte-aligned
/// state-UBO descriptor. Proven by a probe compile against the pinned toolchain
/// (a binding-5 sampler's TEX immediate reads word 10).
const MR_DESC_BYTE_OFF: u32 = 4;
const EXTRA_MAPS_DESC_BYTE_OFF: u32 = 32;
const TIC_MSAA: u32 = 1;
const TIC_USER_BASE: u32 = 2;
/// Where the resolve pass's texture-handle word lives in the context's cb page —
/// its own word, apart from the scene draws' TEX_DESC_OFF, preloaded at mapSlot
/// (it never changes: it always names the MSAA TIC).
const RESOLVE_DESC_OFF: u64 = 0x900;
/// Largest texture edge the sampler accepts here. This caps what a TIC will be asked
/// to describe — it is NOT the render-target cap (RT_W/RT_H); a texture is only ever
/// fetched, so a 9×1805 glyph atlas is legal.
const MAX_TEX_DIM: u32 = 16384;

// ── the VRAM sub-allocator with a real free (extent_heap.zig) ────────────────
//
// The device's `valloc` is a bump allocator with no free, which is correct for things
// that live for the GPU session (targets, the shader image) but wrong for GL buffers and
// textures: `glBufferData` releases and re-creates its store, and the 2D toolkit
// re-uploads its vertex data every frame, so a bump allocator would leak the whole vertex
// array per frame and exhaust VRAM in seconds. So GL resources come from
// extent_heap.ExtentHeap — a first-fit free list over one region mapped 1:1 at init,
// coalescing neighbours on free (pure, host-tested).
const extent_heap = @import("extent_heap.zig");

const Buffer = struct {
    alive: bool = false,
    va: u64 = 0,
    size: u64 = 0, // rounded allocation size (for free)
    used: u64 = 0, // bytes the caller asked for (the stream extent)
};

const Texture = struct {
    alive: bool = false,
    tic: u32 = 0,
    va: u64 = 0,
    size: u64 = 0,
    w: u32 = 0,
    h: u32 = 0,
    pitch: u32 = 0,
};

const Phase = enum { idle, rendering, detiling };

/// One pool slot: a window's private frame pipeline. Slot resources are created on the
/// slot's first acquire and reused forever after (the per-slot VA offsets never move).
const Ctx = struct {
    slot: u32,
    in_use: bool,
    mapped: bool,
    map_failed: bool,
    dst: idraw.Dst,

    rt_layout: til.Layout,
    cb_phys: u64,
    gr_push_phys: u64,
    gr_sem_phys: u64,
    ce_push_phys: u64,
    ce_sem_phys: u64,

    phase: Phase,
    recording: bool,
    abandoned: bool,
    landed: bool,
    w: u32,
    h: u32,
    // The viewport/scissor state most recently EMITTED into this frame's push, so a
    // draw re-emits only on change: the whole-desktop frame confines each window's 3D
    // to its content rect this way, while runs of 2D draws (all full-frame) add nothing.
    cur_vp: idraw.Rect,
    cur_sc: ?idraw.Rect,

    // Diagnostics (GLSTAT).
    n_kicked: u32,
    n_landed: u32,
    n_busy: u32,
    n_mirror_miss: u32,
    // Kicks refused by a wedged FIFO ring (fifo.Error out of submit/kickChannel).
    // The dropped kick's fence never retires, so the context stays in its phase and
    // every later beginFrame reports DrawBusy; a nonzero count here is what tells a
    // GLSTAT reader "the ring wedged" apart from "the frame is merely in flight".
    n_kick_fail: u32,
    t_kick: u64,
    lat_sum: u64,
    lat_max: u64,
    lat_n: u32,

    p: hostpush.HostPush,
    gr_want: u32,
    ce_want: u32,
    ce_fence: u32,

    fn va(self: *const Ctx, off: u64) u64 {
        return gmmu.VA_GL_CTX0 + @as(u64, self.slot) * gmmu.VA_GL_CTX_STRIDE + off;
    }

    fn iface(self: *Ctx) idraw.IDrawCtx {
        return .{ .ctx = self, .vtable = &ctx_vtable };
    }

    const ctx_vtable = idraw.IDrawCtx.VTable{
        .beginFrame = vtBeginFrame,
        .clear = vtClear,
        .draw = vtDraw,
        .readPixels = vtReadPixels,
        .endFrame = vtEndFrame,
        .frameReady = vtFrameReady,
        .discard = vtDiscard,
    };

    fn cast(ctx: *anyopaque) *Ctx {
        return @ptrCast(@alignCast(ctx));
    }
    fn vtBeginFrame(ctx: *anyopaque, w: u32, h: u32) idraw.Error!void {
        return cast(ctx).beginFrame(w, h);
    }
    fn vtClear(ctx: *anyopaque, m: idraw.ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?idraw.Rect) idraw.Error!void {
        return cast(ctx).clear(m, color, depth, stencil, sc);
    }
    fn vtDraw(ctx: *anyopaque, p: *const idraw.Pipeline, d: *const idraw.Draw) idraw.Error!void {
        return cast(ctx).draw(p, d);
    }
    fn vtReadPixels(ctx: *anyopaque, r: idraw.Rect, fmt: idraw.ReadFormat, dst: []u8) idraw.Error!void {
        _ = cast(ctx);
        _ = r;
        _ = fmt;
        _ = dst;
        // glReadPixels is the one blocking call in the contract, and the desktop path
        // never issues it (the compositor samples the mirror directly). Implementing it
        // means a CE copy of the target to sysmem plus a wait; it lands with the lit path,
        // not before, so refuse rather than return uninitialised bytes.
        return idraw.Error.DrawDeviceLost;
    }
    fn vtEndFrame(ctx: *anyopaque) idraw.Error!void {
        return cast(ctx).endFrame();
    }
    fn vtFrameReady(ctx: *anyopaque) bool {
        const self = cast(ctx);
        self.pump();
        return self.landed;
    }
    fn vtDiscard(ctx: *anyopaque) void {
        cast(ctx).discardFrame();
    }

    fn beginFrame(self: *Ctx, w: u32, h: u32) idraw.Error!void {
        if (w == 0 or h == 0 or w > RT_W or h > RT_H) return idraw.Error.DrawBadViewport;
        self.pump();
        if (self.recording or self.phase != .idle) {
            self.n_busy += 1;
            return idraw.Error.DrawBusy;
        }
        self.recording = true;
        self.landed = false;
        self.w = w;
        self.h = h;
        // Open the frame's push and program the state every draw in it shares. The scene
        // renders at 8x MSAA into the device's ONE shared sample-extent scratch pair —
        // safe to share across contexts because a frame is a single push, executed
        // atomically by the in-order GR channel: scene and resolve cannot interleave
        // with another context's. endFrame resolves the 8 samples into this context's
        // own 1x target, which is what the de-tile ships to the screen — that resolve is
        // where the chrome's rounded edges get their smoothness.
        self.p = hostpush.HostPush.init(self.gr_push_phys, GR_PUSH_BYTES);
        const p = &self.p;
        methods.ctSelect(p, 1);
        methods.colorTargetBlMsaa(p, gmmu.VA_GL_MSAA_RT, device.msaa_rt_layout.row_stride_bytes / 4, RT_H * 2, device.msaa_rt_layout.bh_log2, device.msaa_rt_layout.size_bytes, w, h);
        // The depth target shares the sample extent (a lit draw tests it; 2D leaves the
        // test off per draw). Both targets block-linear — a pitch colour target with a
        // bound Z wedges the engine.
        methods.depthTargetBl(p, gmmu.VA_GL_MSAA_ZT, device.msaa_zt_layout.row_stride_bytes / 4, RT_H * 2, device.msaa_zt_layout.bh_log2);
        methods.depthTestOff(p);
        methods.setAntiAlias(p, methods.AA_MODE_4X2_D3D);
        methods.setAaSamplePositions8x(p);
        methods.viewportFull(p, w, h);
        self.cur_vp = .{ .x = 0, .y = 0, .w = w, .h = h };
        self.cur_sc = null;
        // Bind the TIC/TSC pools so a texture-sampling draw can fetch its descriptor — an
        // unbound pool makes the sampler read a bogus header and stalls the SM with no Xid.
        methods.texPools(p, gmmu.VA_GL_TICPOOL, TIC_USER_BASE + @as(u32, MAX_TEX), gmmu.VA_GL_TICPOOL + 0x400, 1);
        // NAK root cbuf (cb0): the compiled shaders read a per-sample coverage mask at +24;
        // on a zeroed cb page that reads as "no samples", so every fragment is discarded.
        // Single-sampled means one enabled sample — all-ones. The +16 sample positions are
        // inert at 1x1 but the shader still reads the two words, so give it something.
        methods.bindCb0(p, self.va(gmmu.GL_CTX_CB_OFF), 0x1000);
        methods.loadCb(p, 16, &.{ methods.AA_8X_POSITIONS[0], methods.AA_8X_POSITIONS[1], 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF });
    }

    fn clear(self: *Ctx, m: idraw.ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?idraw.Rect) idraw.Error!void {
        _ = stencil;
        _ = sc;
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        // A scissored clear is not something the desktop asks for; the full-target clear is
        // what both the compositor (colour only) and the model viewer (colour + depth) use.
        const p = &self.p;
        if (m.color and m.depth) {
            methods.clearColorDepth(p, color[0], color[1], color[2], color[3], depth);
        } else if (m.color) {
            methods.clearColor(p, color[0], color[1], color[2], color[3]);
        } else if (m.depth) {
            methods.clearZOnly(p, depth);
        }
    }

    fn draw(self: *Ctx, p: *const idraw.Pipeline, d: *const idraw.Draw) idraw.Error!void {
        if (!self.recording) return idraw.Error.DrawDeviceLost;

        // Three dialects share this path: the compositor's flat 2D, the model
        // viewer's lit geometry, and lit geometry carrying the glTF material maps
        // (GL_KUDOS_material_maps, spec RND-005). All are triangles, float
        // attributes and the proven push-constant binding — they differ only in
        // the program, the sampler set, and whether depth is tested. Anything
        // else (non-triangles, an unsupported blend equation) is refused rather
        // than approximated.
        if (d.prim != .triangles) return idraw.Error.DrawOutOfResources;
        if (p.blend.enable and !lower.blendIsPremultOver(p.blend)) {
            // The card blends only premultiplied-over (the one grounded coefficient
            // set); anything else is refused rather than mis-emitted from an
            // unverified constant. Name it ONCE so the refusal is never a silent
            // GL_OUT_OF_MEMORY — this is how the model viewer's straight-alpha
            // translucent pass currently reads on hardware (APP-010; the fix is a
            // premultiplied-alpha model path, tracked separately).
            if (!blend_refusal_logged) {
                blend_refusal_logged = true;
                log("gl.opengl: blend {s}/{s} REFUSED — only premultiplied-over is grounded; draw dropped (APP-010 needs a premultiplied model path)\n", .{ @tagName(p.blend.src), @tagName(p.blend.dst) });
            }
            return idraw.Error.DrawOutOfResources;
        }
        const lit = p.key.lights != 0;
        const maps = lit and anyMatMap(p);

        const dev = device;
        const vs = dev.up.find(if (lit) "v_norm_lit" else "v_mvp_tex_col") orelse return idraw.Error.DrawOutOfResources;
        const fs = dev.up.find(if (maps) "f_pbr" else if (lit) "f_tex_blinnphong" else "f_tex_modulate") orelse return idraw.Error.DrawOutOfResources;

        // The texture this draw samples: the bound unit's, or the built-in white default
        // (a flat fill and an untextured model both sample white so the one program's
        // texel * colour reduces to the colour they want).
        var tic: u32 = TIC_WHITE;
        if (p.key.units >= 1) {
            if (p.units[0]) |u| {
                if (u.texture == 0 or u.texture > MAX_TEX or !dev.textures[u.texture - 1].alive)
                    return idraw.Error.DrawBadTexture;
                tic = dev.textures[u.texture - 1].tic;
            }
        }

        // The material-map handles, resolved like the base unit; each null slot
        // falls back to its neutral-identity TIC (idraw.MatMap order: metal-rough
        // white, normal flat +Z, occlusion white, emissive black).
        var map_tics = [4]u32{ TIC_WHITE, dev.tic_flat_normal, TIC_WHITE, dev.tic_black };
        if (maps) {
            for (p.mat_maps, 0..) |mm, i| {
                const u = mm orelse continue;
                if (u.texture == 0 or u.texture > MAX_TEX or !dev.textures[u.texture - 1].alive)
                    return idraw.Error.DrawBadTexture;
                map_tics[i] = dev.textures[u.texture - 1].tic;
            }
        }

        const push = &self.p;
        // Guard the frame's push page. Refuse the draw that would overflow rather than let
        // HostPush panic — the shape goes missing from this frame, it does not crash the
        // kernel — and count it: the caller swallows the error (GL records a flag nobody
        // reads mid-frame), so this counter is the only witness that pixels were lost.
        if (push.bytes() + 0x400 > GR_PUSH_BYTES) {
            cnt_draws_dropped.inc();
            return idraw.Error.DrawOutOfResources;
        }

        // The pipeline's viewport/scissor, emitted on change: this is how one frame
        // hosts both the full-screen 2D pass and each window's inline 3D (confined to
        // its content rectangle).
        const vp = p.viewport;
        if (vp.x != self.cur_vp.x or vp.y != self.cur_vp.y or vp.w != self.cur_vp.w or vp.h != self.cur_vp.h) {
            methods.viewportAt(push, vp.x, vp.y, vp.w, vp.h);
            self.cur_vp = vp;
        }
        const sc_changed = blk: {
            const a = p.scissor orelse break :blk self.cur_sc != null;
            const b = self.cur_sc orelse break :blk true;
            break :blk a.x != b.x or a.y != b.y or a.w != b.w or a.h != b.h;
        };
        if (sc_changed) {
            if (p.scissor) |sc| methods.scissorAt(push, sc.x, sc.y, sc.w, sc.h) else methods.scissorOff(push);
            self.cur_sc = p.scissor;
        }

        methods.pipelineShader(push, methods.SLOT_VERTEX, vs.gprs, CB_GROUP_VS, vs.va);
        methods.pipelineShader(push, methods.SLOT_PIXEL, fs.gprs, CB_GROUP_FS, fs.va);
        methods.invalidateShaderCaches(push);

        // Vertex attributes. Each enabled array attribute is its own stream (gles gathers
        // each into its own tightly-packed region of one staging buffer), bound at the
        // shader-input location that equals its AttribSlot index. A disabled or constant
        // attribute falls back to the vertex-stream substitute the channel init set.
        for (d.attribs, 0..) |attrib, i| {
            const arr = switch (attrib) {
                .array => |a| a,
                .disabled, .constant => continue,
            };
            if (arr.buffer == 0 or arr.buffer > MAX_BUF or !dev.buffers[arr.buffer - 1].alive)
                return idraw.Error.DrawBadBuffer;
            const fmt = lower.attribFormat(arr.format) orelse return idraw.Error.DrawOutOfResources;
            const b = dev.buffers[arr.buffer - 1];
            const slot: u32 = @intCast(i);
            methods.vertexStreamAt(push, slot, b.va + arr.offset, arr.stride, b.used - arr.offset);
            methods.vertexAttribAt(push, slot, slot, 0, fmt);
        }

        // The push-constant block into cb0: the MVP for the flat program, or the full
        // marshalled lighting block for the lit one. Written in <=16-word runs (the class
        // hangs on a longer LOAD run).
        methods.bindCb0(push, self.va(gmmu.GL_CTX_CB_OFF), 0x1000);
        var pc: [64]u32 = undefined;
        const n_words = marshalPc(p.uniforms, lit, p.blend.enable, &pc);
        var off: u32 = 0;
        while (off < n_words) : (off += 16) {
            const end = @min(off + 16, n_words);
            methods.loadCb(push, PC_MVP_OFFSET + off * 4, pc[off..end]);
        }

        // The texture handle into the descriptor cbuf, then re-select cb0 (LOAD goes
        // through whichever cbuf is selected, so it must end on cb0).
        methods.bindCbSlot(push, self.va(gmmu.GL_CTX_CB_OFF) + TEX_DESC_OFF, 0x100, CB_GROUP_FS, TEX_DESC_SLOT);
        methods.loadCb(push, 0, &.{tex.handle(tic, 0)});
        if (maps) {
            // f_pbr's remaining samplers: metal-rough on binding 1, then
            // normal/occlusion/emissive contiguous on bindings 3-5.
            methods.loadCb(push, MR_DESC_BYTE_OFF, &.{tex.handle(map_tics[0], 0)});
            methods.loadCb(push, EXTRA_MAPS_DESC_BYTE_OFF, &.{
                tex.handle(map_tics[1], 0),
                tex.handle(map_tics[2], 0),
                tex.handle(map_tics[3], 0),
            });
        }
        methods.bindCb0(push, self.va(gmmu.GL_CTX_CB_OFF), 0x1000);

        // Per-fragment state.
        if (p.blend.enable) methods.blendPremultOn(push) else methods.blendOff(push);
        if (p.depth.test_enable) methods.depthTestOn(push) else methods.depthTestOff(push);

        // The draw itself — indexed when the caller bound an index buffer (the model
        // viewer draws u16-indexed triangles), sequential otherwise (the 2D toolkit).
        if (d.index) |ix| {
            if (ix.buffer == 0 or ix.buffer > MAX_BUF or !dev.buffers[ix.buffer - 1].alive)
                return idraw.Error.DrawBadBuffer;
            const ib = dev.buffers[ix.buffer - 1];
            const width: u64 = switch (ix.type) {
                .u8 => 1,
                .u16 => 2,
                .u32 => 4,
            };
            methods.indexBufferTyped(push, ib.va + ix.offset, @as(u64, d.count) * width, lower.indexSize(ix.type));
            methods.drawIndexed(push, d.first, d.count);
        } else {
            methods.drawTriangles(push, d.first, d.count);
        }
    }

    fn endFrame(self: *Ctx) idraw.Error!void {
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        self.recording = false;
        const p = &self.p;
        // Resolve pass (same push — atomic with the scene): barrier the ROP-written MSAA
        // samples for texture reads (WFI + tex-cache invalidate), then a fullscreen
        // triangle averages the 8 samples of each pixel into this context's own 1x
        // target — the surface the de-tile below ships out. Blending and depth are
        // forced off: the resolve REPLACES pixels, it does not composite them.
        p.incr(hostpush.SUBCH_HOST, hostpush.WFI, 1); // WFI: MSAA writes → tex reads
        p.data(0);
        methods.invalidateTexCache(p);
        methods.setAntiAlias(p, methods.AA_MODE_1X1);
        methods.colorTargetBl(p, self.va(gmmu.GL_CTX_RT_OFF), RT_W, RT_H, self.rt_layout.bh_log2, self.rt_layout.size_bytes);
        methods.depthTestOff(p);
        methods.blendOff(p);
        methods.viewportFull(p, self.w, self.h);
        const rvs = device.up.find("v_fullscreen") orelse return idraw.Error.DrawOutOfResources;
        const rfs = device.up.find("f_resolve_msaa8") orelse return idraw.Error.DrawOutOfResources;
        methods.pipelineShader(p, methods.SLOT_VERTEX, rvs.gprs, CB_GROUP_VS, rvs.va);
        methods.pipelineShader(p, methods.SLOT_PIXEL, rfs.gprs, CB_GROUP_FS, rfs.va);
        methods.invalidateShaderCaches(p);
        // One fullscreen triangle from the device's fixed 3-vertex buffer; only the
        // position attribute matters and it is re-pointed here (the scene's other
        // attribute streams still name mapped staging memory, and the resolve's vertex
        // shader reads none of them).
        methods.vertexStreamAt(p, 0, device.fstri_va, 12, 36);
        methods.vertexAttribAt(p, 0, 0, 0, methods.ATTR_R32G32B32_FLOAT);
        // The resolve samples the MSAA TIC through its own preloaded handle word.
        methods.bindCbSlot(p, self.va(gmmu.GL_CTX_CB_OFF) + RESOLVE_DESC_OFF, 0x100, CB_GROUP_FS, TEX_DESC_SLOT);
        methods.bindCb0(p, self.va(gmmu.GL_CTX_CB_OFF), 0x1000);
        methods.drawTriangles(p, 0, 3);
        // Fence the resolve so the de-tile can gate on it, and so `frameReady` means the
        // pixels really landed.
        p.incr(hostpush.SUBCH_HOST, hostpush.WFI, 1); // WFI: resolve retired
        p.data(0);
        self.gr_want = device.gr.nextFence();
        gr_mod.semRelease(p, self.va(gmmu.GL_CTX_GRSEM_OFF), self.gr_want);
        device.gr.submit(device.g, p, self.va(gmmu.GL_CTX_GRPUSH_OFF), self.gr_push_phys) catch {
            self.n_kick_fail += 1;
        };
        self.n_kicked += 1;
        self.t_kick = tsc.rdtsc();
        // GPU-chained de-tile of the drawn rectangle into the window's mirror, gated on
        // the render fence. Until the window's mirror exists (first-upload race), park in
        // `rendering` and let pump() de-tile once it appears.
        if (present.mirrorTarget(self.dst.win_base)) |mt| {
            self.kickDetile(mt, true);
            self.phase = .detiling;
        } else {
            self.n_mirror_miss += 1;
            self.phase = .rendering;
        }
    }

    /// Kick the CE de-tile of the viewport rect into the window's mirror from this
    /// context's private CE push. `chained` prepends a GPU-side acquire on the render
    /// fence so the copy self-orders behind the render.
    fn kickDetile(self: *Ctx, mt: present.MirrorTarget, chained: bool) void {
        const dst_va = mt.va + (@as(u64, self.dst.off_y) * mt.stride_px + self.dst.off_x) * 4;
        var p = hostpush.HostPush.init(self.ce_push_phys, 0x1000);
        if (chained) gr_mod.semAcquire(&p, self.va(gmmu.GL_CTX_GRSEM_OFF), self.gr_want);
        self.ce_fence +%= 1;
        if (self.ce_fence == 0) self.ce_fence = 1;
        self.ce_want = self.ce_fence;
        ce.copyBlToPitch(&p, dst_va, mt.stride_px * 4, self.va(gmmu.GL_CTX_RT_OFF), self.rt_layout.row_stride_bytes, RT_H, self.rt_layout.bh_log2, self.w * 4, self.h, self.va(gmmu.GL_CTX_CESEM_OFF), self.ce_want);
        fifo.kickChannel(device.g, device.f.userd_phys, device.f.ring_phys, self.va(gmmu.GL_CTX_CEPUSH_OFF), self.ce_push_phys, p.bytes(), &device.f.gp_put, device.f.runlist, device.f.chid) catch {
            self.n_kick_fail += 1;
        };
    }

    /// Advance this context's pipeline as far as retired fences allow — one-word polls,
    /// never a wait.
    fn pump(self: *Ctx) void {
        switch (self.phase) {
            .idle => {},
            .rendering => {
                if (!semDone(self.gr_sem_phys, self.gr_want)) return;
                if (self.abandoned) {
                    self.abandoned = false;
                    self.phase = .idle;
                    return;
                }
                const mt = present.mirrorTarget(self.dst.win_base) orelse {
                    self.n_mirror_miss += 1;
                    return;
                };
                self.kickDetile(mt, false);
                self.phase = .detiling;
            },
            .detiling => {
                if (!semDone(self.ce_sem_phys, self.ce_want)) return;
                self.phase = .idle;
                if (self.abandoned) {
                    self.abandoned = false;
                } else {
                    self.landed = true;
                    self.n_landed += 1;
                    const dt = tsc.rdtsc() -% self.t_kick;
                    self.lat_sum +%= dt;
                    self.lat_n += 1;
                    if (dt > self.lat_max) self.lat_max = dt;
                }
            },
        }
    }

    fn discardFrame(self: *Ctx) void {
        self.landed = false;
        if (self.recording) {
            self.recording = false;
            return;
        }
        if (self.phase != .idle) self.abandoned = true;
    }
};

/// Fill the shaders' push-constant block from the packed ES 1.1 state image, and return
/// how many 32-bit words it occupies.
///
/// The flat 2D program reads only the MVP, so its block is 16 words. The lit program reads
/// the layout `pc_layout.glsl` fixes — mvp, model, light_mvp, and the light/material
/// parameters — so its block is 64 words, marshalled from the ES state:
///
///   - `model` <- the MODELVIEW, and the eye at the origin, so the fragment lights in eye
///     space, which is exactly where OpenGL ES 1.1 lights. The normal and world-position
///     the vertex program derives with this matrix are therefore the eye-space quantities
///     the standard's equation wants — this is the reason it is correct, not a fudge.
///   - `light_dir` <- light 0's position (gles has already transformed it to eye space).
///   - `light_color.rgb` <- light 0's diffuse, `.w` <- its specular strength.
///   - `ambient.rgb` <- the light-model ambient, `.w` <- the material shininess exponent.
///
/// Directional light 0 only (the model viewer's case); a fuller lighting environment is
/// the general-shader path, not this one.
fn marshalPc(u: []const u8, lit: bool, blend: bool, out: *[64]u32) u32 {
    const uni = idraw.uniform;
    copyWords(out[0..16], u, uni.OFF_MVP); // mvp
    if (!lit) return 16;
    copyWords(out[16..32], u, uni.OFF_MODELVIEW); // model (eye-space lighting)
    copyWords(out[32..48], u, uni.OFF_MVP); // light_mvp: unused by the non-shadow fragment
    copyWords(out[48..52], u, uni.OFF_LIGHTS + 0x30); // light_dir <- light0.position
    // light_dir.w = the fragment's alpha mode (spec APP-010): the translucent
    // pass (blend on) tells the shader to use the texture's alpha and output
    // premultiplied; an opaque draw forces alpha 1.
    out[51] = @bitCast(@as(f32, if (blend) 1.0 else 0.0));
    copyWords(out[52..56], u, uni.OFF_LIGHTS + 0x10); // light_color <- light0.diffuse
    out[55] = word(u, uni.OFF_LIGHTS + 0x20); // .w = specular strength (light0.specular.r)
    copyWords(out[56..60], u, uni.OFF_LIGHT_MODEL_AMBIENT); // ambient <- scene ambient
    out[59] = word(u, uni.OFF_MATERIAL + 0x40); // .w = shininess exponent
    out[60] = 0;
    out[61] = 0;
    out[62] = 0;
    out[63] = @bitCast(@as(f32, 1)); // eye_pos = origin
    return 64;
}

/// Any material map bound → the lit draw shades f_pbr (GL_KUDOS_material_maps).
fn anyMatMap(p: *const idraw.Pipeline) bool {
    for (p.mat_maps) |mm| {
        if (mm != null) return true;
    }
    return false;
}

fn word(u: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, u[off..][0..4], .little);
}
fn copyWords(dst: []u32, u: []const u8, off: usize) void {
    for (dst, 0..) |*w, i| w.* = word(u, off + i * 4);
}

/// Non-blocking fence poll: one cacheline invalidate + read of a sysmem word.
fn semDone(sem_phys: u64, want: u32) bool {
    shim.invalidateLine(sem_phys);
    const sem: *volatile u32 = @ptrFromInt(sem_phys);
    return sem.* == want;
}

/// The device singleton (lives for the GPU session; gpu.zig publishes its iface and
/// clears it on teardown).
const Device = struct {
    g: gsp.Gsp,
    f: *fifo.Fifo,
    gr: *gr_mod.Gr,
    up: shaders.Uploaded,
    ctxs: [MAX_CTX]Ctx,

    buffers: [MAX_BUF]Buffer,
    textures: [MAX_TEX]Texture,
    buf_heap: extent_heap.ExtentHeap,
    tex_heap: extent_heap.ExtentHeap,
    // The 1:1-mapped physical base of each heap's VA window. The buffer heap is
    // SYSMEM (the CPU memcpys vertex/index bytes through the identity map —
    // bufWrite); the texture heap is VRAM (written once at create through the
    // PRAMIN window — texPhys), sampled from VRAM every frame.
    buf_heap_phys: u64,
    tex_heap_phys: u64,
    pool_phys: u64, // TIC/TSC pool (CPU-writable descriptor storage)

    // Built-in neutral TICs for null material-map slots (GL_KUDOS_material_maps):
    // a flat +Z normal texel and a black texel, created once at init through the
    // ordinary texture path and never destroyed. TIC_WHITE serves the metal-rough
    // and occlusion neutrals.
    tic_flat_normal: u32 = TIC_WHITE,
    tic_black: u32 = TIC_WHITE,

    // The ONE shared 8x MSAA scratch pair, panel-sized at the 4x2 sample extent
    // (colour + ZF32 depth). Every context's scene renders here and resolves into its
    // own 1x target inside the same push; sharing is safe because the channel executes
    // each frame as one atomic push, so no two frames are mid-flight against it at once.
    msaa_rt_layout: til.Layout,
    msaa_zt_layout: til.Layout,
    // The resolve pass's fixed fullscreen triangle: three (x,y,z) vertices in a
    // zero-padded page of the buffer heap, uploaded once at init.
    fstri_va: u64,

    limits_val: idraw.Limits,

    fn iface(self: *Device) idraw.IDraw {
        // Frames land in the window's VRAM mirror; the compositor samples it in place, so
        // there is no CPU surface upload — the opposite of the software backend.
        return .{ .ctx = self, .vtable = &dev_vtable, .delivers_in_place = false };
    }

    const dev_vtable = idraw.IDraw.VTable{
        .bufferCreate = vtBufferCreate,
        .bufferUpdate = vtBufferUpdate,
        .bufferDestroy = vtBufferDestroy,
        .textureCreate = vtTextureCreate,
        .textureUpdate = vtTextureUpdate,
        .textureDestroy = vtTextureDestroy,
        .limits = vtLimits,
        .acquire = vtAcquire,
        .release = vtRelease,
    };

    fn cast(ctx: *anyopaque) *Device {
        return @ptrCast(@alignCast(ctx));
    }
    fn vtBufferCreate(ctx: *anyopaque, bytes: []const u8, usage: idraw.Usage) idraw.Error!idraw.BufferHandle {
        return cast(ctx).bufferCreate(bytes, usage);
    }
    fn vtBufferUpdate(ctx: *anyopaque, h: idraw.BufferHandle, off: u32, bytes: []const u8) idraw.Error!void {
        return cast(ctx).bufferUpdate(h, off, bytes);
    }
    fn vtBufferDestroy(ctx: *anyopaque, h: idraw.BufferHandle) void {
        cast(ctx).bufferDestroy(h);
    }
    fn vtTextureCreate(ctx: *anyopaque, d: idraw.TexDesc) idraw.Error!idraw.TextureHandle {
        // A refused create is loud: the caller's draws then silently sample the white
        // texel, which reads on screen as solid blocks — the log line is the difference
        // between seeing the cause and chasing the symptom.
        return cast(ctx).textureCreate(d) catch |e| {
            const w: u32 = if (d.levels.len != 0) d.levels[0].w else 0;
            const h: u32 = if (d.levels.len != 0) d.levels[0].h else 0;
            log("gl.opengl: texture create {}x{} fmt={s} REFUSED: {}\n", .{ w, h, @tagName(d.format), e });
            return e;
        };
    }
    fn vtTextureUpdate(ctx: *anyopaque, h: idraw.TextureHandle, level: u32, r: idraw.Rect, px: []const u8) idraw.Error!void {
        return cast(ctx).textureUpdate(h, level, r, px);
    }
    fn vtTextureDestroy(ctx: *anyopaque, h: idraw.TextureHandle) void {
        cast(ctx).textureDestroy(h);
    }
    fn vtLimits(ctx: *anyopaque) idraw.Limits {
        return cast(ctx).limits_val;
    }
    fn vtAcquire(ctx: *anyopaque, dst: idraw.Dst) ?idraw.IDrawCtx {
        return cast(ctx).acquire(dst);
    }
    fn vtRelease(ctx: *anyopaque, c: idraw.IDrawCtx) void {
        _ = ctx;
        const slot_ctx = Ctx.cast(c.ctx);
        slot_ctx.discardFrame();
        slot_ctx.in_use = false;
    }

    fn bufferCreate(self: *Device, bytes: []const u8, usage: idraw.Usage) idraw.Error!idraw.BufferHandle {
        _ = usage;
        for (&self.buffers, 0..) |*b, i| {
            if (b.alive) continue;
            const size = @max(@as(u64, bytes.len), 0x1000);
            const va = self.buf_heap.alloc(size) orelse return idraw.Error.DrawOutOfResources;
            if (bytes.len != 0) self.bufWrite(va, 0, bytes);
            b.* = .{ .alive = true, .va = va, .size = std.mem.alignForward(u64, size, 0x1000), .used = bytes.len };
            return @intCast(i + 1);
        }
        return idraw.Error.DrawOutOfResources;
    }

    fn bufferUpdate(self: *Device, h: idraw.BufferHandle, off: u32, bytes: []const u8) idraw.Error!void {
        if (h == 0 or h > MAX_BUF or !self.buffers[h - 1].alive) return idraw.Error.DrawBadBuffer;
        const b = &self.buffers[h - 1];
        if (off + bytes.len > b.size) return idraw.Error.DrawBadBuffer;
        self.bufWrite(b.va, off, bytes);
        if (off + bytes.len > b.used) b.used = off + bytes.len;
    }

    fn bufferDestroy(self: *Device, h: idraw.BufferHandle) void {
        if (h == 0 or h > MAX_BUF or !self.buffers[h - 1].alive) return;
        const b = &self.buffers[h - 1];
        if (self.buf_heap.freeBlock(b.va, b.size)) |lost| {
            // Free-list full — the block leaks rather than corrupting the list.
            // Loud: the capacity is sized far above the live resource count.
            log("gl.opengl: buf heap free-list full — leaking 0x{x} bytes at 0x{x}\n", .{ lost.size, lost.va });
        }
        b.* = .{};
    }

    /// Upload a texture, expanding whatever the seam hands over to BGRA8 on the way in:
    /// the card samples one pitch-linear BGRA8 format, and a single-channel or
    /// two-channel source is widened here (once, on create) so the sampler and its TIC
    /// never have to know the source format. This is what lets the font atlas
    /// (luminance+alpha coverage) render without a luminance TIC encoding.
    fn textureCreate(self: *Device, d: idraw.TexDesc) idraw.Error!idraw.TextureHandle {
        if (d.levels.len == 0) return idraw.Error.DrawBadTexture;
        const l0 = d.levels[0];
        // The cap is the SAMPLER's, not the render target's: a texture is fetched
        // through a TIC descriptor and never rasterized into, so a tall glyph atlas
        // (9×1805) is fine even though no render target could be that shape.
        if (l0.w == 0 or l0.h == 0 or l0.w > MAX_TEX_DIM or l0.h > MAX_TEX_DIM) return idraw.Error.DrawBadTexture;
        for (&self.textures, 0..) |*t, i| {
            if (t.alive) continue;
            const pitch = std.mem.alignForward(u32, l0.w * 4, 32);
            const size = @as(u64, pitch) * l0.h;
            const va = self.tex_heap.alloc(size) orelse {
                // Never silent: name the request and the heap's actual shape, so
                // "texture create refused" is attributable to exhaustion vs
                // fragmentation from one line.
                var total: u64 = 0;
                var largest: u64 = 0;
                for (self.tex_heap.free[0..self.tex_heap.n]) |e| {
                    total += e.size;
                    largest = @max(largest, e.size);
                }
                log("gl.opengl: texture {}x{} ({} KiB) REFUSED — tex heap free {} KiB, largest {} KiB\n", .{ l0.w, l0.h, size / 1024, total / 1024, largest / 1024 });
                return idraw.Error.DrawOutOfResources;
            };
            self.writeBgraRows(self.texPhys(va), pitch, l0.w, l0.h, d.format, l0.pixels);
            // The TIC index IS the table slot (offset past the built-ins): a texture's
            // descriptor lives and dies with its slot, so churning windows re-use the
            // same pool entry instead of leaking one per create until the pool is full.
            const tic_index = TIC_USER_BASE + @as(u32, @intCast(i));
            const tic = tex.ticPitchBgra8(va, l0.w, l0.h, pitch);
            vram.writeBytes(self.g.regs, self.pool_phys + @as(u64, tic_index) * 32, std.mem.asBytes(&tic));
            t.* = .{ .alive = true, .tic = tic_index, .va = va, .size = std.mem.alignForward(u64, size, 0x1000), .w = l0.w, .h = l0.h, .pitch = pitch };
            return @intCast(i + 1);
        }
        log("gl.opengl: texture {}x{} REFUSED — all {} slots alive\n", .{ l0.w, l0.h, MAX_TEX });
        return idraw.Error.DrawOutOfResources;
    }

    fn textureUpdate(self: *Device, h: idraw.TextureHandle, level: u32, r: idraw.Rect, px: []const u8) idraw.Error!void {
        if (level != 0) return idraw.Error.DrawBadTexture;
        if (h == 0 or h > MAX_TEX or !self.textures[h - 1].alive) return idraw.Error.DrawBadTexture;
        const t = self.textures[h - 1];
        if (r.x < 0 or r.y < 0) return idraw.Error.DrawBadTexture;
        const rx: u32 = @intCast(r.x);
        const ry: u32 = @intCast(r.y);
        if (rx + r.w > t.w or ry + r.h > t.h) return idraw.Error.DrawBadTexture;
        // Overwrite the rect row by row, BGRA-expanded, at the texture's pitch.
        const bpp = bytesPer(idraw.TexFormat.bgra8); // px is already the caller's source format
        _ = bpp;
        var y: u32 = 0;
        while (y < r.h) : (y += 1) {
            const dst_off = @as(u64, ry + y) * t.pitch + @as(u64, rx) * 4;
            self.writeBgraRow(self.texPhys(t.va) + dst_off, r.w, idraw.TexFormat.bgra8, px[@as(usize, y) * r.w * 4 ..]);
        }
    }

    fn textureDestroy(self: *Device, h: idraw.TextureHandle) void {
        if (h == 0 or h > MAX_TEX or !self.textures[h - 1].alive) return;
        const t = &self.textures[h - 1];
        if (self.tex_heap.freeBlock(t.va, t.size)) |lost| {
            log("gl.opengl: tex heap free-list full — leaking 0x{x} bytes at 0x{x}\n", .{ lost.size, lost.va });
        }
        // The TIC pool slot leaks (the pool is a flat array with no free list); textures
        // are far fewer than the pool holds. A tighter pool allocator is a later refinement.
        t.* = .{};
    }

    fn acquire(self: *Device, dst: idraw.Dst) ?idraw.IDrawCtx {
        // Every slot's VRAM + MMU mapping was allocated at init (premapSlots), so
        // acquire only ever hands out an already-mapped slot — it never allocates
        // or maps on the render path. A window opening therefore costs nothing that
        // could stretch a frame. Returns null when all mapped slots are busy (or a
        // slot was retired at init because its map failed); that window stays 2D.
        var i: u32 = 0;
        while (i < MAX_CTX) : (i += 1) {
            const c = &self.ctxs[i];
            if (c.in_use or !c.mapped) continue;
            c.pump();
            if (c.phase != .idle or c.recording) continue;
            return checkout(c, dst);
        }
        return null;
    }

    fn checkout(c: *Ctx, dst: idraw.Dst) idraw.IDrawCtx {
        c.in_use = true;
        c.dst = dst;
        c.phase = .idle;
        c.recording = false;
        c.abandoned = false;
        c.landed = false;
        return c.iface();
    }

    fn mapSlot(self: *Device, c: *Ctx) !void {
        const valloc = self.f.mmu.valloc;
        c.rt_layout = til.layout2d(RT_W, RT_H, 4);
        const rt_phys = try valloc.alloc(c.rt_layout.size_bytes, c.rt_layout.align_bytes);
        try self.f.mmu.mapVramBlockLinear(c.va(gmmu.GL_CTX_RT_OFF), rt_phys, c.rt_layout.size_bytes);

        c.cb_phys = try valloc.alloc(0x1000, 0x1000);
        vram.fill(self.g.regs, c.cb_phys, 0x1000, 0);
        // Preload the resolve pass's texture-handle word: it always names the MSAA TIC,
        // so it is written once here and endFrame only binds the cbuf window over it.
        vram.write32(self.g.regs, c.cb_phys + RESOLVE_DESC_OFF, tex.handle(TIC_MSAA, 0));
        try self.f.mmu.mapVram(c.va(gmmu.GL_CTX_CB_OFF), c.cb_phys, 0x1000);

        // A multi-page GR pushbuffer (the compositor's whole-desktop frame is large), and
        // single-page CE push + fence words.
        c.gr_push_phys = try allocSysPages(self.f, c.va(gmmu.GL_CTX_GRPUSH_OFF), GR_PUSH_BYTES / 0x1000);
        c.gr_sem_phys = try allocSysPages(self.f, c.va(gmmu.GL_CTX_GRSEM_OFF), 1);
        c.ce_push_phys = try allocSysPages(self.f, c.va(gmmu.GL_CTX_CEPUSH_OFF), 1);
        c.ce_sem_phys = try allocSysPages(self.f, c.va(gmmu.GL_CTX_CESEM_OFF), 1);
        c.mapped = true;
        log("gl.opengl: ctx slot {} mapped (RT {}x{} BL, push {}KiB)\n", .{ c.slot, RT_W, RT_H, GR_PUSH_BYTES / 1024 });
    }

    // ── BGRA expansion + heap addressing helpers ─────────────────────────────

    fn bufPhys(self: *Device, buf_va: u64) u64 {
        return self.buf_heap_phys + (buf_va - gmmu.VA_GL_MESH);
    }

    /// Write into the SYSMEM-backed buffer heap: a plain memcpy through the
    /// identity map, then a cache-line flush so the GPU's next vertex/index
    /// fetch (a PCIe DMA read, not a snooping access) sees the bytes.
    fn bufWrite(self: *Device, buf_va: u64, off: u64, bytes: []const u8) void {
        const phys = self.bufPhys(buf_va) + off;
        const p: [*]u8 = @ptrFromInt(phys);
        @memcpy(p[0..bytes.len], bytes);
        shim.flushRange(phys, bytes.len);
    }
    fn texPhys(self: *Device, tex_va: u64) u64 {
        return self.tex_heap_phys + (tex_va - gmmu.VA_GL_TEXWIN);
    }

    fn writeBgraRows(self: *Device, phys: u64, pitch: u32, w: u32, h: u32, fmt: idraw.TexFormat, pixels: []const u8) void {
        const bpp = bytesPer(fmt);
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            self.writeBgraRow(phys + @as(u64, y) * pitch, w, fmt, pixels[@as(usize, y) * w * bpp ..]);
        }
    }

    /// Widen one row of the source format to BGRA8 and write it. The widening mirrors how
    /// the software backend samples each format, so a texture looks the same on both.
    fn writeBgraRow(self: *Device, phys: u64, w: u32, fmt: idraw.TexFormat, src: []const u8) void {
        var row: [RT_W * 4]u8 = undefined;
        const bpp = bytesPer(fmt);
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const s = src[x * bpp ..];
            const o = x * 4;
            switch (fmt) {
                .bgra8 => {
                    row[o + 0] = s[0];
                    row[o + 1] = s[1];
                    row[o + 2] = s[2];
                    row[o + 3] = s[3];
                },
                // luminance replicates into b,g,r with alpha opaque.
                .luminance8 => {
                    row[o + 0] = s[0];
                    row[o + 1] = s[0];
                    row[o + 2] = s[0];
                    row[o + 3] = 0xff;
                },
                // alpha carries in the alpha channel, colour zero.
                .alpha8 => {
                    row[o + 0] = 0;
                    row[o + 1] = 0;
                    row[o + 2] = 0;
                    row[o + 3] = s[0];
                },
                // luminance then alpha: coverage in every channel (matches soft.zig).
                .luminance_alpha8 => {
                    row[o + 0] = s[0];
                    row[o + 1] = s[0];
                    row[o + 2] = s[0];
                    row[o + 3] = s[1];
                },
            }
        }
        vram.writeBytes(self.g.regs, phys, row[0 .. w * 4]);
    }
};

fn bytesPer(f: idraw.TexFormat) usize {
    return switch (f) {
        .bgra8 => 4,
        .luminance_alpha8 => 2,
        .luminance8, .alpha8 => 1,
    };
}

fn allocSysPages(f: *fifo.Fifo, at_va: u64, n: u32) !u64 {
    const phys = shim.allocPagesPhys(n) orelse return error.OpenGlAlloc;
    @memset(@as([*]u8, @ptrFromInt(phys))[0 .. @as(u64, n) * 0x1000], 0);
    shim.flushRange(phys, @as(u64, n) * 0x1000);
    try f.mmu.mapSysmem(at_va, phys, @as(u64, n) * 0x1000);
    return phys;
}

var device: Device = undefined;
var device_ready: bool = false;
/// One-shot guard so a refused blend names itself once, not every frame.
var blend_refusal_logged: bool = false;
/// Draws refused because the frame's push page was full. Each one is a shape missing
/// from the presented frame, so the count is a visible defect, not bookkeeping: "drop"
/// marks it a fault counter and the heads-up display's fault line trips on it.
var cnt_draws_dropped = counter.Counter{ .mod = .gpu, .name = "draws_dropped" };

pub fn pumpAll() void {
    if (!device_ready) return;
    for (&device.ctxs) |*c| {
        if (c.in_use) c.pump();
    }
}

pub fn dumpStatus() void {
    if (!device_ready) return;
    for (&device.ctxs) |*c| {
        if (!c.mapped) continue;
        const lat_avg: u64 = if (c.lat_n > 0) tsc.ticksToUs(c.lat_sum / c.lat_n) else 0;
        log("gl.opengl: GLSTAT s{} u={} ph={s} k={} b={} l={} m={} kf={} lat_avg={}us lat_max={}us\n", .{
            c.slot,     c.in_use,        @tagName(c.phase), c.n_kicked, c.n_busy,
            c.n_landed, c.n_mirror_miss, c.n_kick_fail,     lat_avg,    tsc.ticksToUs(c.lat_max),
        });
        c.lat_sum = 0;
        c.lat_n = 0;
        c.lat_max = 0;
        // Mirror probe: PRAMIN-read two dwords of the window's mirror (its origin and the
        // mid-viewport) so an outside observer can tell "frames never reach the mirror"
        // apart from "the compositor never shows it". This line is also the render proof
        // the boot-2 suite gates on (boot2_passthrough.py: a live GL window is a slot with
        // a mapped mirror AND an advancing kick counter).
        if (c.in_use) {
            if (present.mirrorTarget(c.dst.win_base)) |mt| {
                const origin = mt.phys + (@as(u64, c.dst.off_y) * mt.stride_px + c.dst.off_x) * 4;
                const mid = origin + (@as(u64, c.h / 2) * mt.stride_px + c.w / 2) * 4;
                log("gl.opengl: GLSTAT slot={} mirror va=0x{x} stride={} origin=0x{x:0>8} mid=0x{x:0>8}\n", .{
                    c.slot, mt.va, mt.stride_px, vram.read32(device.g.regs, origin), vram.read32(device.g.regs, mid),
                });
            } else log("gl.opengl: GLSTAT slot={} mirror MISSING\n", .{c.slot});
        }
    }
}

pub const Error = error{OpenGlAlloc} || gmmu.Error || error{VramOutOfMemory};

/// Build the device: the built-in white texture + TIC/TSC pool, the two GL heaps, and the
/// context pool (slots map lazily on first acquire). Runs once after GR bring-up; every
/// GPU access here is a CPU-side PRAMIN/VRAM write, nothing is submitted yet.
pub fn init(g: gsp.Gsp, f: *fifo.Fifo, gr: *gr_mod.Gr, up: shaders.Uploaded) Error!idraw.IDraw {
    const valloc = f.mmu.valloc;

    // TIC[0]: the built-in opaque-white default (a flat fill samples it, so the 2D
    // program's texel is white and its output is the vertex colour). 8x8 so the 32-B
    // pitch minimum holds.
    const TW: u32 = 8;
    const tex_pitch: u32 = TW * 4;
    const white_phys = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, white_phys, 0x1000, 0xffff_ffff); // one opaque-white pixel per dword
    try f.mmu.mapVram(gmmu.VA_GL_TEX, white_phys, 0x1000);

    const pool_phys = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, pool_phys, 0x1000, 0);
    const white_tic = tex.ticPitchBgra8(gmmu.VA_GL_TEX, TW, TW, tex_pitch);
    const tsc_e = tex.tscLinearWrap();
    vram.writeBytes(g.regs, pool_phys + @as(u64, TIC_WHITE) * 32, std.mem.asBytes(&white_tic));
    vram.writeBytes(g.regs, pool_phys + 0x400, std.mem.asBytes(&tsc_e)); // TSC[0]
    try f.mmu.mapVram(gmmu.VA_GL_TICPOOL, pool_phys, 0x1000);

    // The two GL heaps, each one contiguous region mapped 1:1 to its VA window and
    // sub-allocated with a real free list. 16 MiB of buffers is ample for the
    // desktop; the texture heap fills its whole VA window, because a single glTF
    // PBR model carries five 2048² BGRA maps (~80 MiB decoded, APP-011).
    //
    // The BUFFER heap lives in SYSMEM, not VRAM: the 2D toolkit re-stages its vertex
    // arrays every frame, and writing them through the PRAMIN window costs one uncached
    // MMIO write per dword — measured at tens of milliseconds per loaded frame, which
    // alone locked the desktop to half the panel rate. In sysmem the CPU fills buffers
    // at memcpy speed and the GPU's vertex/index fetch DMAs them over PCIe (the same
    // way it already reads the pushbuffers) — a few MB/frame is nothing on a x16 link.
    // Textures stay in VRAM: they are written once at create and sampled every frame.
    const buf_bytes: u64 = 16 * 1024 * 1024;
    const tex_bytes: u64 = gmmu.VA_GL_TEXWIN_SIZE;
    const buf_phys = try allocSysPages(f, gmmu.VA_GL_MESH, @intCast(buf_bytes / 0x1000));
    const tex_phys = try valloc.alloc(tex_bytes, 0x1000);
    try f.mmu.mapVram(gmmu.VA_GL_TEXWIN, tex_phys, tex_bytes);

    // The shared 8x MSAA scratch pair: colour + ZF32 depth, panel-sized at the 4x2
    // SAMPLE extent (8 samples per pixel = 4x wider, 2x taller). The scene renders
    // here; each frame's resolve averages it into the context's 1x target. TIC[1]
    // describes the colour surface for the resolve pass's texel fetches.
    const msaa_rt_layout = til.layout2d(RT_W * 4, RT_H * 2, 4);
    const msaa_rt_phys = try valloc.alloc(msaa_rt_layout.size_bytes, msaa_rt_layout.align_bytes);
    try f.mmu.mapVramBlockLinear(gmmu.VA_GL_MSAA_RT, msaa_rt_phys, msaa_rt_layout.size_bytes);
    const msaa_zt_layout = til.layout2d(RT_W * 4, RT_H * 2, 4);
    const msaa_zt_phys = try valloc.alloc(msaa_zt_layout.size_bytes, msaa_zt_layout.align_bytes);
    try f.mmu.mapVramBlockLinear(gmmu.VA_GL_MSAA_ZT, msaa_zt_phys, msaa_zt_layout.size_bytes);
    const msaa_tic = tex.ticBlBgra8Msaa8(gmmu.VA_GL_MSAA_RT, RT_W, RT_H, msaa_rt_layout.bh_log2);
    vram.writeBytes(g.regs, pool_phys + @as(u64, TIC_MSAA) * 32, std.mem.asBytes(&msaa_tic));

    device = .{
        .g = g,
        .f = f,
        .gr = gr,
        .up = up,
        .ctxs = undefined,
        .buffers = .{Buffer{}} ** MAX_BUF,
        .textures = .{Texture{}} ** MAX_TEX,
        .buf_heap = extent_heap.ExtentHeap.init(gmmu.VA_GL_MESH, buf_bytes),
        .tex_heap = extent_heap.ExtentHeap.init(gmmu.VA_GL_TEXWIN, tex_bytes),
        .buf_heap_phys = buf_phys,
        .tex_heap_phys = tex_phys,
        .pool_phys = pool_phys,
        .msaa_rt_layout = msaa_rt_layout,
        .msaa_zt_layout = msaa_zt_layout,
        .fstri_va = 0, // set below, once the heap exists in `device`
        .limits_val = .{
            .max_texture_size = MAX_TEX_DIM,
            .texture_units = idraw.MAX_UNITS,
            .samples = 8, // the scene renders 8x MSAA and resolves per frame
            .subpixel_bits = 8,
        },
    };
    // The resolve pass's fullscreen triangle — three (x,y,z) vertices covering clip
    // space — in a zeroed page of the buffer heap (zeroed so any stray attribute fetch
    // inside the page reads inert data).
    {
        const fstri = [9]f32{ -1.0, -1.0, 0.5, 3.0, -1.0, 0.5, -1.0, 3.0, 0.5 };
        const va = device.buf_heap.alloc(0x1000) orelse return Error.OpenGlAlloc;
        // allocSysPages zeroed the whole heap at map time; just write the triangle.
        device.bufWrite(va, 0, std.mem.asBytes(&fstri));
        device.fstri_va = va;
    }
    for (&device.ctxs, 0..) |*c, i| {
        c.* = .{
            .slot = @intCast(i),
            .in_use = false,
            .mapped = false,
            .map_failed = false,
            .dst = undefined,
            .rt_layout = undefined,
            .cb_phys = 0,
            .gr_push_phys = 0,
            .gr_sem_phys = 0,
            .ce_push_phys = 0,
            .ce_sem_phys = 0,
            .phase = .idle,
            .recording = false,
            .abandoned = false,
            .landed = false,
            .w = 0,
            .h = 0,
            .cur_vp = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .cur_sc = null,
            .n_kicked = 0,
            .n_landed = 0,
            .n_busy = 0,
            .n_mirror_miss = 0,
            .n_kick_fail = 0,
            .t_kick = 0,
            .lat_sum = 0,
            .lat_max = 0,
            .lat_n = 0,
            .p = undefined,
            .gr_want = 0,
            .ce_want = 0,
            .ce_fence = 0,
        };
    }
    // Pre-map EVERY context slot now, before the desktop's first present. Each
    // slot's render target is a full-desktop-sized block-linear surface whose VRAM
    // allocation + MMU mapping costs a few ms; done lazily on first acquire it
    // stretched the frame that opened a window (several windows opening at once —
    // the under-load case — dropped that many frames). Front-loading it here means
    // acquire never touches the allocator or the page tables. A slot that cannot
    // map is retired exactly as the lazy path retired it: its future window stays
    // 2D, and the loud line names the slot.
    premapSlots();
    // The neutral material-map texels (spec RND-005): flat +Z normal and black,
    // through the ordinary texture path so they live in the TIC pool like any
    // sampled image. 8x8 for the same 32-B pitch minimum as the white built-in.
    {
        var flat_px: [8 * 8 * 4]u8 = undefined;
        var black_px: [8 * 8 * 4]u8 = undefined;
        var i: usize = 0;
        while (i < flat_px.len) : (i += 4) {
            flat_px[i..][0..4].* = .{ 255, 128, 128, 255 }; // BGRA of RGB (0.5, 0.5, 1.0)
            black_px[i..][0..4].* = .{ 0, 0, 0, 255 };
        }
        const hf = device.textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 8, .h = 8, .pixels = &flat_px }} }) catch return Error.OpenGlAlloc;
        device.tic_flat_normal = device.textures[hf - 1].tic;
        const hb = device.textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 8, .h = 8, .pixels = &black_px }} }) catch return Error.OpenGlAlloc;
        device.tic_black = device.textures[hb - 1].tic;
    }
    device_ready = true;
    counter.register(&cnt_draws_dropped);
    log("gl.opengl: GR IDraw device up ({} ctx slots, RT {}x{} BL, 2D path)\n", .{ MAX_CTX, RT_W, RT_H });
    return device.iface();
}

/// Map all context slots up front (see the call site in `init`). Best-effort: a
/// slot whose mapping fails is retired, not fatal — the design already tolerates a
/// missing GL context by leaving that window 2D. Separated from `init` so the
/// intent (front-load every slot's allocation off the render path) reads on its own.
fn premapSlots() void {
    for (&device.ctxs) |*c| {
        device.mapSlot(c) catch |e| {
            c.map_failed = true;
            log("gl.opengl: ctx slot {} pre-map failed: {} — slot retired\n", .{ c.slot, e });
        };
    }
}
