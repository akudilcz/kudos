//! Real IPresent backend — the hardware implementation of the iface/ipresent
//! contract for the native 4090. Wraps the GPU
//! modules (ce/gmmu/vram/fifo/shim + the modeset/chan flip path) behind the vtable
//! so present.zig's frame path is hardware-independent. This module is the ONLY
//! place under the seam that imports those HW modules for the steady-state frame.
//!
//! The seam is contract-only, never a behaviour change: `copyPitch` emits the
//! ce.copyPitch method stream (VA_SEM semaphore, fence 0 = no release),
//! `presentFlip` is buildWindowMethods/windowUpdate/chan.submit, and the batch
//! uses the single shared push_phys page.

const ipresent = @import("ipresent");
const gsp = @import("../gsp/gsp.zig");
const fifo = @import("../engines/fifo.zig");
const ce = @import("../engines/ce.zig");
const gmmu = @import("../engines/gmmu.zig");
const vram = @import("../engines/vram.zig");
const shim = @import("../rm/shim.zig");
const chan = @import("../engines/chan.zig");
const modeset = @import("../display/modeset.zig");
const overlay_plane = @import("overlay_plane");
const disp = @import("../display/disp.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const hostpush = @import("hostpush");
const flip_pacing = @import("flip_pacing.zig");
const Push = @import("../engines/push.zig").Push;

/// The HW-blended overlay plane's flip handles, the
/// odd window co-flipped with the desktop window when a glass window is routed to
/// it. The blend is per-pixel PREMULTI at K1=0xff — the routed window's own alpha
/// bytes carry the glass, so there is no per-frame K1 state.
pub const OverlayHw = struct {
    wndw: chan.CoreChan,
    wimm: chan.CoreChan, // WIMM channel — per-frame SET_POINT_OUT (window output position)
    window: u32,
    ctx_handle: u32,
    ilut_phys: u64,
    ntfy_handle: u32, // overlay's own flip notifier (every interlocked window arms one)
    ntfy_va: u64,
    // The overlay is DOUBLE-BUFFERED like the desktop plane (Step 2b):
    // the CE writes the OFF-scanout `back`, the flip swaps front↔back.
    // Writing the buffer being scanned out would tear every frame.
    surface: u64, // overlay scanout FRONT (currently displayed)
    surface_back: u64, // overlay scanout BACK (CE target for the routed window)
    // The routed window's on-head rectangle THIS frame:
    // the plane is sized to the window (out_w×out_h) and positioned at (point_x,
    // point_y) via the WIMM SET_POINT_OUT, so ONLY the window's pixels exist on the
    // plane (a full-head overlay would darken the screen by (1−K1/255)).
    point_x: u16 = 0,
    point_y: u16 = 0,
    out_w: u16 = 0,
    out_h: u16 = 0,
    // This frame's route decision (a glass window is routed to this plane). Set by
    // setOverlayArm each frame; consumed by presentFlip via overlay_plane.step.
    armed: bool = false,
    // The plane's PERSISTENT arm state (whether content is currently latched). The
    // pure overlay_plane.step state machine turns
    // (plane, armed) into the per-frame action: content co-flip, one-shot BLANK on
    // the routed→unrouted edge (else the last glass ghosts — NVDisplay keeps
    // scanning its last image, nouveau wndwc37e_image_clr parity), or nothing. That
    // logic is HOST-TESTED in overlay_plane.zig (it had two bugs before extraction).
    plane: overlay_plane.Plane = .{},
};

/// Per-head flip handles (the HW-typed parts of a head that only the flip path
/// touches). Kept out of present.State's HeadState so State stays HW-free.
pub const HeadHw = struct {
    wndw: chan.CoreChan, // the head's window channel (flip pushes + drain)
    index: u32, // head id (RG register stride — real scanline/vblank read)
    window: u32, // window index (channel + method addressing)
    ctx_handle: u32, // scanout ctxdma
    pitch: u64, // surface row stride in bytes
    mode: disp.Mode, // native mode (flip re-emits the image methods)
    ntfy_handle: u32, // window flip-completion notifier ctxdma (vsync pacing)
    ntfy_va: u64, // VRAM addr of the notifier page (PRAMIN-read STATUS==BEGUN)
    ntfy_armed: bool, // a flip has armed the notifier at least once (else nothing to wait for)
    last_flip_tsc: u64, // TSC at the last presentFlip — the refresh-pacing anchor
    overlay: ?OverlayHw = null, // HW-blend overlay plane for this head (null = single-window)
};

/// The real backend's opaque context. Holds the GPU handles + per-head flip
/// handles + the single open batch. present.State keeps a pointer to this via the
/// ipresent.IPresent handle.
pub const RealCtx = struct {
    g: gsp.Gsp,
    f: *fifo.Fifo,
    valloc: *vram.Allocator,
    heads: [4]HeadHw,
    nheads: usize,
    open: ?hostpush.HostPush, // the batch pushbuffer, open between begin/endBatch

    /// Build the ipresent.IPresent handle backed by this ctx + the static vtable.
    pub fn backend(self: *RealCtx) ipresent.IPresent {
        return .{ .ctx = self, .vt = &vtable };
    }

    pub fn init(g: gsp.Gsp, f: *fifo.Fifo, valloc: *vram.Allocator) RealCtx {
        return .{ .g = g, .f = f, .valloc = valloc, .heads = undefined, .nheads = 0, .open = null };
    }

    /// Register a head's flip handles from a disp.Disp.Head at `index`.
    pub fn setHead(self: *RealCtx, index: usize, h: disp.Disp.Head) void {
        const ov: ?OverlayHw = if (h.overlay) |o|
            .{ .wndw = o.wndw, .wimm = o.wimm, .window = o.window, .ctx_handle = o.ctx_handle, .ilut_phys = o.ilut_phys, .ntfy_handle = o.ntfy_handle, .ntfy_va = o.ntfy_va, .surface = o.surface, .surface_back = o.surface_back, .armed = false, .plane = .{} }
        else
            null;
        self.heads[index] = .{ .wndw = h.wndw, .index = h.index, .window = h.window, .ctx_handle = h.ctx_handle, .pitch = h.pitch, .mode = h.mode, .ntfy_handle = h.ntfy_handle, .ntfy_va = h.ntfy_va, .ntfy_armed = false, .last_flip_tsc = 0, .overlay = ov };
        if (index + 1 > self.nheads) self.nheads = index + 1;
    }

    /// Record this frame's overlay route decision (Step 2b).
    /// `armed=true` means a glass window is routed: presentFlip co-flips the
    /// overlay displaying `out_w`×`out_h` from the overlay back buffer at head
    /// position (`point_x`,`point_y`), premult-blended per pixel — the caller
    /// (present.gpuFrameEnd) must have CE-copied the window into the overlay back
    /// buffer first. `armed=false` → presentFlip's state machine (overlay_plane.step)
    /// decides: one-shot BLANK if content was showing (else it ghosts), else nothing.
    /// No-op when the head has no overlay (the compositor only routes when
    /// disp.overlayAvailable(), true iff prim.overlay != null).
    pub fn setOverlayArm(self: *RealCtx, index: usize, armed: bool, point_x: u16, point_y: u16, out_w: u16, out_h: u16) void {
        const ov = &(self.heads[index].overlay orelse return);
        ov.armed = armed;
        if (armed) {
            ov.point_x = point_x;
            ov.point_y = point_y;
            ov.out_w = out_w;
            ov.out_h = out_h;
        }
    }
};

fn ctxOf(p: *anyopaque) *RealCtx {
    return @ptrCast(@alignCast(p));
}

// ── vtable implementations ─────────────────────────────────────────────────────

fn mapSysmem(p: *anyopaque, va: u64, phys: u64, len: u64) ipresent.MapError!void {
    ctxOf(p).f.mmu.mapSysmem(va, phys, len) catch return ipresent.MapError.BackendMapFailed;
}

fn remapSysmem(p: *anyopaque, va: u64, phys: u64, len: u64) ipresent.MapError!void {
    ctxOf(p).f.mmu.remapSysmem(va, phys, len) catch return ipresent.MapError.BackendMapFailed;
}

fn mapVram(p: *anyopaque, va: u64, phys: u64, len: u64) ipresent.MapError!void {
    ctxOf(p).f.mmu.mapVram(va, phys, len) catch return ipresent.MapError.BackendMapFailed;
}

fn allocVram(p: *anyopaque, size: u64, alignment: u64) ipresent.MapError!u64 {
    return ctxOf(p).valloc.alloc(size, alignment) catch ipresent.MapError.BackendVramExhausted;
}

fn flushRange(_: *anyopaque, addr: u64, len: u64) void {
    shim.flushRange(addr, len);
}

fn beginBatch(p: *anyopaque) void {
    const c = ctxOf(p);
    if (c.open != null) @panic("present_real: nested beginBatch — the single push_phys page would be clobbered");
    c.open = c.f.begin();
}

fn copyPitch(p: *anyopaque, dst_va: u64, dst_pitch: u32, src_va: u64, src_pitch: u32, line_bytes: u32, lines: u32, fence: u32) void {
    const c = ctxOf(p);
    // The batch must be open; emit the SAME ce.copyPitch stream as the pre-seam
    // code (VA_SEM semaphore, fence 0 = no release). Byte-identical by construction.
    ce.copyPitch(&(c.open.?), dst_va, dst_pitch, src_va, src_pitch, line_bytes, lines, gmmu.VA_SEM, fence);
}

fn endBatch(p: *anyopaque, fence: u32) ipresent.SubmitError!void {
    const c = ctxOf(p);
    defer c.open = null;
    _ = c.f.submitWait(c.g, &(c.open.?), fence) catch return ipresent.SubmitError.BackendFenceTimeout;
}

/// Kick the batch and close it WITHOUT waiting on the fence — the CE runs while the
/// caller does other work (the vblank wait). `waitFence` collects the result before the
/// flip. This is what moves the ~2.4ms CE fence round-trip OFF the frame's critical path.
fn endBatchKick(p: *anyopaque, fence: u32) ipresent.SubmitError!void {
    const c = ctxOf(p);
    defer c.open = null;
    _ = fence; // the fence rides the batch's final copy (already staged by copyPitch)
    c.f.kick(c.g, c.open.?.bytes()) catch return ipresent.SubmitError.BackendFenceTimeout;
}

/// Block on a fence kicked by `endBatchKick` (sysmem semaphore poll). Safe to call after
/// an unbounded amount of other work — if the CE already finished it returns instantly.
fn waitFence(p: *anyopaque, fence: u32) ipresent.SubmitError!void {
    const c = ctxOf(p);
    _ = c.f.waitSem(c.g, fence) catch return ipresent.SubmitError.BackendFenceTimeout;
}

fn nextFence(p: *anyopaque) u32 {
    return ctxOf(p).f.nextFence();
}

/// One refresh interval in microseconds from the head's mode timings — the pure
/// math (incl. the clk=0 guard) lives in flip_pacing (host-tested); this shim only
/// narrows disp.Mode to the timing scalars it needs.
fn frameUs(mode: disp.Mode) u64 {
    return flip_pacing.frameUs(.{ .h = mode.h, .h_blank = mode.h_blank, .v = mode.v, .v_blank = mode.v_blank, .clock_khz = mode.clock_khz });
}

/// Read the head's current scanline (RG_VLINE, bits 15:0) — the LIVE raster
/// position, the same register the scan watchdog + bring-up "moving" check use.
/// `vline >= mode.v` (v_active) means the head is in the VERTICAL BLANK.
fn vline(c: *RealCtx, hw: *const HeadHw) u32 {
    const hoff: u64 = @as(u64, hw.index) * disp.RG_HEAD_STRIDE;
    return c.g.regs.read32(disp.RG_VLINE_REG + hoff) & disp.RG_VLINE_MASK;
}

/// Flip-timing instrumentation captured by the last `waitFlipLatched` call, so
/// present.zig's FLIP line can report WHY a frame took as long as it did: the
/// scanline at entry (were we already in blank → about to burn a full frame?),
/// how long the wait took, and whether we hit the safety timeout.
pub var dbg_vline_entry: u32 = 0;
pub var dbg_wait_blank_us: u64 = 0; // total wait to the latch point (out of blank if needed, then into blank)
pub var dbg_wait_timedout: bool = false;

/// Single-flip-ahead pacing guard (triple buffering). Called by
/// `gpuFrameEnd` AFTER compositing ring[compose], BEFORE arming its flip. It holds the
/// loop to at most ONE flip in flight: it waits until the head has crossed into vblank
/// once since the previous flip armed — the latch point at which the previous
/// `pending` buffer became live and the buffer about to rotate into `compose` is freed.
/// (The GSP never writes the BEGUN notifier on this path — `nf=0` every frame — so the
/// live RG_VLINE scanline is the latch proxy, the same signal the scan watchdog trusts.)
///
/// Waiting HERE, after the composite, is what keeps the cadence at one present per
/// refresh: the composite is already paid for, so the remaining wait for the previous
/// flip's latch is short and self-pacing. Blocking before the composite instead would
/// skip whole iterations at a random phase. Catch the ACTIVE→BLANK edge: if already in
/// blank, first wait for active, so one blank cannot take two flips. A 2-frame safety
/// timeout keeps a stalled head from hanging the loop.
fn waitFlipLatched(p: *anyopaque, head_index: usize) ipresent.SubmitError!void {
    const c = ctxOf(p);
    const hw = &c.heads[head_index];
    if (!hw.ntfy_armed) return; // no flip yet — nothing to sync against
    const v_active = hw.mode.v;
    const t0 = tsc.rdtsc();
    dbg_vline_entry = vline(c, hw);
    dbg_wait_timedout = false;
    const frame_us = frameUs(hw.mode);
    const deadline = t0 + tsc.usTicks(flip_pacing.TIMEOUT_FRAMES * frame_us);
    // ONE FLIP PER REFRESH — the spacing rule (fast path only ≥ ~0.75 refresh after
    // the last flip) and the wait-path selection live in the pure, HOST-TESTED
    // flip_pacing.decide, which is covered against both failure modes: skipping a
    // refresh (30 fps) and flipping twice in one vblank (~78 presents/s).
    // This function keeps only the hardware side: the live RG_VLINE reads, rdtsc,
    // and the pause-spin wait loops the decision selects between.
    const spacing_ticks = tsc.usTicks(flip_pacing.spacingUs(frame_us));
    const decision = flip_pacing.decide(vline(c, hw) >= v_active, t0, hw.last_flip_tsc, spacing_ticks);
    // Already in vblank AND a refresh has elapsed → the previous flip has latched; go.
    if (decision == .go) {
        dbg_wait_blank_us = 0;
        return;
    }
    // Either mid-active, or too soon after the last flip (still inside its refresh):
    // wait for the NEXT rising edge into vblank — the previous flip's latch point, one
    // refresh boundary away at most. This is what phase-locks the loop to the panel.
    // If we are ALREADY in blank but not spaced enough, first wait OUT of blank so the
    // edge detector below sees a real rising edge (not this same vblank).
    const t1 = tsc.rdtsc();
    if (decision == .wait_active_then_edge) {
        while (vline(c, hw) >= v_active) {
            if (tsc.rdtsc() >= deadline) {
                dbg_wait_timedout = true;
                break;
            }
            asm volatile ("pause");
        }
    }
    while (vline(c, hw) < v_active) {
        if (tsc.rdtsc() >= deadline) {
            dbg_wait_timedout = true;
            break;
        }
        asm volatile ("pause");
    }
    dbg_wait_blank_us = tsc.elapsedUs(t1);
    // The 2-frame safety timeout fired: the head never reached the expected vblank
    // edge — a stalled/stuck head, not a normal wait. Report it loudly instead of
    // returning as if the previous flip latched: ipresent.SubmitError.
    // BackendDrainTimeout exists for exactly this, and the frame path disables GPU
    // presenting when it sees one. Returning success here instead would keep handing
    // frames to a head that is not consuming them.
    if (dbg_wait_timedout) return ipresent.SubmitError.BackendDrainTimeout;
}

/// Non-blocking pump gate (`gpu_flip_ready`): may we START the next frame's composite?
/// TRUE once the PREVIOUS flip's window channel has DRAINED (GET==PUT) — the engine
/// consumed that flip's pushbuffer. This is open ~99% of the refresh, so the pump
/// composites every damaged iteration and the ONE vsync alignment happens inside
/// `waitFlipLatched` (composite-first → wait for blank → flip). It must NOT gate on
/// beam-in-blank (`vline>=v_active`): that window is ~2.7% of the refresh, so the pump
/// misses it on most iterations, spins a whole refresh, and presents every-other-frame
/// = 30fps + jitter.
///
/// With TRIPLE BUFFERING the gate is WIDE OPEN: the ring guarantees ring[compose] is
/// never on scanout and never the pending-flip buffer, so it is ALWAYS safe to start
/// the next frame's composite — no completion signal is needed to gate it. Pacing is
/// the single vline wait inside `waitFlipLatched` (composite-first → one blank wait →
/// flip = exactly one present per refresh). Gating the pump on the window channel's
/// DRAIN (GET==PUT) was WRONG: a NON_TEARING interval=1 flip's UPDATE is not consumed
/// until near its vblank latch, and with a flip in flight GET lags PUT for most of the
/// refresh — so the drain gate stalled the pump for ~22 ms at a time (sustained 25fps,
/// measured). No flip notifier is available either (GSP never writes BEGUN — `nf=0`
/// every frame, verified). So we gate on nothing and let the ring + the vline wait pace.
fn flipReady(p: *anyopaque, head_index: usize) bool {
    _ = p;
    _ = head_index;
    return true; // triple-buffered: composing the next frame is always safe (see above)
}

fn presentFlip(p: *anyopaque, head_index: usize, scanout_phys: u64) ipresent.SubmitError!void {
    const c = ctxOf(p);
    const hw = &c.heads[head_index];
    // Reset the notifier slot to NOT_BEGUN before arming (nouveau corec37d_ntfy_init
    // zeroes the 4-dword slot; we map the ctxdma at start=notifier so OFFSET=0 and
    // one dword carries STATUS 31:30 — zeroing dword0 suffices for our synchronous
    // single-slot wait). The engine flips it to BEGUN at the vblank latch.
    vram.write32(c.g.regs, hw.ntfy_va, 0);

    // Overlay plane decision, from the pure host-tested state machine
    // (overlay_plane.zig). `act.do_overlay` = touch the overlay
    // (arm image+WIMM+UPDATE, interlocked with the desktop); `act.blank` = the arm is
    // a K1=0 transparent BLANK (the one-shot on the routed→unrouted edge that clears
    // the ghost) vs a real content co-flip; `act.swap` = swap the overlay buffers
    // (content only). Interlocking the overlay ONLY when do_overlay keeps the desktop
    // UPDATE from waiting on an unarmed partner (the step-2a black-screen wedge).
    const act = if (hw.overlay) |ov| overlay_plane.step(ov.plane, ov.armed) else overlay_plane.Action{ .do_overlay = false, .blank = false, .swap = false, .next = .{} };
    const co_flip = act.do_overlay and !act.blank; // arming real content this frame
    const do_overlay = act.do_overlay;
    const flip_mask: u32 = (@as(u32, 1) << @intCast(hw.window)) |
        (if (do_overlay) @as(u32, 1) << @intCast(hw.overlay.?.window) else 0);

    // NOUVEAU ORDER (nv50_disp_atomic_commit_tail): push ALL windows' image methods
    // FIRST, THEN all UPDATEs — so no interlocked UPDATE reaches hardware naming a
    // window whose image hasn't been armed yet (that parks the flip → black). With
    // chan.submit kicking PUT per call, we build the overlay's IMAGE into its
    // channel (no UPDATE) before submitting the desktop's UPDATE.

    // Phase A — overlay IMAGE (no update yet): re-bind ILUT + arm its OWN notifier
    // (every interlocked window resets+arms a notifier and re-loads its ILUT each
    // commit — leaving either stale makes the arm invalid) + image methods with
    // PREMULTI blend (K1=0xff), DEPTH=254 (above the desktop plane). The plane is WINDOW-SIZED
    // (out_w×out_h) reading the overlay back buffer from (0,0); its OUTPUT POSITION
    // on the head is the WIMM SET_POINT_OUT (below). Then arm the WIMM point so the
    // window appears at (point_x,point_y) — Step 2b.
    if (do_overlay) {
        const ov = &hw.overlay.?;
        vram.write32(c.g.regs, ov.ntfy_va, 0);
        var obuf: [256]u32 = undefined;
        var opush = Push.init(&obuf);
        modeset.buildWindowNotifierSet(&opush, ov.ntfy_handle);
        if (co_flip) {
            // Content arm: window-sized (out_w×out_h) from the overlay back buffer,
            // per-pixel PREMULTI blend (the glass carries its own alpha bytes),
            // DEPTH=254 (above the desktop).
            modeset.buildWindowMethods(&opush, ov.window, ov.ctx_handle, ov.surface_back, hw.pitch, 254, true, ov.out_w, ov.out_h);
        } else {
            // Blank arm (disarm on the routed→unrouted edge): IMAGE-CLEAR the window
            // (detach its scanout ctxdma) so it contributes nothing and the stale glass
            // is gone. This is nouveau wndwc37e_image_clr parity and matches how the
            // overlay is armed at bring-up (disp.zig commitAll). A full-mode K1=0
            // image-SET instead would put a full-head plane at DEPTH=254 — the exact
            // black-panel trap (bring-up arms the overlay
            // CLEARED). No ILUT on a cleared window (no scanout to LUT).
            modeset.buildWindowClr(&opush);
        }
        // ILUT only on a content arm — a cleared window fetches no surface to LUT.
        if (co_flip) modeset.buildIlut(&opush, ov.ctx_handle, ov.ilut_phys);
        chan.submit(&ov.wndw, c.g.regs, opush) catch return ipresent.SubmitError.BackendFlipFailed;

        // WIMM SET_POINT_OUT: the window's output position on the head, interlocked
        // with the window channel (buildWimm with interlock=true → its UPDATE names
        // the window). nouveau order: the WIMM point + WIMM
        // UPDATE are emitted BEFORE the window UPDATE, so the window's UPDATE (with
        // INTERLOCK_WITH_WIN_IMM below) holds until the point armed. On a blank arm the
        // point is moot (K1=0) but we still arm it so the WIMM interlock partner is
        // present for this frame's mask==kicked-set.
        var mbuf: [16]u32 = undefined;
        var mpush = Push.init(&mbuf);
        modeset.buildWimm(&mpush, ov.point_x, ov.point_y, true);
        chan.submit(&ov.wimm, c.g.regs, mpush) catch return ipresent.SubmitError.BackendFlipFailed;
    }

    // Phase B — desktop IMAGE + its UPDATE (carrying flip_mask), then the overlay's
    // UPDATE (same mask). The desktop image + update go in one push; the overlay's
    // image is already armed (Phase A), so kicking the desktop UPDATE naming both
    // windows is safe. Then the overlay UPDATE completes the co-latch.
    var wbuf: [256]u32 = undefined;
    var wpush = Push.init(&wbuf);
    modeset.buildWindowNotifierSet(&wpush, hw.ntfy_handle);
    modeset.buildWindowMethods(&wpush, hw.window, hw.ctx_handle, scanout_phys, hw.pitch, 255, false, hw.mode.h, hw.mode.v);
    modeset.windowUpdate(&wpush, false, flip_mask, false);
    chan.submit(&hw.wndw, c.g.regs, wpush) catch return ipresent.SubmitError.BackendFlipFailed;

    if (do_overlay) {
        const ov = &hw.overlay.?;
        var obuf: [16]u32 = undefined;
        var opush = Push.init(&obuf);
        // with_wimm=true: the overlay window UPDATE interlocks with its WIMM channel
        // (INTERLOCK_WITH_WIN_IMM bit 12), so the image holds until the SET_POINT_OUT
        // armed in Phase A latches — the window appears at (point_x,point_y), not the
        // stale position (nouveau wndwc37e_update parity).
        modeset.windowUpdate(&opush, false, flip_mask, true);
        chan.submit(&ov.wndw, c.g.regs, opush) catch return ipresent.SubmitError.BackendFlipFailed;
        // Commit the state machine's next state (content-shown vs transparent).
        ov.plane = act.next;
        if (act.swap) {
            // Overlay front/back swap (symmetric with the desktop swap in present.zig):
            // the flip we just armed scans out the buffer the CE wrote this frame; the
            // OTHER buffer becomes the next frame's CE target. Without this the CE would
            // overwrite the buffer being scanned out → tearing.
            // A BLANK arm (K1=0) reads no content → act.swap is false, so it does not swap.
            const t = ov.surface;
            ov.surface = ov.surface_back;
            ov.surface_back = t;
        }
    }
    hw.ntfy_armed = true; // the notifier is now armed; waitFlipLatched can poll BEGUN
    hw.last_flip_tsc = tsc.rdtsc(); // refresh-pacing anchor for the next flip
}

const vtable = ipresent.VTable{
    .mapSysmem = mapSysmem,
    .remapSysmem = remapSysmem,
    .mapVram = mapVram,
    .allocVram = allocVram,
    .flushRange = flushRange,
    .beginBatch = beginBatch,
    .copyPitch = copyPitch,
    .endBatch = endBatch,
    .endBatchKick = endBatchKick,
    .waitFence = waitFence,
    .nextFence = nextFence,
    .waitFlipLatched = waitFlipLatched,
    .flipReady = flipReady,
    .presentFlip = presentFlip,
};
