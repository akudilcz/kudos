//! Host tests of src/drivers/gpu/display/modeset.zig (reached through the gpu_root module-root shim).

const std = @import("std");
const modeset = @import("testroot").gpu.modeset;
const OLUT_BYTES = modeset.OLUT_BYTES;
const OLUT_SIZE_FIELD = modeset.OLUT_SIZE_FIELD;
const Mode = modeset.Mode;
const Push = modeset.Push;
const SOR_PROTOCOL_DP_A = modeset.SOR_PROTOCOL_DP_A;
const SOR_PROTOCOL_DP_B = modeset.SOR_PROTOCOL_DP_B;
const buildCoreInit = modeset.buildCoreInit;
const buildCoreMethods = modeset.buildCoreMethods;
const buildCursorImage = modeset.buildCursorImage;
const buildIlut = modeset.buildIlut;
const buildOlut = modeset.buildOlut;
const buildWimm = modeset.buildWimm;
const buildWindowClr = modeset.buildWindowClr;
const buildWindowMethods = modeset.buildWindowMethods;
const buildWindowNotifierSet = modeset.buildWindowNotifierSet;
const buildWindowOwner = modeset.buildWindowOwner;
const coreUpdate = modeset.coreUpdate;
const deriveRaster = modeset.deriveRaster;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const fillIdentityIlut = modeset.fillIdentityIlut;
const fillIdentityOlut = modeset.fillIdentityOlut;
const fixedU016ToFp16 = modeset.fixedU016ToFp16;
const windowUpdate = modeset.windowUpdate;

/// Ultrawide native mode (the centre 3440x1440 panel, hand-decoded from its
/// EDID, which the ultrawide bring-up ruled out as the fault).
const test_mode_uw = Mode{
    .h = 3440,
    .v = 1440,
    .clock_khz = 319750,
    .h_blank = 160,
    .h_sync_off = 48,
    .h_sync_w = 32,
    .v_blank = 41,
    .v_sync_off = 3,
    .v_sync_w = 10,
    .h_sync_neg = false,
    .v_sync_neg = true,
};

/// The forced 4K60 timing (identical values to disp.zig mode4k, restated here as
/// a test vector — disp.zig's constant is private and hardware-scoped).
const test_mode_4k = Mode{
    .h = 3840,
    .v = 2160,
    .clock_khz = 533250,
    .h_blank = 160,
    .h_sync_off = 48,
    .h_sync_w = 32,
    .v_blank = 62,
    .v_sync_off = 3,
    .v_sync_w = 5,
    .h_sync_neg = false,
    .v_sync_neg = true,
};

test "deriveRaster ultrawide native: nv50_head_atomic_check_mode one-unit sync bias" {
    const r = deriveRaster(test_mode_uw);
    try expectEqual(@as(u32, 3600), r.h_active); // h + h_blank (total raster width)
    try expectEqual(@as(u32, 31), r.h_synce); // h_sync_w - 1
    try expectEqual(@as(u32, 111), r.h_blanke); // h_blank - h_sync_off - 1
    try expectEqual(@as(u32, 3551), r.h_blanks); // blanke + h
    try expectEqual(@as(u32, 1481), r.v_active); // v + v_blank
    try expectEqual(@as(u32, 9), r.v_synce); // v_sync_w - 1
    try expectEqual(@as(u32, 37), r.v_blanke); // v_blank - v_sync_off - 1
    try expectEqual(@as(u32, 1477), r.v_blanks); // blanke + v
}

test "deriveRaster 4K60 CVT-RB" {
    const r = deriveRaster(test_mode_4k);
    try expectEqual(@as(u32, 4000), r.h_active);
    try expectEqual(@as(u32, 31), r.h_synce);
    try expectEqual(@as(u32, 111), r.h_blanke);
    try expectEqual(@as(u32, 3951), r.h_blanks);
    try expectEqual(@as(u32, 2222), r.v_active);
    try expectEqual(@as(u32, 4), r.v_synce);
    try expectEqual(@as(u32, 58), r.v_blanke);
    try expectEqual(@as(u32, 2218), r.v_blanks);
}

test "buildCoreMethods ultrawide golden stream (incl. RASTER_BLANK2 = (0<<16)|1, the Xid-56 rule)" {
    var buf: [40]u32 = undefined;
    var p = Push.init(&buf);
    // head 0, SOR 0, protocol DP_A (8), window 0, the ultrawide's displayId 0x2000.
    buildCoreMethods(&p, 0, 0, SOR_PROTOCOL_DP_A, 0, 0x2000, test_mode_uw);
    try expectEqualSlices(u32, &[_]u32{
        // 1. SOR_SET_CONTROL(0): OWNER_MASK=head0 bit | PROTOCOL DP_A << 8
        0x00040300, 0x00000801,
        // 2. RASTER_SIZE..BLANK_START incrementing run of 4 (h | v<<16)
        0x00102064,
        (1481 << 16) | 3600, // SET_RASTER_SIZE       0x05C90E10
        (9 << 16) | 31, // SET_RASTER_SYNC_END    0x0009001F
        (37 << 16) | 111, // SET_RASTER_BLANK_END   0x0025006F
        (1477 << 16) | 3551, // SET_RASTER_BLANK_START 0x05C50DDF
        // RASTER_BLANK2: progressive blank2e=0 blank2s=1 → (0<<16)|1, NOT 0
        // (0 is rejected by the GSP with DISP Xid 56 on method 0x2074).
        0x00042074,
        (0 << 16) | 1,
        0x00042008, 0x00000000, // STRUCTURE = PROGRESSIVE
        0x00042018, 0x00000010, // DITHER_CONTROL (8bpc, disabled)
        0x00042000, 0x00000000, // PROCAMP raw 0
        0x0004200C, 319750 * 1000, // PIXEL_CLOCK_FREQUENCY (Hz) = 0x130EFF70
        0x00042028, 319750 * 1000, // PIXEL_CLOCK_FREQUENCY_MAX
        // HEAD_USAGE_BOUNDS: CURSOR W256_H256(4) | OLUT_ALLOWED | UPSCALING | TAPS_2
        0x00042030, 0x00001114,
        // CONTROL_OUTPUT_RESOURCE: vsync- (bit3) | depth 8bpc(4<<4) | EXT_PACKET_WIN NONE
        0x00042004, 0xFC000048,
        0x00042020, 0x00002000, // DISPLAY_ID
        0x0004204C, (1440 << 16) | 3440, // VIEWPORT_SIZE_IN  0x05A00D70
        0x00042058, (1440 << 16) | 3440, // VIEWPORT_SIZE_OUT
        0x00041000, 0x00000000, // WINDOW_SET_CONTROL(0).OWNER = head 0
    }, buf[0..p.n]);
}

test "buildCoreMethods 4K60 on head 1 / SOR 2 / window 1: per-instance strides and hsync+ vsync-" {
    var buf: [40]u32 = undefined;
    var p = Push.init(&buf);
    buildCoreMethods(&p, 1, 2, SOR_PROTOCOL_DP_B, 1, 0x800, test_mode_4k);
    try expectEqualSlices(u32, &[_]u32{
        0x00040340, 0x00000902, // SOR_SET_CONTROL(2)=0x300+2*0x20, owner head1, DP_B
        0x00102464, // raster run at 0x2064 + 1*0x400
        (2222 << 16) | 4000,
        (4 << 16) | 31,
        (58 << 16) | 111,
        (2218 << 16) | 3951,
        0x00042474,
        (0 << 16) | 1,
        0x00042408,
        0x00000000,
        0x00042418,
        0x00000010,
        0x00042400,
        0x00000000,
        0x0004240C,
        533250 * 1000,
        0x00042428,
        533250 * 1000,
        0x00042430,
        0x00001114,
        0x00042404,
        0xFC000048,
        0x00042420,
        0x00000800,
        0x0004244C,
        (2160 << 16) | 3840,
        0x00042458,
        (2160 << 16) | 3840,
        0x00041080, 0x00000001, // WINDOW_SET_CONTROL(1)=0x1000+0x80, OWNER = head 1
    }, buf[0..p.n]);
}

test "fillIdentityOlut: byte-exact 10-bit → 16-bit identity ramp (the dark-panel encoding)" {
    var buf: [OLUT_BYTES]u8 = undefined;
    @memset(&buf, 0xAA); // poison so untouched bytes are caught
    fillIdentityOlut(&buf);
    // 32-byte VSS header zeroed.
    for (buf[0..0x20]) |b| try expectEqual(@as(u8, 0), b);
    // Entry i = {u16 r, u16 g, u16 b, u16 pad} with r=g=b = (i<<6)|(i>>4), LE.
    const checks = [_]struct { i: u32, v: u16 }{
        .{ .i = 0, .v = 0x0000 },
        .{ .i = 1, .v = 0x0040 }, // (1<<6)|(1>>4)
        .{ .i = 512, .v = 0x8020 }, // (512<<6)|(512>>4)
        .{ .i = 1023, .v = 0xFFFF }, // full scale maps exactly to 0xFFFF
        .{ .i = 1024, .v = 0xFFFF }, // replicated last entry (INTERPOLATE "next")
    };
    for (checks) |c| {
        const off = 0x20 + c.i * 8;
        const lo: u8 = @intCast(c.v & 0xff);
        const hi: u8 = @intCast(c.v >> 8);
        try expectEqualSlices(u8, &[_]u8{ lo, hi, lo, hi, lo, hi, 0, 0 }, buf[off .. off + 8]);
    }
    try expectEqual(@as(u64, 0x20 + 1025 * 8), OLUT_BYTES);
    try expectEqual(@as(u32, 1029), OLUT_SIZE_FIELD); // VSS(4) + 1024 + 1
}

test "fixedU016ToFp16: golden vectors vs nouveau fixedU0_16_FP16 (wndwc57e.c:145)" {
    try expectEqual(@as(u16, 0x0000), fixedU016ToFp16(0x0000)); // 0.0
    try expectEqual(@as(u16, 0x1400), fixedU016ToFp16(0x0040)); // 64/65536 = 2^-10
    try expectEqual(@as(u16, 0x2800), fixedU016ToFp16(0x0800)); // 2048/65536 = 2^-5
    try expectEqual(@as(u16, 0x3800), fixedU016ToFp16(0x8000)); // 0.5
    try expectEqual(@as(u16, 0x3BFE), fixedU016ToFp16(0xFFC0)); // ramp top (1023<<6)
    try expectEqual(@as(u16, 0x3BFF), fixedU016ToFp16(0xFFFF)); // ~0.99951 (max input)
}

test "fillIdentityIlut: byte-exact FP16-encoded identity ramp (NOT raw fixed16)" {
    var buf: [OLUT_BYTES]u8 = undefined;
    @memset(&buf, 0xAA);
    fillIdentityIlut(&buf);
    for (buf[0..0x20]) |b| try expectEqual(@as(u8, 0), b);
    // Entry i = FP16(i<<6); pad 0. The FP16 encoding is what fixed the dark panel —
    // a raw-fixed16 ramp here leaves the window normalizing garbage → black output.
    const checks = [_]struct { i: u32, v: u16 }{
        .{ .i = 0, .v = 0x0000 },
        .{ .i = 1, .v = 0x1400 }, // FP16(0x0040)
        .{ .i = 512, .v = 0x3800 }, // FP16(0x8000) = 0.5
        .{ .i = 1023, .v = 0x3BFE }, // FP16(0xFFC0)
        .{ .i = 1024, .v = 0x3BFE }, // replicated last entry
    };
    for (checks) |c| {
        const off = 0x20 + c.i * 8;
        const lo: u8 = @intCast(c.v & 0xff);
        const hi: u8 = @intCast(c.v >> 8);
        try expectEqualSlices(u8, &[_]u8{ lo, hi, lo, hi, lo, hi, 0, 0 }, buf[off .. off + 8]);
    }
}

test "buildOlut golden stream: DIRECT10 + INTERPOLATE + SIZE=1029, offset >> 8" {
    var buf: [8]u32 = undefined;
    var p = Push.init(&buf);
    buildOlut(&p, 0, 0xCAFE0007, 0x0034_5600);
    try expectEqualSlices(u32, &[_]u32{
        // OLUT_CONTROL: INTERPOLATE(bit0) | MODE_DIRECT10(3:2=2) | SIZE 1029 (18:8)
        0x00042280, 0x00040509,
        0x00042284, 0xFFFFFFFF, // FP_NORM_SCALE
        0x00042288, 0xCAFE0007, // CONTEXT_DMA_OLUT
        0x0004228C, 0x00003456, // OFFSET_OLUT = vram off >> 8
    }, buf[0..p.n]);
}

test "buildIlut golden stream: DIRECT10, INTERPOLATE DISABLED, SIZE=1029" {
    var buf: [6]u32 = undefined;
    var p = Push.init(&buf);
    buildIlut(&p, 0xCAFE0003, 0x0012_3400);
    try expectEqualSlices(u32, &[_]u32{
        0x00040440, 0x00040508, // ILUT_CONTROL: no bit0 (interpolate off), DIRECT10, 1029
        0x00040444, 0xCAFE0003,
        0x00040448, 0x00001234,
    }, buf[0..p.n]);
}

test "buildWindowMethods ultrawide golden stream: 256B-aligned pitch >> 6, opaque blend" {
    var buf: [32]u32 = undefined;
    var p = Push.init(&buf);
    // The black-at-native fix: 3440*4 = 13760 is 64- but not 256-byte aligned; the
    // scanout pitch is padded to 13824 (see disp.zig / calc.zig pitch math). The
    // window encodes pitch>>6 = 216.
    buildWindowMethods(&p, 0, 0xCAFE0002, 0x0100_0000, 13824, 255, false, 3440, 1440);
    try expectEqualSlices(u32, &[_]u32{
        // PRESENT_CONTROL: MIN_PRESENT_INTERVAL=1 (interval 0 in an interlocked
        // commit never presents → black head), BEGIN_MODE NON_TEARING.
        0x00040308, 0x00000001,
        // SET_SIZE .. SET_PLANAR_STORAGE(0) incrementing run of 4.
        0x00100224,
        (1440 << 16) | 3440, // SET_SIZE
        0x00000000, // SET_STORAGE: BLOCK_HEIGHT ONE_GOB (c67e: no MEMORY_LAYOUT)
        0x000000CF, // SET_PARAMS: FORMAT A8R8G8B8
        13824 >> 6, // SET_PLANAR_STORAGE = pitch>>6 = 216
        0x00040240, 0xCAFE0002, // SET_CONTEXT_DMA_ISO(0)
        0x00040260, 0x00010000, // SET_OFFSET(0) = phys >> 8
        0x00040290, 0x00000000, // SET_POINT_IN(0) = 0,0
        0x00040298, (1440 << 16) | 3440, // SET_SIZE_IN
        0x000402A4, (1440 << 16) | 3440, // SET_SIZE_OUT
        // Composition run of 7 @ 0x2EC: DEPTH=255, K1=0xff, factors 0x4422
        // (src K1/K1, dst NEG_K1 ×2 — PIXEL_NONE constant alpha), color key off,
        // ranges full.
        0x001C02EC,
        255 << 4, // COMPOSITION_CONTROL: DEPTH
        0x000000FF, // CONSTANT_ALPHA: K1
        0x00004422, // FACTOR_SELECT
        0xFFFF0000, // KEY_ALPHA
        0xFFFF0000, // KEY_RED_CR
        0xFFFF0000, // KEY_GREEN_Y
        0xFFFF0000, // KEY_BLUE_CB
    }, buf[0..p.n]);
}

test "buildWindowClr golden stream: interval 0 + ctxdma 0 detaches the scanout" {
    var buf: [4]u32 = undefined;
    var p = Push.init(&buf);
    buildWindowClr(&p);
    try expectEqualSlices(u32, &[_]u32{
        0x00040308, 0x00000000, // PRESENT_CONTROL interval=0
        0x00040240, 0x00000000, // SET_CONTEXT_DMA_ISO(0) = 0 → no surface
    }, buf[0..p.n]);
}

test "buildWindowNotifierSet golden stream: MODE=WRITE, OFFSET=0" {
    var buf: [4]u32 = undefined;
    var p = Push.init(&buf);
    buildWindowNotifierSet(&p, 0xCAFE0005);
    try expectEqualSlices(u32, &[_]u32{
        0x0004021C, 0xCAFE0005,
        0x00040220, 0x00000000,
    }, buf[0..p.n]);
}

test "windowUpdate golden: interlock flags + UPDATE with WIN_IMM at bit 12 (not bit 1)" {
    var buf: [6]u32 = undefined;
    var p = Push.init(&buf);
    windowUpdate(&p, true, 1 << 0, true);
    try expectEqualSlices(u32, &[_]u32{
        0x00040370, 0x00000001, // SET_INTERLOCK_FLAGS: core
        0x00040374, 0x00000001, // SET_WINDOW_INTERLOCK_FLAGS: BIT(window 0)
        // UPDATE bit0 | INTERLOCK_WITH_WIN_IMM at bit 12 — bit 1 is reserved on the
        // WINDOW update (writing it let the image latch before the WIMM point armed).
        0x00040200, 0x00001001,
    }, buf[0..p.n]);

    var p2 = Push.init(&buf);
    windowUpdate(&p2, false, 1 << 3, false);
    try expectEqualSlices(u32, &[_]u32{
        0x00040370, 0x00000000,
        0x00040374, 0x00000008,
        0x00040200, 0x00000001,
    }, buf[0..p2.n]);
}

test "buildWimm golden: SET_POINT_OUT x|y<<16, UPDATE INTERLOCK_WITH_WINDOW at bit 1" {
    var buf: [4]u32 = undefined;
    var p = Push.init(&buf);
    buildWimm(&p, 1500, 300, true);
    try expectEqualSlices(u32, &[_]u32{
        0x00040208, (300 << 16) | 1500,
        0x00040200, 0x00000003, // bit0 | bit1 (WIMM uses bit 1, asymmetric with WNDW)
    }, buf[0..p.n]);
}

test "coreUpdate golden: notifier bracket (NOTIFY at bit 12, OFFSET 11:4) around UPDATE" {
    var buf: [10]u32 = undefined;
    var p = Push.init(&buf);
    coreUpdate(&p, 1 << 0, 0x30);
    try expectEqualSlices(u32, &[_]u32{
        0x0004020C, 0x00001030, // NOTIFIER_CONTROL: MODE=WRITE | OFFSET 0x30 | NOTIFY
        0x00040218, 0x00000000, // SET_INTERLOCK_FLAGS: none
        0x0004021C, 0x00000001, // SET_WINDOW_INTERLOCK_FLAGS: BIT(0)
        0x00040200, 0x00000001, // UPDATE
        0x0004020C, 0x00000000, // NOTIFY=DISABLE
    }, buf[0..p.n]);

    var p2 = Push.init(&buf);
    coreUpdate(&p2, 0, null); // isolated owner update: no notifier bracket
    try expectEqualSlices(u32, &[_]u32{
        0x00040218, 0x00000000,
        0x0004021C, 0x00000000,
        0x00040200, 0x00000001,
    }, buf[0..p2.n]);
}

test "buildCursorImage golden: enable/format/size/hotspot + K1 src-over blend" {
    var buf: [8]u32 = undefined;
    var p = Push.init(&buf);
    buildCursorImage(&p, 0, 0xCAFE0004, 0x0020_0000, 5, 9);
    try expectEqualSlices(u32, &[_]u32{
        // CONTROL_CURSOR: ENABLE(31) | A8R8G8B8(0xCF) | W32_H32 | hotspot 5,9
        0x0004209C, 0x80000000 | 0xCF | (5 << 12) | (9 << 20),
        // COMPOSITION: K1=0xff | FACTOR K1(2) | NEG_K1_TIMES_SRC(7) | MODE=BLEND
        0x000420A0, 0x000072FF,
        0x00042088, 0xCAFE0004,
        0x00042090, 0x00002000, // image_off >> 8
    }, buf[0..p.n]);
}

test "buildWindowOwner golden: OWNER 3:0 = head index at the window's control offset" {
    var buf: [2]u32 = undefined;
    var p = Push.init(&buf);
    buildWindowOwner(&p, 2, 1);
    try expectEqualSlices(u32, &[_]u32{ 0x00041100, 0x00000001 }, buf[0..p.n]);
}

test "buildCoreInit golden: notifier bind + per-window format/usage bounds for all 8 windows" {
    var buf: [50]u32 = undefined;
    var p = Push.init(&buf);
    buildCoreInit(&p, 0xCAFE0006);
    try expectEqual(@as(usize, 2 + 8 * 6), p.n);
    try expectEqualSlices(u32, &[_]u32{ 0x00040208, 0xCAFE0006 }, buf[0..2]); // SET_CONTEXT_DMA_NOTIFIER
    // Window 0 triple; every window w repeats it at +w*0x80 offsets.
    try expectEqualSlices(u32, &[_]u32{
        0x00041004, 0x0000000F, // FORMAT_USAGE_BOUNDS: RGB_PACKED 1/2/4/8 BPP
        0x00041008, 0x00000000, // ROTATED_FORMAT_USAGE_BOUNDS
        0x00041010, 0x00117FFF, // MAX_PIXELS 0x7fff | ILUT_ALLOWED(16) | TAPS_2(20)
    }, buf[2..8]);
    // Spot-check window 7's offsets (0x1004/8/10 + 7*0x80 = 0x1384/8/90).
    try expectEqualSlices(u32, &[_]u32{
        0x00041384, 0x0000000F,
        0x00041388, 0x00000000,
        0x00041390, 0x00117FFF,
    }, buf[44..50]);
}
