//! The live desktop, on real monitors.
//!
//! The GL device (drivers/gl/opengl.zig) renders the WHOLE desktop as one frame
//! per present and de-tiles it straight into video memory. This file owns where
//! that frame lands and how it reaches the panel: a triple-buffered scanout ring
//! (compose → pending → scanout, `tri_ring`), the flip that arms the finished
//! buffer at the monitor's vblank, and the pacing that holds 60 Hz.
//!
//! ## How one frame goes out
//!
//! 1. The desktop draws through gles into the GL device; `mirrorTarget` tells the
//!    device the ring's current COMPOSE buffer (keyed by `DESKTOP_WIN_BASE`), and
//!    the device's copy-engine de-tile lands the frame there.
//! 2. `presentDesktopFrame` (published as `iaccel.accel.whole_frame_end`) flips
//!    the compose buffer to scanout and rotates the ring. Nothing is assembled
//!    here — the frame arrived complete.
//!
//! ## Why this file is big, and why it is still one file
//!
//! Nearly everything here mutates one `State`: the channels, the scanout ring,
//! the cursor plane, the flip pacing. It is one live object, and splitting it
//! across files would not divide the concern — it would just publish a mutable
//! global for five files to write to.
//!
//! What CAN be separated already has been, into the pure modules beside this one, each
//! host-tested: `flip_pacing`, `flip_stats`, `fps_window`, `tri_ring`. The rule is in
//! CLAUDE.md: a fact that can be
//! a pure function must live where `zig build test` can reach it, never inside a file
//! that touches hardware. What is left here is the part that genuinely cannot be — the
//! sequencing of real operations against a real card.
//!
//! ## Timing
//!
//! The copy engine is waited on (microseconds for a dirty rectangle). The flip is NOT:
//! we submit it and move on, and the NEXT frame's copies are gated on the previous flip
//! having latched at the monitor's vblank. That keeps the fence round-trip off the
//! critical path. The compositor polls `flip_ready` so it can keep sampling input rather
//! than blocking inside a frame.
//!
//! The compositor's task and the bring-up task can both reach the GPU, so a spinlock
//! serializes them.

const algn = @import("algn"); // alignment: ONE home
const log = @import("../rm/log.zig").gpu;
const gsp = @import("../gsp/gsp.zig");
const fifo = @import("../engines/fifo.zig");
const gmmu = @import("../engines/gmmu.zig");
const ce = @import("../engines/ce.zig");
const vram = @import("../engines/vram.zig");
const disp = @import("../display/disp.zig");
const shim = @import("../rm/shim.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const counter = @import("../../../kernel/debug/counter.zig");

/// Presents whose interval exceeded refresh + JITTER_BUDGET_US — a dropped
/// frame (spec R9). Counted on every build; zero is the steady-state truth.
var cnt_frame_drops = counter.Counter{ .mod = .gpu, .name = "frame_drops" };
/// PERF-008 evidence (input-receipt → present latency, judged per present in
/// presentDesktopFrame; the arithmetic is the pure, host-tested input_latency
/// module). `input_present_max_us` is a high-water mark — the worst latency any
/// consumed input waited from receipt to its frame's flip; `over_budget` counts
/// presents whose consumed input overran the one-frame budget (panel refresh +
/// flip_stats.JITTER_BUDGET_US). Zero over-budget is the runtime proof of PERF-008.
var cnt_input_present_max_us = counter.Counter{ .mod = .gpu, .name = "input_present_max_us" };
var cnt_input_present_over_budget = counter.Counter{ .mod = .gpu, .name = "input_present_over_budget" };
const chan = @import("../engines/chan.zig");
const modeset = @import("../display/modeset.zig");
const ctxdma = @import("../engines/ctxdma.zig");
const Push = @import("../engines/push.zig").Push;
const spinlock = @import("../../../kernel/sync/spinlock.zig");
const surface = @import("surface");
const iaccel = @import("iaccel"); // the compositor seam: publish our hooks, call theirs
const cursor = @import("cursor.zig");
const ipresent = @import("ipresent");
const present_real = @import("present_real.zig");
const tri_ring = @import("tri_ring.zig");
const fps_window = @import("fps_window.zig");
const flip_pacing = @import("flip_pacing.zig");
const flip_stats = @import("flip_stats.zig");
const input_latency = @import("input_latency"); // named: ONE instance with iaccel's latch
const buildinfo = @import("buildinfo");
const idisplay = @import("idisplay");
const calc = @import("../rm/calc.zig"); // alignment has ONE home

pub const Error = fifo.Error;

/// Back-surface GPU window: VA_SYSMEM + 16 MiB (the first 16 MiB belong to the
/// stage-4/5 gradient buffer). Scanouts: head i at VA_VRAM + i*32 MiB. A back-
/// surface move (realloc on resize) REMAPS this same slot via gmmu.remapSysmem
/// rather than hopping to a second fixed slot (ensureBackMapped) — one slot
/// suffices for any number of moves.
const SRC_WIN: u64 = gmmu.VA_SYSMEM + 0x100_0000;
const HEAD_STRIDE: u64 = 0x200_0000;

/// Global present state — written by enableDesktopMirror (bring-up task), used
/// by the framebuffer hook (compositor task) under `lock`.
const HeadState = struct {
    // The HW-typed flip handles (wndw channel, window index, ctx_handle, mode)
    // live in the backend's RealCtx, keyed by this head's index; HeadState keeps
    // only the triple-buffer bookkeeping + the geometry scalars the frame path
    // needs to clip, so State stays hardware-free and host-testable.
    index: u32, // head id (RG register stride, cursor channel instance)
    w: u64, // head active pixels
    h: u64,
    pitch: u64, // scanout row stride in bytes
    // Triple-buffer ring (the session update cycle). `ring[i]` are the
    // three scanout surfaces; the role indices (`compose`/`pending`/`scanout`) and
    // their per-frame rotation live in the pure, HOST-TESTED tri_ring module —
    // present.zig keeps only the VA/phys addressing. Per frame: CE composites into
    // ring[compose] (never on-scanout, never pending → no wait, no tear),
    // presentFlip arms it, then `ring.rotate()` advances the roles so
    // compose→pending→scanout. `composeVa/Phys` and `scanoutPhys` expose the
    // current frame's target and the displayed surface to the frame path.
    ring_va: [3]u64,
    ring_phys: [3]u64,
    ring: tri_ring.TriRing, // role indices + rotation (pure, host-tested)

    fn composeVa(self: *const HeadState) u64 {
        return self.ring_va[self.ring.compose];
    }
    fn composePhys(self: *const HeadState) u64 {
        return self.ring_phys[self.ring.compose];
    }
    fn scanoutPhys(self: *const HeadState) u64 {
        return self.ring_phys[self.ring.scanout];
    }
};

/// A secondary monitor (any head not hosting the desktop): painted once with
/// the workspace fill at stage 6, then static. Tracked so verifyMonitorFill
/// can PRAMIN-check the paint actually landed (and repaint once, loudly, if it
/// did not — the "middle monitor black" failure was an unverified one-shot
/// paint).
const Secondary = struct {
    h: disp.Disp.Head,
    va: u64, // GMMU VA the fill targets (repaint path)
};

/// Flat dark purple for the secondary monitors — the classic SunOS/OpenWindows
/// workspace color. Solid fill makes scanout verification trivial: every
/// pixel must read back exactly this value.
const WORKSPACE_FILL: u32 = 0xFF66_6699;

// ── Measuring the frame cadence ─────────────────────────────────────────────────
// A measurement build records how evenly frames actually reach the monitor, and
// flip_stats.zig (pure, host-tested) judges the result. Both probes below are off
// in a normal build: the per-frame cost is small, but it is noise a real session
// should not pay.

// Per-frame flip timing over netdebug (the FLIP line: iv/gap/wt/c/f/vl) — the µs
// spent waiting for the previous flip to latch, compositing, and submitting the
// flip, plus the inter-present interval. Capped at FLIP_TIMING_FRAMES so it cannot
// flood a long session.
//
// ⚠ OBSERVER EFFECT: FLIP_TIMING formats + emits a log line EVERY frame, INSIDE
// the present path it measures. bufPrint + per-byte diag-ring + netdebug
// line-assembly all run on the measured thread, so the timing includes its own
// reporting cost. Fine for coarse pacing (ms-scale bugs), but it perturbs the
// sub-ms idle steady-state figures. To measure the TRUE frame time with near-zero
// perturbation, use FLIP_SAMPLE instead: it stores raw integer samples into a ring
// (one struct store per frame, no formatting, no emit) and dumps the whole ring
// ONCE when full — so the measured frames carry no reporting cost. Use exactly one
// of the two.
const FLIP_TIMING = false;
const FLIP_TIMING_FRAMES: u32 = 100_000;

// Low-perturbation flip sampling: record raw per-frame timings into an in-memory
// ring (NO formatting, NO log call inside the frame), then dump the full ring in one
// burst after it fills, and stop. One clean measurement window with zero per-frame
// emit cost on the measured thread. Mutually exclusive with FLIP_TIMING.
// Enabled by the BUILD OPTION `-Dflip-sample`, not a source edit, so a measurement
// run is one command away from a normal build; the FLIPSTAT verdict below turns
// the window into a pass/fail answer.
const FLIP_SAMPLE = buildinfo.flip_sample;
const FLIP_SAMPLE_FRAMES: usize = 600; // ring depth — 10 s at 60 Hz; dumped once when full
// Skip the cold-start transition before recording — the FULL_SEED_FRAMES forced
// full-damage seeds plus the ~0.25 s it takes the deferred-completion pipeline to
// fill and the flip gate to settle into steady vblank pacing. This is "from the
// first present" in spirit: from the moment the LIVE desktop's cadence is
// established, not the very first flip while the pipeline is still priming. The
// flip gate (present.flipsDrained → desktopPump) locks on the first flip, so
// 0.25 s is all the settle needed. A dropped OR double-presented frame in the 10 s window
// after that IS a bug. The SAME window applies whether it auto-arms at the first
// present or is re-armed by the `flipstat` shell command after the scene changed
// (five model windows opened): opening a window costs nothing on the render path —
// every context slot's VRAM and MMU mapping is allocated up front at GL device init
// (opengl.init), never lazily on first acquire — so there is no load ramp to skip.
const FLIP_SAMPLE_WARMUP: u32 = 16; // ~0.25 s past the seeds — the cold-start settle
const FLIP_SAMPLE_HEARTBEAT: usize = 128; // emit a FLIPREC progress line every N samples
comptime {
    if (FLIP_TIMING and FLIP_SAMPLE) @compileError("enable only one of FLIP_TIMING / FLIP_SAMPLE");
}

/// One frame's raw timing sample (all µs unless noted) — stored, not formatted, per
/// frame under FLIP_SAMPLE. Same fields as the FLIP log line so the dumped format is
/// identical and the analysis is unchanged. cb is KiB (dbg_copied_bytes>>10).
const FlipSample = struct {
    iv: u32,
    gap: u32,
    wt: u32,
    c: u32,
    emit: u32,
    f: u32,
    vl: u32,
    cpu: u32,
    cb: u32,
    nb: u32,
};
var flip_samples: [FLIP_SAMPLE_FRAMES]FlipSample = undefined;
var flip_sample_n: usize = 0; // frames recorded into the ring so far

/// True while a flip-sample window is armed and still recording — the session
/// loop's periodic diagnostics gate on this and hold off. Anything that burns
/// loop time between flips lands in the samples as a fake late frame: GLSTAT's
/// 2-second PRAMIN probe plus its emit burst costs ~1.5 ms and injects perfectly
/// periodic outlier PAIRS that fail the `steady` verdict with the mean dead-on.
/// Comptime-false on non-sample builds, so the gate costs nothing in a normal image.
pub fn sampleActive() bool {
    if (comptime !FLIP_SAMPLE) return false;
    return flip_sample_n < FLIP_SAMPLE_FRAMES;
}
var flip_sample_dumped: bool = false; // the one-shot dump has fired

/// Re-arm the -Dflip-sample cadence window at RUNTIME (the `flipstat` shell
/// command, shell.zig): reset the ring, the one-shot dump latch, and the timing
/// counter so a FRESH sample records from now — measuring the CURRENT scene (e.g.
/// five spinning model windows), not the boot-time desktop. The same short cold-
/// start warmup applies: opening those windows allocated nothing on the render
/// path (context slots are mapped up front at GL device init), so there is no
/// load ramp that would read as a late frame.
/// Returns false on a non-measurement build (the command reports it loudly).
/// Same-core with the present pump (core 0 runs both the shell and the session
/// loop), so the resets need no synchronisation.
pub fn rearmFlipSample() bool {
    if (comptime !FLIP_SAMPLE) return false;
    flip_sample_n = 0;
    flip_sample_dumped = false;
    if (state) |*st| st.flip_timing_n = 0;
    return true;
}

/// Saturating cast to u32 for the sample fields — a diagnostic path must never panic
/// the kernel on a stray oversized value; clamp instead of trapping.
inline fn u32sat(v: u64) u32 {
    return if (v > 0xffff_ffff) 0xffff_ffff else @intCast(v);
}

// ── The live mirror: one object, one lock ───────────────────────────────────────
// Everything below this point reads or writes this. It exists from the moment the
// desktop is mirrored to a monitor until teardown; `state` is null either side of that.

const State = struct {
    // Frame-path GPU operations go through this injected backend (iface/
    // ipresent). The real backend (present_real) wraps
    // ce/gmmu/vram/fifo/shim + the flip path; the addressing/pacing logic is host-tested by the pure sub-suites (flip_stats/flip_pacing/fps_window/tri_ring/overlay_plane). The
    // g/f/valloc handles below remain ONLY for the out-of-seam bring-up / verify /
    // soak / HW-cursor / vblank paths, which stay on direct HW calls by design.
    backend: ipresent.IPresent,
    backend_ctx: present_real.RealCtx, // the real backend's storage (native)
    g: gsp.Gsp,
    f: *fifo.Fifo,
    heads: [4]HeadState,
    nheads: usize,
    secondaries: [2]Secondary,
    nsecondaries: usize,
    valloc: *vram.Allocator, // VRAM bump allocator (scanout ring + staging surfaces)
    // Hardware cursor: the primary head's
    // cursor PIO USER page, or 0 when the HW cursor is not live (bring-up
    // failed → software cursor, loudly).
    curs_user: u64,
    lock: spinlock.SpinLock,
    presents: u64, // MONOTONIC frame counter — total flips ever (the frame number).
    refresh_us: u64, // primary panel refresh period (µs) — the FLIPSTAT verdict target
    // Rolling-window FPS by the counter-sample method: the session loop calls
    // fpsSample() at ~FPS_SAMPLE_HZ, pushing {presents, now} into a small ring
    // spanning FPS_WINDOW_S. The ring eviction + rate math live in the pure,
    // HOST-TESTED fps_window module; present.zig keeps the call-rate throttle,
    // the lock, and the tsc reads.
    fps_win: fps_window.FpsWindow(FPS_SAMPLES),
    // Flip-timing instrumentation, maintained only on -Dflip-sample builds.
    flip_timing_n: u32,
    last_present_tsc: u64,
    /// TSC of the previous present for the permanent drop counter (unlike
    /// last_present_tsc this is maintained on every build, not just
    /// -Dflip-sample ones).
    last_drop_check_tsc: u64 = 0,
    last_flip_done_tsc: u64, // end of the previous frame's flip — to measure loop gap
};
/// Rolling FPS: sample the frame counter at ~2 Hz and keep a 5 s window (≥10
/// samples + a little slack). FPS = counter-diff over time-diff across the window
/// (the pure fps_window module owns the ring + rate math).
const FPS_SAMPLE_HZ: u64 = 2;
const FPS_WINDOW_S: u64 = 5;
const FPS_SAMPLES: usize = 16; // > FPS_WINDOW_S × FPS_SAMPLE_HZ
var state: ?State = null;

/// Push one {frame-count, now} sample and evict samples older than FPS_WINDOW_S.
/// Called at ~FPS_SAMPLE_HZ from the session loop (self-throttled by last_ts).
var fps_last_sample_ts: u64 = 0;
pub fn fpsSample() void {
    const st = &(state orelse return);
    const now = tsc.rdtsc();
    const period = tsc.hz() / FPS_SAMPLE_HZ;
    if (fps_last_sample_ts != 0 and now - fps_last_sample_ts < period) return;
    fps_last_sample_ts = now;
    st.lock.acquire();
    defer st.lock.release();
    st.fps_win.push(st.presents, now, tsc.usTicks(FPS_WINDOW_S * 1_000_000));
}

/// Smoothed FPS: frame-counter diff ÷ time diff over the sample window. 0 until
/// there are ≥2 samples spanning some time.
pub fn fps() u32 {
    const st = &(state orelse return 0);
    st.lock.acquire();
    defer st.lock.release();
    return st.fps_win.rate(tsc.hz());
}

/// Phys of the 1 MiB staging buffer stage4Copy mapped at VA_SYSMEM; the
/// workspace fill (stage 6) rewrites its contents CPU-side. 0 until stage 4 ran.
var stage_phys: usize = 0;

/// Staging-buffer length (one source band must stay inside this mapping).
const STAGE_LEN: u64 = 0x100000;

/// Workspace-fill band height in lines: paintWorkspace CE-copies the staging
/// buffer down each panel FILL_BAND_LINES rows at a time, so one band
/// (FILL_BAND_LINES * pitch bytes) must stay inside the STAGE_LEN source
/// mapping — 64 lines * 4K-wide pitch (16 KiB) = 1 MiB exactly; every real
/// panel's pitch is smaller. A single full-frame copy would read far past the
/// mapping → MMU fault.
const FILL_BAND_LINES: u32 = 64;

/// HW cursor image is CURSOR_IMG_N x CURSOR_IMG_N ARGB pixels. Must stay 32:
/// modeset.buildCursorImage programs the head's cursor plane with the
/// CURSOR_SIZE_W32_H32 enum (clc37d.h:481).
const CURSOR_IMG_N: usize = 32;
/// Worst-case cursor edge the head usage-bounds declares (CURSOR=W256_H256,
/// modeset.headSetHeadUsageBounds). We ALLOCATE and pre-zero this full square so
/// no uninitialized VRAM is ever scannable regardless of what extent the plane
/// reads, then write the smaller CURSOR_IMG_N sprite into its top-left.
const CURSOR_MAX_N: usize = 256;
/// A8R8G8B8 = 4 bytes/pixel (the only format the c37a cursor plane accepts;
/// curs507a_format).
const CURSOR_IMG_BPP: usize = 4;
/// VRAM alignment for the cursor image. The OFFSET field carries phys>>8, so
/// 256-byte alignment is the hard floor; page-align (4 KiB)
/// to satisfy the allocator's natural granularity and stay safely above it.
const CURSOR_IMG_ALIGN: u64 = 0x1000;

/// All scanout buffers start unwritten; the whole-desktop frame redraws every
/// pixel every flip, so one rotation of the triple-buffer ring populates all
/// three surfaces. Pub: the session warm-up (gpu.zig) pumps until this many
/// presents so no unwritten buffer can ever reach scanout.
pub const FULL_SEED_FRAMES: u8 = 3; // the tri_ring depth (scanout/pending/compose)

/// PRAMIN scanout verification (verifyMonitorFill / verifyDesktopOnScanout)
/// reads VERIFY_SAMPLES pixels scattered deterministically across the panel:
/// sample s lands at ((s*SCATTER_X_MUL + SCATTER_X_OFF) mod w,
///                    (s*SCATTER_Y_MUL + SCATTER_Y_OFF) mod h).
/// The multipliers/offsets are arbitrary co-prime-ish picks that keep the 8
/// points off any single row/column and away from the (0,0) corner.
const VERIFY_SAMPLES: u32 = 8;
/// verifyDesktopOnScanout CONFIRMED threshold: tolerate a couple of samples
/// that changed between the last flip and the readback (blink cursor).
const VERIFY_PASS_MIN: u32 = 6;
const SCATTER_X_MUL: u64 = 397;
const SCATTER_X_OFF: u64 = 41;
const SCATTER_Y_MUL: u64 = 251;
const SCATTER_Y_OFF: u64 = 23;

/// The scatter point for verify sample `s` on a w x h surface (see the
/// SCATTER_* constants above — shared by both PRAMIN verifies).
fn scatterPoint(s: u32, w: u64, h: u64) struct { x: u64, y: u64 } {
    return .{
        .x = (@as(u64, s) * SCATTER_X_MUL + SCATTER_X_OFF) % w,
        .y = (@as(u64, s) * SCATTER_Y_MUL + SCATTER_Y_OFF) % h,
    };
}

/// Stage 4 — first real copy, entirely off-screen. Gradient in sysmem →
/// scratch VRAM, PRAMIN-verify 16 samples; also maps head 0 at the VA_VRAM
/// window base for stage 6. Paints NOTHING on the scanout
/// (no bring-up test pattern).
// ── Bring-up: prove the path, then light up the monitors ────────────────────────
// Runs once. Each step here is a check that the NEXT step is allowed to assume — a
// copy engine that cannot hit off-screen scratch will not be trusted with a panel.

pub fn stage4Copy(g: gsp.Gsp, f: *fifo.Fifo, valloc: *vram.Allocator, d: disp.Disp) Error!void {
    // 1 MiB gradient staging buffer in sysmem, mapped at VA_SYSMEM. The buffer
    // (phys stashed in stage_phys) is reused by the stage-6 workspace fill,
    // which overwrites it with the flat WORKSPACE_FILL color once the gradient
    // has served stage 4/5.
    const LEN = STAGE_LEN;
    const stage = shim.allocPagesPhys(@intCast(LEN / 0x1000)) orelse return error.FifoSysmemAlloc;
    stage_phys = stage;
    const px: [*]u32 = @ptrFromInt(stage);
    var i: u32 = 0;
    while (i < LEN / 4) : (i += 1) px[i] = 0xFF000000 | (i & 0xFF) | (((i >> 10) & 0xFF) << 8) | (((i >> 14) & 0xFF) << 16);
    // Conservative host-cache discipline for CE sysmem reads: the nominally
    // coherent HOST/VOL GMMU aperture was not enough for every GSP/shared-memory
    // path on this target, so flush CPU-written source lines before the CE reads.
    shim.flushRange(stage, LEN);
    try f.mmu.mapSysmem(gmmu.VA_SYSMEM, stage, LEN);

    // Scratch VRAM target, mapped high in the VA_VRAM window (clear of heads).
    const scratch = try valloc.alloc(LEN, 0x1000);
    const scratch_va = gmmu.VA_VRAM + 0x0f00_0000;
    try f.mmu.mapVram(scratch_va, scratch, LEN);

    var p = f.begin();
    const fence1 = f.nextFence();
    ce.copyPitch(&p, scratch_va, 0x1000, gmmu.VA_SYSMEM, 0x1000, 0x1000, @intCast(LEN / 0x1000), gmmu.VA_SEM, fence1);
    _ = try f.submitWait(g, &p, fence1);

    // Verify 16 sample dwords via PRAMIN.
    var ok: u32 = 0;
    var s: u32 = 0;
    while (s < 16) : (s += 1) {
        const off: u64 = (LEN / 16) * s;
        const want = px[off / 4];
        const got = vram.read32(g.regs, scratch + off);
        if (got == want) ok += 1 else log("gpu.present: stage4 sample {} MISMATCH +0x{x}: got 0x{x} want 0x{x}\n", .{ s, off, got, want });
    }
    log("gpu.present: stage4 CE copy verify: {}/16 samples match\n", .{ok});
    if (ok != 16) return error.FifoSemTimeout;

    // Map head 0 at the VA_VRAM window base — enableDesktopMirror reuses this
    // mapping. Nothing is copied there: the scanout stays untouched until the
    // desktop's first present (no bring-up test pattern).
    const h0 = d.heads[0];
    try f.mmu.mapVram(gmmu.VA_VRAM, h0.surface_phys, algn.up(h0.pitch * h0.h, 0x1000));
}

/// Stage 6 — pick the PRIMARY head (the widest-aspect panel = the ultrawide),
/// double-buffer it for vsynced desktop presents, bring up the hardware
/// cursor on it, and paint the workspace fill on every other monitor. The
/// logical desktop is raised to the primary's native mode (3440x1440).
pub fn enableDesktopMirror(g: gsp.Gsp, f: *fifo.Fifo, d: disp.Disp, valloc: *vram.Allocator) Error!void {
    // Primary = max aspect ratio (w/h) — the ultrawide by definition.
    var best: usize = 0;
    var i: usize = 1;
    while (i < d.nheads) : (i += 1) {
        if (@as(u64, d.heads[i].w) * d.heads[best].h > @as(u64, d.heads[best].w) * d.heads[i].h) best = i;
    }
    const prim = d.heads[best];

    // Map the primary's THREE ring buffers (triple buffering). Each
    // gets its own full 32 MB VA slot (a surface can be >16 MB: ultrawide 19.9 MB, 4K
    // 33 MB, so half-stride spacing would overlap). The VA_VRAM window runs from
    // VA_VRAM (0x0800_0000) up to VA_WMIRROR (0x2000_0000) — 384 MiB = 12 × 32 MB slots.
    // Slots 0-2 = heads, 3 = ring[0] front, 4 = ring[1], 5/6 = overlay planes, and
    // ~slot 7 (offset 0x0f00_0000) still holds the stage-4/5 scratch mapping (never
    // unmapped → mapping ring[2] there fails GmmuAlreadyMapped). So ring[2] takes
    // slot 8 (offset 0x1000_0000), clear of every prior mapping. Stage 4 already mapped
    // head 0's surface at the window base, so ring[0] reuses VA_VRAM when primary IS
    // head 0.
    const ring0_va: u64 = if (best == 0) gmmu.VA_VRAM else gmmu.VA_VRAM + 3 * HEAD_STRIDE;
    const ring1_va: u64 = gmmu.VA_VRAM + 4 * HEAD_STRIDE;
    const ring2_va: u64 = gmmu.VA_VRAM + 8 * HEAD_STRIDE;
    const len = algn.up(prim.pitch * prim.h, 0x1000);
    if (best != 0) try f.mmu.mapVram(ring0_va, prim.surface_phys, len);
    try f.mmu.mapVram(ring1_va, prim.surface_back, len);
    try f.mmu.mapVram(ring2_va, prim.surface_third, len);

    // Workspace fill on the secondary monitors: rewrite the stage-4 staging
    // buffer (already mapped at VA_SYSMEM) to the flat WORKSPACE_FILL color,
    // then CE-copy it across each panel. Tracked in `secondaries` so
    // verifyMonitorFill can PRAMIN-check the paint and repaint on mismatch.
    const stage_px: [*]u32 = @ptrFromInt(stage_phys);
    var k: u64 = 0;
    while (k < STAGE_LEN / 4) : (k += 1) stage_px[k] = WORKSPACE_FILL;
    shim.flushRange(stage_phys, STAGE_LEN);

    var secondaries: [2]Secondary = undefined;
    var nsecondaries: usize = 0;
    i = 0;
    var slot: u64 = 1;
    while (i < d.nheads) : (i += 1) {
        if (i == best) continue;
        const h = d.heads[i];
        if (slot > 2) {
            // Slots 1-2 are the only secondary slots (3 = primary front, 4 = back).
            log("gpu.present: >2 secondary monitors unsupported (head {} skipped)\n", .{i});
            continue;
        }
        const va = gmmu.VA_VRAM + slot * HEAD_STRIDE;
        slot += 1;
        if (i != 0) try f.mmu.mapVram(va, h.surface_phys, algn.up(h.pitch * h.h, 0x1000));
        const use_va = if (i == 0) gmmu.VA_VRAM else va;
        try paintWorkspace(g, f, use_va, h);
        secondaries[nsecondaries] = .{ .h = h, .va = use_va };
        nsecondaries += 1;
    }

    // Hardware cursor on the primary head: PIO channel + 32x32 ARGB crosshair in
    // VRAM, bound via core-channel methods + one core UPDATE.
    // Failure is LOUD and leaves the software cursor in place (curs_user = 0)
    // — the documented fallback contract for this boundary.
    var curs_user: u64 = 0;
    var core = d.core;
    curs: {
        const user = chan.cursorChannelInit(g, d.root, d.subdevice, prim.index) catch |e| {
            log("gpu.present: HW cursor channel alloc failed: {} — software cursor\n", .{e});
            break :curs;
        };
        // Reserve the worst-case 256x256 region (see CURSOR_MAX_N) so the pre-zero
        // below never writes past the allocation into a neighbouring VRAM object.
        const img = valloc.alloc(CURSOR_MAX_N * CURSOR_MAX_N * CURSOR_IMG_BPP, CURSOR_IMG_ALIGN) catch |e| {
            log("gpu.present: HW cursor VRAM alloc failed: {} — software cursor\n", .{e});
            break :curs;
        };
        // Zero the cursor VRAM region FIRST: valloc is a bump allocator that does
        // NOT clear memory, so any byte the plane scans that argb32 didn't write is
        // stale VRAM — the green pixels that track the cursor. The plane reads a
        // tightly-packed w*h*4 image (nouveau curs507a_acquire: pitch == w*cpp,
        // no offset), so writing the full 32x32 covers what it reads. But the head
        // usage-bounds declares CURSOR=W256_H256 (modeset headSetHeadUsageBounds),
        // and to be provably safe against any read up to that declared maximum we
        // zero the whole 256x256 worst-case region, then write the 32x32 sprite.
        vram.fill(g.regs, img, CURSOR_MAX_N * CURSOR_MAX_N * CURSOR_IMG_BPP, 0);
        var pix: [CURSOR_IMG_N * CURSOR_IMG_N]u32 = undefined;
        cursor.argb32(&pix, CURSOR_IMG_N);
        var wtr = vram.Writer.init(g.regs, img);
        for (pix) |p| wtr.put(p);
        const handle = ctxdma.createCursor(g.regs, d.ramin_phys, g.fb.fb_size, d.client) catch |e| {
            log("gpu.present: HW cursor ctxdma failed: {} — software cursor\n", .{e});
            break :curs;
        };
        var cbuf: [32]u32 = undefined;
        var cpush = Push.init(&cbuf);
        modeset.buildCursorImage(&cpush, prim.index, handle, img, @intCast(cursor.HOT_X), @intCast(cursor.HOT_Y));
        modeset.coreUpdate(&cpush, 0, 0);
        chan.submit(&core, g.regs, cpush) catch |e| {
            log("gpu.present: HW cursor core submit failed: {} — software cursor\n", .{e});
            break :curs;
        };
        core.waitDrained(g.regs) catch |e| {
            log("gpu.present: HW cursor core drain failed: {} — software cursor\n", .{e});
            break :curs;
        };
        curs_user = user;
        log("gpu.present: HW CURSOR live on head {} ({}x{} ARGB @0x{x})\n", .{ prim.index, CURSOR_IMG_N, CURSOR_IMG_N, img });
    }

    var hs: [4]HeadState = undefined;
    // Ring roles at boot: ring[0] is on scanout (the modeset's initial front), ring[2]
    // is the first CE compose target, ring[1] is the first pending slot. The first
    // present composites ring[2] and flips it; rotate() then advances. (Any starting
    // permutation of the 3 roles is correct; this one keeps ring[0]=the live surface.)
    hs[0] = .{
        .index = prim.index,
        .w = prim.w,
        .h = prim.h,
        .pitch = prim.pitch,
        .ring_va = .{ ring0_va, ring1_va, ring2_va },
        .ring_phys = .{ prim.surface_phys, prim.surface_back, prim.surface_third },
        .ring = .{ .scanout = 0, .pending = 1, .compose = 2 },
    };
    state = .{
        .backend = undefined, // wired below once `state` has its final address
        .backend_ctx = present_real.RealCtx.init(g, f, valloc),
        .g = g,
        .f = f,
        .heads = hs,
        .nheads = 1,
        .secondaries = secondaries,
        .nsecondaries = nsecondaries,
        .curs_user = curs_user,
        .lock = .{},
        .presents = 0,
        .refresh_us = flip_pacing.frameUs(.{ .h = prim.mode.h, .h_blank = prim.mode.h_blank, .v = prim.mode.v, .v_blank = prim.mode.v_blank, .clock_khz = prim.mode.clock_khz }),
        .fps_win = fps_window.FpsWindow(FPS_SAMPLES).init(),
        .flip_timing_n = 0,
        .last_present_tsc = 0,
        .last_drop_check_tsc = 0,
        .last_flip_done_tsc = 0,
        .valloc = valloc,
    };
    // Registration is idempotent (counter.zig scans its table).
    counter.register(&cnt_frame_drops);
    counter.register(&cnt_input_present_max_us);
    counter.register(&cnt_input_present_over_budget);
    // Wire the real backend now that `state` (and thus backend_ctx) has its final
    // address: the ipresent.IPresent handle carries a pointer to backend_ctx. Register
    // the primary head's flip handles with the backend (keyed by head index 0).
    const stp = &state.?;
    stp.backend_ctx.setHead(0, prim);
    stp.backend = stp.backend_ctx.backend();

    // Offer the desktop the GPU: the whole-frame delivery hook, the flip gate,
    // the panel's refresh period (the pump's pipelined-start decision), and the
    // hardware cursor plane.
    iaccel.accel = .{
        // The whole-desktop delivery: the GL desktop draws the entire desktop as one
        // GR frame into the compose buffer and calls this to flip it (see
        // presentDesktopFrame). Publishing it is also the signal that the ring is up and
        // ready to accept a whole frame.
        .whole_frame_end = &presentDesktopFrame,
        .flip_ready = &flipsDrained,
        .refresh_us = @intCast(stp.refresh_us),
        .cursor = if (curs_user != 0) &gpuCursorMove else null,
        .rearm_flip_sample = &rearmFlipSample,
    };
    // Raise the logical desktop to the PRIMARY's native mode — the ultrawide
    // renders the kudos desktop 1:1 at 3440x1440.
    if (iaccel.compositor.set_logical_size) |resize| resize(prim.w, prim.h);
    log("gpu.present: stage6 desktop → primary monitor {}x{} (vsync flip); {} secondary monitor(s) filled 0x{x:0>8}\n", .{ prim.w, prim.h, d.nheads - 1, WORKSPACE_FILL });
}

/// CE-fill one monitor with WORKSPACE_FILL, banding the staging buffer down
/// the panel FILL_BAND_LINES rows at a time (see that constant for why).
/// Fence-synchronous.
fn paintWorkspace(g: gsp.Gsp, f: *fifo.Fifo, use_va: u64, h: disp.Disp.Head) Error!void {
    var p = f.begin();
    const fence = f.nextFence();
    var y: u32 = 0;
    while (y < h.h) : (y += FILL_BAND_LINES) {
        const lines = @min(FILL_BAND_LINES, h.h - y);
        const last = (y + FILL_BAND_LINES >= h.h);
        ce.copyPitch(&p, use_va + @as(u64, y) * h.pitch, @intCast(h.pitch), gmmu.VA_SYSMEM, @intCast(h.pitch), @intCast(h.pitch), lines, gmmu.VA_SEM, if (last) fence else 0);
    }
    _ = try f.submitWait(g, &p, fence);
}

/// PRAMIN-verify each secondary monitor actually scans out WORKSPACE_FILL
/// (VERIFY_SAMPLES scattered pixels). On mismatch: repaint once, loudly, and
/// re-verify; a second failure logs a grep-able MONITOR-FILL FAILED (no silent
/// fallback). The one-shot unverified paint is how a monitor went black
/// undiagnosed.
pub fn verifyMonitorFill() void {
    const st = &(state orelse return);
    st.lock.acquire();
    defer st.lock.release();
    var i: usize = 0;
    while (i < st.nsecondaries) : (i += 1) {
        const mon = st.secondaries[i];
        var attempt: u32 = 0;
        while (attempt < 2) : (attempt += 1) {
            var pass: u32 = 0;
            var s: u32 = 0;
            while (s < VERIFY_SAMPLES) : (s += 1) {
                // Deterministic scatter across the panel.
                const pt = scatterPoint(s, mon.h.w, mon.h.h);
                const got = vram.read32(st.g.regs, mon.h.surface_phys + pt.y * mon.h.pitch + pt.x * 4);
                if (got == WORKSPACE_FILL) pass += 1 else log("gpu.present: monitor {} sample ({},{}) got 0x{x:0>8} want 0x{x:0>8}\n", .{ i, pt.x, pt.y, got, WORKSPACE_FILL });
            }
            if (pass == VERIFY_SAMPLES) {
                log("gpu.present: MONITOR-FILL CONFIRMED monitor={} {}x{} (8/8)\n", .{ i, mon.h.w, mon.h.h });
                break;
            }
            if (attempt == 0) {
                log("gpu.present: monitor {} fill verify FAILED ({}/8) — repainting once\n", .{ i, pass });
                paintWorkspace(st.g, st.f, mon.va, mon.h) catch |e| {
                    log("gpu.present: monitor {} repaint failed: {}\n", .{ i, e });
                };
            } else {
                log("gpu.present: MONITOR-FILL FAILED monitor={} ({}/8 after repaint)\n", .{ i, pass });
            }
        }
    }
}

/// Last present count observed by scanWatchdog — used to skip the (blocking) vline
/// probe while frames are actively flipping (a flip proves scanout is live).
var wd_last_presents: u64 = 0;

/// Scanline watchdog (diagnosis for the intermittent black monitor): read each
/// tracked head's raster position (disp.RG_VLINE_REG, the same register the
/// bring-up "moving=true" check reads) twice, 1 ms apart. A live head's vline
/// advances continuously (a 60 Hz frame is ~16 ms; vblank is far shorter than
/// 1 ms x 2 samples). Logs ONLY on a stall — a stalled head means scanout
/// stopped (vs a dropped DP link / sleeping panel, which keeps scanning into a
/// dead wire). Called every few seconds by the session loop; silent when
/// healthy.
///
/// SKIPPED while presenting: the two `udelay(1000)` probes are a ~2 ms blocking
/// stall, which every 5 s crossed a frame's refresh budget (a visible pacing hitch,
/// measured). A flip advancing `presents` PROVES scanout is live (the window channel
/// latched at vblank), so the probe is only meaningful when NOT presenting — an idle
/// or wedged desktop. Gate on present activity: if presents advanced since last call,
/// scanout is live → return immediately, no blocking probe.
pub fn scanWatchdog() void {
    const st = &(state orelse return);
    st.lock.acquire();
    defer st.lock.release();
    if (st.presents != wd_last_presents) {
        // Frames flipped since last check → scanout is provably live; skip the probe.
        wd_last_presents = st.presents;
        return;
    }
    wd_last_presents = st.presents;
    // Primary + secondaries: everything that should be scanning.
    var idx: usize = 0;
    while (idx < st.nheads + st.nsecondaries) : (idx += 1) {
        const head_index: u32 = if (idx < st.nheads) st.heads[idx].index else st.secondaries[idx - st.nheads].h.index;
        const hw: u64 = if (idx < st.nheads) st.heads[idx].w else st.secondaries[idx - st.nheads].h.w;
        const hh: u64 = if (idx < st.nheads) st.heads[idx].h else st.secondaries[idx - st.nheads].h.h;
        const hoff: u64 = @as(u64, head_index) * disp.RG_HEAD_STRIDE;
        const v1 = st.g.regs.read32(disp.RG_VLINE_REG + hoff) & disp.RG_VLINE_MASK;
        tsc.udelay(1000);
        const v2 = st.g.regs.read32(disp.RG_VLINE_REG + hoff) & disp.RG_VLINE_MASK;
        if (v1 == v2) {
            // One retry — we could have sampled vblank twice by misfortune.
            tsc.udelay(1000);
            const v3 = st.g.regs.read32(disp.RG_VLINE_REG + hoff) & disp.RG_VLINE_MASK;
            if (v3 == v1) log("gpu.present: SCANOUT-STALL head={} vline stuck at {} ({}x{})\n", .{ head_index, v1, hw, hh });
        }
    }
}

/// The `iaccel.Accel.cursor` hook: move the HW cursor — two MMIO writes on the
/// primary head's cursor PIO page (chan.cursorMove). Single writer (the pump
/// task); no lock, no flush handshake, independent of the render pipeline.
// ── The hooks the compositor calls (published via iface/iaccel.zig) ─────────────

fn gpuCursorMove(x: i32, y: i32) void {
    const st = &(state orelse return);
    if (st.curs_user == 0) return;
    chan.cursorMove(st.g.regs, st.curs_user, x, y);
}

/// Non-blocking flip gate for the pump (`iaccel.Accel.flip_ready`): true when
/// every tracked head's window channel has drained, i.e. the previously
/// submitted flip latched at vblank. True with the mirror off (no GPU pacing).
fn flipsDrained() bool {
    var st = &(state orelse return true);
    st.lock.acquire();
    defer st.lock.release();
    var i: usize = 0;
    while (i < st.nheads) : (i += 1) {
        if (!st.backend.flipReady(i)) return false;
    }
    return true;
}

/// Blocking drain of every tracked head — the pending final flip must latch
/// before PRAMIN scanout verification (which reads the front surface) and
/// before GSP teardown (disableDesktopMirror). Loud on timeout; teardown
/// proceeds regardless (the card is about to be reset anyway).
pub fn waitIdle() void {
    var st = &(state orelse return);
    st.lock.acquire();
    defer st.lock.release();
    var i: usize = 0;
    while (i < st.nheads) : (i += 1) {
        st.backend.waitFlipLatched(i) catch |e| {
            log("gpu.present: waitIdle: head {} drain failed: {}\n", .{ i, e });
        };
    }
}

/// Disable every GPU present hook — the loud fallback when the frame path hits an
/// unrecoverable backend error (drain/fence/flip). "Mirror OFF" must mean the GPU
/// path is fully unhooked, not partially: a hook left installed keeps being called
/// against a backend already known dead, each call silently paying a full
/// fence-timeout budget.
fn disableHooks() void {
    iaccel.accel = .{};
}

/// GL frame delivery target: where a finished GR frame de-tiles. The whole-desktop
/// frame (drawn under the reserved DESKTOP_WIN_BASE) lands straight in the current
/// compose buffer of the scanout ring; `presentDesktopFrame` then flips that same
/// buffer. The compose role never sits on scanout or pending (tri_ring invariant),
/// so writing it is always safe, and it is resolved per frame here so it tracks
/// the ring's rotation. There are no other draw targets: every pixel goes through
/// the one whole-desktop frame.
pub const MirrorTarget = struct { va: u64, stride_px: u32, phys: u64 };
pub fn mirrorTarget(win_base: u64) ?MirrorTarget {
    const st = &(state orelse return null);
    st.lock.acquire();
    defer st.lock.release();
    if (win_base != iaccel.DESKTOP_WIN_BASE) return null;
    const hs = &st.heads[0];
    return .{ .va = hs.composeVa(), .stride_px = @intCast(hs.pitch / 4), .phys = hs.composePhys() };
}

// ── End of frame ────────────────────────────────────────────────────────────────

/// One-shot flip-sample ring dump + the steady-60Hz verdict, called at the end of every
/// present (either delivery path). Once the sample ring is full, format + emit every
/// stored frame in one burst, then latch off so no further frame carries reporting cost.
/// The dump itself perturbs the frames it runs in, but those are AFTER the measurement
/// window and are simply not sampled. Comptime-inert unless `-Dflip-sample`.
fn emitFlipStatIfComplete(st: *State) void {
    if (!(FLIP_SAMPLE and !flip_sample_dumped and flip_sample_n >= FLIP_SAMPLE_FRAMES)) return;
    flip_sample_dumped = true;
    log("FLIPDUMP begin n={}\n", .{flip_sample_n});
    for (flip_samples[0..flip_sample_n]) |s| {
        log("FLIP iv={} gap={} wt={} c={} emit={} f={} vl={} cpu={} cb={} nb={}\n", .{ s.iv, s.gap, s.wt, s.c, s.emit, s.f, s.vl, s.cpu, s.cb, s.nb });
    }
    log("FLIPDUMP end\n", .{});
    // THE VERDICT (the steady-60Hz verdict): judge the window's present intervals against
    // the panel refresh with the host-tested criteria in flip_stats, and answer the run's
    // question in one greppable line — locked to the panel, no missed vblank, no
    // double-present. This is what a `make start` performance run passes or fails on.
    var ivs: [FLIP_SAMPLE_FRAMES]u64 = undefined;
    for (flip_samples[0..flip_sample_n], 0..) |s, k| ivs[k] = s.iv;
    const v = flip_stats.judge(ivs[0..flip_sample_n], st.refresh_us);
    // THE VERDICT GOES FIRST. The trace bus truncates a line at 120 bytes, and this
    // record is long enough to reach that limit. Anything at the end of it can be cut in
    // half — and a `verdict=PASS` clipped to `verdict=PAS` is not a garbled line, it is a
    // passing run that the test suite reads as a failure. Put the answer where it cannot
    // be cut; the statistics that follow it may truncate without harm.
    log("FLIPSTAT verdict={s} n={} refresh_us={} mean={} min={} max={} stdev={} locked={} steady={} double={}\n", .{
        if (v.pass()) "PASS" else "FAIL",
        v.n,
        st.refresh_us,
        v.mean_us,
        v.min_us,
        v.max_us,
        v.stdev_us,
        @intFromBool(v.locked),
        @intFromBool(v.steady),
        @intFromBool(!v.no_double),
    });
}

/// Whole-desktop delivery (`iaccel.Accel.whole_frame_end`): the desktop was drawn as ONE
/// hardware-OpenGL frame and de-tiled straight into the current compose buffer (the GR
/// context's `mirrorTarget(DESKTOP_WIN_BASE)` resolves to `composeVa`, so its `endFrame`
/// de-tile lands the whole panel there). There is nothing to composite here — just pace
/// to vblank, flip the compose buffer onto scanout, and rotate the ring. The caller has
/// already waited for the de-tile to land (`gles.finish`), so the buffer is complete.
///
/// The desktop is the primary head (head 0); secondaries are static fills.
fn presentDesktopFrame() void {
    const st = &(state orelse return);
    st.lock.acquire();
    defer st.lock.release();
    const i: usize = 0; // the desktop lives on the primary head
    const hs = &st.heads[i];
    // Read on EVERY build: the permanent frame-drop interval (below) anchors on
    // it, not only the FLIP_SAMPLE cadence ring — a zero here would disarm the
    // drop counter's interval check.
    const t_frame_start = tsc.rdtsc();
    // Single-flip-ahead guard: the previous flip must have latched before we arm the next,
    // or two flips race for one vblank. The compose buffer we are about to flip was safe
    // to de-tile into (never on scanout, never pending — the tri_ring invariant).
    st.backend.waitFlipLatched(i) catch |e| {
        log("gpu.present: desktop flip-ahead guard failed: {} — mirror OFF\n", .{e});
        disableHooks();
        return;
    };
    // Arm the compose buffer (now holding the whole de-tiled desktop) as the new scanout:
    // window image at composePhys, standalone UPDATE, interval=1, NON_TEARING. The HW
    // latches it at the next vblank.
    st.backend.presentFlip(i, hs.composePhys()) catch |e| {
        log("gpu.present: desktop flip submit failed: {} — mirror OFF\n", .{e});
        disableHooks();
        return;
    };
    // Rotate: the buffer we just armed becomes `pending`; the old pending (latched by now)
    // becomes `scanout`; the old scanout becomes next frame's `compose`.
    hs.ring.rotate();
    // PERF-008 judgement: the input this frame consumed (latched at sampling by
    // main_root.zig's input pass into iaccel.input_latch) is now armed for scanout —
    // take the receipt → flip-armed delta and judge it against the one-frame
    // budget, the same refresh + jitter tolerance the frame-drop check uses.
    // The arithmetic is the host-tested input_latency module; only the TSC read
    // and the counters live here at the device edge. Cost per present: one
    // rdtsc + a compare (a divide only on input-carrying frames) — hot-path safe.
    if (iaccel.input_latch.presented(tsc.rdtsc())) |lat_tsc| {
        const lat_us = input_latency.deltaUs(lat_tsc, tsc.hz());
        cnt_input_present_max_us.peak(lat_us);
        if (input_latency.overBudget(lat_us, st.refresh_us + flip_stats.JITTER_BUDGET_US))
            cnt_input_present_over_budget.inc();
    }
    if (st.presents == 0) log("gpu.present: GPU DESKTOP active — first whole-frame flip\n", .{});
    // 60 Hz cadence: record the inter-present interval into the SAME sample ring and emit
    // the SAME FLIPSTAT verdict as the composite path. The composite-specific fields
    // (blit volume, composite time) are zero — this path has no per-frame blit list.
    // PERMANENT frame-drop evidence (DIAG-003, PERF-003): every present interval
    // is judged by flip_stats.missedDeadline on EVERY build — the windowed
    // FLIPSTAT verdict samples 10 s, this counter never stops. Zero in `stats`
    // at the end of a run is the runtime proof no frame was dropped.
    {
        if (st.last_drop_check_tsc != 0 and tsc.hz() != 0) {
            const iv2 = tsc.ticksToUs(t_frame_start - st.last_drop_check_tsc);
            if (flip_stats.missedDeadline(iv2, st.refresh_us)) cnt_frame_drops.inc();
        }
        st.last_drop_check_tsc = t_frame_start;
    }
    if (FLIP_SAMPLE) {
        st.flip_timing_n += 1;
        if (st.flip_timing_n > FLIP_SAMPLE_WARMUP and flip_sample_n < FLIP_SAMPLE_FRAMES) {
            const iv = if (st.last_present_tsc != 0) tsc.ticksToUs(t_frame_start - st.last_present_tsc) else 0;
            flip_samples[flip_sample_n] = .{ .iv = u32sat(iv), .gap = 0, .wt = 0, .c = 0, .emit = 0, .f = 0, .vl = present_real.dbg_vline_entry, .cpu = 0, .cb = 0, .nb = 0 };
            flip_sample_n += 1;
            if (flip_sample_n % FLIP_SAMPLE_HEARTBEAT == 0) log("FLIPREC {}/{}\n", .{ flip_sample_n, FLIP_SAMPLE_FRAMES });
        }
        st.last_present_tsc = t_frame_start;
    }
    emitFlipStatIfComplete(st);
    st.presents += 1; // monotonic frame counter — DESKTOP-ON-SCANOUT + rolling FPS read it
}

/// Presents so far, or 0 when the mirror is off — read by the GPU session loop's
/// per-second stats line.
pub fn presentCount() u64 {
    const st = &(state orelse return 0);
    return st.presents;
}

/// The armed overlay plane, as it is being scanned out: the FRONT buffer's VA
/// and the on-head rect the display engine blends it at (plane-local source
/// origin is always (0,0)).
// ── Views for diagnostics (screenshots, the scanout check) ──────────────────────

pub const OverlayView = struct {
    va: u64,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

/// Everything a reader needs to reconstruct WHAT THE MONITOR SHOWS for head 0
/// (the capture must reproduce the display engine's
/// composition). The screenshot path is the only consumer.
///
/// `head_va` is `ring[scanout]` — NOT `gmmu.VA_VRAM`, which is only ring[0]'s
/// VA and goes stale the moment the triple-buffer ring rotates. `overlay` is
/// non-null only while a glass window is actually armed on the plane; the
/// caller must then PREMULTI-blend it over the head copy to match the HW.
pub const CaptureView = struct {
    head_va: u64,
    w: u32,
    h: u32,
    pitch: u32,
    overlay: ?OverlayView,
};

/// Snapshot the head-0 scanout addressing + armed overlay. Null when the GPU
/// present path is not up (no state) — the caller must fail loudly, not guess.
pub fn captureView() ?CaptureView {
    const st = &(state orelse return null);
    st.lock.acquire();
    defer st.lock.release();
    const hs = &st.heads[0];
    return .{
        .head_va = hs.ring_va[hs.ring.scanout],
        .w = @intCast(hs.w),
        .h = @intCast(hs.h),
        .pitch = @intCast(hs.pitch),
        .overlay = null,
    };
}

/// Serial-side proof that the DESKTOP is on the primary scanout: PRAMIN-read
/// sample pixels from the currently scanned-out (front) surface and verify each
/// is POPULATED — the whole-desktop frame renders in VRAM, so there is no sysmem
/// copy to pixel-match against; a blank/unwritten scanout reads 0x00000000, so
/// non-zero samples prove the de-tiled frame actually reached the front surface.
/// Requires at least one flip. Logs PASS/FAIL per sample; overall verdict on one
/// line (grep "DESKTOP-ON-SCANOUT").
pub fn verifyDesktopOnScanout(g: gsp.Gsp) void {
    const st = &(state orelse return);
    st.lock.acquire();
    defer st.lock.release();
    if (st.presents == 0) {
        log("gpu.present: DESKTOP-ON-SCANOUT SKIPPED (presents={})\n", .{st.presents});
        return;
    }
    const hs = st.heads[0];
    var pass: u32 = 0;
    var s: u32 = 0;
    while (s < VERIFY_SAMPLES) : (s += 1) {
        const pt = scatterPoint(s, hs.w, hs.h);
        const got = vram.read32(g.regs, hs.scanoutPhys() + pt.y * hs.pitch + pt.x * 4);
        if (got != 0) pass += 1 else log("gpu.present: scanout sample ({},{}) is BLANK (0)\n", .{ pt.x, pt.y });
    }
    log("gpu.present: DESKTOP-ON-SCANOUT {s} (composite; {}/{} non-blank, {} presents)\n", .{ if (pass >= VERIFY_PASS_MIN) "CONFIRMED" else "FAILED", pass, VERIFY_SAMPLES, st.presents });
}

/// Detach the hooks before GSP teardown (the scanouts are about to die).
/// Waits for the final in-flight flip to latch first — teardown must not
/// unload GSP-RM while the EVO is still consuming a window UPDATE.
pub fn disableDesktopMirror() void {
    waitIdle();
    iaccel.accel = .{};
    if (state) |*st| log("gpu.present: mirror OFF after {} presents\n", .{st.presents});
    state = null;
}
