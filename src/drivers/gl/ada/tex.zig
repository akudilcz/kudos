//! TIC (texture header) + TSC (sampler) builders — PURE module, host-tested.
//! Bitfields read from clc997tex.h and NIL descriptor.rs. kudos textures are
//! PITCH-linear 2D single-mip BGRA8 (legal on Ada for TWO_D_NO_MIPMAP;
//! block-linear is only needed for depth formats and mipmaps) — CPU-writable
//! with no de-tile pass.

/// PITCH-variant TIC for a 2D BGRA8 (A8B8G8R8-components, BGRA-swizzled)
/// single-mip texture. `va` must be 32-B aligned, `pitch` a 32-B multiple.
pub fn ticPitchBgra8(va: u64, w: u32, h: u32, pitch: u32) [8]u32 {
    var t = [_]u32{0} ** 8;
    // dw0: COMPONENTS=A8B8G8R8(0x08), R/G/B/A UNORM(2),
    // X=IN_B(4) Y=IN_G(3) Z=IN_R(2) W=IN_A(5)  (BGRA source swizzle)
    t[0] = 0x08 | (2 << 7) | (2 << 10) | (2 << 13) | (2 << 16) |
        (4 << 19) | (3 << 22) | (2 << 25) | (5 << 28);
    // dw1: ADDRESS_BITS31TO5 (MW 63:37): VA[31:5] at bits 31:5.
    t[1] = @truncate(va & 0xffff_ffe0);
    // dw2: ADDRESS_BITS48TO32 (80:64) | HEADER_VERSION SELECT_PITCH=2 (87:85).
    t[2] = @as(u32, @intCast((va >> 32) & 0x1ffff)) | (2 << 21);
    // dw3: PITCH_BITS20TO5 (111:96) | LOD_ANISO_QUALITY2/QUALITY/ISO (112-114)
    // | MAX_MIP_LEVEL (127:124) = 0.
    t[3] = ((pitch >> 5) & 0xffff) | (1 << 16) | (1 << 17) | (1 << 18);
    // dw4: WIDTH_MINUS_ONE (144:128) | TEXTURE_TYPE TWO_D_NO_MIPMAP=7
    // (154:151) | SECTOR_PROMOTION PROMOTE_TO_2_V=1 (156:155) |
    // BORDER_SIZE BORDER_SAMPLER_COLOR=7 (159:157).
    t[4] = ((w - 1) & 0x1ffff) | (7 << 23) | (1 << 27) | (7 << 29);
    // dw5: HEIGHT_MINUS_ONE (175:160) | NORMALIZED_COORDS (191).
    t[5] = ((h - 1) & 0xffff) | (1 << 31);
    // dw6: ANISO_FINE_SPREAD_FUNC TWO=2 (216:215) | COARSE ONE=1 (218:217).
    t[6] = (2 << 23) | (1 << 25);
    // dw7: RES_VIEW 0..0, 1x1 MS, MIN_LOD_CLAMP 0.
    return t;
}

/// TSC: repeat-wrap, bilinear, no mips, no aniso, no depth compare.
pub fn tscLinearWrap() [8]u32 {
    var t = [_]u32{0} ** 8;
    // dw0: ADDRESS_U/V/P WRAP(0) | S_R_G_B_CONVERSION (bit 13, NVK always).
    t[0] = 1 << 13;
    // dw1: MAG_FILTER LINEAR=2 (2:0) | MIN_FILTER LINEAR=2 (5:4) |
    // MIP_FILTER NONE=1 (7:6).
    t[1] = 2 | (2 << 4) | (1 << 6);
    return t;
}

/// BLOCK-LINEAR ZF32 TIC — sampling a depth buffer (shadow map). Components
/// ZF32=0x2f, R=FLOAT(7), sources R001 (tic doc §3); HEADER_VERSION
/// SELECT_BLOCKLINEAR=3 with GOB block-height from the surface tiling;
/// address bits 31:9 (512-B min alignment).
pub fn ticBlZf32(va: u64, w: u32, h: u32, bh_log2: u5) [8]u32 {
    var t = [_]u32{0} ** 8;
    // dw0: COMPONENTS ZF32 | R FLOAT | sources X=IN_R(2) Y=ZERO(0) Z=ZERO(0)
    // W=ONE_FLOAT(7).
    t[0] = 0x2f | (7 << 7) | (2 << 19) | (0 << 22) | (0 << 25) | (7 << 28);
    // dw1: ADDRESS_BITS31TO9 at MW 63:41 -> dw1 bits 31:9.
    t[1] = @truncate(va & 0xffff_fe00);
    // dw2: ADDRESS_BITS48TO32 | HEADER_VERSION SELECT_BLOCKLINEAR=3.
    t[2] = @as(u32, @intCast((va >> 32) & 0x1ffff)) | (3 << 21);
    // dw3: GOBS_PER_BLOCK_HEIGHT (101:99 -> dw3 bits 5:3) | LOD quality bits.
    t[3] = (@as(u32, bh_log2) << 3) | (1 << 16) | (1 << 17) | (1 << 18);
    t[4] = ((w - 1) & 0x1ffff) | (1 << 23) | (1 << 27) | (7 << 29); // TWO_D=1
    t[5] = ((h - 1) & 0xffff) | (1 << 31);
    t[6] = (2 << 23) | (1 << 25);
    return t;
}

/// BLOCK-LINEAR BGRA8 TIC — sampling a color render target (the RTT
/// composited over the desktop). Same components/swizzle as the pitch
/// variant; BL addressing + block height.
pub fn ticBlBgra8(va: u64, w: u32, h: u32, bh_log2: u5) [8]u32 {
    var t = [_]u32{0} ** 8;
    t[0] = 0x08 | (2 << 7) | (2 << 10) | (2 << 13) | (2 << 16) |
        (4 << 19) | (3 << 22) | (2 << 25) | (5 << 28);
    t[1] = @truncate(va & 0xffff_fe00); // ADDRESS_BITS31TO9
    t[2] = @as(u32, @intCast((va >> 32) & 0x1ffff)) | (3 << 21); // BL v3
    t[3] = (@as(u32, bh_log2) << 3) | (1 << 16) | (1 << 17) | (1 << 18);
    t[4] = ((w - 1) & 0x1ffff) | (1 << 23) | (1 << 27) | (7 << 29); // TWO_D
    t[5] = ((h - 1) & 0xffff) | (1 << 31);
    t[6] = (2 << 23) | (1 << 25);
    return t;
}

/// BLOCK-LINEAR BGRA8 TIC for an 8x-MSAA surface (the resolve pass samples
/// it with texelFetch → TLD.MS): ticBlBgra8 plus MULTI_SAMPLE_COUNT
/// MODE_4X2_D3D — MW 235:232 = dword 7 bits 11:8 = 4 (clb097tex.h:527,532).
/// Width/height in PIXELS.
pub fn ticBlBgra8Msaa8(va: u64, w: u32, h: u32, bh_log2: u5) [8]u32 {
    var t = ticBlBgra8(va, w, h, bh_log2);
    t[7] |= 4 << 8; // MULTI_SAMPLE_COUNT = MODE_4X2_D3D (8 samples)
    return t;
}

/// TSC for shadow sampling: clamp-to-edge, bilinear (HW PCF), DEPTH_COMPARE
/// with LEQUAL — texture() on a sampler2DShadow returns the comparison.
pub fn tscShadow() [8]u32 {
    var t = [_]u32{0} ** 8;
    // dw0: ADDRESS U/V/P CLAMP_TO_EDGE(2) | DEPTH_COMPARE (bit 9) |
    // DEPTH_COMPARE_FUNC LEQUAL=3 (12:10) | SRGB bit 13.
    t[0] = 2 | (2 << 3) | (2 << 6) | (1 << 9) | (3 << 10) | (1 << 13);
    t[1] = 2 | (2 << 4) | (1 << 6); // bilinear, no mips
    return t;
}

/// Combined image+sampler handle as NAK-compiled shaders read it from the
/// descriptor cbuf: TIC index 19:0 | TSC index 31:20
/// (nvk_descriptor_types.h:14-22).
pub fn handle(tic_index: u32, tsc_index: u32) u32 {
    return (tic_index & 0xfffff) | (tsc_index << 20);
}
