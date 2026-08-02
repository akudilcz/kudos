//! Display engine bring-up over the GSP-RM (M9.5). Allocates the display object
//! tree and probes the connected output, following nouveau's r535/r570 disp path.
//! Runs after the RM client/device/subdevice tree (rm.clientDeviceCtor) is up.
//!
//! Sequence (Phase 2-5 of the map):
//!   1. RAMIN: a 0x10000 VRAM instmem buffer; hand its phys addr to the GSP via
//!      WRITE_INST_MEM so the RM can place display state there.
//!   2. NV04_DISPLAY_COMMON (objcom): the object every NV0073_* display ctrl runs on.
//!   3. GET_STATIC_INFO (subdevice): the window-present mask.
//!   4. GET_SUPPORTED (objcom): the mask of connected displayId's.
//!   5. AD102_DISP root (0xc770): the display engine root the channels hang off.

const algn = @import("algn"); // alignment: ONE home
const std = @import("std");
const log = @import("../base/log.zig").gpu;
const gsp = @import("../gsp/gsp.zig");
const rm = @import("../gsp/rm.zig");
const nvrm = @import("../base/nvrm.zig");
const vram = @import("../core/vram.zig");
const mmio = @import("../base/mmio.zig");
const shim = @import("../base/shim.zig");
const fblayout = @import("../base/fblayout.zig");
const dp = @import("dp.zig");
const chan = @import("../core/chan.zig");
const ctxdma = @import("../core/ctxdma.zig");
const modeset = @import("modeset.zig");
const calc = @import("../base/calc.zig");
const edid = @import("edid.zig");
const Push = @import("../core/push.zig").Push;
const gate = @import("../../../kernel/debug/gate.zig");
const alignUp = algn.up;

/// RAMIN instmem size/alignment (nouveau disp->inst: nvkm_gpuobj_new(0x10000,0x10000)).
const RAMIN_SIZE: u64 = 0x10000;

/// Ultrawide-only display policy. When true, bring-up drives
/// ONLY the widest-aspect connected monitor (the centre 3440x1440 ultrawide) and
/// leaves every other connected panel dark — not modeset, no head, no workspace
/// fill. This is a deliberate single-monitor desktop, not a fallback: the two 4K
/// side monitors are intentionally not presented to. Set false to drive every
/// connected monitor (one head each), the multi-monitor behaviour.
const ULTRAWIDE_ONLY = true;

/// NV_PDISP raster-position register for head 0 (RG_DPCA-style: current
/// scanline/vline in bits 15:0). Reading it twice with a delay is the "is this
/// head actually scanning?" probe used by the bring-up moving check below and
/// by present.scanWatchdog — a live head's vline advances continuously.
pub const RG_VLINE_REG: u64 = 0x616330;
/// Per-head stride of the NV_PDISP RG register block (head h: RG_VLINE_REG + h*stride).
pub const RG_HEAD_STRIDE: u64 = 0x800;
/// Mask of the vline (current scanline) field, bits 15:0 of RG_VLINE_REG.
pub const RG_VLINE_MASK: u32 = 0xffff;

// Solid fill color (BGRA8888), single-sourced so drawTestPattern (the write) and
// driveMonitor's readback check (the verify) can never drift apart. Full-white
// lights the room — every pixel of every driven monitor is 0xffffffff.
const FILL_COLOR: u32 = 0xff000000; // opaque black (desktop appears via CE)

/// Fill the entire VRAM scanout surface with FILL_COLOR (BGRA8888). Uses a windowed
/// VRAM writer (one PRAMIN select per 64 KiB) so a 4K surface is written in
/// ~thousands of selects, not ~8M. Honors the pitch padding past w*4.
fn drawTestPattern(regs: mmio.Mapping, phys: u64, pitch: u64, w: u32, h: u32) void {
    var wr = vram.Writer.init(regs, phys);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        wr.seek(phys + @as(u64, y) * pitch); // honor pitch padding past w*4
        var x: u32 = 0;
        while (x < w) : (x += 1) wr.put(FILL_COLOR);
    }
}

/// A display mode's active resolution + timings — owned by the pure, host-tested
/// edid.zig (single source of truth). Re-exported so `disp.Mode` references (and
/// present_real/dp) resolve unchanged.
pub const Mode = edid.Mode;

/// Parse the preferred detailed-timing descriptor into a Mode (pure; edid.zig).
const parsePreferredMode = edid.parsePreferredMode;

/// Read `displayId`'s EDID via NV0073_CTRL_SPECIFIC_GET_EDID_V2 and return its
/// native (preferred) mode. Falls back to mode4k (loudly) if the RM read fails or
/// the EDID header magic (00 FF FF FF FF FF FF 00) is missing — a bad EDID must not
/// silently yield a garbage timing that blanks the head.
fn readNativeMode(g: gsp.Gsp, displayId: u32) Mode {
    var p = std.mem.zeroes(nvrm.SpecificGetEdidV2Params);
    p.subDeviceInstance = 0;
    p.displayId = displayId;
    p.bufferSize = nvrm.EDID_MAX_BYTES;
    rm.control(g, nvrm.RM_DISP, nvrm.CTRL_SPECIFIC_GET_EDID_V2, std.mem.asBytes(&p)) catch |e| {
        log("gpu.disp: GET_EDID_V2 failed for displayId=0x{x}: {} — forcing 4K\n", .{ displayId, e });
        return mode4k;
    };
    if (!edid.headerValid(p.edidBuffer[0..8])) {
        log("gpu.disp: displayId=0x{x} EDID header invalid (0x{x}) — forcing 4K\n", .{ displayId, p.edidBuffer[0] });
        return mode4k;
    }
    return parsePreferredMode(p.edidBuffer[0..128]);
}

/// What the bring-up produced: the handles + probed state the mode-set needs.
pub const Disp = struct {
    objcom: u32, // NV04_DISPLAY_COMMON
    root: u32, // AD102_DISP
    ramin_phys: u64, // VRAM instmem address handed to the GSP
    window_mask: u32, // present windows (from GET_STATIC_INFO)
    display_mask: u32, // candidate displayId's (from GET_SUPPORTED)
    target_id: u32, // the largest attached monitor (mode-set target)
    mode: Mode, // its native mode (head raster-timing source)
    surface_phys: u64, // VRAM scanout framebuffer (linear BGRA8888)
    pitch: u64, // surface row stride in bytes (64-byte aligned)
    heads: [4]Head, // every lit head's scanout (CE present path targets)
    nheads: usize,
    core: chan.CoreChan, // the ONE shared core channel (cursor image bind + UPDATE)
    client: u32, // disp RM client handle (ctxdma context tags)
    subdevice: u32, // RM subdevice handle (internal-display ctrl target)

    pub const Head = struct {
        index: u32, // head id (core-method stride, cursor channel instance)
        surface_phys: u64, // ring buffer 0 (initial scanout surface)
        surface_back: u64, // ring buffer 1
        surface_third: u64, // ring buffer 2 (triple buffering)
        pitch: u64,
        w: u32,
        h: u32,
        window: u32, // window index (channel + method addressing)
        ctx_handle: u32, // scanout ctxdma (covers all VRAM — both surfaces)
        wndw: chan.CoreChan, // the head's window channel (flip pushes)
        mode: Mode, // native mode (flip re-emits the image methods)
        ntfy_handle: u32, // window flip-completion notifier ctxdma (vsync pacing)
        ntfy_va: u64, // VRAM addr of the notifier page (PRAMIN-read STATUS)
        // The HW-blended overlay plane for this head,
        // null unless HW_PLANE_BLEND. The present flip path co-flips it with the
        // desktop window each frame when a translucent window is routed to it.
        overlay: ?Overlay = null,
    };
};

pub const Error = error{ NoDisplayConnected, VramOutOfMemory, RamhtFull, CoreUpdateTimeout, SurfaceReadbackMismatch } || rm.Error || chan.Error || dp.Error;

/// Bring up the display engine on the booted GSP-RM. `objs` are the RM handles
/// from rm.clientDeviceCtor; `valloc` carves the RAMIN from free VRAM.
pub fn bringUp(g: gsp.Gsp, objs: rm.RmObjects, valloc: *vram.Allocator) Error!Disp {
    // 1. RAMIN instmem in VRAM; zero it (the RM expects a clean buffer) and tell
    //    the GSP its physical address.
    const ramin = try valloc.alloc(RAMIN_SIZE, RAMIN_SIZE);
    vram.fill(g.regs, ramin, RAMIN_SIZE, 0);
    var im = nvrm.WriteInstMemParams{
        .instMemPhysAddr = ramin,
        .instMemSize = RAMIN_SIZE,
        .instMemAddrSpace = nvrm.ADDR_FBMEM,
        .instMemCpuCacheAttr = nvrm.MEMORY_WRITECOMBINED,
    };
    try rm.control(g, objs.subdevice, nvrm.CTRL_INTERNAL_DISPLAY_WRITE_INST_MEM, std.mem.asBytes(&im));
    log("gpu.disp: RAMIN @0x{x} ({} KiB) written to GSP\n", .{ ramin, RAMIN_SIZE >> 10 });

    // 2. NV04_DISPLAY_COMMON — handle RM_DISP, no params. Parent = device.
    try rm.allocObject(g, objs.client, objs.device, nvrm.RM_DISP, nvrm.NV04_DISPLAY_COMMON, &.{});

    // 2b. DP_SET_MANUAL_DISPLAYPORT — tell the GSP-RM the driver drives DP manually
    //     (link train + stream config). r535_disp_oneinit does this right after
    //     NV04_DISPLAY_COMMON; WITHOUT it the RM is in auto mode and rejects a
    //     manual DP_CONFIG_STREAM with 0x16 (the mode-set blocker). Params = just
    //     subDeviceInstance (=0).
    {
        var mdp = [_]u8{0} ** 4; // NV0073_CTRL_CMD_DP_SET_MANUAL_DISPLAYPORT_PARAMS
        try rm.control(g, nvrm.RM_DISP, nvrm.CTRL_DP_SET_MANUAL_DISPLAYPORT, mdp[0..]);
        log("gpu.disp: DP_SET_MANUAL_DISPLAYPORT OK\n", .{});
    }

    // 3. Display static info (subdevice ctrl) → window-present mask.
    var si = std.mem.zeroes(StaticInfoParams);
    rm.control(g, objs.subdevice, nvrm.CTRL_INTERNAL_DISPLAY_GET_STATIC_INFO, std.mem.asBytes(&si)) catch |e| {
        log("gpu.disp: GET_STATIC_INFO failed: {}\n", .{e});
        return e;
    };
    log("gpu.disp: window mask=0x{x} numHeads={}\n", .{ si.windowPresentMask, si.numHeads });

    // 4. Connected displays (objcom ctrl) → displayId mask.
    var sup = nvrm.SystemGetSupportedParams{ .subDeviceInstance = 0, .displayMask = 0, .displayMaskDDC = 0 };
    try rm.control(g, nvrm.RM_DISP, nvrm.CTRL_SYSTEM_GET_SUPPORTED, std.mem.asBytes(&sup));
    log("gpu.disp: supported displayMask=0x{x} (DDC 0x{x})\n", .{ sup.displayMask, sup.displayMaskDDC });

    // 4b. Probe every candidate display: which has a monitor attached. Collect all
    //     connected displayIds; force a common 4K mode on each (the user wants the
    //     same 3840x2160 on all monitors, not their per-panel native modes).
    var mons: [4]Monitor = undefined;
    var nmon: usize = 0;
    // Probe all 32 displayId bits (0..31). `bit` is u6 so incrementing past 31 does
    // not wrap a u5 (which would loop forever); the shift takes @intCast(bit).
    var bit: u6 = 0;
    while (bit < 32 and nmon < mons.len) : (bit += 1) {
        const id = @as(u32, 1) << @intCast(bit);
        if ((sup.displayMask & id) == 0) continue;

        var cs = nvrm.SystemGetConnectStateParams{ .subDeviceInstance = 0, .flags = 0, .displayMask = id, .retryTimeMs = 0 };
        // A GET_CONNECT_STATE RM failure is a real error, not "no monitor" — log it
        // (like GET_STATIC_INFO does) before skipping, rather than swallowing it.
        rm.control(g, nvrm.RM_DISP, nvrm.CTRL_SYSTEM_GET_CONNECT_STATE, std.mem.asBytes(&cs)) catch |e| {
            log("gpu.disp: GET_CONNECT_STATE failed for displayId=0x{x}: {}\n", .{ id, e });
            continue;
        };
        // One line per candidate (connected or not) so a monitor kudos isn't lighting
        // is visible as a probed-but-not-connected entry rather than silently absent.
        log("gpu.disp: candidate displayId=0x{x} connected={}\n", .{ id, (cs.displayMask & id) != 0 });
        if ((cs.displayMask & id) == 0) continue; // not connected

        // Read this monitor's EDID and drive its NATIVE mode, not a forced 4K. A
        // non-4K panel (e.g. the larger centre monitor) rejects a hardcoded 3840x2160
        // CVT timing → "out of range"/no signal → dark, while true 4K panels accept
        // it. The preferred detailed-timing descriptor (EDID block 0) is the native
        // mode. If EDID read/parse fails, fall back to mode4k and say so loudly.
        const mode = readNativeMode(g, id);
        log("gpu.disp: displayId=0x{x} CONNECTED — native {}x{} @ {} kHz | hblank={} hsoff={} hsw={} vblank={} vsoff={} vsw={} hneg={} vneg={}\n", .{ id, mode.h, mode.v, mode.clock_khz, mode.h_blank, mode.h_sync_off, mode.h_sync_w, mode.v_blank, mode.v_sync_off, mode.v_sync_w, mode.h_sync_neg, mode.v_sync_neg });
        mons[nmon] = .{ .id = id, .mode = mode };
        nmon += 1;
    }

    // 5. AD102_DISP root (0xc770) — handle (oclass<<16), no params. Parent = device.
    try rm.allocObject(g, objs.client, objs.device, nvrm.AD102_DISP << 16, nvrm.AD102_DISP, &.{});

    if (nmon == 0) {
        log("gpu.disp: no monitor attached to the 4090 — stopping before mode-set\n", .{});
        return error.NoDisplayConnected;
    }

    // 6+7. Drive EVERY connected monitor on its own head — a clean loop over the
    //      Display struct's driveMonitor. Per-monitor non-fatal so one failure
    //      doesn't block the others.
    // Allocate the ONE shared core channel (nouveau has a single core channel for
    // the whole disp; only window+WIMM are per-head), and run its one-time init
    // (window usage-bounds) once.
    const dispRoot: u32 = nvrm.AD102_DISP << 16;
    var core = try chan.coreChannelInit(g, valloc, dispRoot, objs.subdevice);
    // Core notifier buffer (VRAM) + its ctxdma (chid=0, the core channel), bound via
    // SET_CONTEXT_DMA_NOTIFIER in core-init so the final UPDATE can signal FINISHED.
    const notifier = try valloc.alloc(0x1000, 0x1000);
    vram.fill(g.regs, notifier, 0x1000, 0);
    const ntfy_handle = try ctxdma.createNotifier(g.regs, ramin, notifier, objs.client);
    {
        var ibuf: [128]u32 = undefined;
        var ipush = Push.init(&ibuf);
        modeset.buildCoreInit(&ipush, ntfy_handle);
        try chan.submit(&core, g.regs, ipush);
    }
    var display = Display{ .g = g, .objs = objs, .valloc = valloc, .ramin = ramin, .root = dispRoot, .core = core, .notifier = notifier };

    // Ultrawide-only policy: drive ONLY the widest-aspect
    // monitor. Find it (max w/h, the same criterion present.enableDesktopMirror uses
    // to pick the primary) and swap it to mons[0], then drive exactly one head. The
    // other connected panels stay dark. When the policy is off, drive every monitor
    // (head = loop index), the multi-monitor path.
    if (ULTRAWIDE_ONLY) {
        var wide: usize = 0;
        var j: usize = 1;
        while (j < nmon) : (j += 1) {
            if (@as(u64, mons[j].mode.h) * mons[wide].mode.v > @as(u64, mons[wide].mode.h) * mons[j].mode.v) wide = j;
        }
        const tmp = mons[0];
        mons[0] = mons[wide];
        mons[wide] = tmp;
    }
    // driveMonitor allocates a distinct surface/OLUT/window/WIMM/ctxdma per head and
    // hands out distinct SORs via assigned_sors. Per-monitor failures are isolated
    // (one bad head doesn't block the others). Capped at mons.len (4) — 4090 has 4 heads.
    const drive_n: usize = if (ULTRAWIDE_ONLY) 1 else nmon;
    log("gpu.disp: {} monitor(s) detected — driving {} ({s})\n", .{ nmon, drive_n, if (ULTRAWIDE_ONLY) "ultrawide only" else "all" });
    // Per-monitor failures are NON-fatal: light as many of the connected monitors as
    // will come up (one bad head shouldn't blank the others). Track how many lit; if
    // NONE lit, that's a real bring-up failure.
    var staged: [4]Prepared = undefined;
    var nstaged: usize = 0;
    for (mons[0..drive_n], 0..) |mon, idx| {
        const head: u32 = @intCast(idx);
        staged[nstaged] = display.prepareMonitor(head, mon) catch |e| {
            log("gpu.disp: head {} (displayId=0x{x}) staging failed: {} — continuing\n", .{ head, mon.id, e });
            continue;
        };
        nstaged += 1;
    }
    if (nstaged == 0) return error.NoDisplayConnected;
    // ONE atomic interlocked latch across every staged head (nouveau parity).
    try display.commitAll(staged[0..nstaged]);
    log("gpu.disp: {}/{} monitor(s) lit\n", .{ nstaged, drive_n });

    var heads: [4]Disp.Head = undefined;
    for (staged[0..nstaged], 0..) |p, i| {
        heads[i] = .{ .index = p.head, .surface_phys = p.surface, .surface_back = p.surface_back, .surface_third = p.surface_third, .pitch = p.pitch, .w = p.mon.mode.h, .h = p.mon.mode.v, .window = p.window, .ctx_handle = p.ctx_handle, .wndw = p.wndw, .mode = p.mon.mode, .ntfy_handle = p.ntfy_handle, .ntfy_va = p.ntfy_va, .overlay = p.overlay };
    }

    return .{
        .objcom = nvrm.RM_DISP,
        .root = nvrm.AD102_DISP << 16,
        .ramin_phys = ramin,
        .window_mask = si.windowPresentMask,
        .display_mask = sup.displayMask,
        .target_id = mons[0].id,
        .mode = mons[0].mode,
        .surface_phys = display.surface0,
        .pitch = display.pitch0,
        .heads = heads,
        .nheads = nstaged,
        .core = display.core,
        .client = objs.client,
        .subdevice = objs.subdevice,
    };
}

/// Standard 3840x2160 @ ~60 Hz CVT-RB-ish timing — forced on every monitor so all
/// three show the same 4K mode. (Pixel clock + blanking are a common 4K60 set; the
/// monitors all reported 4K-capable native modes.)
const mode4k = Mode{
    .h = 3840,
    .v = 2160,
    .clock_khz = 533250,
    .h_blank = 160, // CVT-RB: 80 front + 32 sync + 48 back ≈ 160 blank
    .h_sync_off = 48,
    .h_sync_w = 32,
    .v_blank = 62,
    .v_sync_off = 3,
    .v_sync_w = 5,
    .h_sync_neg = false,
    .v_sync_neg = true,
};

/// One connected monitor's identity + native mode (probe result).
const Monitor = struct { id: u32, mode: Mode };

// CPU-side staging buffer for building LUTs before writing them to VRAM. File
// scope, NOT a driveMonitor stack array: two 8 KiB LUT buffers in one frame
// overflow the task stack and corrupt the msgq state, which surfaces as the next
// RPC hanging the GSP queue. GPU init is single-threaded, so one shared buffer,
// reused OLUT-then-ILUT per head, is safe.
var lut_stage: [modeset.OLUT_BYTES]u8 = undefined;

/// The display engine, brought up once. Holds the shared RM handles + the disp
/// RAMIN; `driveMonitor` then lights up one monitor per head — looping over all
/// connected monitors is just calling it N times.
const Display = struct {
    g: gsp.Gsp,
    objs: rm.RmObjects,
    valloc: *vram.Allocator,
    ramin: u64, // disp->inst (holds the RAMHT + ctxdma descriptors)
    root: u32, // AD102_DISP
    core: chan.CoreChan, // the ONE shared core channel (drives all heads)
    notifier: u64, // VRAM core-notifier buffer (SET_NOTIFIER_CONTROL polls this)
    assigned_sors: u8 = 0, // bitmask of SORs handed out (DFP_ASSIGN_SOR excludeMask)
    surface0: u64 = 0, // head-0 scanout surface (for the post-hold readback check)
    pitch0: u64 = 0, // head-0 surface row stride

    /// Stage `mon` on `head`: own VRAM surface (test pattern), own ctxdma, own
    /// window+WIMM channels (the core channel is shared), DP train, EVO mode-set
    /// staging. Everything is STAGED but NOT latched — commitAll() then arms all
    /// windows and latches the core in ONE atomic interlocked commit, exactly like
    /// nouveau nv50_disp_atomic_commit_tail (the byte-diff of kudos' pushbuffer
    /// stream vs the instrumented-nouveau working stream showed the interlocked
    /// global commit as the only remaining structural divergence: nouveau windows
    /// carry 0x370=1/0x374=<all-windows mask> and the core carries 0x21c=<mask>).
    fn prepareMonitor(self: *Display, head: u32, mon: Monitor) !Prepared {
        const g = self.g;
        const window: u32 = head * 2;
        const mode = mon.mode;

        // Own VRAM scanout surface (linear BGRA8888), with the test pattern.
        // Pitch MUST be 256-byte aligned: NVDisplay's linear scanout pitch
        // granularity is 256 bytes (EVO SURFACE_SET_STORAGE.PITCH is programmed as
        // pitch>>8, nouveau base507c.c:104). 3440*4=13760 is 64- but not 256-aligned
        // — the GSP rejected that window's UPDATE (Xid 56 CMDre mthd 0x200 subcode
        // 0x2f), which is why the ultrawide stayed black at native while 1080p
        // (7680) and 4K (15360) pitches worked.
        const pitch: u64 = alignUp(@as(u64, mode.h) * 4, 256);
        const surface = try self.valloc.alloc(pitch * mode.v, 0x1000);
        drawTestPattern(g.regs, surface, pitch, mode.h, mode.v);
        // Record head 0's surface so bringUp can hand it up for the post-hold
        // readback (proving the pixels persist through the display-active period).
        if (head == 0) {
            self.surface0 = surface;
            self.pitch0 = pitch;
        }
        // TRIPLE BUFFERING (the session update cycle): three full-mode
        // scanout surfaces per head form a rotating ring [scanout][pending][compose].
        // The CE always composites into the buffer that is neither on scanout nor
        // pending-flip, so it needs NO vblank wait and cannot tear at any phase — the
        // fix for the 30fps/jitter stall (a double buffer's only free surface WAS the
        // pending-flip one, forcing a per-frame latch wait). NOT pre-filled (a PRAMIN
        // fill of every buffer costs tens of seconds): the first flip of each does a
        // full-frame CE copy, so a buffer is fully written before it is scanned out.
        const surface_back = try self.valloc.alloc(pitch * mode.v, 0x1000);
        const surface_third = try self.valloc.alloc(pitch * mode.v, 0x1000);

        // Read the fill back from VRAM (through the PRAMIN window) and verify it
        // matches what drawTestPattern wrote — the "did the pixels actually land in
        // VRAM" correctness check, not a diagnostic. Solid FILL_COLOR everywhere.
        const px0 = vram.read32(g.regs, surface);
        const pxmid = vram.read32(g.regs, surface + (mode.v / 2) * pitch + (mode.h / 2) * 4);
        log("gpu.disp: head {} surface@0x{x} readback px[0]=0x{x:0>8} px[center]=0x{x:0>8}\n", .{ head, surface, px0, pxmid });
        if (px0 != FILL_COLOR or pxmid != FILL_COLOR) {
            log("gpu.disp: head {} surface readback MISMATCH: px[0]=0x{x:0>8} (want 0x{x:0>8}) px[center]=0x{x:0>8} (want 0x{x:0>8})\n", .{ head, px0, FILL_COLOR, pxmid, FILL_COLOR });
            return error.SurfaceReadbackMismatch;
        }

        // DP link train (GSP auto-trains; wakes the sink via DPCD 0x600=D0). Pass
        // the assigned-SOR mask so this head gets a DISTINCT SOR (nouveau
        // r535_outp_acquire sorExcludeMask = disp->rm.assigned_sors).
        const link = try dp.linkUp(g, mon.id, self.assigned_sors, mode);
        self.assigned_sors |= @as(u8, 1) << @intCast(link.sor_id);

        // Own ctxdma (per-window) + RAMHT entry binding this surface.
        const ctx_handle = try ctxdma.createScanout(g.regs, self.ramin, g.fb.fb_size, self.objs.client, window);

        // OLUT (output LUT). A/B-tested: NOT the cause of the dark panel (head 0 fails
        // identically with it disabled), so keep it — it matches nouveau headc57d.
        // Staged via the file-scope lut_stage buffer, NOT a stack array: two 8 KiB
        // LUT buffers on this frame overflowed the task stack and corrupted the msgq
        // state (first RPC inside this frame hung the GSP queue).
        const olut_phys = try self.valloc.alloc(modeset.OLUT_BYTES, 0x100);
        modeset.fillIdentityOlut(&lut_stage);
        vram.writeBytes(g.regs, olut_phys, &lut_stage);
        const olut_handle = try ctxdma.createOlut(g.regs, self.ramin, g.fb.fb_size, self.objs.client);

        // Per-head window + window-immediate channels (the core channel is shared).
        const wndw = try chan.windowChannelInit(g, self.valloc, self.root, self.objs.subdevice, window);
        var wimm = try chan.wimmChannelInit(g, self.valloc, self.root, self.objs.subdevice, window);

        // Window ILUT buffer (input LUT) — MANDATORY on c57e/c67e windows for
        // fixed-point formats (nouveau forces a dummy IDENTITY degamma even with no
        // user LUT: wndw.c ilut_identity branch + wndwc57e .ilut_identity=true).
        // Entries are FP16-encoded (wndwc57e_ilut_load). Without it the window's
        // pixels pass through an unprogrammed input LUT → BLACK output while every
        // commit succeeds. Staged via lut_stage (file scope), not the stack.
        const ilut_phys = try self.valloc.alloc(modeset.OLUT_BYTES, 0x100);
        modeset.fillIdentityIlut(&lut_stage);
        vram.writeBytes(g.regs, ilut_phys, &lut_stage);

        // WIMM point (window output position 0,0) — armed standalone up front.
        // nouveau's captured working stream has NO WIMM traffic during the modeset,
        // so keep it out of the atomic commit entirely.
        var mbuf: [16]u32 = undefined;
        var mpush = Push.init(&mbuf);
        modeset.buildWimm(&mpush, 0, 0, false);
        try chan.submit(&wimm, g.regs, mpush);
        try wimm.waitDrained(g.regs);

        // Per-window flip-completion notifier: a page of VRAM the display engine
        // writes STATUS=BEGUN into at each flip's vblank latch, plus a ctxdma the
        // window SET_CONTEXT_DMA_NOTIFIER binds. The present flip path resets it,
        // arms it, and polls STATUS==BEGUN as the vsync pacing point — replacing the
        // GET==PUT drain, which only meant "methods fetched" not "flip presented"
        // (the session update cycle + vsync pacing).
        const ntfy_va = try self.valloc.alloc(0x1000, 0x1000);
        vram.fill(g.regs, ntfy_va, 0x1000, 0);
        const ntfy_handle = try ctxdma.createWindowNotifier(g.regs, self.ramin, ntfy_va, self.objs.client, window);

        // HW-blended overlay: the head's odd window, sharing this head's SOR/link +
        // OLUT (per-head), with its own resource set.
        const overlay: ?Overlay = if (HW_PLANE_BLEND) try self.prepareOverlay(head, mode, pitch) else null;

        return .{ .head = head, .window = window, .mon = mon, .sor_id = link.sor_id, .protocol = link.protocol, .surface = surface, .surface_back = surface_back, .surface_third = surface_third, .pitch = pitch, .ctx_handle = ctx_handle, .olut_handle = olut_handle, .olut_phys = olut_phys, .ilut_phys = ilut_phys, .wndw = wndw, .ntfy_handle = ntfy_handle, .ntfy_va = ntfy_va, .overlay = overlay };
    }

    /// Build the odd window's (head*2+1) resource set for a HW-blended overlay:
    /// own surface front+back (256-aligned pitch), scanout ctxdma, window + WIMM
    /// channels, window ILUT (FP16 identity), WIMM point, and a flip notifier —
    /// mirroring the even window minus the per-HEAD resources (SOR/link, OLUT,
    /// core/head raster methods), which the overlay shares.
    fn prepareOverlay(self: *Display, head: u32, mode: Mode, pitch: u64) !Overlay {
        const g = self.g;
        const window: u32 = head * 2 + 1;
        log("gpu.disp: [overlay h{d} w{d}] prepare start — mode {d}x{d} pitch={d} (256-aligned={})\n", .{ head, window, mode.h, mode.v, pitch, pitch % 256 == 0 });

        // Own scanout surfaces at the SAME 256-aligned pitch as the desktop plane.
        // Not pre-filled — the first overlay flip does a full CE copy of its content.
        const surface = try self.valloc.alloc(pitch * mode.v, 0x1000);
        const surface_back = try self.valloc.alloc(pitch * mode.v, 0x1000);
        log("gpu.disp: [overlay h{d} w{d}] surfaces front=0x{x} back=0x{x} ({d} bytes each)\n", .{ head, window, surface, surface_back, pitch * mode.v });

        const ctx_handle = try ctxdma.createScanout(g.regs, self.ramin, g.fb.fb_size, self.objs.client, window);
        log("gpu.disp: [overlay h{d} w{d}] scanout ctxdma handle=0x{x}\n", .{ head, window, ctx_handle });

        // Own window + WIMM channels (channels are per-window).
        const wndw = try chan.windowChannelInit(g, self.valloc, self.root, self.objs.subdevice, window);
        var wimm = try chan.wimmChannelInit(g, self.valloc, self.root, self.objs.subdevice, window);
        log("gpu.disp: [overlay h{d} w{d}] window + WIMM channels up\n", .{ head, window });

        // Own window ILUT (FP16 identity — mandatory on c67e windows).
        const ilut_phys = try self.valloc.alloc(modeset.OLUT_BYTES, 0x100);
        modeset.fillIdentityIlut(&lut_stage);
        vram.writeBytes(g.regs, ilut_phys, &lut_stage);
        log("gpu.disp: [overlay h{d} w{d}] ILUT (FP16 identity) @0x{x}\n", .{ head, window, ilut_phys });

        // WIMM point (overlay output at 0,0), armed standalone up front.
        var mbuf: [16]u32 = undefined;
        var mpush = Push.init(&mbuf);
        modeset.buildWimm(&mpush, 0, 0, false);
        try chan.submit(&wimm, g.regs, mpush);
        try wimm.waitDrained(g.regs);
        log("gpu.disp: [overlay h{d} w{d}] WIMM point armed (0,0) + drained\n", .{ head, window });

        // Own flip notifier.
        const ntfy_va = try self.valloc.alloc(0x1000, 0x1000);
        vram.fill(g.regs, ntfy_va, 0x1000, 0);
        const ntfy_handle = try ctxdma.createWindowNotifier(g.regs, self.ramin, ntfy_va, self.objs.client, window);
        log("gpu.disp: [overlay h{d} w{d}] flip notifier va=0x{x} handle=0x{x}\n", .{ head, window, ntfy_va, ntfy_handle });

        log("gpu.disp: [overlay h{d} w{d}] PREPARED — all resources up, shares head SOR/link+OLUT\n", .{ head, window });
        return .{ .window = window, .surface = surface, .surface_back = surface_back, .ctx_handle = ctx_handle, .ilut_phys = ilut_phys, .wndw = wndw, .wimm = wimm, .ntfy_handle = ntfy_handle, .ntfy_va = ntfy_va };
    }

    /// The GLOBAL atomic commit — byte-matched to the instrumented-nouveau working
    /// stream's EXACT shape (nv50_disp_atomic_commit_tail as the GSP actually saw
    /// it). Nouveau's whole 3-head modeset is TWO core UPDATEs:
    ///   1. ONE standalone core kick: every head's raster/OR/viewport methods, then
    ///      owner assigns for ALL 8 windows (window w → head w/2), then a
    ///      notifier-bracketed non-interlocked UPDATE.
    ///   2. Stage every head's OLUT (no update).
    ///   3. Each window channel gets ONE kick: image+ILUT+blend, then
    ///      SET_INTERLOCK_FLAGS=1 / SET_WINDOW_INTERLOCK_FLAGS=<all-windows mask> /
    ///      UPDATE — windows cannot drain until the core latches, so no waits here.
    ///   4. ONE final core UPDATE with 0x21c=<mask>, notifier-bracketed.
    fn commitAll(self: *Display, staged: []Prepared) !void {
        const g = self.g;
        // Interlock mask = every window co-committed this epoch. It MUST name exactly
        // the set of window channels kicked with an armed UPDATE below, or the engine
        // trips Xid 56 subcode 0x2d (interlocked-but-not-armed). Both the mask and the
        // kick loop iterate `staged` + each head's overlay, so they cannot drift
        // (the wedge invariant).
        var window_mask: u32 = 0;
        for (staged) |p| {
            window_mask |= @as(u32, 1) << @intCast(p.window);
            if (p.overlay) |ov| window_mask |= @as(u32, 1) << @intCast(ov.window);
        }
        log("gpu.disp: atomic commit — {} head(s), window interlock mask=0x{x}\n", .{ staged.len, window_mask });

        // 1. Core kick #1: all heads' mode methods + ALL window owners + standalone
        //    UPDATE (nouveau commits every raster and owner assign in this one epoch).
        vram.write32(g.regs, self.notifier + 0, 0);
        vram.write32(g.regs, self.notifier + 4, 0);
        vram.write32(g.regs, self.notifier + 8, 0);
        vram.write32(g.regs, self.notifier + 12, 0);
        var cbuf: [768]u32 = undefined;
        var cpush = Push.init(&cbuf);
        for (staged) |p| modeset.buildCoreMethods(&cpush, p.head, p.sor_id, p.protocol, p.window, p.mon.id, p.mon.mode);
        var w: u32 = 0;
        while (w < 8) : (w += 1) modeset.buildWindowOwner(&cpush, w, w / 2);
        modeset.coreUpdate(&cpush, 0, 0);
        try chan.submit(&self.core, g.regs, cpush);

        // 2. Stage every head's OLUT — committed by the final interlocked UPDATE.
        var lbuf: [64]u32 = undefined;
        var lpush = Push.init(&lbuf);
        for (staged) |p| modeset.buildOlut(&lpush, p.head, p.olut_handle, p.olut_phys);
        try chan.submit(&self.core, g.regs, lpush);

        // 3. One kick per window: image + ILUT + interlocked UPDATE together. Every
        //    window named in window_mask MUST be kicked here (invariant above).
        for (staged) |*p| {
            var wbuf: [256]u32 = undefined;
            var wpush = Push.init(&wbuf);
            // Opaque desktop plane: DEPTH=255 (bottom), K1=0xff (fully opaque). The
            // translucent overlay plane, when live, uses
            // a lower depth + its window's alpha; that path passes different values.
            modeset.buildWindowMethods(&wpush, p.window, p.ctx_handle, p.surface, p.pitch, 255, false, p.mon.mode.h, p.mon.mode.v);
            modeset.buildIlut(&wpush, p.ctx_handle, p.ilut_phys);
            modeset.windowUpdate(&wpush, true, window_mask, false);
            try chan.submit(&p.wndw, g.regs, wpush);
            log("gpu.disp: [commit] window {d} (h{d} desktop) armed DEPTH=255 K1=0xff (opaque), interlock=0x{x}\n", .{ p.window, p.head, window_mask });

            // The overlay window, if live, is co-committed in the SAME atomic epoch —
            // it MUST be a member of this interlocked commit (named in window_mask AND
            // kicked here) or the mask==kicked-set invariant breaks → Xid 56. But it is
            // armed IMAGE-CLEARED, not image-set: `buildWindowClr` detaches its scanout
            // ctxdma so it fetches no surface and contributes NO pixels, leaving the
            // desktop plane fully visible. Arming it full-head image-set (even at K1=0)
            // put a full-head BLACK plane at DEPTH=254 nearer the viewer than the
            // desktop and blacked the whole panel (bring-up arms the overlay
            // CLEARED; nouveau wndwc37e_image_clr). Real content is
            // armed later, only on a routed co-flip (present_real.presentFlip).
            if (p.overlay) |*ov| {
                var obuf: [256]u32 = undefined;
                var opush = Push.init(&obuf);
                modeset.buildWindowClr(&opush);
                modeset.windowUpdate(&opush, true, window_mask, false);
                try chan.submit(&ov.wndw, g.regs, opush);
                log("gpu.disp: [commit] window {d} (h{d} OVERLAY) armed IMAGE-CLEARED (no scanout), interlock=0x{x}\n", .{ ov.window, p.head, window_mask });
            }
        }
        log("gpu.disp: [commit] all windows kicked (mask=0x{x}); no drain — awaiting final core UPDATE latch\n", .{window_mask});

        // 4. The ONE interlocked core UPDATE, notifier-bracketed.
        // corec37d_ntfy_init zeros ALL FOUR notifier dwords (_0 STATUS=NOT_BEGUN,
        // _1/_2/_3=0), not just _0 — the engine reads/writes the whole slot.
        vram.write32(g.regs, self.notifier + 0, 0); // _0 = NOT_BEGUN
        vram.write32(g.regs, self.notifier + 4, 0); // _1
        vram.write32(g.regs, self.notifier + 8, 0); // _2
        vram.write32(g.regs, self.notifier + 12, 0); // _3
        var ubuf: [16]u32 = undefined;
        var upush = Push.init(&ubuf);
        modeset.coreUpdate(&upush, window_mask, 0);
        try chan.submit(&self.core, g.regs, upush);

        // Poll the notifier for FINISHED (status bits 31:30 == 2). ~2 s budget.
        var ntfy_done = false;
        var spins: u32 = 0;
        while (spins < 2000) : (spins += 1) {
            const st = vram.read32(g.regs, self.notifier) >> 30;
            if (st == modeset.NOTIFIER_STATUS_FINISHED) {
                ntfy_done = true;
                break;
            }
            shim.delayUs(1000);
        }

        // Per-head: confirm the head is scanning (vline advances when live) and
        // log. PURELY diagnostic — the 50 ms-per-head vline delta (150 ms of
        // boot on 3 heads) is only worth paying when someone can see the
        // result, so the sampling is gated with the log line it feeds (the
        // FINISHED notifier above is the real commit check either way).
        for (staged) |p| {
            if (!gate.on(.gpu)) break;
            const hoff: u64 = @as(u64, p.head) * RG_HEAD_STRIDE;
            const vline1 = g.regs.read32(RG_VLINE_REG + hoff) & RG_VLINE_MASK;
            shim.delayUs(50_000);
            const vline2 = g.regs.read32(RG_VLINE_REG + hoff) & RG_VLINE_MASK;
            log("gpu.disp: head {} displayId=0x{x} {}x{} sor {} surface@0x{x} | UPDATE finished={} vline {}->{} moving={}\n", .{ p.head, p.mon.id, p.mon.mode.h, p.mon.mode.v, p.sor_id, p.surface, ntfy_done, vline1, vline2, vline1 != vline2 });
            if (p.overlay) |ov| {
                // The overlay was co-committed in the SAME interlocked epoch, so this
                // head's FINISHED notifier IS the overlay's latch confirmation too (no
                // Xid means the interlock held).
                log("gpu.disp: head {} OVERLAY window {} co-committed + latched (interlock 0x{x}, finished={}) — HW plane blend live\n", .{ p.head, ov.window, window_mask, ntfy_done });
            }
        }

        // The notifier is the mode-set's "committed" signal (modeset.zig). A commit
        // that never reaches FINISHED is a failed mode-set, not a diagnostic.
        if (!ntfy_done) return error.CoreUpdateTimeout;
    }
};

/// One staged (but not yet latched) head — everything commitAll needs.
// HW display-plane alpha blending: promote the head's
// odd window (head*2+1) to a second armed plane the display engine blends over the
// desktop plane, for one translucent overlay per monitor. OFF by default — the
// overlay path is GPU-commit code (Xid 56 interlock risk) that can only be verified
// on a watched passthrough run; flip on for that run, default-on once proven.
const HW_PLANE_BLEND = true;

const Prepared = struct {
    head: u32,
    window: u32,
    mon: Monitor,
    sor_id: u32,
    protocol: u32,
    surface: u64,
    surface_back: u64,
    surface_third: u64, // ring buffer 2 (triple buffering)
    pitch: u64,
    ctx_handle: u32,
    olut_handle: u32,
    olut_phys: u64,
    ilut_phys: u64,
    wndw: chan.CoreChan,
    ntfy_handle: u32, // window flip-completion notifier ctxdma
    ntfy_va: u64, // VRAM addr of the notifier page (PRAMIN-read STATUS)
    // Overlay plane (odd window head*2+1), present only when HW_PLANE_BLEND and the
    // head hosts the desktop. Shares the head's SOR/link + OLUT; carries its OWN
    // surface/ctxdma/window+WIMM channel/ILUT/notifier so it can be co-committed and
    // flipped independently. null → single-window head (today's behavior).
    overlay: ?Overlay = null,
};

/// The odd window's resource set for HW-blended overlay.
const Overlay = struct {
    window: u32, // head*2+1
    surface: u64, // overlay scanout front (256-byte-aligned pitch, shared value)
    surface_back: u64,
    ctx_handle: u32, // overlay scanout ctxdma
    ilut_phys: u64, // overlay window ILUT (own copy)
    wndw: chan.CoreChan, // overlay window channel
    wimm: chan.CoreChan, // overlay WIMM (window-immediate) channel — per-frame SET_POINT_OUT
    ntfy_handle: u32,
    ntfy_va: u64,
};

// Boot-stack frame budget guard. `bringUp` runs on the 16 KiB→64 KiB boot stack
// (boot/boot.asm "Boot stack"; the native GPU bring-up runs on this stack) and
// holds `staged: [4]Prepared` + `heads: [4]Head` + a by-value `Disp` (also
// `[4]Head`) live at once, and passes `Disp` by value into several present/verify
// helpers. Growing these structs silently grows that frame, and an overflow here
// runs off the boot stack into the page tables — a black-screen boot with no
// diagnostic. This cap turns such regrowth into a BUILD failure instead. If a real
// need pushes past the cap, raise BOTH this number and `stack_bottom` together
// and re-verify the native boot — do not just bump the cap.
const HEAD_ARR_BUDGET = 4 * 256; // [4]Head, generous ceiling over today's 216 B/Head
comptime {
    std.debug.assert(@sizeOf([4]Disp.Head) <= HEAD_ARR_BUDGET);
    std.debug.assert(@sizeOf([4]Prepared) <= HEAD_ARR_BUDGET + 4 * 32);
}

/// NV2080_CTRL_INTERNAL_DISPLAY_GET_STATIC_INFO_PARAMS (r570 nvrm/disp.h). Mixed
/// NvBool(1B)/u32 — explicit pad bytes after each bool keep every u32 at its C
/// offset. Adjacent bools (bExternal/bInternalMuxSupported) share one 4-byte slot.
const StaticInfoParams = extern struct {
    feHwSysCap: u32, // 0
    windowPresentMask: u32, // 4
    bFbRemapperEnabled: u8, // 8
    _pad0: [3]u8 = .{ 0, 0, 0 }, // 9
    numHeads: u32, // 12
    i2cPort: u32, // 16
    internalDispActiveMask: u32, // 20
    embeddedDisplayPortMask: u32, // 24
    bExternalMuxSupported: u8, // 28
    bInternalMuxSupported: u8, // 29
    _pad1: [2]u8 = .{ 0, 0 }, // 30
    numDispChannels: u32, // 32
};
comptime {
    std.debug.assert(@sizeOf(StaticInfoParams) == 36);
    std.debug.assert(@offsetOf(StaticInfoParams, "numHeads") == 12);
    std.debug.assert(@offsetOf(StaticInfoParams, "numDispChannels") == 32);
}
