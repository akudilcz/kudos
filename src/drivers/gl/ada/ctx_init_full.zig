//! Full NVK one-time 3D context init for ADA_A (0xc997) — PURE module
//! (imports only hostpush).
//!
//! Every method and value is the hardware's own encoding, cross-checked against
//! mesa-26.0.3
//! src/nouveau/vulkan/nvk_cmd_draw.c `nvk_push_draw_state_init` (lines
//! 139-655), offsets/bitfields from headers/nvidia/classes/clc997.h.
//! Ada path only: code guarded `< VOLTA/TURING/MAXWELL` is dead on AD102
//! and omitted; `>= BLACKWELL_A` likewise. MME macro/scratch traffic is
//! skipped (see the SKIPPED block at the bottom). Subchannel 0 throughout.

pub const hostpush = @import("hostpush");

pub const SUBCH_3D: u32 = 0;

// Method offsets (clc997.h), in NVK emission order.
const SET_OBJECT: u32 = 0x0000;
const SET_MME_DATA_FIFO_CONFIG: u32 = 0x0574;
const SET_TESSELLATION_PARAMETERS: u32 = 0x0320;
const SET_RENDER_ENABLE_C: u32 = 0x1558;
const SET_Z_COMPRESSION: u32 = 0x19cc;
const SET_COLOR_COMPRESSION_0: u32 = 0x19e0; // +i*4
const SET_CT_SELECT: u32 = 0x121c;
const SET_ALIASED_LINE_WIDTH_ENABLE: u32 = 0x020c;
const SET_DA_PRIMITIVE_RESTART_VERTEX_ARRAY: u32 = 0x0de8;
const SET_BLEND_SEPARATE_FOR_ALPHA: u32 = 0x133c;
const SET_SINGLE_CT_WRITE_CONTROL: u32 = 0x0f90;
const SET_SINGLE_ROP_CONTROL: u32 = 0x135c;
const SET_TWO_SIDED_STENCIL_TEST: u32 = 0x1594;
const SET_ALPHA_TO_COVERAGE_OVERRIDE: u32 = 0x16b4;
const SET_SHADE_MODE: u32 = 0x12d4;
const SET_API_VISIBLE_CALL_LIMIT: u32 = 0x0d64;
const SET_ZCULL_STATS: u32 = 0x151c;
const SET_L1_CONFIGURATION: u32 = 0x0308;
const SET_REDUCE_COLOR_THRESHOLDS_ENABLE: u32 = 0x0d9c;
const SET_REDUCE_COLOR_THRESHOLDS_UNORM8: u32 = 0x10cc;
const SET_REDUCE_COLOR_THRESHOLDS_UNORM10: u32 = 0x10e0; // then UNORM16,FP11,FP16,SRGB8 (run of 5)
const CHECK_SPH_VERSION: u32 = 0x16a8;
const CHECK_AAM_VERSION: u32 = 0x1794;
const SET_L2_CACHE_CONTROL_FOR_ROP_PREFETCH_READ_REQUESTS: u32 = 0x0218;
const SET_L2_CACHE_CONTROL_FOR_ROP_NONINTERLOCKED_READ_REQUESTS: u32 = 0x10fc;
const SET_L2_CACHE_CONTROL_FOR_ROP_INTERLOCKED_READ_REQUESTS: u32 = 0x1290;
const SET_L2_CACHE_CONTROL_FOR_ROP_NONINTERLOCKED_WRITE_REQUESTS: u32 = 0x12d8;
const SET_L2_CACHE_CONTROL_FOR_ROP_INTERLOCKED_WRITE_REQUESTS: u32 = 0x12dc;
const SET_BLEND_PER_FORMAT_ENABLE: u32 = 0x1140;
const SET_ATTRIBUTE_DEFAULT: u32 = 0x1610;
const SET_DA_OUTPUT: u32 = 0x164c;
const SET_RENDER_ENABLE_CONTROL: u32 = 0x030c;
const SET_PS_OUTPUT_SAMPLE_MASK_USAGE: u32 = 0x0300;
const SET_BLEND_OPT_CONTROL: u32 = 0x0fdc;
const SET_BLEND_FLOAT_OPTION: u32 = 0x19c0;
const SET_BLEND_STATE_PER_TARGET: u32 = 0x12e4;
const SET_ALPHA_TEST: u32 = 0x12ec;
const SET_TWO_SIDED_LIGHT: u32 = 0x1688;
const SET_COLOR_CLAMP: u32 = 0x2600;
const SET_PS_SATURATE: u32 = 0x13a8;
const SET_ZPASS_PIXEL_COUNT: u32 = 0x1514;
const SET_POINT_SIZE: u32 = 0x1518;
const SET_ATTRIBUTE_POINT_SIZE: u32 = 0x1910;
const SET_POINT_SPRITE: u32 = 0x1520;
const SET_POINT_SPRITE_SELECT: u32 = 0x1604;
const SET_ANTI_ALIASED_POINT: u32 = 0x1658;
const SET_FILL_VIA_TRIANGLE: u32 = 0x113c; // NVB197_
const SET_POLY_SMOOTH: u32 = 0x0db4;
const SET_VIEWPORT_PIXEL: u32 = 0x1924;
const SET_ANTI_ALIAS_ENABLE: u32 = 0x1534;
const SET_POST_PS_INITIAL_COVERAGE: u32 = 0x1138; // NVB197_
const SET_OFFSET_RENDER_TARGET_INDEX: u32 = 0x11f0; // NVB197_
const SET_WINDOW_ORIGIN: u32 = 0x13ac;
const SET_WINDOW_OFFSET_X: u32 = 0x0df8; // then _Y (run of 2)
const SET_ACTIVE_ZCULL_REGION: u32 = 0x1590;
const SET_CLIP_ID_TEST: u32 = 0x197c;
const SET_VIEWPORT_SCALE_OFFSET: u32 = 0x192c;
const SET_VIEWPORT_CLIP_CONTROL: u32 = 0x193c;
const SET_SCISSOR_ENABLE_0: u32 = 0x0e00; // +i*16
const SET_CT_MRT_ENABLE: u32 = 0x0fac;
const SET_VARIABLE_PIXEL_RATE_SAMPLE_ORDER_0: u32 = 0x0280; // +i*4, NVC597_
const SET_SHADER_LOCAL_MEMORY_WINDOW: u32 = 0x077c;
const BIND_GROUP_CONSTANT_BUFFER_0: u32 = 0x2410; // +g*32
const SET_RT_LAYER: u32 = 0x15cc;
const SET_POINT_CENTER_MODE: u32 = 0x165c;
const SET_EDGE_FLAG: u32 = 0x15e4;
const SET_SAMPLER_BINDING: u32 = 0x1234;
const SET_VERTEX_STREAM_SUBSTITUTE_A: u32 = 0x0f84; // then _B (run of 2)
const SET_PS_WARP_WATERMARKS: u32 = 0x1450;
const SET_PS_REGISTER_WATERMARKS: u32 = 0x1454;
const SET_VERTEX_STREAM_A_FORMAT_0: u32 = 0x1c00; // +b*16, b=0..31 (B array is contiguous)
const SET_GLOBAL_BASE_INSTANCE_INDEX: u32 = 0x1438;

/// Everything nvk_push_draw_state_init emits on an Ada (0xc997) device, in
/// the same order with the same values, minus the MME macro/scratch traffic
/// (see SKIPPED below). `zero_page_va` = mapped, zeroed page (NVK's
/// dev->zero_page equivalent) for the vertex-stream substitute.
pub fn emit(p: *hostpush.HostPush, zero_page_va: u64) void {
    // SET_OBJECT (nvk_cmd_draw.c:145): CLASS_ID 15:0 = 0xC997, ENGINE_ID 20:16 = 0
    p.incr(SUBCH_3D, SET_OBJECT, 1);
    p.data(0x0000c997);

    // SET_MME_DATA_FIFO_CONFIG (nvk_cmd_draw.c:174): FIFO_SIZE 2:0 = SIZE_4KB(1)
    p.immd(SUBCH_3D, SET_MME_DATA_FIFO_CONFIG, 1);

    // SET_TESSELLATION_PARAMETERS (nvk_cmd_draw.c:258): all fields 0
    // (DOMAIN_TYPE_ISOLINE, SPACING_INTEGER, OUTPUT_PRIMITIVES_POINTS)
    p.immd(SUBCH_3D, SET_TESSELLATION_PARAMETERS, 0);

    // SET_RENDER_ENABLE_C (nvk_cmd_draw.c:260): MODE 2:0 = TRUE(1)
    p.immd(SUBCH_3D, SET_RENDER_ENABLE_C, 1);

    // SET_Z_COMPRESSION (nvk_cmd_draw.c:262): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_Z_COMPRESSION, 1);

    // SET_COLOR_COMPRESSION(0..7) (nvk_cmd_draw.c:263-265): ENABLE_TRUE each
    p.incr(SUBCH_3D, SET_COLOR_COMPRESSION_0, 8);
    var cc: u32 = 0;
    while (cc < 8) : (cc += 1) p.data(1);

    // SET_CT_SELECT (nvk_cmd_draw.c:267): TARGET_COUNT 3:0 = 1, TARGET0..7 = 0
    p.immd(SUBCH_3D, SET_CT_SELECT, 1);

    // SET_ALIASED_LINE_WIDTH_ENABLE (nvk_cmd_draw.c:272): V_TRUE
    p.immd(SUBCH_3D, SET_ALIASED_LINE_WIDTH_ENABLE, 1);

    // SET_DA_PRIMITIVE_RESTART_VERTEX_ARRAY (nvk_cmd_draw.c:274): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_DA_PRIMITIVE_RESTART_VERTEX_ARRAY, 0);

    // SET_BLEND_SEPARATE_FOR_ALPHA (nvk_cmd_draw.c:276): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_BLEND_SEPARATE_FOR_ALPHA, 1);
    // SET_SINGLE_CT_WRITE_CONTROL (nvk_cmd_draw.c:277): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_SINGLE_CT_WRITE_CONTROL, 1);
    // SET_SINGLE_ROP_CONTROL (nvk_cmd_draw.c:278): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_SINGLE_ROP_CONTROL, 0);
    // SET_TWO_SIDED_STENCIL_TEST (nvk_cmd_draw.c:279): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_TWO_SIDED_STENCIL_TEST, 1);

    // SET_ALPHA_TO_COVERAGE_OVERRIDE (nvk_cmd_draw.c:281):
    // QUALIFY_BY_ANTI_ALIAS_ENABLE 0:0 = 1 | QUALIFY_BY_PS_SAMPLE_MASK_OUTPUT 1:1 = 0
    p.immd(SUBCH_3D, SET_ALPHA_TO_COVERAGE_OVERRIDE, 0x1);

    // SET_SHADE_MODE (nvk_cmd_draw.c:286): V_OGL_SMOOTH = 0x1D01
    p.immd(SUBCH_3D, SET_SHADE_MODE, 0x1d01);

    // SET_API_VISIBLE_CALL_LIMIT (nvk_cmd_draw.c:288): V__128 = 8
    p.immd(SUBCH_3D, SET_API_VISIBLE_CALL_LIMIT, 8);

    // SET_ZCULL_STATS (nvk_cmd_draw.c:290): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_ZCULL_STATS, 1);

    // SET_L1_CONFIGURATION (nvk_cmd_draw.c:292):
    // DIRECTLY_ADDRESSABLE_MEMORY 2:0 = SIZE_48KB(3)
    p.immd(SUBCH_3D, SET_L1_CONFIGURATION, 3);

    // SET_REDUCE_COLOR_THRESHOLDS_ENABLE (nvk_cmd_draw.c:295): V_FALSE
    p.immd(SUBCH_3D, SET_REDUCE_COLOR_THRESHOLDS_ENABLE, 0);
    // SET_REDUCE_COLOR_THRESHOLDS_UNORM8 (nvk_cmd_draw.c:296):
    // ALL_COVERED_ALL_HIT_ONCE 7:0 = 0xff
    p.immd(SUBCH_3D, SET_REDUCE_COLOR_THRESHOLDS_UNORM8, 0xff);
    // SET_REDUCE_COLOR_THRESHOLDS_{UNORM10,UNORM16,FP11,FP16,SRGB8}
    // (nvk_cmd_draw.c:299-314): contiguous run of 5
    p.incr(SUBCH_3D, SET_REDUCE_COLOR_THRESHOLDS_UNORM10, 5);
    p.data(0xff); // UNORM10 ALL_COVERED_ALL_HIT_ONCE 7:0
    p.data(0xff); // UNORM16 ALL_COVERED_ALL_HIT_ONCE 7:0
    p.data(0x3f); // FP11    ALL_COVERED_ALL_HIT_ONCE 5:0
    p.data(0xff); // FP16    ALL_COVERED_ALL_HIT_ONCE 7:0
    p.data(0xff); // SRGB8   ALL_COVERED_ALL_HIT_ONCE 7:0

    // CHECK_SPH_VERSION (nvk_cmd_draw.c:319): CURRENT 15:0 = 3 | OLDEST_SUPPORTED 31:16 = 3
    p.incr(SUBCH_3D, CHECK_SPH_VERSION, 1);
    p.data(0x00030003);
    // CHECK_AAM_VERSION (nvk_cmd_draw.c:323): CURRENT 15:0 = 2 | OLDEST_SUPPORTED 31:16 = 2
    p.incr(SUBCH_3D, CHECK_AAM_VERSION, 1);
    p.data(0x00020002);

    // SET_L2_CACHE_CONTROL_FOR_ROP_* (nvk_cmd_draw.c:331-340):
    // POLICY 5:4 = EVICT_NORMAL(1) -> 0x10 each
    p.immd(SUBCH_3D, SET_L2_CACHE_CONTROL_FOR_ROP_PREFETCH_READ_REQUESTS, 0x10);
    p.immd(SUBCH_3D, SET_L2_CACHE_CONTROL_FOR_ROP_NONINTERLOCKED_READ_REQUESTS, 0x10);
    p.immd(SUBCH_3D, SET_L2_CACHE_CONTROL_FOR_ROP_INTERLOCKED_READ_REQUESTS, 0x10);
    p.immd(SUBCH_3D, SET_L2_CACHE_CONTROL_FOR_ROP_NONINTERLOCKED_WRITE_REQUESTS, 0x10);
    p.immd(SUBCH_3D, SET_L2_CACHE_CONTROL_FOR_ROP_INTERLOCKED_WRITE_REQUESTS, 0x10);

    // SET_BLEND_PER_FORMAT_ENABLE (nvk_cmd_draw.c:342):
    // SNORM8_UNORM16_SNORM16 4:4 = TRUE -> 0x10
    p.immd(SUBCH_3D, SET_BLEND_PER_FORMAT_ENABLE, 0x10);

    // SET_ATTRIBUTE_DEFAULT (nvk_cmd_draw.c:344): COLOR_FRONT_DIFFUSE 0:0 =
    // VECTOR_0001(0) | COLOR_FRONT_SPECULAR 1:1 = VECTOR_0001(1) |
    // GENERIC_VECTOR 2:2 = VECTOR_0001(1) | FIXED_FNC_TEXTURE 3:3 =
    // VECTOR_0001(1) | DX9_COLOR0 4:4 = VECTOR_0001(0) |
    // DX9_COLOR1_TO_COLOR15 5:5 = VECTOR_0000(0) -> 0x0e
    p.immd(SUBCH_3D, SET_ATTRIBUTE_DEFAULT, 0x0e);

    // SET_DA_OUTPUT (nvk_cmd_draw.c:353): VERTEX_ID_USES_ARRAY_START 12:12 = TRUE -> 0x1000
    p.immd(SUBCH_3D, SET_DA_OUTPUT, 0x1000);

    // SET_RENDER_ENABLE_CONTROL (nvk_cmd_draw.c:355): CONDITIONAL_LOAD_CONSTANT_BUFFER_FALSE
    p.immd(SUBCH_3D, SET_RENDER_ENABLE_CONTROL, 0);

    // SET_PS_OUTPUT_SAMPLE_MASK_USAGE (nvk_cmd_draw.c:358):
    // ENABLE 0:0 = 1 | QUALIFY_BY_ANTI_ALIAS_ENABLE 1:1 = 1 -> 0x3
    p.immd(SUBCH_3D, SET_PS_OUTPUT_SAMPLE_MASK_USAGE, 0x3);

    // SET_BLEND_OPT_CONTROL (nvk_cmd_draw.c:366): ALLOW_FLOAT_PIXEL_KILLS_TRUE
    p.immd(SUBCH_3D, SET_BLEND_OPT_CONTROL, 1);
    // SET_BLEND_FLOAT_OPTION (nvk_cmd_draw.c:367): ZERO_TIMES_ANYTHING_IS_ZERO_TRUE
    p.immd(SUBCH_3D, SET_BLEND_FLOAT_OPTION, 1);
    // SET_BLEND_STATE_PER_TARGET: ENABLE_FALSE — deliberately NOT NVK's TRUE
    // (nvk_cmd_draw.c:368). With per-target blend state enabled the hardware ignores
    // the COMMON blend registers (SET_BLEND_COLOR_OP.. at 0x1340-0x1358, the ones the
    // draw path programs) in favour of per-target registers nothing here ever writes —
    // so every "translucent" draw lands opaque. kudos renders to ONE colour target and
    // programs blending through the common state, so the common state must be live.
    p.immd(SUBCH_3D, SET_BLEND_STATE_PER_TARGET, 0);

    // SET_ALPHA_TEST (nvk_cmd_draw.c:379): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_ALPHA_TEST, 0);
    // SET_TWO_SIDED_LIGHT (nvk_cmd_draw.c:380): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_TWO_SIDED_LIGHT, 0);
    // SET_COLOR_CLAMP (nvk_cmd_draw.c:381): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_COLOR_CLAMP, 1);
    // SET_PS_SATURATE (nvk_cmd_draw.c:382): OUTPUT0..7 all FALSE -> 0
    p.immd(SUBCH_3D, SET_PS_SATURATE, 0);

    // SET_ZPASS_PIXEL_COUNT (nvk_cmd_draw.c:394): ENABLE_TRUE ("blob always leaves this on")
    p.immd(SUBCH_3D, SET_ZPASS_PIXEL_COUNT, 1);

    // SET_POINT_SIZE (nvk_cmd_draw.c:396): fui(1.0)
    p.incr(SUBCH_3D, SET_POINT_SIZE, 1);
    p.data(0x3f800000);
    // SET_ATTRIBUTE_POINT_SIZE (nvk_cmd_draw.c:397): ENABLE 0:0 = TRUE, SLOT 11:4 = 0
    p.immd(SUBCH_3D, SET_ATTRIBUTE_POINT_SIZE, 1);

    // SET_POINT_SPRITE (nvk_cmd_draw.c:424): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_POINT_SPRITE, 1);
    // SET_POINT_SPRITE_SELECT (nvk_cmd_draw.c:425): RMODE 1:0 = ZERO(0) |
    // ORIGIN 2:2 = TOP(1) | TEXTURE0..9 = PASSTHROUGH(0) -> 0x4
    p.immd(SUBCH_3D, SET_POINT_SPRITE_SELECT, 0x4);

    // SET_ANTI_ALIASED_POINT (nvk_cmd_draw.c:441): ENABLE_FALSE (GL_POINT_SMOOTH off)
    p.immd(SUBCH_3D, SET_ANTI_ALIASED_POINT, 0);

    // SET_FILL_VIA_TRIANGLE (nvk_cmd_draw.c:444, NVB197): MODE_DISABLED
    p.immd(SUBCH_3D, SET_FILL_VIA_TRIANGLE, 0);

    // SET_POLY_SMOOTH (nvk_cmd_draw.c:446): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_POLY_SMOOTH, 0);

    // SET_VIEWPORT_PIXEL (nvk_cmd_draw.c:448): CENTER_AT_HALF_INTEGERS = 0
    p.immd(SUBCH_3D, SET_VIEWPORT_PIXEL, 0);

    // SET_ANTI_ALIAS_ENABLE (nvk_cmd_draw.c:458): V_TRUE (always MSAA-rasterize
    // -> strict/rectangular lines)
    p.immd(SUBCH_3D, SET_ANTI_ALIAS_ENABLE, 1);

    // SET_POST_PS_INITIAL_COVERAGE (nvk_cmd_draw.c:461, NVB197): USE_PRE_PS_COVERAGE_TRUE
    p.immd(SUBCH_3D, SET_POST_PS_INITIAL_COVERAGE, 1);
    // SET_OFFSET_RENDER_TARGET_INDEX (nvk_cmd_draw.c:462, NVB197): BY_VIEWPORT_INDEX_FALSE
    p.immd(SUBCH_3D, SET_OFFSET_RENDER_TARGET_INDEX, 0);

    // SET_WINDOW_ORIGIN (nvk_cmd_draw.c:468): MODE 0:0 = UPPER_LEFT(0) | FLIP_Y 4:4 = FALSE(0)
    p.immd(SUBCH_3D, SET_WINDOW_ORIGIN, 0);

    // SET_WINDOW_OFFSET_X/_Y (nvk_cmd_draw.c:473-475): 0, 0
    p.incr(SUBCH_3D, SET_WINDOW_OFFSET_X, 2);
    p.data(0);
    p.data(0);

    // SET_ACTIVE_ZCULL_REGION (nvk_cmd_draw.c:477): ID 5:0 = 0x3f (no region)
    p.immd(SUBCH_3D, SET_ACTIVE_ZCULL_REGION, 0x3f);

    // SET_CLIP_ID_TEST (nvk_cmd_draw.c:481): ENABLE_FALSE
    p.immd(SUBCH_3D, SET_CLIP_ID_TEST, 0);

    // SET_VIEWPORT_SCALE_OFFSET (nvk_cmd_draw.c:488): ENABLE_TRUE
    p.immd(SUBCH_3D, SET_VIEWPORT_SCALE_OFFSET, 1);

    // SET_VIEWPORT_CLIP_CONTROL (nvk_cmd_draw.c:490): MIN_Z_ZERO_MAX_Z_ONE 0:0
    // = FALSE(0) | GEOMETRY_GUARDBAND_Z 2:1 = SAME_AS_XY_GUARDBAND(0) |
    // PIXEL_MIN_Z 3:3 = CLAMP(1) | PIXEL_MAX_Z 4:4 = CLAMP(1) |
    // GEOMETRY_GUARDBAND 7:7 = SCALE_256(0) | LINE_POINT_CULL_GUARDBAND 10:10
    // = SCALE_256(0) | GEOMETRY_CLIP 13:11 = WZERO_CLIP(0) -> 0x18
    p.immd(SUBCH_3D, SET_VIEWPORT_CLIP_CONTROL, 0x18);

    // SET_SCISSOR_ENABLE(0..15) (nvk_cmd_draw.c:500-501): V_FALSE each
    var sc: u32 = 0;
    while (sc < 16) : (sc += 1)
        p.immd(SUBCH_3D, SET_SCISSOR_ENABLE_0 + sc * 16, 0);

    // SET_CT_MRT_ENABLE (nvk_cmd_draw.c:503): V_TRUE
    p.immd(SUBCH_3D, SET_CT_MRT_ENABLE, 1);

    // SET_VARIABLE_PIXEL_RATE_SAMPLE_ORDER(0..12) (nvk_cmd_draw.c:509-522,
    // NVC597): opaque blob-copied values
    p.incr(SUBCH_3D, SET_VARIABLE_PIXEL_RATE_SAMPLE_ORDER_0, 13);
    p.data(0xa23eb139);
    p.data(0xfb72ea61);
    p.data(0xd950c843);
    p.data(0x88fac4e5);
    p.data(0x1ab3e1b6);
    p.data(0xa98fedc2);
    p.data(0x2107654b);
    p.data(0xe0539773);
    p.data(0x698badcf);
    p.data(0x71032547);
    p.data(0xdef05397);
    p.data(0x56789abc);
    p.data(0x00001234);

    // SET_SHADER_LOCAL_MEMORY_WINDOW (nvk_cmd_draw.c:544): 0xff << 24
    // (top-of-4G hole, nvc0_screen.c heritage)
    p.incr(SUBCH_3D, SET_SHADER_LOCAL_MEMORY_WINDOW, 1);
    p.data(0xff000000);

    // BIND_GROUP_CONSTANT_BUFFER(group 0..4) x slot 0..15 (nvk_cmd_draw.c:546-553):
    // VALID 0:0 = FALSE | SHADER_SLOT 8:4 = slot
    var grp: u32 = 0;
    while (grp < 5) : (grp += 1) {
        var slot: u32 = 0;
        while (slot < 16) : (slot += 1)
            p.immd(SUBCH_3D, BIND_GROUP_CONSTANT_BUFFER_0 + grp * 32, @intCast(slot << 4));
    }

    // SET_RT_LAYER (nvk_cmd_draw.c:557): V 15:0 = 0 | CONTROL 16:16 = V_SELECTS_LAYER(0)
    p.immd(SUBCH_3D, SET_RT_LAYER, 0);

    // SET_POINT_CENTER_MODE (nvk_cmd_draw.c:564): V_OGL = 0
    p.immd(SUBCH_3D, SET_POINT_CENTER_MODE, 0);
    // SET_EDGE_FLAG (nvk_cmd_draw.c:565): V_TRUE
    p.immd(SUBCH_3D, SET_EDGE_FLAG, 1);
    // SET_SAMPLER_BINDING (nvk_cmd_draw.c:566): V_INDEPENDENTLY = 0
    p.immd(SUBCH_3D, SET_SAMPLER_BINDING, 0);

    // SET_VERTEX_STREAM_SUBSTITUTE_A/_B (nvk_cmd_draw.c:569-571): zero page VA
    p.incr(SUBCH_3D, SET_VERTEX_STREAM_SUBSTITUTE_A, 2);
    p.data(@intCast(zero_page_va >> 32)); // ADDRESS_UPPER 7:0
    p.data(@truncate(zero_page_va)); // ADDRESS_LOWER 31:0

    // SET_PS_WARP_WATERMARKS (nvk_cmd_draw.c:578): LOW 15:0 = 0x8 | HIGH 31:16
    // = max_warps_per_mp(48, sm89) * mp_per_tpc(2) = 0x60 (AD102 constants,
    // mesa winsys/nouveau_device.c:118-169)
    p.incr(SUBCH_3D, SET_PS_WARP_WATERMARKS, 1);
    p.data(0x00600008);
    // SET_PS_REGISTER_WATERMARKS (nvk_cmd_draw.c:582): LOW 15:0 = 0x80 | HIGH 31:16 = 0x1000
    p.incr(SUBCH_3D, SET_PS_REGISTER_WATERMARKS, 1);
    p.data(0x10000080);

    // SET_VERTEX_STREAM_A_FORMAT(0..31) (nvk_cmd_draw.c:590-594): ENABLE 12:12
    // = FALSE, STRIDE 11:0 = 0. Indices 16..31 land on the contiguous
    // SET_VERTEX_STREAM_B_FORMAT array — same layout, same loop as NVK's.
    var vb: u32 = 0;
    while (vb < 32) : (vb += 1)
        p.immd(SUBCH_3D, SET_VERTEX_STREAM_A_FORMAT_0 + vb * 16, 0);

    // SET_GLOBAL_BASE_INSTANCE_INDEX (nvk_cmd_draw.c:645): 0
    p.immd(SUBCH_3D, SET_GLOBAL_BASE_INSTANCE_INDEX, 0);

    // ── SKIPPED (deliberately, vs nvk_push_draw_state_init) ────────────────
    // * MME instruction-RAM upload loop (nvk_cmd_draw.c:151-171,
    //   LOAD_MME_START_ADDRESS_RAM_POINTER / LOAD_MME_INSTRUCTION_RAM_POINTER):
    //   kudos runs no MME macros; the programs come from nvk_build_mme at
    //   runtime and are not transcribable constants.
    // * CALL_MME_MACRO(NVK_MME_SET_PRIV_REG) x2 (nvk_cmd_draw.c:188-248): the
    //   SET_FALCON04 priv pokes clearing gr_gpcs_tpcs_sm_disp_ctrl bit 3 and
    //   gr_gpcs_tpcs_sms_hww_warp_esr_report_mask bit 14 — dEQP workarounds,
    //   need the SET_PRIV_REG macro + falcon wait logic.
    // * All SET_MME_SHADOW_SCRATCH writes (nvk_cmd_draw.c:253, 257, 450-452,
    //   478, 588-589, 615-622, 646-649): scratch registers only MME macros read.
    // * CALL_MME_MACRO(NVK_MME_UPDATE_WINDOW_CLIP) (nvk_cmd_draw.c:479-480):
    //   window-clip state lives behind an MME macro + scratch.
    // * CALL_MME_MACRO(NVK_MME_SELECT_CB0) + BIND_GROUP_CONSTANT_BUFFER
    //   VALID_TRUE x5 + LOAD_CONSTANT_BUFFER_OFFSET zero-fill
    //   (nvk_cmd_draw.c:624-640): NVK's root-descriptor-table cb0 at
    //   queue->draw_cb0 — a runtime address we don't have; binding/zeroing
    //   with no selector set would be undefined. kudos selects and binds its
    //   own cb0 via methods.zig bindCb0.
    // * < VOLTA/TURING/MAXWELL guarded code (nvk_cmd_draw.c:316-317, 328-329,
    //   363-364, 370-377, 525-532, 596-608) and >= HOPPER_A (610-611,
    //   0xcb97 > 0xc997): dead on AD102 (ADA_A 0xc997).
}

// ── host test ────────────────────────────────────────────────────────────────
