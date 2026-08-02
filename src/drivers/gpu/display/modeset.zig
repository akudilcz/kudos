//! EVO/NvDisplay mode-set method-stream builder for the RTX 4090 (AD102).
//!
//! Builds the EVO method dwords that light up ONE head at a given mode, scanning
//! out a linear BGRA8888 VRAM surface bound by a ctxdma handle. There is NO
//! "set mode" RM ctrl — raster timing, SOR owner, surface bind and the flip are
//! all EVO methods pushed into the disp core and window channels.
//!
//! Derived from nouveau (linux-source-7.0.0 drivers/gpu/drm/nouveau/dispnv50/* and
//! the class headers include/nvhw/class/clc37d.h, clc57d.h, clc57e.h, clc37e.h).
//!
//! The Ada dispatch gotcha:
//!   - Core   = corec57d (NVC57D) but its Update/SOR/interlock/viewport reuse the
//!              c37d emitters → those dwords use NVC37D offsets.
//!   - Head   = headc57d  → raster/clock/usage-bounds use NVC57D offsets.
//!   - Window = wndwc67e (← wndwc57e, clc57e.h) → image-set uses NVC57E offsets.
//!   - Window Update = wndwc37e (NVC37E).
//!   - Ada binds a REAL ctxdma (SET_CONTEXT_DMA_ISO = handle), not a raw address.
//!
//! The core channel and the window channel are SEPARATE pushbuffers, so this
//! module is split into a core builder, a window builder, and their two Updates.
//! The caller owns one `Push` per channel and kicks each channel's PUT.
//!
//! Driver-side ordering (nv50_disp_atomic_commit_tail), reproduced by the caller:
//!   1. RM nvif_outp_acquire_sor (NOT a method — an NV0073 ctrl)
//!   2. buildCoreMethods (SOR ctrl + head mode/or/viewport + window-owner)
//!   3. buildWindowMethods (image set) → window push
//!   4. windowUpdate → window push, kick
//!   5. coreUpdate → core push, kick, then poll the core notifier for FINISHED.

pub const Push = @import("../core/push.zig").Push;
pub const Mode = @import("disp.zig").Mode;

// ===========================================================================
// Method offsets and field encodings (cited to the nouveau class headers).
// Bit ranges are written as { lo, width } pairs and applied with `field()`.
// ===========================================================================

// --- NVC37D core (corec37d / sorc37d / headc37d view+update) -------------
// clc37d.h
const NVC37D_UPDATE: u32 = 0x00000200;
//   UPDATE = 0x1 | SPECIAL_HANDLING_NONE(21:20=0) | INHIBIT_INTERRUPTS_FALSE(24=0)
const NVC37D_SET_CONTEXT_DMA_NOTIFIER: u32 = 0x00000208; // clc37d.h:60
const NVC37D_SET_INTERLOCK_FLAGS: u32 = 0x00000218; // clc37d.h:70
const NVC37D_SET_WINDOW_INTERLOCK_FLAGS: u32 = 0x0000021C; // clc37d.h:102

// SOR_SET_CONTROL(or) @ 0x300 + or*0x20 (clc37d.h:204)
//   OWNER_MASK 7:0  (HEAD0=0x1, i.e. bit `head`)   PROTOCOL 11:8
/// Core method offset of SOR_SET_CONTROL for output resource `sor` (per-OR stride 0x20).
fn sorSetControl(sor: u32) u32 {
    return 0x00000300 + sor * 0x00000020;
}
const SOR_PROTOCOL_SINGLE_TMDS_A: u32 = 0x1; // clc37d.h:217
pub const SOR_PROTOCOL_DP_A: u32 = 0x8; // clc37d.h:220
pub const SOR_PROTOCOL_DP_B: u32 = 0x9; // clc37d.h:221

// WINDOW_SET_CONTROL(w) @ 0x1000 + w*0x80 (clc37d.h:232); OWNER 3:0 = HEAD index
/// Core method offset of WINDOW_SET_CONTROL for window `w` (per-window stride 0x80).
fn windowSetControl(w: u32) u32 {
    return 0x00001000 + w * 0x00000080;
}

// HEAD viewport — reuses NVC37D offsets even on Ada (headc37d_view) ----------
// clc37d.h:451 / :454, +head*0x400
/// Core method offset of HEAD_SET_VIEWPORT_SIZE_IN for `head` (per-head stride 0x400).
fn headViewportSizeIn(head: u32) u32 {
    return 0x0000204C + head * 0x00000400;
}
/// Core method offset of HEAD_SET_VIEWPORT_SIZE_OUT for `head` (per-head stride 0x400).
fn headViewportSizeOut(head: u32) u32 {
    return 0x00002058 + head * 0x00000400;
}

// --- NVC57D head (headc57d), +head*0x400 ----------------------------------
// clc57d.h
/// Core method offset of HEAD_SET_CONTROL_OUTPUT_RESOURCE for `head` (stride 0x400).
fn headSetControlOutputResource(head: u32) u32 {
    return 0x00002004 + head * 0x00000400; // clc57d.h:161
}
/// Core method offset of HEAD_SET_DISPLAY_ID for `head` (stride 0x400).
fn headSetDisplayId(head: u32) u32 {
    return 0x00002020 + head * 0x00000400; // headc57d_display_id raw 0x2020
}
/// Core method offset of HEAD_SET_PIXEL_CLOCK_FREQUENCY for `head` (stride 0x400).
fn headSetPixelClockFrequency(head: u32) u32 {
    return 0x0000200C + head * 0x00000400; // clc57d.h:220
}
/// Core method offset of HEAD_SET_PIXEL_CLOCK_FREQUENCY_MAX for `head` (stride 0x400).
fn headSetPixelClockFrequencyMax(head: u32) u32 {
    return 0x00002028 + head * 0x00000400; // clc57d.h:235
}
/// Core method offset of HEAD_SET_RASTER_SIZE for `head` (stride 0x400).
fn headSetRasterSize(head: u32) u32 {
    return 0x00002064 + head * 0x00000400; // clc57d.h:256
}
/// Core method offset of HEAD_SET_RASTER_SYNC_END for `head` (stride 0x400).
fn headSetRasterSyncEnd(head: u32) u32 {
    return 0x00002068 + head * 0x00000400; // clc57d.h:259
}
/// Core method offset of HEAD_SET_RASTER_BLANK_END for `head` (stride 0x400).
fn headSetRasterBlankEnd(head: u32) u32 {
    return 0x0000206C + head * 0x00000400; // clc57d.h:262
}
/// Core method offset of HEAD_SET_RASTER_BLANK_START for `head` (stride 0x400).
fn headSetRasterBlankStart(head: u32) u32 {
    return 0x00002070 + head * 0x00000400; // clc57d.h:265
}
/// Core method offset of HEAD_SET_RASTER_BLANK2 for `head` (stride 0x400).
fn headSetRasterBlank2(head: u32) u32 {
    return 0x00002074 + head * 0x00000400; // headc57d_mode raw 0x2074 (RASTER_BLANK2)
}
/// Core method offset of HEAD raster STRUCTURE (interlace control) for `head`.
fn headSetRasterStructure(head: u32) u32 {
    // headc57d_mode raw 0x2008 = m->interlace (0 = PROGRESSIVE). No symbolic name
    // in clc57d.h; nouveau writes it raw. (RASTER "interlace control" / STRUCTURE.)
    return 0x00002008 + head * 0x00000400;
}
/// Core method offset of HEAD_SET_HEAD_USAGE_BOUNDS for `head` (stride 0x400).
fn headSetHeadUsageBounds(head: u32) u32 {
    return 0x00002030 + head * 0x00000400; // clc57d.h:240
}
/// Core method offset of HEAD_SET_PROCAMP for `head` (stride 0x400).
fn headSetProcamp(head: u32) u32 {
    return 0x00002000 + head * 0x00000400; // clc57d.h:149
}
/// Core method offset of HEAD_SET_OLUT_CONTROL for `head` (stride 0x400).
fn headSetOlutControl(head: u32) u32 {
    return 0x00002280 + head * 0x00000400; // clc57d.h:337
}
/// Core method offset of HEAD_SET_OLUT_FP_NORM_SCALE for `head` (stride 0x400).
fn headSetOlutFpNormScale(head: u32) u32 {
    return 0x00002284 + head * 0x00000400; // clc57d.h:349
}
/// Core method offset of HEAD_SET_CONTEXT_DMA_OLUT for `head` (stride 0x400).
fn headSetContextDmaOlut(head: u32) u32 {
    return 0x00002288 + head * 0x00000400; // clc57d.h:351
}
/// Core method offset of HEAD_SET_OFFSET_OLUT for `head` (stride 0x400).
fn headSetOffsetOlut(head: u32) u32 {
    return 0x0000228c + head * 0x00000400; // clc57d.h:353
}

// HEAD_SET_CONTROL_OUTPUT_RESOURCE field positions (clc57d.h:162..186):
//   CRC_MODE 1:0, HSYNC_POLARITY 2:2, VSYNC_POLARITY 3:3, PIXEL_DEPTH 7:4,
//   COLOR_SPACE_OVERRIDE 24:24, EXT_PACKET_WIN 31:26.
const OR_PIXEL_DEPTH_BPP_24_444: u32 = 0x4; // clc57d.h:177 (8bpc, depth code 4)
const OR_EXT_PACKET_WIN_NONE: u32 = 0x3F; // clc57d.h:219

// HEAD_SET_HEAD_USAGE_BOUNDS fields (clc57d.h:240..255):
//   CURSOR 2:0 (W256_H256=4), OLUT_ALLOWED 4:4, OUTPUT_SCALER_TAPS 14:12 (TAPS_2=1),
//   UPSCALING_ALLOWED 8:8.
const HUB_CURSOR_W256_H256: u32 = 0x4;
const HUB_OUTPUT_SCALER_TAPS_2: u32 = 0x1;

// --- NVC57E window image set (wndwc67e_image_set / wndwc57e_image_set) ------
// clc57e.h. (c67e == c57e except SET_STORAGE omits MEMORY_LAYOUT — see below.)
const NVC57E_SET_PRESENT_CONTROL: u32 = 0x00000308; // clc57e.h:94
const NVC57E_SET_SIZE: u32 = 0x00000224; // clc57e.h:27
const NVC57E_SET_STORAGE: u32 = 0x00000228; // clc57e.h:30
const NVC57E_SET_PARAMS: u32 = 0x0000022C; // clc57e.h:41
/// Window method offset of SET_PLANAR_STORAGE for `plane` (per-plane stride 4).
fn nvc57eSetPlanarStorage(plane: u32) u32 {
    return 0x00000230 + plane * 0x00000004; // clc57e.h:79
}
/// Window method offset of SET_CONTEXT_DMA_ISO for `plane` (per-plane stride 4).
fn nvc57eSetContextDmaIso(plane: u32) u32 {
    return 0x00000240 + plane * 0x00000004; // clc57e.h:81
}
/// Window method offset of SET_OFFSET for `plane` (per-plane stride 4).
fn nvc57eSetOffset(plane: u32) u32 {
    return 0x00000260 + plane * 0x00000004; // clc57e.h:83
}
/// Window method offset of SET_POINT_IN for `plane` (per-plane stride 4).
fn nvc57eSetPointIn(plane: u32) u32 {
    return 0x00000290 + plane * 0x00000004; // clc57e.h:85
}
const NVC57E_SET_SIZE_IN: u32 = 0x00000298; // clc57e.h:88
const NVC57E_SET_SIZE_OUT: u32 = 0x000002A4; // clc57e.h:91

// Window-channel completion notifier (wndwc37e_ntfy_set; class-invariant across
// c37e/c57e/c67e — the window classes reuse wndwc37e's notifier path). Distinct
// from the CORE notifier (c37d 0x208/0x20c): the WINDOW class uses 0x21C/0x220 and
// the CONTROL word has NO notify-enable bit (only MODE 0:0 + OFFSET 11:4).
// clc37e.h:40-46. Emitted BEFORE the image methods in a flip; the engine writes
// STATUS (dword0 bits 31:30) to the bound notifier at the flip's vblank latch.
const NVC37E_SET_CONTEXT_DMA_NOTIFIER: u32 = 0x0000021C; // clc37e.h:40
const NVC37E_SET_NOTIFIER_CONTROL: u32 = 0x00000220; // clc37e.h:42
/// Notifier STATUS enum (dword0 31:30), shared core/window (cl507c.h:33-35).
pub const WNDW_NOTIFIER_STATUS_BEGUN: u32 = 1;

/// Arm the window completion notifier for a flip: bind the notifier ctxdma and
/// point SET_NOTIFIER_CONTROL at it. The ctxdma maps start=notifier (see
/// ctxdma.createWindowNotifier), so OFFSET=0; MODE=WRITE(0). Emit into the WINDOW
/// channel BEFORE the image methods (nouveau nv50_wndw_flush_set order: ntfy_set →
/// image_set → … → UPDATE). The engine sets STATUS=BEGUN at the flip's vblank.
pub fn buildWindowNotifierSet(push: *Push, ntfy_handle: u32) void {
    push.mthd(NVC37E_SET_CONTEXT_DMA_NOTIFIER, ntfy_handle);
    push.mthd(NVC37E_SET_NOTIFIER_CONTROL, field(0, 1, 0) | field(4, 8, 0)); // MODE=WRITE, OFFSET=0
}

// SET_PARAMS.FORMAT (clc57e.h:42, 7:0): BGRA8888 == A8R8G8B8 == 0xCF.
const WIN_FORMAT_A8R8G8B8: u32 = 0xCF; // clc57e.h:48
// SET_STORAGE.BLOCK_HEIGHT (3:0) ONE_GOB for a linear/pitch surface (wndw.c:312).
const WIN_BLOCK_HEIGHT_ONE_GOB: u32 = 0x0; // clc57e.h NVD_BLOCK_HEIGHT_ONE_GOB
// SET_PRESENT_CONTROL: MIN_PRESENT_INTERVAL 3:0, BEGIN_MODE 6:4 (NON_TEARING=0),
// TIMESTAMP_MODE 8:8 (DISABLE=0).

// --- NVC37E window update (wndwc37e_update) -------------------------------
// clc37e.h
const NVC37E_UPDATE: u32 = 0x00000200; // clc37e.h:28 (UPDATE = 0x1)
const NVC37E_SET_INTERLOCK_FLAGS: u32 = 0x00000370; // wndwc37e raw 0x370
const NVC37E_SET_WINDOW_INTERLOCK_FLAGS: u32 = 0x00000374; // wndwc37e raw 0x374

// --- NVC37B window-immediate (WIMM) — SET_POINT_OUT + UPDATE (clc37b.h) ----
const NVC37B_UPDATE: u32 = 0x00000200;
const NVC37B_SET_POINT_OUT0: u32 = 0x00000208;

// --- NVC37E window composition/blend (wndwc37e_blend_set) -----------------
// clc37e.h: 7-method incrementing run from 0x2EC.
const NVC37E_SET_COMPOSITION_CONTROL: u32 = 0x000002EC;
const FACTOR_K1: u32 = 0x2; // SRC_COLOR_FACTOR_MATCH_SELECT_K1 (clc37e.h:192)
const FACTOR_NEG_K1: u32 = 0x4; // DST_COLOR_FACTOR_MATCH_SELECT_NEG_K1 (clc37e.h:208)

// ===========================================================================
// Bitfield helper. width-bit field at bit `lo`.
// ===========================================================================
/// Pack `val` into a `width`-bit field starting at bit `lo` (masking `val` to
/// width first). The building block for every method-dword bit layout below.
fn field(lo: u5, comptime width: u6, val: u32) u32 {
    const mask: u32 = if (width >= 32) 0xffffffff else (@as(u32, 1) << @intCast(width)) - 1;
    return (val & mask) << lo;
}

// ===========================================================================
// Derived raster timings (nv50_head_atomic_check_mode, head.c:283).
//
// kudos' Mode carries EDID detailed-timing fields; nouveau works from DRM
// crtc_* fields. The DRM fields map to the EDID fields as:
//   crtc_hdisplay     = h
//   crtc_hsync_start  = h + h_sync_off            (active + front porch)
//   crtc_hsync_end    = h + h_sync_off + h_sync_w
//   crtc_htotal       = h + h_blank
//   crtc_hblank_end   = crtc_htotal               (blank ends at end of line)
// and likewise for vertical. nouveau then biases by one unit into the sync:
//   active = total
//   synce  = sync_end - sync_start - 1            = sync_w - 1
//   blanke = hblank_end - sync_start - 1          = h_blank - h_sync_off - 1
//   blanks = blanke + display                     = blanke + h
// We compute these directly from the EDID fields (no DRM intermediary), which
// yields the identical EVO register values.
// ===========================================================================
const Raster = struct {
    h_active: u32, // m->h.active  (= total raster width)
    h_synce: u32, // m->h.synce
    h_blanke: u32, // m->h.blanke
    h_blanks: u32, // m->h.blanks
    v_active: u32, // m->v.active  (= total raster height)
    v_synce: u32,
    v_blanke: u32,
    v_blanks: u32,
};

/// Derive the EVO raster register values (active/synce/blanke/blanks) from the
/// EDID-sourced `mode` fields, matching nv50_head_atomic_check_mode (see the block
/// comment above for the DRM→EDID field mapping and the one-unit sync bias).
pub fn deriveRaster(mode: Mode) Raster {
    // Progressive only (first light). Interlace (raster 0x2074/0x2008) is left at
    // PROGRESSIVE; see headSetRasterStructure / blank2 below.
    const h_total = mode.h + mode.h_blank;
    const v_total = mode.v + mode.v_blank;
    return .{
        .h_active = h_total,
        .h_synce = mode.h_sync_w - 1, // sync_end - sync_start - 1
        .h_blanke = mode.h_blank - mode.h_sync_off - 1, // hblank_end - hsync_start - 1
        .h_blanks = (mode.h_blank - mode.h_sync_off - 1) + mode.h,
        .v_active = v_total,
        .v_synce = mode.v_sync_w - 1,
        .v_blanke = mode.v_blank - mode.v_sync_off - 1,
        .v_blanks = (mode.v_blank - mode.v_sync_off - 1) + mode.v,
    };
}

// ===========================================================================
// Core channel methods: SOR control, head mode/or/viewport, window-owner.
// Emitted into the core (NVC57D) pushbuffer in nouveau's commit order.
//
//   head     — head index (0..7); raster methods add head*0x400
//   sor_id   — SOR (OR) index from OR_GET_INFO; SOR_SET_CONTROL adds sor_id*0x20
//   protocol — SOR PROTOCOL enum (clc37d.h): DP_A=8, DP_B=9, SINGLE_TMDS_A=1
//   window   — window index this head scans out (WINDOW_SET_CONTROL owner)
//   display_id — RM displayId for HEAD_SET_DISPLAY_ID
// ===========================================================================
/// Emit the core-channel mode-set methods for one head: SOR control, head raster
/// timing, output-resource/sync polarity, viewport, and window-owner assignment.
pub fn buildCoreMethods(
    push: *Push,
    head: u32,
    sor_id: u32,
    protocol: u32,
    window: u32,
    display_id: u32,
    mode: Mode,
) void {
    const r = deriveRaster(mode);

    // --- 1. SOR control: connect head→output (sorc37d_ctrl, NVC37D) ----------
    //   ctrl = (protocol << 8) | (1 << head)
    //   OWNER_MASK is bits 7:0; HEAD0=0x1, so the head's bit is 1<<head.
    //   PROTOCOL is bits 11:8. (disp.c:1551 builds exactly this: ctrl |= PROTOCOL
    //   then ctrl |= BIT(head).)
    const sor_ctrl = field(0, 8, @as(u32, 1) << @intCast(head)) | field(8, 4, protocol);
    push.mthd(sorSetControl(sor_id), sor_ctrl);

    // --- 2. Head raster timing (headc57d_mode, NVC57D) -----------------------
    // SET_RASTER_SIZE..SET_RASTER_BLANK_START are one incrementing run of 4.
    push.mthdRun(headSetRasterSize(head), &[_]u32{
        field(0, 15, r.h_active) | field(16, 15, r.v_active), // SET_RASTER_SIZE
        field(0, 15, r.h_synce) | field(16, 15, r.v_synce), // SET_RASTER_SYNC_END
        field(0, 15, r.h_blanke) | field(16, 15, r.v_blanke), // SET_RASTER_BLANK_END
        field(0, 15, r.h_blanks) | field(16, 15, r.v_blanks), // SET_RASTER_BLANK_START
    });
    // RASTER_BLANK2 = blank2e<<16 | blank2s. For a PROGRESSIVE mode nouveau's
    // nv50_head_atomic_check_mode (head.c:320-321) sets blank2e=0, blank2s=1 → this
    // is (0<<16)|1, NOT 0. (Verified: writing 0 makes the GSP reject method 0x2074
    // with a DISP Xid 56.) STRUCTURE/interlace = 0 (PROGRESSIVE).
    push.mthd(headSetRasterBlank2(head), (0 << 16) | 1);
    push.mthd(headSetRasterStructure(head), 0); // PROGRESSIVE

    // Dither control + procamp, programmed explicitly rather than left at their reset
    // defaults. Ordinary panels tolerate the defaults; a display with a G-SYNC module is
    // strict about the output pipeline being fully configured, and these two writes cost
    // nothing.
    push.mthd(0x00002018 + head * 0x400, 0x10); // HEAD_SET_DITHER_CONTROL (BITS=8bpc, disabled)
    push.mthd(headSetProcamp(head), 0);

    // Pixel clock in Hz. ADJ1000DIV1001 (bit 31) FALSE for non-1000/1001 modes.
    push.mthd(headSetPixelClockFrequency(head), field(0, 31, mode.clock_khz * 1000));
    push.mthd(headSetPixelClockFrequencyMax(head), field(0, 31, mode.clock_khz * 1000));

    // HEAD_USAGE_BOUNDS (headc57d_mode tail): cursor W256_H256, OUTPUT_SCALER_TAPS_2,
    // OLUT_ALLOWED=TRUE, UPSCALING_ALLOWED=TRUE — EXACTLY as nouveau headc57d_mode.
    // On Ada the head requires an OLUT: OLUT_ALLOWED=FALSE + no OLUT bound leaves the
    // post-blend pipe with no LUT and the head emits no valid output → dark panel +
    // the core UPDATE is rejected (notifier never FINISHED, DISP Xid 56). The OLUT
    // itself is bought below via emitOlut (identity LUT).
    push.mthd(headSetHeadUsageBounds(head), field(0, 3, HUB_CURSOR_W256_H256) |
        field(4, 1, 1) | // OLUT_ALLOWED TRUE (identity OLUT bound below)
        field(8, 1, 1) | // UPSCALING_ALLOWED TRUE (nouveau sets this)
        field(12, 3, HUB_OUTPUT_SCALER_TAPS_2));

    // --- 3. Output resource / sync polarity (headc57d_or, NVC57D) ------------
    // CRC_MODE ACTIVE_RASTER(0), HSYNC/VSYNC polarity from mode flags, 8bpc depth,
    // COLOR_SPACE_OVERRIDE DISABLE(0), EXT_PACKET_WIN NONE. Sync polarity comes
    // from the EDID detailed-timing flags (Mode.h/v_sync_neg); the EVO field is
    // 1=NEGATIVE_TRUE, 0=POSITIVE_TRUE, set to asyh->or.nhsync (headc57d.c:70).
    const or_val = field(0, 2, 0) | // CRC_MODE ACTIVE_RASTER
        field(2, 1, if (mode.h_sync_neg) 1 else 0) | // HSYNC_POLARITY
        field(3, 1, if (mode.v_sync_neg) 1 else 0) | // VSYNC_POLARITY
        field(4, 4, OR_PIXEL_DEPTH_BPP_24_444) |
        field(24, 1, 0) | // COLOR_SPACE_OVERRIDE DISABLE
        field(26, 6, OR_EXT_PACKET_WIN_NONE);
    push.mthd(headSetControlOutputResource(head), or_val);

    // HEAD_SET_DISPLAY_ID (headc57d_display_id). 0 disables.
    push.mthd(headSetDisplayId(head), display_id);

    // --- 4. Head viewport (headc37d_view, NVC37D offsets) --------------------
    // No scaling: in == out == active resolution. WIDTH 14:0, HEIGHT 30:16.
    push.mthd(headViewportSizeIn(head), field(0, 15, mode.h) | field(16, 15, mode.v));
    push.mthd(headViewportSizeOut(head), field(0, 15, mode.h) | field(16, 15, mode.v));

    // --- 5. Window owner (corec37d_wndw_owner, NVC37D) -----------------------
    // Assign this window to this head. OWNER 3:0 = head index.
    push.mthd(windowSetControl(window), field(0, 4, head));
}

// OLUT (output LUT) — MANDATORY on Ada. See buildOlut / OLUT_ENTRIES below.
// SIZE field (OLUT_CONTROL 18:8) = VSS header(4) + entries(1024) + 1 = 1029.
pub const OLUT_SIZE_FIELD: u32 = 4 + 1024 + 1;
// Number of 8-byte ramp entries after the 32-byte VSS header: 1024 + 1 replicated.
pub const OLUT_ENTRIES: u32 = 1024 + 1;
// Total OLUT buffer bytes: 32-byte VSS header + OLUT_ENTRIES * 8.
pub const OLUT_BYTES: u64 = 0x20 + @as(u64, OLUT_ENTRIES) * 8;
const OLUT_CTRL_MODE_DIRECT10: u32 = 0x2; // clc57d.h:347

/// Fill `buf` (>= OLUT_BYTES) with an identity DIRECT10 output LUT, byte-for-byte
/// as nouveau headc57d_olut_load builds it: a 32-byte zeroed VSS header, then 1024
/// entries of {u16 red, u16 green, u16 blue, u16 pad} where entry i maps the 10-bit
/// index to a 16-bit output (i<<6 | i>>4, the standard 10→16 identity), then a
/// final entry replicating the last (INTERPOLATE needs a "next" entry).
pub fn fillIdentityOlut(buf: []u8) void {
    @memset(buf[0..0x20], 0); // VSS header
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        const v: u16 = @intCast((i << 6) | (i >> 4)); // 10-bit index → 16-bit identity
        const off = 0x20 + i * 8;
        writeU16(buf, off + 0, v); // red
        writeU16(buf, off + 2, v); // green
        writeU16(buf, off + 4, v); // blue
        writeU16(buf, off + 6, 0); // pad
    }
    // Replicate the last entry (index 1023) into entry 1024.
    const last: u16 = @intCast((1023 << 6) | (1023 >> 4));
    const off = 0x20 + 1024 * 8;
    writeU16(buf, off + 0, last);
    writeU16(buf, off + 2, last);
    writeU16(buf, off + 4, last);
    writeU16(buf, off + 6, 0);
}

/// Little-endian u16 store into a byte buffer (OLUT entries are u16 triplets).
fn writeU16(buf: []u8, off: u32, v: u16) void {
    buf[off] = @intCast(v & 0xff);
    buf[off + 1] = @intCast(v >> 8);
}

/// Emit the head OLUT-set methods (headc57d_olut_set): bind the identity OLUT so the
/// head produces valid output. `olut_handle` is the OLUT ctxdma; `olut_off` is its
/// VRAM byte offset. MUST be pushed on the core channel as part of the modeset.
pub fn buildOlut(push: *Push, head: u32, olut_handle: u32, olut_off: u64) void {
    // OLUT_CONTROL: INTERPOLATE_ENABLE(bit0) | MIRROR_DISABLE(0) | MODE_DIRECT10(3:2) | SIZE(18:8).
    push.mthd(headSetOlutControl(head), field(0, 1, 1) |
        field(2, 2, OLUT_CTRL_MODE_DIRECT10) |
        field(8, 11, OLUT_SIZE_FIELD));
    push.mthd(headSetOlutFpNormScale(head), 0xffffffff);
    push.mthd(headSetContextDmaOlut(head), olut_handle);
    push.mthd(headSetOffsetOlut(head), @intCast(olut_off >> 8));
}

// ===========================================================================
// Hardware cursor — CORE-channel head methods (headc37d_curs_set; the c57d/
// c77d head reuses the c37d cursor setters, headc57d.c:259). Offsets are the
// c37d ones (clc37d.h).
// ===========================================================================

/// Core method offset of HEAD_SET_CONTROL_CURSOR for `head` (stride 0x400).
fn headSetControlCursor(head: u32) u32 {
    return 0x0000209c + head * 0x00000400; // clc37d.h:473
}
/// Core method offset of HEAD_SET_CONTROL_CURSOR_COMPOSITION (stride 0x400).
fn headSetControlCursorComposition(head: u32) u32 {
    return 0x000020a0 + head * 0x00000400; // clc37d.h:492
}
/// Core method offset of HEAD_SET_CONTEXT_DMA_CURSOR(head, 0) (stride 0x400).
fn headSetContextDmaCursor(head: u32) u32 {
    return 0x00002088 + head * 0x00000400; // clc37d.h:469
}
/// Core method offset of HEAD_SET_OFFSET_CURSOR(head, 0) (stride 0x400).
fn headSetOffsetCursor(head: u32) u32 {
    return 0x00002090 + head * 0x00000400; // clc37d.h:471
}

const CURSOR_FORMAT_A8R8G8B8: u32 = 0xCF; // clc37d.h:479
const CURSOR_SIZE_W32_H32: u32 = 0; // clc37d.h:481
// HEAD_SET_CONTROL_CURSOR_COMPOSITION field values (clc37d.h:493-501):
// K1 = full source alpha (src-over blend); the two FACTOR_SELECT enums pick
// K1 / NEG_K1_TIMES_SRC so out = K1*src + (1-K1)*dst; MODE=BLEND.
const CURSOR_COMP_K1: u32 = 0xff;
const CURSOR_COMP_FACTOR_K1: u32 = 2; // CURSOR_COLOR_FACTOR_SELECT
const CURSOR_COMP_FACTOR_NEG_K1_TIMES_SRC: u32 = 7; // VIEWPORT_COLOR_FACTOR_SELECT

/// Bind a 32x32 A8R8G8B8 cursor image to `head` (headc37d_curs_set parity):
/// CONTROL_CURSOR (enable, format, size, hotspot) + COMPOSITION (K1=0xff
/// src-over blend) + CONTEXT_DMA/OFFSET (all-VRAM ctxdma + image byte offset
/// >>8). Committed by the caller's core UPDATE.
pub fn buildCursorImage(push: *Push, head: u32, curs_handle: u32, image_off: u64, hot_x: u32, hot_y: u32) void {
    push.mthd(headSetControlCursor(head), field(31, 1, 1) | // ENABLE
        field(0, 8, CURSOR_FORMAT_A8R8G8B8) |
        field(8, 2, CURSOR_SIZE_W32_H32) |
        field(12, 8, hot_x) | field(20, 8, hot_y) |
        field(28, 2, 0)); // DE_GAMMA NONE
    push.mthd(headSetControlCursorComposition(head), field(0, 8, CURSOR_COMP_K1) |
        field(8, 4, CURSOR_COMP_FACTOR_K1) |
        field(12, 4, CURSOR_COMP_FACTOR_NEG_K1_TIMES_SRC) |
        field(16, 1, 0)); // MODE = BLEND
    push.mthd(headSetContextDmaCursor(head), curs_handle);
    push.mthd(headSetOffsetCursor(head), @intCast(image_off >> 8));
}

// ===========================================================================
// Window ILUT (input LUT) — MANDATORY on c57e/c67e windows for fixed-point
// formats. nouveau forces a dummy IDENTITY degamma LUT even when the user set
// none (nv50_wndw_atomic_check_lut: `if (!ilut && wndw->func->ilut_identity &&
// format != FP16) ilut = &dummy;` + wndwc57e `.ilut_identity = true`): the ILUT
// is how the window's fixed-point pixels are normalized into the FP composition
// pipeline. WITHOUT it the window's pixels pass through an unprogrammed input
// LUT → BLACK output while every commit succeeds (the exact "all metrics green,
// dark panel" symptom). Buffer geometry is identical to the OLUT (32-byte VSS
// header + 1025 8-byte entries → OLUT_BYTES), but the entry VALUES are
// FP16-encoded (wndwc57e_ilut_load: fixedU0_16_FP16), NOT raw fixed16.
// ===========================================================================

/// Convert a U0.16 fixed-point color component to FP16 (half-float), exactly as
/// nouveau's fixedU0_16_FP16 (wndwc57e.c:145): normalize the mantissa to the MSB,
/// counting one exponent step per shift (plus one for the exiting test, matching
/// the C `while (--exp && ...)`), take the top 10 fraction bits, bias by 15.
pub fn fixedU016ToFp16(v: u16) u16 {
    if (v == 0) return 0;
    var f: u32 = v;
    var exp: i32 = 0;
    while ((f & 0x8000) == 0) : (f <<= 1) exp -= 1;
    exp -= 1; // the C loop decrements once more on the exiting evaluation
    const man: u16 = @intCast(((f << 1) & 0xffc0) >> 6);
    const e: u16 = @intCast(exp + 15);
    return (e << 10) | man;
}

/// Fill `buf` (>= OLUT_BYTES; same geometry as the OLUT) with an identity DIRECT10
/// INPUT LUT, byte-for-byte as nouveau wndwc57e_ilut_load + nv50_lut_load's identity
/// ramp: 32-byte zeroed VSS header, then 1024 entries of {r,g,b,pad} u16 where entry
/// i = FP16(i<<6) (the U0.16 identity converted to half-float), then the last entry
/// replicated (interpolate modes need a "next" entry; harmless with it disabled).
pub fn fillIdentityIlut(buf: []u8) void {
    @memset(buf[0..0x20], 0); // VSS header
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        const v = fixedU016ToFp16(@intCast(i << 6)); // identity ramp, FP16-encoded
        const off = 0x20 + i * 8;
        writeU16(buf, off + 0, v); // red
        writeU16(buf, off + 2, v); // green
        writeU16(buf, off + 4, v); // blue
        writeU16(buf, off + 6, 0); // pad
    }
    const last = fixedU016ToFp16(@intCast(@as(u32, 1023) << 6));
    const off = 0x20 + 1024 * 8;
    writeU16(buf, off + 0, last);
    writeU16(buf, off + 2, last);
    writeU16(buf, off + 4, last);
    writeU16(buf, off + 6, 0);
}

// NVC57E window ILUT methods (clc57e.h:126-141).
const NVC57E_SET_ILUT_CONTROL: u32 = 0x00000440;
const NVC57E_SET_CONTEXT_DMA_ILUT: u32 = 0x00000444;
const NVC57E_SET_OFFSET_ILUT: u32 = 0x00000448;
const ILUT_CTRL_MODE_DIRECT10: u32 = 0x2; // clc57e.h:136

/// Emit the window ILUT-set methods (wndwc57e_ilut_set) into the WINDOW channel:
/// ILUT_CONTROL (INTERPOLATE_DISABLE | MODE_DIRECT10 | SIZE 1029), the ctxdma the
/// window resolves the LUT through (the all-VRAM scanout ctxdma works — same chid-1
/// resolution path as SET_CONTEXT_DMA_ISO), and the LUT's VRAM byte offset.
pub fn buildIlut(push: *Push, ilut_handle: u32, ilut_off: u64) void {
    // INTERPOLATE_DISABLE(bit0=0) | MIRROR_DISABLE(bit1=0) | MODE_DIRECT10(3:2) | SIZE(18:8).
    push.mthd(NVC57E_SET_ILUT_CONTROL, field(2, 2, ILUT_CTRL_MODE_DIRECT10) |
        field(8, 11, OLUT_SIZE_FIELD));
    push.mthd(NVC57E_SET_CONTEXT_DMA_ILUT, ilut_handle);
    push.mthd(NVC57E_SET_OFFSET_ILUT, @intCast(ilut_off >> 8));
}

// ===========================================================================
// Window channel methods: bind the scanout surface (wndwc67e_image_set, NVC57E).
// Emitted into the WINDOW channel pushbuffer (NOT the core channel).
//
//   window         — window index (selects the channel; not encoded in offsets)
//   ctxdma_handle  — ctxdma covering the VRAM surface (SET_CONTEXT_DMA_ISO)
//   surface_phys   — VRAM byte offset of the surface (SET_OFFSET = phys >> 8)
//   pitch          — row stride in bytes (SET_PLANAR_STORAGE = pitch >> 6)
//   mode           — active resolution (image w/h and src/dst sizes)
// ===========================================================================
/// Emit the window-channel methods that bind the scanout surface: present control,
/// size/storage/format/pitch, ctxdma+offset, src/dst geometry, and opaque blend.
pub fn buildWindowMethods(
    push: *Push,
    window: u32,
    ctxdma_handle: u32,
    surface_phys: u64,
    pitch: u64,
    // Plane blend: `depth` is the composition
    // z-order (lower = nearer the viewer, so an overlay above the desktop plane
    // uses a smaller depth than the desktop's 255). `premult` selects the factor
    // mode, K1 is always 0xff:
    //   false → PIXEL_NONE (0x4422, dst=NEG_K1): a plain opaque plane, alpha bytes
    //           ignored — the desktop plane.
    //   true  → PREMULTI (0x7722, dst=NEG_K1_TIMES_SRC): per-pixel
    //           out = src + (1−srcAlpha)·dst — the glass overlay, whose surface
    //           carries premultiplied alpha (translucent windows).
    // Never mix them up: PIXEL_NONE on glass caps text at the window opacity;
    // PREMULTI on an alpha-less surface degenerates additive (the ~90%-transparent
    // shipped bug — its srcAlpha=0 made the dst factor 1).
    depth: u8,
    premult: bool,
    // Window OUTPUT rectangle (Step 2b). `out_w`×`out_h`
    // is the on-CRTC size the window fetches and displays; the desktop plane passes
    // the full mode (`mode.h`×`mode.v` at the call site) — identical to the pre-2b
    // behaviour — and the
    // routed overlay plane passes the glass window's size so ONLY its pixels exist on
    // the plane (a full-plane overlay would darken the whole head by (1−K1/255) under
    // the constant-alpha blend). The output POSITION on the head is the WIMM channel's
    // SET_POINT_OUT (buildWimm), NOT set here — so a window painted at plane-local
    // (0,0) is displayed at (point_x,point_y) by the WIMM point.
    out_w: u32,
    out_h: u32,
) void {
    _ = window; // the window channel is selected by the caller's Push/PUT, not here

    // SET_PRESENT_CONTROL: MIN_PRESENT_INTERVAL 1, BEGIN_MODE NON_TEARING(0),
    // TIMESTAMP_MODE DISABLE(0). nouveau sets interval=1 (not 0) on a modeset where
    // the window interlocks with the core (nv50_wndw_flush_set, wndw.c:152) — an
    // interval-0 window in an interlocked commit never presents → black head.
    push.mthd(NVC57E_SET_PRESENT_CONTROL, field(0, 4, 1) | field(4, 3, 0) | field(8, 1, 0));

    // SET_SIZE .. SET_PLANAR_STORAGE(0): one incrementing run of 4 (wndwc57e).
    // SET_STORAGE on c67e (Ada) sets ONLY BLOCK_HEIGHT — MEMORY_LAYOUT is omitted
    // (wndwc67e_image_set vs wndwc57e). For a linear surface BLOCK_HEIGHT=ONE_GOB(0),
    // so SET_STORAGE == 0. SET_SIZE is the window's viewport (out_w×out_h) — the
    // region the window scans out.
    push.mthdRun(NVC57E_SET_SIZE, &[_]u32{
        field(0, 16, out_w) | field(16, 16, out_h), // SET_SIZE
        field(0, 4, WIN_BLOCK_HEIGHT_ONE_GOB), // SET_STORAGE (c67e: block height only)
        field(0, 8, WIN_FORMAT_A8R8G8B8), // SET_PARAMS (rounding/clamp/swap = 0)
        field(0, 13, @intCast(pitch >> 6)), // SET_PLANAR_STORAGE(0) = pitch>>6
    });

    // SET_CONTEXT_DMA_ISO(0) = ctxdma handle (Ada uses a real ctxdma, not a raw addr).
    push.mthd(nvc57eSetContextDmaIso(0), ctxdma_handle);
    // SET_OFFSET(0) = VRAM byte offset >> 8.
    push.mthd(nvc57eSetOffset(0), @intCast(surface_phys >> 8));

    // SET_POINT_IN(0): source origin 0,0 — the caller places the window's pixels at
    // the surface origin (the desktop fills the whole surface; the overlay CE-copies
    // the glass window to plane-local (0,0)).
    push.mthd(nvc57eSetPointIn(0), field(0, 16, 0) | field(16, 16, 0));
    // SET_SIZE_IN: source fetch w|h = the output size (no scaling).
    push.mthd(NVC57E_SET_SIZE_IN, field(0, 16, out_w) | field(16, 16, out_h));
    // SET_SIZE_OUT: crtc (dest) w|h = the output size.
    push.mthd(NVC57E_SET_SIZE_OUT, field(0, 16, out_w) | field(16, 16, out_h));

    // Composition/blend (wndwc37e_blend_set, NVC37E @0x2EC, 7-method run). WITHOUT
    // this the window's composition factors sit at reset (likely ZERO) so the window
    // contributes nothing → black head. For an OPAQUE primary: DEPTH=255, K1=0xff,
    // src=K1(0x2), dst=NEG_K1(0x4) → out = K1*src + (1-K1)*dst = src. Color-key off,
    // key ranges full (clc37e.h).
    push.mthdRun(NVC37E_SET_COMPOSITION_CONTROL, &[_]u32{
        field(4, 8, depth), // SET_COMPOSITION_CONTROL: COLOR_KEY_SELECT=DISABLE(0), DEPTH (z-order)
        field(0, 8, 0xff), // SET_COMPOSITION_CONSTANT_ALPHA: K1=0xff, K2=0
        // FACTOR_SELECT — see the `premult` param doc: PIXEL_NONE 0x4422
        // (dst=NEG_K1(4)) for opaque planes, PREMULTI 0x7722
        // (dst=NEG_K1_TIMES_SRC(7)) for the glass overlay. src=K1(2) in both.
        field(0, 4, 2) | field(4, 4, 2) |
            field(8, 4, @as(u32, if (premult) 7 else 4)) |
            field(12, 4, @as(u32, if (premult) 7 else 4)),
        field(0, 16, 0) | field(16, 16, 0xffff), // SET_KEY_ALPHA min=0 max=0xffff
        field(0, 16, 0) | field(16, 16, 0xffff), // SET_KEY_RED_CR
        field(0, 16, 0) | field(16, 16, 0xffff), // SET_KEY_GREEN_Y
        field(0, 16, 0) | field(16, 16, 0xffff), // SET_KEY_BLUE_CB
    });
}

/// Window image CLEAR (wndwc37e_image_clr) — detach the window's scanout so it is a
/// valid interlocked-commit member (still kicked, still in the mask → the
/// mask==kicked-set invariant holds) but scans out NOTHING. Used to arm the overlay
/// plane empty at bring-up and to blank it on the routed→unrouted edge. Exact nouveau
/// parity (dispnv50/wndwc37e.c wndwc37e_image_clr): the WHOLE method set is
///   SET_PRESENT_CONTROL(interval=0, NON_TEARING) + SET_CONTEXT_DMA_ISO(0)=0.
/// NO size/offset/blend/ILUT — a window with no ctxdma fetches no surface, so it
/// contributes no pixels regardless of its old size/depth. The caller emits a normal
/// `windowUpdate` after this (naming the window in the interlock mask) and kicks PUT.
pub fn buildWindowClr(push: *Push) void {
    push.mthd(NVC57E_SET_PRESENT_CONTROL, field(0, 4, 0) | field(4, 3, 0) | field(8, 1, 0)); // interval=0, NON_TEARING
    push.mthd(nvc57eSetContextDmaIso(0), 0); // detach scanout surface → no pixels
}

// ===========================================================================
// Window Update (wndwc37e_update, NVC37E). Emit into the WINDOW channel, then
// the caller kicks the window PUT. No interlock for a standalone first light.
// ===========================================================================
/// Window UPDATE (wndwc37e_update). On a modeset every interlock is ON:
///   SET_INTERLOCK_FLAGS       = (interlock[CURS]<<1) | interlock[CORE] = 1 (core)
///   SET_WINDOW_INTERLOCK_FLAGS = interlock[WNDW] = BIT(window) — pass `window_bit`
///   UPDATE.INTERLOCK_WITH_WIN_IMM (bit 12) = !!(interlock[WIMM] & BIT(window)) = with_wimm
/// `core_interlock` = wait for the core channel; `window_bit` = BIT(window) so the
/// window's own arm is reflected; `with_wimm` = interlock with the WIMM channel.
pub fn windowUpdate(push: *Push, core_interlock: bool, window_bit: u32, with_wimm: bool) void {
    push.mthd(NVC37E_SET_INTERLOCK_FLAGS, if (core_interlock) 1 else 0);
    push.mthd(NVC37E_SET_WINDOW_INTERLOCK_FLAGS, window_bit);
    // INTERLOCK_WITH_WIN_IMM is NVC37E_UPDATE bit 12 (clc37e.h: 12:12) — NOT bit 1,
    // which is reserved on the WINDOW update. (The WIMM channel's own UPDATE uses
    // bit 1 for INTERLOCK_WITH_WINDOW per clc37b.h, so the two are not symmetric.)
    // Writing bit 1 here left the window image free to latch before the WIMM
    // SET_POINT_OUT armed — an output-position glitch. nouveau wndwc37e_update.
    push.mthd(NVC37E_UPDATE, 0x00000001 | (if (with_wimm) @as(u32, 1) << 12 else 0));
}

// ===========================================================================
// Window-immediate (WIMM, NVC37B): SET_POINT_OUT — the window's OUTPUT POSITION
// on the head — plus the WIMM UPDATE. This lives ONLY in the WIMM channel, not
// the window channel; without it the window has no defined destination on the
// head and nothing is composited (black). Emit into the WIMM channel.
// nouveau wimmc37b_point + wimmc37b_update (dispnv50/wimmc37b.c).
// ===========================================================================
/// Emit the WIMM channel's SET_POINT_OUT (window output position `x`,`y` on the head)
/// plus its UPDATE, optionally interlocked with the window (true on a modeset).
pub fn buildWimm(push: *Push, x: u32, y: u32, interlock_with_window: bool) void {
    push.mthd(NVC37B_SET_POINT_OUT0, field(0, 16, x) | field(16, 16, y));
    // UPDATE.INTERLOCK_WITH_WINDOW (bit1) = !!(interlock[WNDW] & BIT(window)) — on a
    // modeset this is TRUE (wimmc37b_update), so the WIMM point latches together with
    // the window image. The WIMM Update is emitted BEFORE the window Update.
    push.mthd(NVC37B_UPDATE, 0x00000001 | (if (interlock_with_window) @as(u32, 1) << 1 else 0));
}

// ===========================================================================
// Core Update (corec37d_update, NVC37D). Emit into the CORE channel, then the
// caller kicks the core PUT and polls the core notifier STATUS==FINISHED.
// No interlock for a standalone first light.
// ===========================================================================
/// Core UPDATE. `wndw_interlock` = SET_WINDOW_INTERLOCK_FLAGS (BIT(window) so the
/// core latch waits for the window channel to arm; 0 for the isolated owner update).
/// `ntfy_off` (if non-null) brackets the UPDATE with SET_NOTIFIER_CONTROL so the
/// caller can poll the core notifier for FINISHED (the proper commit signal).
/// nouveau corec37d_update.
pub fn coreUpdate(push: *Push, wndw_interlock: u32, ntfy_off: ?u32) void {
    if (ntfy_off) |off| {
        // MODE=WRITE(0) | OFFSET=(off>>4)<<4 (11:4) | NOTIFY=ENABLE(bit12).
        push.mthd(NVC37D_SET_NOTIFIER_CONTROL, ((off >> 4) << 4) | (@as(u32, 1) << 12));
    }
    push.mthd(NVC37D_SET_INTERLOCK_FLAGS, 0); // no cursor/base/ovly
    push.mthd(NVC37D_SET_WINDOW_INTERLOCK_FLAGS, wndw_interlock);
    push.mthd(NVC37D_UPDATE, 0x00000001);
    if (ntfy_off != null) push.mthd(NVC37D_SET_NOTIFIER_CONTROL, 0); // NOTIFY=DISABLE
}

const NVC37D_SET_NOTIFIER_CONTROL: u32 = 0x0000020c; // clc37d.h:62
pub const NOTIFIER_STATUS_FINISHED: u32 = 2; // NV_DISP_NOTIFIER__0_STATUS_FINISHED (31:30)

/// The window-owner assignment (WINDOW_SET_CONTROL(window).OWNER = head), pushed into
/// the core channel in its own isolated non-interlocked core UPDATE before the window
/// is armed. nouveau corec37d_wndw_owner. OWNER field 3:0 = head index (OWNER_HEAD(i)=i).
pub fn buildWindowOwner(push: *Push, window: u32, head: u32) void {
    push.mthd(windowSetControl(window), field(0, 4, head));
}

// NVC57D window usage-bounds (clc57d.h:30/82/134), per-window stride 0x80.
/// Core method offset of WINDOW_SET_WINDOW_FORMAT_USAGE_BOUNDS for window `w`.
fn winFormatUsageBounds(w: u32) u32 {
    return 0x00001004 + w * 0x00000080;
}
/// Core method offset of WINDOW_SET_WINDOW_ROTATED_FORMAT_USAGE_BOUNDS for window `w`.
fn winRotatedFormatUsageBounds(w: u32) u32 {
    return 0x00001008 + w * 0x00000080;
}
/// Core method offset of WINDOW_SET_WINDOW_USAGE_BOUNDS for window `w`.
fn winUsageBounds(w: u32) u32 {
    return 0x00001010 + w * 0x00000080;
}

// ===========================================================================
// Core channel INIT (corec57d_init, dispnv50/corec57d.c). MUST run on the core
// channel before the mode-set: it grants each window permission to fetch pixel
// formats (WINDOW_SET_WINDOW_FORMAT_USAGE_BOUNDS) and sets fetch limits
// (WINDOW_SET_WINDOW_USAGE_BOUNDS). Without it the window fetches nothing and the
// head scans out no signal — even though every RM call succeeds. `notifier` is the
// core sync ctxdma handle (0 to skip; first light uses a delay instead).
// ===========================================================================
/// Emit the one-time core-channel init: bind the sync notifier and grant every
/// window its format/usage bounds (without this the window fetches nothing → black).
pub fn buildCoreInit(push: *Push, notifier: u32) void {
    push.mthd(NVC37D_SET_CONTEXT_DMA_NOTIFIER, notifier);
    var w: u32 = 0;
    while (w < 8) : (w += 1) {
        // FORMAT_USAGE_BOUNDS: RGB_PACKED 1/2/4/8 BPP all TRUE (bits 0-3 = 0xf).
        push.mthd(winFormatUsageBounds(w), 0xf);
        // ROTATED_FORMAT_USAGE_BOUNDS: 0.
        push.mthd(winRotatedFormatUsageBounds(w), 0);
        // USAGE_BOUNDS: MAX_PIXELS_FETCHED_PER_LINE=0x7fff (14:0), ILUT_ALLOWED=TRUE
        // (bit16 — every window binds the mandatory identity ILUT, buildIlut; matches
        // mainline corec57d_init), INPUT_SCALER_TAPS (22:20, TAPS_2=1 → bit 20).
        push.mthd(winUsageBounds(w), field(0, 15, 0x7fff) | field(16, 1, 1) | field(20, 3, 1));
    }
}
