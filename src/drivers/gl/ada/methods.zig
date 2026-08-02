//! ADA_A (0xc997) 3D method-stream emitters — PURE module (imports only
//! hostpush, which imports nothing): every emitter is host-golden-tested
//! below, the kernel and `zig test` compile the same code.
//!
//! Method offsets/bitfields read from mesa clc997.h, in NVK emission order.
//! Subchannel 0 throughout.

pub const hostpush = @import("hostpush");

pub const SUBCH_3D: u32 = 0;

// §1 one-time context init
const SET_TESSELLATION_PARAMETERS: u32 = 0x0320;
const SET_RENDER_ENABLE_C: u32 = 0x1558;
const SET_CT_SELECT: u32 = 0x121c;
const SET_DA_PRIMITIVE_RESTART_VERTEX_ARRAY: u32 = 0x0de8;
const SET_VIEWPORT_PIXEL: u32 = 0x1924;
const SET_ANTI_ALIAS_ENABLE: u32 = 0x1534;
const SET_ANTI_ALIAS: u32 = 0x15d0;
const SET_WINDOW_ORIGIN: u32 = 0x13ac;
const SET_WINDOW_OFFSET_X: u32 = 0x0df8;
const SET_VIEWPORT_SCALE_OFFSET: u32 = 0x192c;
const SET_VIEWPORT_CLIP_CONTROL: u32 = 0x193c;
const SET_VIEWPORT_Z_CLIP: u32 = 0x0d7c;
const SET_SCISSOR_ENABLE_0: u32 = 0x0e00; // +i*16
const SET_CT_MRT_ENABLE: u32 = 0x0fac;
const SET_VERTEX_STREAM_SUBSTITUTE_A: u32 = 0x0f84;
pub const SET_VERTEX_STREAM_A_FORMAT_0: u32 = 0x1c00; // +j*16, streams 0..15
const SET_VERTEX_STREAM_B_FORMAT_0: u32 = 0x1d00; // +j*16, streams 16..31
pub const BIND_GROUP_CONSTANT_BUFFER_0: u32 = 0x2410; // +g*32
const SET_SHADER_LOCAL_MEMORY_WINDOW: u32 = 0x077c;
const OGL_SET_CULL: u32 = 0x1918;
const OGL_SET_FRONT_FACE: u32 = 0x191c;
const OGL_SET_CULL_FACE: u32 = 0x1920;
const SET_FRONT_POLYGON_MODE: u32 = 0x0dac;
const SET_BLEND_0: u32 = 0x1360;
const SET_CT_WRITE_0: u32 = 0x1a00;
pub const SET_ZT_SELECT: u32 = 0x1538;
const SET_ACTIVE_ZCULL_REGION: u32 = 0x1590;

// §2 render targets
pub const SET_COLOR_TARGET_A_0: u32 = 0x0800; // +j*64: A,B,WIDTH,HEIGHT,FORMAT,MEMORY,THIRD_DIM,ARRAY_PITCH,LAYER
pub const SET_SURFACE_CLIP_HORIZONTAL: u32 = 0x0ff4;

// §3 viewport / scissor / clear
pub const SET_VIEWPORT_SCALE_X_0: u32 = 0x0a00; // +i*32: SX,SY,SZ,OX,OY,OZ
pub const SET_VIEWPORT_CLIP_HORIZONTAL_0: u32 = 0x0c00; // +i*16
pub const SET_SCISSOR_HORIZONTAL_0: u32 = 0x0e04; // +i*16
pub const SET_CLEAR_SURFACE_CONTROL: u32 = 0x10f8;
pub const SET_COLOR_CLEAR_VALUE_0: u32 = 0x0d80; // +i*4, RGBA f32
const SET_Z_CLEAR_VALUE: u32 = 0x0d90;
pub const CLEAR_SURFACE: u32 = 0x19d0;

/// Color RT format (clc997.h:1012-1083): A8R8G8B8 = kudos' 0xAARRGGBB.
pub const CT_FORMAT_A8R8G8B8: u32 = 0xCF;

/// One-time 3D context state after SET_OBJECT (only the REQUIRED set; the
/// cargo-cult block is deliberately omitted).
/// `zero_va` = a mapped, zeroed page: substitute source for disabled
/// vertex-stream reads.
pub fn ctxInit(p: *hostpush.HostPush, zero_va: u64) void {
    p.immd(SUBCH_3D, SET_TESSELLATION_PARAMETERS, 0);
    p.immd(SUBCH_3D, SET_RENDER_ENABLE_C, 1); // MODE_TRUE
    p.immd(SUBCH_3D, SET_CT_SELECT, 1); // COUNT=1, TARGET0=0
    p.immd(SUBCH_3D, SET_ZT_SELECT, 0); // no depth target (until P4)
    // ZCULL: no region (0x3f = invalid id -> zcull off). NVK sets this in its
    // one-time init (nvk_cmd_draw.c:477); without it the first Z operation
    // touches an unconfigured zcull region (P4d hang on HW).
    p.immd(SUBCH_3D, SET_ACTIVE_ZCULL_REGION, 0x3f);
    p.immd(SUBCH_3D, SET_DA_PRIMITIVE_RESTART_VERTEX_ARRAY, 0);
    p.immd(SUBCH_3D, SET_VIEWPORT_PIXEL, 0); // CENTER_AT_HALF_INTEGERS = 0 (clc997.h:3789; 1 is AT_INTEGERS)
    p.immd(SUBCH_3D, SET_ANTI_ALIAS_ENABLE, 1);
    p.immd(SUBCH_3D, SET_ANTI_ALIAS, 0); // MODE_1X1
    p.immd(SUBCH_3D, SET_WINDOW_ORIGIN, 0); // UPPER_LEFT, no flip
    p.incr(SUBCH_3D, SET_WINDOW_OFFSET_X, 2);
    p.data(0);
    p.data(0);
    p.immd(SUBCH_3D, SET_VIEWPORT_SCALE_OFFSET, 1); // ENABLE_TRUE
    p.incr(SUBCH_3D, SET_VIEWPORT_CLIP_CONTROL, 1);
    p.data(0x18); // pixel min/max Z CLAMP; guardband 256; WZERO_CLIP
    p.immd(SUBCH_3D, SET_VIEWPORT_Z_CLIP, 1); // ZERO_TO_POSITIVE_W (Vulkan)
    var i: u32 = 0;
    while (i < 16) : (i += 1) p.immd(SUBCH_3D, SET_SCISSOR_ENABLE_0 + i * 16, 0);
    p.immd(SUBCH_3D, SET_CT_MRT_ENABLE, 1);
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_SUBSTITUTE_A, 2);
    p.data(@intCast(zero_va >> 32));
    p.data(@truncate(zero_va));
    var j: u32 = 0;
    while (j < 16) : (j += 1) {
        p.immd(SUBCH_3D, SET_VERTEX_STREAM_A_FORMAT_0 + j * 16, 0); // ENABLE=0
        p.immd(SUBCH_3D, SET_VERTEX_STREAM_B_FORMAT_0 + j * 16, 0);
    }
    var grp: u32 = 0;
    while (grp < 5) : (grp += 1) {
        var slot: u32 = 0;
        while (slot < 16) : (slot += 1)
            p.immd(SUBCH_3D, BIND_GROUP_CONSTANT_BUFFER_0 + grp * 32, @intCast((slot << 4) | 0)); // VALID_FALSE
    }
    p.incr(SUBCH_3D, SET_SHADER_LOCAL_MEMORY_WINDOW, 1);
    p.data(0xff000000);
    p.immd(SUBCH_3D, OGL_SET_CULL, 0); // disabled
    p.incr(SUBCH_3D, OGL_SET_FRONT_FACE, 1);
    p.data(0x901); // CCW
    p.incr(SUBCH_3D, OGL_SET_CULL_FACE, 1);
    p.data(0x405); // BACK (inert while cull disabled)
    p.incr(SUBCH_3D, SET_FRONT_POLYGON_MODE, 2);
    p.data(0x1b02); // FILL
    p.data(0x1b02); // FILL (back)
    p.immd(SUBCH_3D, SET_BLEND_0, 0);
    p.incr(SUBCH_3D, SET_CT_WRITE_0, 1);
    p.data(0x1111); // R|G|B|A enabled
}

/// Bind RT0 as a pitch-linear A8R8G8B8 target of w×h (pitch in bytes,
/// 128-B aligned) and set the surface clip to the full target (§2).
pub fn colorTargetPitch(p: *hostpush.HostPush, va: u64, w: u32, h: u32, pitch: u32) void {
    p.incr(SUBCH_3D, SET_COLOR_TARGET_A_0, 9);
    p.data(@intCast(va >> 32)); // A: OFFSET_UPPER
    p.data(@truncate(va)); // B: OFFSET_LOWER
    p.data(pitch); // WIDTH: pitch bytes for PITCH layout
    p.data(h); // HEIGHT
    p.data(CT_FORMAT_A8R8G8B8); // FORMAT
    p.data(1 << 12); // MEMORY: LAYOUT_PITCH
    p.data(1); // THIRD_DIMENSION: 1 layer
    p.data(0); // ARRAY_PITCH
    p.data(0); // LAYER offset
    p.incr(SUBCH_3D, SET_SURFACE_CLIP_HORIZONTAL, 2);
    p.data(w << 16); // X=0, WIDTH
    p.data(h << 16); // Y=0, HEIGHT
}

/// Bind RT0 as a BLOCK-LINEAR A8R8G8B8 target (required whenever a Z buffer
/// is bound — pitch color + Z is a HW no-go; NVK nvk_cmd_draw.c:946-974).
/// WIDTH is in ELEMENTS for block-linear (vs pitch bytes for pitch layout).
/// MSAA color target: WIDTH is the row stride in ELEMENTS and HEIGHT the
/// SAMPLE-extent height (4x2 the pixel dims at 8x), while SET_SURFACE_CLIP
/// stays in PIXELS — the render area (nvk_cmd_draw.c:1144-1147, 1074-1082).
pub fn colorTargetBlMsaa(p: *hostpush.HostPush, va: u64, row_el: u32, h_sa: u32, bh_log2: u5, size_bytes: u64, clip_w_px: u32, clip_h_px: u32) void {
    p.incr(SUBCH_3D, SET_COLOR_TARGET_A_0, 9);
    p.data(@intCast(va >> 32)); // A: OFFSET_UPPER
    p.data(@truncate(va)); // B: OFFSET_LOWER
    p.data(row_el); // WIDTH: row stride in elements
    p.data(h_sa); // HEIGHT: sample extent
    p.data(CT_FORMAT_A8R8G8B8); // FORMAT
    p.data(@as(u32, bh_log2) << 4); // MEMORY: BLOCK_HEIGHT log2, BLOCKLINEAR
    p.data(1); // THIRD_DIMENSION: 1 layer
    p.data(@intCast(size_bytes >> 2)); // ARRAY_PITCH (array stride >> 2)
    p.data(0); // LAYER offset
    p.incr(SUBCH_3D, SET_SURFACE_CLIP_HORIZONTAL, 2);
    p.data(clip_w_px << 16); // x=0, width in PIXELS
    p.data(clip_h_px << 16); // y=0, height in PIXELS
}

pub fn colorTargetBl(p: *hostpush.HostPush, va: u64, w: u32, h: u32, bh_log2: u5, size_bytes: u64) void {
    p.incr(SUBCH_3D, SET_COLOR_TARGET_A_0, 9);
    p.data(@intCast(va >> 32)); // A: OFFSET_UPPER
    p.data(@truncate(va)); // B: OFFSET_LOWER
    p.data(w); // WIDTH: elements (blocklinear)
    p.data(h); // HEIGHT
    p.data(CT_FORMAT_A8R8G8B8); // FORMAT
    p.data(@as(u32, bh_log2) << 4); // MEMORY: BLOCK_HEIGHT log2, LAYOUT_BLOCKLINEAR
    p.data(1); // THIRD_DIMENSION: 1 layer
    p.data(@intCast(size_bytes >> 2)); // ARRAY_PITCH (array stride >> 2)
    p.data(0); // LAYER offset
    p.incr(SUBCH_3D, SET_SURFACE_CLIP_HORIZONTAL, 2);
    p.data(w << 16);
    p.data(h << 16);
}

/// Viewport 0 transform + clip + scissor covering the full w×h target (§3).
/// Depth range [0,1].
pub fn viewportFull(p: *hostpush.HostPush, w: u32, h: u32) void {
    viewportAt(p, 0, 0, w, h);
}

/// Viewport at an arbitrary framebuffer rectangle (top-left origin): the raster
/// scale/offset centre NDC on the rect, and the viewport clip matches it. This is what
/// confines a draw to one window's content area inside the whole-desktop frame.
pub fn viewportAt(p: *hostpush.HostPush, x: i32, y: i32, w: u32, h: u32) void {
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    p.incr(SUBCH_3D, SET_VIEWPORT_SCALE_X_0, 6);
    p.data(@bitCast(wf * 0.5)); // SCALE_X
    p.data(@bitCast(hf * 0.5)); // SCALE_Y
    p.data(@bitCast(@as(f32, 1.0))); // SCALE_Z = maxZ-minZ
    p.data(@bitCast(xf + wf * 0.5)); // OFFSET_X
    p.data(@bitCast(yf + hf * 0.5)); // OFFSET_Y
    p.data(@bitCast(@as(f32, 0.0))); // OFFSET_Z = minZ
    // The clip rect's X0/Y0 are unsigned 16-bit fields; a rect nudged off the top/left
    // edge clamps to the frame (the scale/offset above still place the geometry, so
    // clipping is all that changes — which is exactly what going off-screen means).
    const cx: u32 = @intCast(@max(x, 0));
    const cy: u32 = @intCast(@max(y, 0));
    const cw: u32 = @intCast(@max(@as(i64, x) + w - cx, 0));
    const ch: u32 = @intCast(@max(@as(i64, y) + h - cy, 0));
    p.incr(SUBCH_3D, SET_VIEWPORT_CLIP_HORIZONTAL_0, 4);
    p.data(cx | (cw << 16)); // X0 | WIDTH
    p.data(cy | (ch << 16)); // Y0 | HEIGHT
    p.data(@bitCast(@as(f32, 0.0))); // MIN_Z
    p.data(@bitCast(@as(f32, 1.0))); // MAX_Z
    p.incr(SUBCH_3D, SET_SCISSOR_HORIZONTAL_0, 2);
    p.data(cx | ((cx + cw) << 16)); // XMIN | XMAX
    p.data(cy | ((cy + ch) << 16)); // YMIN | YMAX
}

/// Scissor test on, clipped to a framebuffer rectangle (top-left origin, clamped to
/// unsigned 16-bit fields as above).
pub fn scissorAt(p: *hostpush.HostPush, x: i32, y: i32, w: u32, h: u32) void {
    const cx: u32 = @intCast(@max(x, 0));
    const cy: u32 = @intCast(@max(y, 0));
    const cw: u32 = @intCast(@max(@as(i64, x) + w - cx, 0));
    const ch: u32 = @intCast(@max(@as(i64, y) + h - cy, 0));
    p.immd(SUBCH_3D, SET_SCISSOR_ENABLE_0, 1);
    p.incr(SUBCH_3D, SET_SCISSOR_HORIZONTAL_0, 2);
    p.data(cx | ((cx + cw) << 16)); // XMIN | XMAX
    p.data(cy | ((cy + ch) << 16)); // YMIN | YMAX
}

/// Scissor test off (the rect registers keep their last value, inert).
pub fn scissorOff(p: *hostpush.HostPush) void {
    p.immd(SUBCH_3D, SET_SCISSOR_ENABLE_0, 0);
}

// §4 vertex input, §5 shader binding, draws
pub const SET_VERTEX_ATTRIBUTE_A_0: u32 = 0x1160; // +i*4, attrs 0..15
const SET_VERTEX_STREAM_A_LOCATION_A_0: u32 = 0x1c04; // +j*16 (VA hi/lo)
pub const SET_VERTEX_STREAM_A_FREQUENCY_0: u32 = 0x1c0c; // +j*16
pub const SET_VERTEX_STREAM_SIZE_A_0: u32 = 0x0600; // +j*8 (hi/lo bytes)
pub const SET_PIPELINE_SHADER_0: u32 = 0x2000; // +j*64
pub const SET_PIPELINE_REGISTER_COUNT_0: u32 = 0x200c; // +j*64
const SET_PIPELINE_BINDING_0: u32 = 0x2010; // +j*64
const SET_PIPELINE_PROGRAM_ADDRESS_A_0: u32 = 0x2014; // +j*64 (hi/lo)
const INVALIDATE_SHADER_CACHES_NO_WFI: u32 = 0x0da4;
pub const SET_GLOBAL_BASE_VERTEX_INDEX: u32 = 0x1434;
pub const SET_GLOBAL_BASE_INSTANCE_INDEX: u32 = 0x1438;
pub const SET_VERTEX_ID_BASE: u32 = 0x1118;
pub const SET_INSTANCE_COUNT: u32 = 0x0220;
pub const BEGIN: u32 = 0x1618;
pub const SET_VERTEX_ARRAY_START: u32 = 0x0d74; // +DRAW_VERTEX_ARRAY 0x0d78, one run
pub const END: u32 = 0x1614;

/// Pipeline slots (SET_PIPELINE_SHADER TYPE, clc997.h:4359-4370).
pub const SLOT_VERTEX: u32 = 1;
pub const SLOT_PIXEL: u32 = 5;

/// Vertex attribute formats (§4): COMPONENT_BIT_WIDTHS 26:21 | NUMERICAL_TYPE
/// 29:27 composites for the formats kudos uses.
pub const ATTR_R32G32B32_FLOAT: u32 = (0x02 << 21) | (7 << 27);
pub const ATTR_R32G32_FLOAT: u32 = (0x04 << 21) | (7 << 27);

/// Enable pipeline slot `slot` with a shader: register count, cbuf bind
/// group (VS=0, FS=4 — NVK convention the blobs were compiled against),
/// PROGRAM_ADDRESS → the SPH VA (absolute; 0x80-aligned).
pub fn pipelineShader(p: *hostpush.HostPush, slot: u32, gprs: u32, group: u32, sph_va: u64) void {
    p.immd(SUBCH_3D, SET_PIPELINE_SHADER_0 + slot * 64, @intCast(1 | (slot << 4))); // ENABLE|TYPE
    p.incr(SUBCH_3D, SET_PIPELINE_REGISTER_COUNT_0 + slot * 64, 4);
    p.data(gprs); // REGISTER_COUNT
    p.data(group); // BINDING: cbuf group
    p.data(@intCast(sph_va >> 32)); // PROGRAM_ADDRESS_A
    p.data(@truncate(sph_va)); // PROGRAM_ADDRESS_B
}

/// Invalidate instruction+constant shader caches after (re)writing programs
/// (NVK sends it each cmdbuf begin).
pub fn invalidateShaderCaches(p: *hostpush.HostPush) void {
    p.incr(SUBCH_3D, INVALIDATE_SHADER_CACHES_NO_WFI, 1);
    p.data((1 << 0) | (1 << 12)); // INSTRUCTION | CONSTANT
}

/// Describe vertex attribute `i`: sourced from stream 0 at byte `offset`,
/// with an ATTR_* format composite.
pub fn vertexAttrib(p: *hostpush.HostPush, i: u32, offset: u32, format: u32) void {
    p.incr(SUBCH_3D, SET_VERTEX_ATTRIBUTE_A_0 + i * 4, 1);
    p.data(0 | (offset << 7) | format); // STREAM=0, SOURCE_ACTIVE
}

/// Enable vertex stream 0: stride, base VA, byte size, per-vertex stepping.
pub fn vertexStream0(p: *hostpush.HostPush, va: u64, stride: u32, size: u64) void {
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_A_FORMAT_0, 3);
    p.data(stride | (1 << 12)); // ENABLE
    p.data(@intCast(va >> 32)); // LOCATION_A
    p.data(@truncate(va)); // LOCATION_B
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_A_FREQUENCY_0, 1);
    p.data(0); // per-vertex
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_SIZE_A_0, 2);
    p.data(@intCast(size >> 32));
    p.data(@truncate(size));
}

/// Describe attribute `attr` (its shader-input location) as sourced from vertex STREAM
/// `stream` at byte `offset` within the element, with an ATTR_* format composite. The
/// general form of `vertexAttrib`, which fixes stream 0: the 2D toolkit gathers each of
/// its attributes into its own tightly-packed region of one staging buffer, so each
/// attribute is its own stream. STREAM is field 4:0, SOURCE 6:6 (0 = ACTIVE), OFFSET
/// 20:7.
pub fn vertexAttribAt(p: *hostpush.HostPush, attr: u32, stream: u32, offset: u32, format: u32) void {
    p.incr(SUBCH_3D, SET_VERTEX_ATTRIBUTE_A_0 + attr * 4, 1);
    p.data((stream & 0x1f) | (offset << 7) | format);
}

/// Enable vertex stream `j` (streams 0..15, A-bank): stride, base VA, byte size,
/// per-vertex stepping. The general form of `vertexStream0`. The three
/// stream-descriptor methods (FORMAT, LOCATION_A, LOCATION_B) sit consecutively so one
/// run of 3 programs them, then FREQUENCY and SIZE at their own per-stream offsets.
pub fn vertexStreamAt(p: *hostpush.HostPush, j: u32, va: u64, stride: u32, size: u64) void {
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_A_FORMAT_0 + j * 16, 3);
    p.data(stride | (1 << 12)); // ENABLE
    p.data(@intCast(va >> 32)); // LOCATION_A
    p.data(@truncate(va)); // LOCATION_B
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_A_FREQUENCY_0 + j * 16, 1);
    p.data(0); // per-vertex
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_SIZE_A_0 + j * 8, 2);
    p.data(@intCast(size >> 32));
    p.data(@truncate(size));
}

// §2 depth target, §6 constant buffers (offsets from clc997.h)
pub const SET_ZT_A: u32 = 0x0fe0; // A,B,FORMAT,BLOCK_SIZE,ARRAY_PITCH (one run of 5)
pub const SET_ZT_SIZE_A: u32 = 0x1228; // A,B,C (one run of 3)
pub const SET_ZT_LAYER: u32 = 0x179c;
pub const SET_Z_COMPRESSION: u32 = 0x19cc;
pub const SET_ZT_SPARSE: u32 = 0x1208;
const SET_DEPTH_TEST: u32 = 0x12cc;
const SET_DEPTH_WRITE: u32 = 0x12e8;
const SET_DEPTH_FUNC: u32 = 0x130c;
pub const SET_CONSTANT_BUFFER_SELECTOR_A: u32 = 0x2380; // SIZE, ADDR_HI, ADDR_LO (run of 3)
pub const LOAD_CONSTANT_BUFFER_OFFSET: u32 = 0x238c; // then LOAD_CONSTANT_BUFFER(i) data

pub const ZT_FORMAT_ZF32: u32 = 0x0A;
pub const DEPTH_FUNC_LESS: u32 = 0x201; // OGL_LESS

/// Bind the block-linear Z target (Z is NEVER pitch-linear). `row_elems` = row
/// stride ÷ bpp; `bh_log2` from til.blockHeightLog2.
pub fn depthTargetBl(p: *hostpush.HostPush, va: u64, row_elems: u32, h: u32, bh_log2: u5) void {
    p.incr(SUBCH_3D, SET_ZT_A, 5);
    p.data(@intCast(va >> 32)); // A
    p.data(@truncate(va)); // B
    p.data(ZT_FORMAT_ZF32); // FORMAT
    p.data(@as(u32, bh_log2) << 4); // BLOCK_SIZE: WIDTH=0, HEIGHT=log2, DEPTH=0
    p.data(0); // ARRAY_PITCH
    p.incr(SUBCH_3D, SET_ZT_SIZE_A, 3);
    p.data(row_elems); // SIZE_A
    p.data(h); // SIZE_B
    p.data(1); // SIZE_C: THIRD_DIMENSION=1, array control
    p.immd(SUBCH_3D, SET_ZT_SELECT, 1); // depth on
    p.immd(SUBCH_3D, SET_ZT_LAYER, 0);
    // NVK emits both unconditionally with the ZT (nvk_cmd_draw.c:1292-1297):
    // Z compression must be OFF for our uncompressed GENERIC-kind surface
    // (default is TRUE → ROP compressed writes against an uncompressed
    // mapping), and ZT sparse off.
    p.immd(SUBCH_3D, SET_Z_COMPRESSION, 0);
    p.immd(SUBCH_3D, SET_ZT_SPARSE, 0);
}

/// Depth test LESS + write enabled (the 3D model path).
pub fn depthTestOn(p: *hostpush.HostPush) void {
    p.immd(SUBCH_3D, SET_DEPTH_TEST, 1);
    p.immd(SUBCH_3D, SET_DEPTH_WRITE, 1);
    p.immd(SUBCH_3D, SET_DEPTH_FUNC, DEPTH_FUNC_LESS);
}

/// Depth fully off (test + writes) — the MSAA resolve pass draws its
/// fullscreen triangle with the (still bound) MSAA ZT untouched.
pub fn depthTestOff(p: *hostpush.HostPush) void {
    p.immd(SUBCH_3D, SET_DEPTH_TEST, 0);
    p.immd(SUBCH_3D, SET_DEPTH_WRITE, 0);
}

// ── MSAA — SET_ANTI_ALIAS is declared with the ctx-init constants above ──────
const SET_HYBRID_ANTI_ALIAS_CONTROL: u32 = 0x0754;
const SET_ANTI_ALIAS_SAMPLE_POSITIONS_0: u32 = 0x11e0;
pub const AA_MODE_1X1: u32 = 0; // single-sampled
pub const AA_MODE_4X2_D3D: u32 = 4; // 8 samples (the Vulkan 8x mapping)

/// Rasterizer sample mode + single-pass hybrid control (PASSES=1, CENTROID
/// PER_FRAGMENT — plain MSAA, no sample shading).
pub fn setAntiAlias(p: *hostpush.HostPush, mode: u32) void {
    p.immd(SUBCH_3D, SET_ANTI_ALIAS, @intCast(mode & 0xf));
    p.immd(SUBCH_3D, SET_HYBRID_ANTI_ALIAS_CONTROL, 1);
}

/// The standard Vulkan 8x sample positions (u4.4 sub-pixel, 4 per dword, a
/// 2x2-pixel group with the 8 per-pixel locations repeating) — the same two
/// dwords the NAK root cbuf's draw.sample_locations bytes form.
pub const AA_8X_POSITIONS = [4]u32{ 0x359DB759, 0x1FFB71D3, 0x359DB759, 0x1FFB71D3 };

pub fn setAaSamplePositions8x(p: *hostpush.HostPush) void {
    p.incr(SUBCH_3D, SET_ANTI_ALIAS_SAMPLE_POSITIONS_0, 4);
    for (AA_8X_POSITIONS) |d| p.data(d);
}

/// Select the uniform buffer as cb0 and attach it to bind groups 0 (vertex)
/// and 4 (fragment), slot 0 — the groups the blobs were compiled against.
/// `size` ≤ 0x10000, 256-B aligned VA.
pub fn bindCb0(p: *hostpush.HostPush, va: u64, size: u32) void {
    p.incr(SUBCH_3D, SET_CONSTANT_BUFFER_SELECTOR_A, 3);
    p.data(size);
    p.data(@intCast(va >> 32));
    p.data(@truncate(va));
    p.immd(SUBCH_3D, BIND_GROUP_CONSTANT_BUFFER_0 + 0 * 32, 1 | (0 << 4)); // VS group, slot 0, VALID
    p.immd(SUBCH_3D, BIND_GROUP_CONSTANT_BUFFER_0 + 4 * 32, 1 | (0 << 4)); // FS group, slot 0, VALID
}

/// Write `words` into the SELECTED constant buffer at byte `offset` through
/// the method stream (the NVK push-constant path — no CPU/GPU coherence to
/// manage). Re-select cb0 (bindCb0) before this if another cbuf was selected.
/// MUST be an increment-once run: LOAD_CONSTANT_BUFFER has a 16-register
/// method window; an incrementing run longer than 16 walks off it and hangs
/// the engine (observed on HW).
pub fn loadCb(p: *hostpush.HostPush, offset: u32, words: []const u32) void {
    p.incOnce(SUBCH_3D, LOAD_CONSTANT_BUFFER_OFFSET, @intCast(1 + words.len));
    p.data(offset);
    for (words) |w| p.data(w);
}

// §7 texture pools
const SET_TEX_SAMPLER_POOL_A: u32 = 0x155c; // A,B,C (va hi/lo, max index)
const SET_TEX_HEADER_POOL_A: u32 = 0x1574; // A,B,C

// Blend + composite-pass state
const SET_BLEND_COLOR_OP: u32 = 0x1340; // OP, SRC_COEFF, DST_COEFF (run of 3)
const SET_BLEND_ALPHA_OP: u32 = 0x134c; // OP, SRC_COEFF, (0x1354 skip), DST 0x1358
const SET_BLEND_ALPHA_SOURCE_COEFF: u32 = 0x1350;
const SET_BLEND_ALPHA_DEST_COEFF: u32 = 0x1358;
const INVALIDATE_TEXTURE_DATA_CACHE: u32 = 0x1338;
const BLEND_OP_ADD: u32 = 0x8006; // OGL_FUNC_ADD
const BLEND_COEFF_ONE: u32 = 0x4001;
const BLEND_COEFF_INV_SRC_ALPHA: u32 = 0x4303;

/// Color-target count: 0 = depth-only pass (shadow map), 1 = RT0.
pub fn ctSelect(p: *hostpush.HostPush, count: u32) void {
    p.immd(SUBCH_3D, SET_CT_SELECT, @intCast(count & 0xf));
}

/// Premultiplied-alpha blending on RT0: rgb = src + dst*(1-a), same for
/// alpha. (Our GL surfaces are premultiplied — alpha 0 background, opaque
/// pixels rgb*1.)
pub fn blendPremultOn(p: *hostpush.HostPush) void {
    p.incr(SUBCH_3D, SET_BLEND_COLOR_OP, 3);
    p.data(BLEND_OP_ADD);
    p.data(BLEND_COEFF_ONE); // COLOR_SOURCE
    p.data(BLEND_COEFF_INV_SRC_ALPHA); // COLOR_DEST
    p.incr(SUBCH_3D, SET_BLEND_ALPHA_OP, 2);
    p.data(BLEND_OP_ADD);
    p.data(BLEND_COEFF_ONE); // ALPHA_SOURCE
    p.incr(SUBCH_3D, SET_BLEND_ALPHA_DEST_COEFF, 1);
    p.data(BLEND_COEFF_INV_SRC_ALPHA);
    p.immd(SUBCH_3D, SET_BLEND_0, 1);
}

pub fn blendOff(p: *hostpush.HostPush) void {
    p.immd(SUBCH_3D, SET_BLEND_0, 0);
}

/// Invalidate the texture data cache — required between rendering INTO a
/// surface and SAMPLING it (RTT read-after-write; pair with a host WFI).
pub fn invalidateTexCache(p: *hostpush.HostPush) void {
    p.incr(SUBCH_3D, INVALIDATE_TEXTURE_DATA_CACHE, 1);
    p.data(0);
}

/// Bind the TIC + TSC pools (32-B entries; maxIndex = count-1).
pub fn texPools(p: *hostpush.HostPush, tic_va: u64, tic_count: u32, tsc_va: u64, tsc_count: u32) void {
    p.incr(SUBCH_3D, SET_TEX_HEADER_POOL_A, 3);
    p.data(@intCast(tic_va >> 32));
    p.data(@truncate(tic_va));
    p.data(tic_count - 1);
    p.incr(SUBCH_3D, SET_TEX_SAMPLER_POOL_A, 3);
    p.data(@intCast(tsc_va >> 32));
    p.data(@truncate(tsc_va));
    p.data(tsc_count - 1);
}

/// Select a buffer and attach it to one bind-group cbuf slot (the general
/// form of bindCb0; slot 1 of group 4 = the fragment descriptor-set cbuf
/// in NAK's cbuf_map order).
pub fn bindCbSlot(p: *hostpush.HostPush, va: u64, size: u32, group: u32, slot: u32) void {
    p.incr(SUBCH_3D, SET_CONSTANT_BUFFER_SELECTOR_A, 3);
    p.data(size);
    p.data(@intCast(va >> 32));
    p.data(@truncate(va));
    p.immd(SUBCH_3D, BIND_GROUP_CONSTANT_BUFFER_0 + group * 32, @intCast(1 | (slot << 4)));
}

/// Depth-only clear of the bound ZT (CLEAR_SURFACE Z_ENABLE alone).
pub fn clearZOnly(p: *hostpush.HostPush, z: f32) void {
    p.immd(SUBCH_3D, SET_CLEAR_SURFACE_CONTROL, 0);
    p.incr(SUBCH_3D, SET_Z_CLEAR_VALUE, 1);
    p.data(@bitCast(z));
    p.incr(SUBCH_3D, CLEAR_SURFACE, 1);
    p.data(0x1); // Z only
}

/// Full clear of RT0 color AND depth (Z_ENABLE | RGBA).
pub fn clearColorDepth(p: *hostpush.HostPush, r: f32, g: f32, b: f32, a: f32, z: f32) void {
    p.immd(SUBCH_3D, SET_CLEAR_SURFACE_CONTROL, 0);
    p.incr(SUBCH_3D, SET_COLOR_CLEAR_VALUE_0, 4);
    p.data(@bitCast(r));
    p.data(@bitCast(g));
    p.data(@bitCast(b));
    p.data(@bitCast(a));
    p.incr(SUBCH_3D, SET_Z_CLEAR_VALUE, 1);
    p.data(@bitCast(z));
    p.incr(SUBCH_3D, CLEAR_SURFACE, 1);
    p.data(0x3d); // Z | R|G|B|A
}

// Indexed draws (doc "Indexed draw" block)
pub const SET_INDEX_BUFFER_A: u32 = 0x17c8; // A,B = VA hi/lo
pub const SET_INDEX_BUFFER_SIZE_A: u32 = 0x0238; // A,B = size hi/lo bytes
pub const SET_INDEX_BUFFER_E: u32 = 0x17d8; // INDEX_SIZE: 0=u8 1=u16 2=u32
const SET_INDEX_BUFFER_F: u32 = 0x17dc; // first index; +DRAW_INDEX_BUFFER 0x17e0
pub const SET_DA_PRIMITIVE_RESTART_INDEX: u32 = 0x1648;

/// Bind a u32 index buffer (once per mesh).
pub fn indexBufferU32(p: *hostpush.HostPush, va: u64, bytes_len: u64) void {
    p.incr(SUBCH_3D, SET_INDEX_BUFFER_A, 2);
    p.data(@intCast(va >> 32));
    p.data(@truncate(va));
    p.incr(SUBCH_3D, SET_INDEX_BUFFER_SIZE_A, 2);
    p.data(@intCast(bytes_len >> 32));
    p.data(@truncate(bytes_len));
    p.immd(SUBCH_3D, SET_INDEX_BUFFER_E, 2); // u32 indices
    p.incr(SUBCH_3D, SET_DA_PRIMITIVE_RESTART_INDEX, 1);
    p.data(0xffffffff);
}

/// Bind an index buffer of a given width (`size_code` from lower.indexSize: 0=u8,
/// 1=u16, 2=u32). The general form of indexBufferU32 — the model viewer draws u16
/// indices, not only u32.
pub fn indexBufferTyped(p: *hostpush.HostPush, va: u64, bytes_len: u64, size_code: u32) void {
    p.incr(SUBCH_3D, SET_INDEX_BUFFER_A, 2);
    p.data(@intCast(va >> 32));
    p.data(@truncate(va));
    p.incr(SUBCH_3D, SET_INDEX_BUFFER_SIZE_A, 2);
    p.data(@intCast(bytes_len >> 32));
    p.data(@truncate(bytes_len));
    p.immd(SUBCH_3D, SET_INDEX_BUFFER_E, @intCast(size_code));
    p.incr(SUBCH_3D, SET_DA_PRIMITIVE_RESTART_INDEX, 1);
    p.data(0xffffffff);
}

/// Indexed TRIANGLES draw from the bound index buffer.
pub fn drawIndexed(p: *hostpush.HostPush, first: u32, count: u32) void {
    p.immd(SUBCH_3D, SET_GLOBAL_BASE_INSTANCE_INDEX, 0);
    p.immd(SUBCH_3D, SET_GLOBAL_BASE_VERTEX_INDEX, 0);
    p.immd(SUBCH_3D, SET_VERTEX_ID_BASE, 0);
    p.immd(SUBCH_3D, SET_INSTANCE_COUNT, 1);
    p.incr(SUBCH_3D, BEGIN, 1);
    p.data(4); // TRIANGLES
    p.incr(SUBCH_3D, SET_INDEX_BUFFER_F, 2);
    p.data(first);
    p.data(count); // DRAW_INDEX_BUFFER
    p.immd(SUBCH_3D, END, 0);
}

/// Non-indexed TRIANGLES draw (per-draw sequence at the top of the doc).
pub fn drawTriangles(p: *hostpush.HostPush, first: u32, count: u32) void {
    p.immd(SUBCH_3D, SET_GLOBAL_BASE_INSTANCE_INDEX, 0);
    p.immd(SUBCH_3D, SET_GLOBAL_BASE_VERTEX_INDEX, 0);
    p.immd(SUBCH_3D, SET_VERTEX_ID_BASE, 0);
    p.immd(SUBCH_3D, SET_INSTANCE_COUNT, 1);
    p.incr(SUBCH_3D, BEGIN, 1);
    p.data(4); // OP_TRIANGLES, no instance iterate
    p.incr(SUBCH_3D, SET_VERTEX_ARRAY_START, 2);
    p.data(first);
    p.data(count); // DRAW_VERTEX_ARRAY
    p.immd(SUBCH_3D, END, 0);
}

/// Full-target color clear of RT0 (§3). rgba components in [0,1].
pub fn clearColor(p: *hostpush.HostPush, r: f32, g: f32, b: f32, a: f32) void {
    p.immd(SUBCH_3D, SET_CLEAR_SURFACE_CONTROL, 0);
    p.incr(SUBCH_3D, SET_COLOR_CLEAR_VALUE_0, 4);
    p.data(@bitCast(r));
    p.data(@bitCast(g));
    p.data(@bitCast(b));
    p.data(@bitCast(a));
    p.incr(SUBCH_3D, CLEAR_SURFACE, 1);
    p.data(0x3c); // R|G|B|A (bits 2..5), no Z/stencil, MRT 0
}

// ── host golden tests ────────────────────────────────────────────────────────
// Header encoding: (SEC_OP<<29)|(COUNT<<16)|(SUBCH<<13)|(METHOD>>2);
// INC=1, IMMD=4.

pub fn hdrInc(mthd: u32, count: u32) u32 {
    return (1 << 29) | (count << 16) | (SUBCH_3D << 13) | (mthd >> 2);
}
pub fn hdrImmd(mthd: u32, val: u32) u32 {
    return (4 << 29) | (val << 16) | (SUBCH_3D << 13) | (mthd >> 2);
}
pub fn hdrIncOnce(mthd: u32, count: u32) u32 {
    return (5 << 29) | (count << 16) | (SUBCH_3D << 13) | (mthd >> 2);
}
