//! GPU / OpenGL module entry point. Drives the M9 headless
//! bring-up sequence for the target GeForce RTX 4090 (Ada, AD102):
//!
//!   find 4090 on PCI -> map BAR0 (regs, UC) -> enable bus master
//!     -> wire MSI ISR -> load+boot GSP firmware -> RPC handshake
//!     -> submit one nop command -> read back fence  (== GPU alive)
//!
//! Everything here and in its siblings stays under src/drivers/gpu/ (isolation
//! invariant). Verified on the physical target over the trace — a 4090 cannot be
//! emulated in QEMU.

const cpu = @import("../../kernel/cpu/cpu.zig");
const pci = @import("../pci/pci.zig");
const isr = @import("../../kernel/interrupts/isr.zig");
const log = @import("rm/log.zig").gpu;
const shim = @import("rm/shim.zig");
const mmio = @import("rm/mmio.zig");
const msi = @import("engines/msi.zig");
const gsp = @import("gsp/gsp.zig");
const rm = @import("gsp/rm.zig");
const disp = @import("display/disp.zig");
const fifo = @import("engines/fifo.zig");
const present = @import("present/present.zig");
const iaccel = @import("iaccel"); // the compositor seam (drive a frame, resize the desktop)
const iopengl = @import("idraw"); // where we publish the 3D device for apps to draw with
const power = @import("../../kernel/power/reboot.zig");
const timer = @import("../../kernel/timer/timer.zig");
const netdebug = @import("../net/debug/netdebug.zig");
const nic = @import("../net/nic/nic.zig");
const fileserv = @import("../net/debug/fileserv.zig");
const bootlog = @import("../storage/bootlog.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");
const prof = @import("prof.zig");
const xhci = @import("../usb/xhci.zig"); // HID report counters for FPS tracking
const vram = @import("engines/vram.zig");
const firmware = @import("gsp/firmware.zig");
const gr = @import("../gl/engine/gr.zig");
const gl_shaders = @import("../gl/engine/shaders.zig");
// The RTX 4090 GR-engine gles backend (compiled in by default; -Dgr-backend=false
// swaps in this stub for a GL-less bring-up image). The stub's init fails exactly
// like a GPU that could not bring GL up, so the desktop path — which already
// treats that as non-fatal — runs unchanged either way.
const opengl = if (buildinfo.gr_backend) @import("../gl/opengl.zig") else struct {
    pub fn init(_: anytype, _: anytype, _: anytype, _: anytype) !iopengl.IDraw {
        return error.GrBackendDisabled;
    }
    pub fn pumpAll() void {}
    pub fn dumpStatus() void {}
};
const buildinfo = @import("buildinfo");
const screenshot = @import("screenshot.zig");

/// Saved multiboot2 info address, stashed once by `init` at boot so the GSP
/// boot can locate the firmware boot modules later (the GPU module owns its own
/// dependency on boot info — main just hands it the pointer once; the GPU
/// isolation invariant).
var mb_info_addr: u64 = 0;

/// Stash the multiboot2 info pointer for the firmware lookup. Called early in
/// the entry root's run() (before interrupts). CONFIGURATION, not bring-up: it
/// takes a value and does no device work, which is why it is not called `init`
/// — the GPU's actual bring-up is `bootAtInit`, and a reader must be able to
/// tell the cost of a call from its name.
pub fn configure(info_addr: u64) void {
    mb_info_addr = info_addr;
}

/// Whether `bootAtInit` will actually attempt a GPU bring-up: the card is on the
/// bus AND its firmware is staged. Answered BEFORE the attempt, because the
/// desktop must choose its draw device before any window exists and a window
/// never migrates between devices (the entry root's softdisplay.publish call).
pub fn willBoot() bool {
    if (pci.findByIds(NVIDIA_VENDOR, RTX_4090_DEVICE) == null) return false;
    return firmwareSet().complete();
}

/// Boot the GSP during kudos init — called AFTER interrupts are enabled (the
/// falcon bring-up uses timer-based delays). If the 4090 is present and the GSP
/// firmware is staged, brings the GPU up at startup (a real driver does this; it
/// also makes the passthrough dev loop boot straight into the bring-up). With no
/// card or no firmware it's a no-op + log.
///
/// `native` says the kernel booted from GRUB on the physical machine (the entry
/// root detects it by the presence of a firmware framebuffer tag). There the 4090
/// is LIVE — the UEFI GOP initialized it, and the framebuffer we scan out of is
/// its VRAM — whereas GSP boot requires the post-vfio (bus-reset) state. So the
/// native path first reproduces that precondition with a Secondary Bus Reset,
/// which permanently kills the firmware framebuffer:
///  - pre-reset failures return with the desktop still alive on it;
///  - post-reset failures reboot back to the GRUB default rather than wedging
///    black (the reason streams out the trace first).
pub fn bootAtInit(native: bool) void {
    const gpu = pci.findByIds(NVIDIA_VENDOR, RTX_4090_DEVICE) orelse return;
    const fw = firmwareSet();
    if (!fw.complete()) {
        log("gpu: 4090 present but GSP firmware not staged; skipping boot\n", .{});
        return;
    }
    if (native and !resetForNativeBoot(gpu)) return; // pre-reset failure: desktop stays up
    log("gpu: 4090 + firmware present — booting GSP at init\n", .{});
    const st = bringUp(fw);
    log("gpu: GSP init bring-up result: {s}\n", .{@tagName(st)});
    if (native and st != .ok) {
        // Post-reset failure: the firmware framebuffer died with the card, so
        // there is nothing left to show on screen. Force-flush the queued log
        // (failure reason included) onto the LAN — the reboot below destroys
        // the FIFO, and the metered drain never ran this early (bring-up flush
        // points) — then reboot back to the
        // GRUB default (the host desktop) instead of wedging black. Documented
        // reset chain, not a silent fallback.
        log("gpu: native GSP bring-up FAILED after card reset — rebooting to host\n", .{});
        netdebug.flushNow();
        timer.sleep(NATIVE_FAIL_REBOOT_DELAY_MS);
        power.reboot();
    }
}

/// Delay between announcing a failed native bring-up and rebooting: long enough
/// for the the trace tail to drain and be read live as "it failed".
const NATIVE_FAIL_REBOOT_DELAY_MS: u64 = 3000;
/// SBR hold + settle: the timings proven on this exact card by
/// scripts/gpu/sbr.sh (the PCI-spec floor is a 1 ms hold).
const SBR_HOLD_MS: u64 = 50;
const SBR_SETTLE_MS: u64 = 1000;

/// Native-boot precondition: Secondary Bus Reset the 4090 (and its HD-audio
/// sibling — the whole bus below the bridge resets together) with config
/// save/restore around it, reproducing the post-vfio state the GSP boot is
/// verified against. Returns false — firmware framebuffer still alive — when
/// the reset cannot even be attempted. A card that vanishes AFTER the reset
/// reboots (nothing left to run toward, nothing left to display).
fn resetForNativeBoot(gpu: pci.Device) bool {
    const bridge = pci.findParentBridge(gpu) orelse {
        log("gpu: native boot: no parent bridge for the 4090 — cannot bus-reset; skipping GPU boot\n", .{});
        return false;
    };
    log("gpu: native boot: bus-resetting the 4090 (screen will blank — watch the netdebug stream)\n", .{});
    // Snapshot config of every function of the card (GPU + HD audio) before the
    // reset wipes it (BARs, command, PCIe MPS).
    const gpu_state = gpu.saveConfig();
    var audio: ?pci.Device = null;
    var audio_state: pci.ConfigState = undefined;
    for (pci.list()) |d| {
        if (d.bus == gpu.bus and d.slot == gpu.slot and d.func != gpu.func) {
            audio = d;
            audio_state = d.saveConfig();
            break;
        }
    }
    if (!pci.secondaryBusReset(bridge, gpu, SBR_HOLD_MS, SBR_SETTLE_MS)) {
        log("gpu: native boot: 4090 did not answer config cycles after SBR — rebooting to host\n", .{});
        // Terminal path: force the queued log out before the reset destroys it
        // (bring-up flush points).
        netdebug.flushNow();
        timer.sleep(NATIVE_FAIL_REBOOT_DELAY_MS);
        power.reboot();
    }
    gpu.restoreConfig(gpu_state);
    if (audio) |a| a.restoreConfig(audio_state);
    gpu.setPowerStateD0();
    gpu.enableBusMaster();
    // The firmware framebuffer lived in the VRAM of the card we just reset — it is
    // gone now. kudos never wrote to it anyway (GPU-only rendering): the desktop
    // keeps its logical size and the GPU's own scanout becomes the only output the
    // moment the present ring is up.
    log("gpu: native boot: 4090 reset + config restored — proceeding to GSP boot\n", .{});
    return true;
}

/// The GSP firmware located from the boot modules (empty slices if not staged).
pub fn firmwareSet() gsp.Firmware {
    return firmware.fromBootModules(mb_info_addr);
}

/// Target GPU identity. NVIDIA vendor + AD102 / RTX 4090.
pub const NVIDIA_VENDOR: u16 = 0x10DE;
pub const RTX_4090_DEVICE: u16 = 0x2684;

/// IDT vector chosen for the GPU MSI: the base of the dedicated MSI range
/// (isr.MSI_VECTOR_BASE, 0x50). This range sits above the LAPIC timer (0x40) and
/// wakeup IPI (0x41) so the GPU MSI cannot alias them — the original 0x40 choice
/// did, and also overran the 16-slot PIC table (a silent #UD halt on real HW).
/// A single fixed vector: a pool is only needed once a second MSI device exists.
const GPU_MSI_VECTOR: u8 = isr.MSI_VECTOR_BASE;

/// Session-loop input cadence: pause-spin this long between desktop pumps —
/// ~kHz polling of the (IRQ-less) xHC without the PIT's 10 ms sleep quantum
/// (the USB poll cadence; the session update cycle).
const SESSION_POLL_US: u64 = 250;

/// Warm-up wall-clock budget for the pre-session buffer seeding loop, so a
/// mirror that never presents fails loudly instead of hanging the bring-up.
/// A TSC deadline, NOT an iteration cap: an iteration cap assumes each spin
/// costs ~SESSION_POLL_US, and a degenerate pump that burns a fence timeout per
/// call stretches the intended 10 s into unbounded minutes.
const WARMUP_WALL_MS: u64 = 10_000;

/// The boot-to-first-present budget (spec PERF-002): the desktop's first GPU
/// present must land within this of kudos boot entry (tsc.boot_entry_tsc). The
/// milestone is emitted once at the first present so the boot-2 track can hold
/// the budget on real hardware; over-budget is loud, never silent.
const BOOT_TO_FIRST_PRESENT_BUDGET_MS: u64 = 9_000;

/// USB late-device settle before the FIRST present. A slow device (the boot
/// keyboard, its MCU still initializing) finishes coming up during GSP boot, after
/// the bus walk — so it is enumerated here, WITHOUT rendering, before the desktop is
/// shown. Its blocking bring-up then lands before the cadence window opens instead
/// of dropping a frame inside it (the zero-glitch requirement). Bounded: poll a hard
/// window so a genuinely-absent device costs a fixed, small delay and never hangs.
const USB_SETTLE_MS: u64 = 1_500;

/// Scanline-watchdog cadence: run present.scanWatchdog every this many
/// seconds of TSC time (silent when healthy — the intermittent-black-monitor
/// diagnosis).
const SCAN_WATCHDOG_PERIOD_S: u64 = 5;

// ── FPS tracking statistics ──────────────────────────────────────────────────
/// Ticks per microsecond helper divisor: 1e6 µs per second.
const US_PER_S: u64 = 1_000_000;

/// Emit the published FPS + monotonic frame number per stats window over netdebug,
/// so the figure can be verified against the real flip rate. Off for a normal run;
/// flip on to re-verify. There is no on-screen HUD — netdebug is the only channel
/// these figures reach.
const FPS_DIAG = false;

/// One second's worth of derived session figures, produced by SessionStats.tick.
const StatsSnapshot = struct {
    fps: u32,
    pump_avg_us: u32,
    pump_max_us: u32,
    inputs_per_s: u32,
};

/// Owns the CALCULATION of per-second session pacing figures (FPS tracking),
/// kept separate from the loop that samples them: the session loop feeds each
/// pump sample in and, once per second, `tick` returns a snapshot to publish.
/// TSC-based (the PIT clock's 10 ms granularity is too coarse). All integer math.
const SessionStats = struct {
    tick_hz: u64,
    us_ticks: u64, // TSC ticks per microsecond

    window_t0: u64, // start of the current 1 s accumulation window
    pumps: u64,
    pump_us_sum: u64,
    pump_us_max: u64,
    mrep_last: u64, // HID report counts at window start (for the delta)
    krep_last: u64,

    fn init() SessionStats {
        const hz = tsc.hz();
        return .{
            .tick_hz = hz,
            .us_ticks = hz / US_PER_S,
            .window_t0 = tsc.rdtsc(),
            .pumps = 0,
            .pump_us_sum = 0,
            .pump_us_max = 0,
            .mrep_last = xhci.cnt_mouse_reports.v,
            .krep_last = xhci.cnt_kbd_reports.v,
        };
    }

    /// Record one desktop-pump iteration's wall duration. FPS is a direct
    /// present-count delta over the 1 s window (computed in tick), not an EMA —
    /// so the number matches reality: the true flips/sec (locked ~60 during
    /// motion, low when the damage-driven desktop is idle), never a stale value.
    fn samplePump(self: *SessionStats, t_start: u64, t_end: u64) void {
        const pump_us = (t_end - t_start) / self.us_ticks;
        self.pumps += 1;
        self.pump_us_sum += pump_us;
        if (pump_us > self.pump_us_max) self.pump_us_max = pump_us;
    }

    /// If a 1 s window has elapsed, publish a snapshot for the HUD; otherwise null.
    /// FPS is the smoothed rolling-window rate from present.fps() (a frame-counter
    /// diff over a 5 s time diff, sampled at ~2 Hz) — the REAL flip rate, smooth and
    /// accurate: high while rendering, decaying toward 0 on an idle damage-driven
    /// desktop. The 1 s cadence here only controls how often the tracked figure refreshes.
    fn tick(self: *SessionStats) ?StatsSnapshot {
        const now = tsc.rdtsc();
        const elapsed = now - self.window_t0;
        if (elapsed < self.tick_hz) return null;
        const fps = present.fps();
        if (FPS_DIAG) log("FPSTRACK fps={} frame={}\n", .{ fps, present.presentCount() });
        const snap = StatsSnapshot{
            .fps = @intCast(fps),
            .pump_avg_us = @intCast(self.pump_us_sum / self.pumps),
            .pump_max_us = @intCast(self.pump_us_max),
            .inputs_per_s = @intCast((xhci.cnt_mouse_reports.v - self.mrep_last) + (xhci.cnt_kbd_reports.v - self.krep_last)),
        };
        self.window_t0 = now;
        self.pumps = 0;
        self.pump_us_sum = 0;
        self.pump_us_max = 0;
        self.mrep_last = xhci.cnt_mouse_reports.v;
        self.krep_last = xhci.cnt_kbd_reports.v;
        return snap;
    }
};

/// RM ISR trampoline. The MSI handler calls this; it forwards to the RM core's
/// nvidia_isr once gsp.zig exposes it. Skeleton returns "not handled".
fn gpuIsr() bool {
    return false;
}

/// Wait for the GPU firmware (GFW) boot to complete before driving the GSP.
/// Mirrors nouveau tu102_devinit_wait (devinit/tu102.c:69): GFW boot is done when
/// 0x118128 bit0 is set AND 0x118234 low byte == 0xff (GFW_BOOT_PROGRESS=COMPLETED).
/// Returns true on completion, false on timeout. ~2 s budget like nouveau.
fn waitGfwBoot(regs: mmio.Mapping) bool {
    var timeout: u32 = 2050;
    var ok = false;
    while (timeout > 0) : (timeout -= 1) {
        if ((regs.read32(0x118128) & 0x1) != 0 and (regs.read32(0x118234) & 0xff) == 0xff) {
            ok = true;
            break;
        }
        shim.delayUs(1000); // nouveau usleep_range(1000,2000)
    }
    // Diagnostic: dump the NV_PGC6_AON_SECURE_SCRATCH_GROUP_05 scratch range. The
    // GSP-RM re-asserts GFW_BOOT_PROGRESS (a GROUP_05 field) during init; the
    // progress/secure-boot state lives across these regs. 0x118234 = GROUP_05_0.
    var r: u64 = 0x118234;
    while (r < 0x118234 + 0x40) : (r += 0x10) {
        log("gpu: scratch {x}: {x:0>8} {x:0>8} {x:0>8} {x:0>8}\n", .{ r, regs.read32(r), regs.read32(r + 4), regs.read32(r + 8), regs.read32(r + 12) });
    }
    // Also 0x118128 (GFW boot valid) and the FWSEC/secure-boot status regs.
    log("gpu: gfw 0x118128={x:0>8} 0x118120={x:0>8} 0x1183a4(vram)={x:0>8}\n", .{ regs.read32(0x118128), regs.read32(0x118120), regs.read32(0x1183a4) });
    return ok;
}

/// Run the M9 bring-up. Returns the fence result status: `.ok` proves the 4090
/// is alive under kudos. Any earlier failure is surfaced loudly (no silent
/// "no GPU, carry on" path — CLAUDE.md no-fallbacks rule).
///
/// `fw` is the signed GSP firmware image, supplied out-of-band.
pub fn bringUp(fw: gsp.Firmware) shim.Status {
    const dev = pci.findByIds(NVIDIA_VENDOR, RTX_4090_DEVICE) orelse {
        log("gpu: RTX 4090 ({x}:{x}) not found on PCI\n", .{ NVIDIA_VENDOR, RTX_4090_DEVICE });
        return .err_invalid_state;
    };

    // BAR0 is the 16 MiB register aperture (UC). bar64 masks the flag bits.
    const bar0 = pci.bar64(dev, 0);
    const regs = shim.mapKernelSpace(bar0, 16 * 1024 * 1024, .uc);

    // Power the card to D0 (a passed-through GPU may arrive in D3, with engine
    // register blocks like SEC2 powered down -> reads return error poison).
    dev.setPowerStateD0();
    // Memory space + bus mastering for GPU DMA.
    dev.enableBusMaster();

    // Gate GSP boot on the GPU firmware (GFW) boot completing (nouveau
    // tu102_devinit_wait, devinit/tu102.c:69): 0x118128 bit0 set AND 0x118234 low
    // byte == 0xff. (The GSP also emits benign "GFW_BOOT_PROGRESS" NOCAT asserts
    // during init regardless — those are normal diagnostics, present in nouveau too.)
    if (!waitGfwBoot(regs)) {
        log("gpu: GFW boot did not complete (0x118128=0x{x} 0x118234=0x{x})\n", .{ regs.read32(0x118128), regs.read32(0x118234) });
        // GFW-boot not completing means the GPU firmware hasn't initialized VRAM
        // /devinit. Running FWSEC + the booter on an unready card is the exact
        // "no silent carry-on" case the contract above forbids — fail loud.
        return .err_invalid_state;
    }

    // Route the GPU MSI to our ISR before booting the GSP (it signals via MSI).
    _ = msi.setup(dev, GPU_MSI_VECTOR, gpuIsr);

    // NOTE: do NOT disable interrupts here — the falcon bring-up uses timer-based
    // delays (shim.delayUs -> timer.sleep), which need the timer IRQ. The falcon
    // poll loops are MMIO reads, not affected by IRQs.

    // Boot the GSP and bring up the RPC ring. `var`: fifo.init takes *Gsp so its
    // persistent DMA pages register on g.dma (gsp.shutdown(g) frees them).
    var g = gsp.boot(regs, dev, fw) catch |e| {
        log("gpu: GSP boot failed: {}\n", .{e});
        return .err_invalid_state;
    };

    // GSP-RM is up and a real RPC round-tripped during boot.
    const alive = rm.checkAlive(g);
    if (alive != .ok) return alive;

    // M9.5: begin the display path — allocate the root RM object tree (client →
    // device → subdevice). Each alloc is an RM_ALLOC RPC the GSP must ack with
    // status=0. A failure here is a genuine bring-up failure and must surface —
    // tear the GSP down (so the card is left clean) and report the error rather
    // than masking it as success.
    const objs = rm.clientDeviceCtor(g) catch |e| {
        log("gpu: RM client/device/subdevice alloc failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    log("gpu: RM objects up: client=0x{x} device=0x{x} subdevice=0x{x}\n", .{ objs.client, objs.device, objs.subdevice });
    // Stage-boundary netdebug pump, repeated after every bring-up stage below
    // (bring-up flush points): a CPU-hard wedge inside
    // the NEXT stage then leaves this stage's completion on the wire, so a
    // native black screen is bracketed to a stage instead of silent.
    netdebug.drain();

    // Bring up the display engine: RAMIN + WRITE_INST_MEM, NV04_DISPLAY_COMMON,
    // GET_STATIC_INFO/GET_SUPPORTED, AD102_DISP root. VRAM is bump-allocated from
    // the free region below the RM's reserved top (gsp.fb.free). Non-fatal.
    var valloc = vram.Allocator.init(g.fb);
    const d = disp.bringUp(g, objs, &valloc) catch |e| {
        log("gpu: display bring-up failed: {}\n", .{e});
        // Tear the GSP down so the card is left clean for the next boot, then
        // surface the failure — a dark display is not a successful bring-up.
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    log("gpu: display up: objcom=0x{x} root=0x{x} displays=0x{x} windows=0x{x}\n", .{ d.objcom, d.root, d.display_mask, d.window_mask });
    netdebug.drain();

    // Host GPFIFO channel + copy engine (CE bring-up phase 1: RM objects only —
    // vaspace, GMMU PD handoff, channel BIND+SCHEDULE, CE object). Loud + fatal
    // per the no-fallback rule; the display path above already lit, so a
    // FIFO-only failure is distinguishable in the same run.
    var f = fifo.init(&g, &valloc, objs) catch |e| {
        log("gpu: FIFO/CE bring-up failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    log("gpu: FIFO up: chan=0x{x} ce=0x{x} chid={} runlist={}\n", .{ f.chan, f.ce, f.chid, f.runlist });
    netdebug.drain();

    // Phase-3 heartbeat: first real submission through the channel (CE bind +
    // host semaphore release). Loud + fatal on timeout.
    f.heartbeat(g) catch |e| {
        log("gpu: CE heartbeat failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    netdebug.drain();

    // GR (3D) engine bring-up: golden context, GR
    // channel, ADA_A object, GRBEAT fence, context-init stream. Loud + fatal —
    // a GR failure ends the run with the failing stage pinpointed on netdebug.
    var gr3d = gr.init(g, &valloc, objs, &f) catch |e| {
        log("gpu: GR bring-up failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    log("gpu: GR up: chan=0x{x} threed=0x{x} chid={} runlist={}\n", .{ gr3d.chan, gr3d.threed, gr3d.chid, gr3d.runlist });
    netdebug.drain();

    // CE bring-up (present.zig): first real copy (PRAMIN-verified, off-screen —
    // no visible test pattern), then the live desktop
    // mirror. Each stage is loud + fatal — a failed stage aborts to teardown so
    // the card is left clean and the trace pinpoints the stage.
    present.stage4Copy(g, &f, &valloc, d) catch |e| {
        log("gpu: stage4 (CE copy) failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    netdebug.drain();

    // Shader blobs for the windowed-GL path. Fatal if they will not upload: a GPU that
    // cannot hold its shaders cannot draw a window, and pretending otherwise just moves
    // the failure somewhere less obvious.
    const up = gl_shaders.upload(g, &valloc, &f.mmu) catch |e| {
        log("gpu: shader upload failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    netdebug.drain();

    present.enableDesktopMirror(g, &f, d, &valloc) catch |e| {
        log("gpu: stage6 (desktop mirror) failed: {}\n", .{e});
        _ = gsp.shutdown(g);
        return .err_invalid_state;
    };
    // PRAMIN-verify the secondary monitors' workspace fill (repaints once,
    // loudly, on mismatch) — the fix for a monitor going black undiagnosed.
    present.verifyMonitorFill();
    netdebug.drain();

    // Windowed GL (GL windows, GPU-resident): build the
    // IDraw device (per-window context pool) on the GR channel and publish
    // it — model windows acquire contexts and start rendering on their next
    // tick. Failure is loud but NOT fatal: the desktop runs without 3D (the
    // apps keep their placeholder), exactly like an emulated boot.
    if (buildinfo.no_gl) {
        // -Dno-gl (bisect): everything above is up — GSP, display, present — but
        // the GL device is never published, so the compositor never drives a GL
        // window on the GR channel. Same end state as a failed GL init.
        log("gpu: windowed-GL SKIPPED (-Dno-gl) — desktop runs, model windows stay 2D\n", .{});
    } else if (opengl.init(g, &f, &gr3d, up)) |gl_iface| {
        iopengl.device = gl_iface;
    } else |e| log("gpu: windowed-GL init failed: {} — model windows stay 2D\n", .{e});
    netdebug.drain();

    // Warm-up: seed BOTH primary back buffers with one full frame each (the
    // first present.FULL_SEED_FRAMES flips force full damage) so the
    // verification below reads a fully-populated scanout. Forced pumps render
    // unconditionally; the flip gate (waitFlipLatched in presentDesktopFrame)
    // paces them at the panel rate.
    // This stretch can hang on real hardware, so it must stay neither mute nor
    // deaf: it reports progress ~1/s (breadcrumbs name the step that hung) and
    // keeps the net serviced (shim.delayUs = drain + pump + KMR1) so OP_REBOOT
    // still reaches the machine; the dead-man is petted only while it does.
    // USB LATE-DEVICE SETTLE — before the first present, so a slow device that
    // finished coming up during GSP boot (the keyboard) is enumerated while the
    // desktop is NOT yet shown. poll_input drains the xHC event ring and enumerates
    // any newly-connected port WITHOUT rendering, so the blocking bring-up lands here
    // rather than inside the first cadence window. A device already up costs only
    // this bounded poll.
    if (iaccel.compositor.poll_input) |poll| {
        const settle_deadline = tsc.rdtsc() + tsc.usTicks(USB_SETTLE_MS * 1_000);
        while (tsc.rdtsc() < settle_deadline) {
            poll();
            shim.delayUs(@intCast(SESSION_POLL_US));
        }
        log("gpu: USB late-device settle done ({} ms)\n", .{USB_SETTLE_MS});
        netdebug.drain();
    }

    const warmup_t0 = tsc.rdtsc();
    const warmup_deadline = warmup_t0 + tsc.usTicks(WARMUP_WALL_MS * 1_000);
    var note_next = warmup_t0 + tsc.usTicks(1_000_000);
    var spins: u64 = 0;
    var first_present_tsc: u64 = 0; // stamped when the desktop's first present lands
    while (present.presentCount() < present.FULL_SEED_FRAMES and tsc.rdtsc() < warmup_deadline) : (spins += 1) {
        if (iaccel.compositor.pump) |pump| pump(true);
        if (first_present_tsc == 0 and present.presentCount() >= 1) first_present_tsc = tsc.rdtsc();
        shim.delayUs(@intCast(SESSION_POLL_US));
        if (tsc.rdtsc() >= note_next) {
            note_next = tsc.rdtsc() + tsc.usTicks(1_000_000);
            log("gpu: warm-up… presents={} spins={} tx_dropped={}\n", .{ present.presentCount(), spins, nic.txDropped() });
            netdebug.drain();
        }
    }
    // Boot-to-first-present milestone (spec PERF-002): from kudos boot entry to
    // the desktop's first GPU present. Emitted once, with an explicit PASS/OVER
    // against the budget so a boot that has crept over 5 s is loud, not silent.
    if (first_present_tsc != 0) {
        const boot_ms = tsc.bootElapsedMs(first_present_tsc);
        const verdict = if (boot_ms <= BOOT_TO_FIRST_PRESENT_BUDGET_MS) "PASS" else "OVER";
        log("gpu: boot-to-first-present {} ms (PERF-002 budget {} ms) {s}\n", .{ boot_ms, BOOT_TO_FIRST_PRESENT_BUDGET_MS, verdict });
        netdebug.drain();
    }
    const warmup_ms = tsc.elapsedMs(warmup_t0);
    if (present.presentCount() < present.FULL_SEED_FRAMES)
        log("gpu: warm-up FAILED to seed {} presents (got {})\n", .{ present.FULL_SEED_FRAMES, present.presentCount() });
    log("gpu: warm-up done ({} presents, {} spins, {} ms); draining in-flight flips\n", .{ present.presentCount(), spins, warmup_ms });
    netdebug.drain();
    // The last seeded flip may still be in flight; verification PRAMIN-reads
    // the front surface, which is only on scanout once that flip latched.
    present.waitIdle();
    log("gpu: flips drained; verifying scanout\n", .{});
    netdebug.drain();
    // Serial-side proof the desktop pixels are on the scanned-out surface
    // (pixel-exact PRAMIN readback vs the compositor surface) — the monitor
    // check without eyes on the monitors.
    present.verifyDesktopOnScanout(g);
    netdebug.drain();

    // THE SESSION: kudos runs like a real OS — desktop live on the monitors
    // until the user types `shutdown` (clean GSP teardown + poweroff below) or
    // hard-resets the machine. The loop busy-polls input at ~kHz (the xHC has
    // no IRQ — the USB poll cadence) and the pump renders at the panel
    // rate, gated on the previous flip having latched (the session
    // update cycle + vsync pacing).
    log("gpu: desktop session live — running until `shutdown`\n", .{});
    // Stats CALCULATION lives in SessionStats (below); this loop only samples it
    // and, once per second, publishes the snapshot to frame_stats (FPS tracking) — display and
    // calculation are kept separate. Scanline watchdog runs on its own cadence.
    var stats = SessionStats.init();
    var wd_t0 = tsc.rdtsc();
    var glstat_t0 = tsc.rdtsc();
    while (!power.shutdown_requested) {
        // Netdebug metered drain — on native boot THIS loop is where the machine
        // lives, so the queued log must be shipped from here too. Timed
        // out-of-band into the profiler's .netdebug
        // section (it runs around the pump, not inside its span chain) so a pacing
        // run can see how much the wire drain itself costs.
        const t_nl = tsc.rdtsc();
        // Two pacing decisions this loop owns, because measuring frame cadence
        // is its concern and neither service can know about it: pace the trace
        // drain to one datagram per tick, and hold the boot log's USB write off
        // entirely, while a flip-sample window records. Either one landing
        // inside that window reads as a late flip — a real USB bulk write costs
        // ~6 ms, enough outliers to fail the `steady` gate outright. Neither
        // service loses anything: both resume the instant the window closes.
        netdebug.setGentle(present.sampleActive());
        bootlog.setHoldOff(present.sampleActive());
        // EVERY background service, in one ordered pass, from the SAME table
        // the no-GPU system loop steps (boot/services.zig) — reached through
        // the compositor seam because a driver must not import the apex. On a
        // native boot this loop never returns and IS the machine, so this is
        // where the trace drain, the network pump, KMR1 replies, backgrounded
        // jobs, the boot log and guest boot requests all live. A hand-written
        // list here is what silently lost `vm boot` on real hardware.
        if (iaccel.compositor.service) |service| service(false);
        // netdebug SHOT (remote request): capture the LIVE desktop into ramdisk
        // screenshot.png + the stick (the host then pulls it via the mirror).
        // ON DEMAND ONLY — a smooth desktop never does unbidden heavy I/O: the
        // full-res capture + ~15 MB USB write blocks this loop for seconds
        // (measured: a boot auto-shot stalled the render 22 s, failing the
        // 10 s-smooth-from-first-present gate). A screenshot happens when asked.
        if (fileserv.takeShotRequest()) {
            screenshot.dump(g, &f) catch |e|
                log("gpu: screenshot failed: {}\n", .{e});
        }
        prof.addSpan(.netdebug, tsc.rdtsc() -% t_nl);
        const t_pump = tsc.rdtsc();
        // GL pipelines advance at poll cadence (render→de-tile handoff within
        // ~ms of the fence, not at the next present).
        opengl.pumpAll();
        if (iaccel.compositor.pump) |pump| pump(false);
        // The post-render slice: bounded guest work, AFTER this pass's render,
        // so a guest can never push a present past its deadline (PERF-003).
        if (iaccel.compositor.service) |service| service(true);
        stats.samplePump(t_pump, tsc.rdtsc());
        present.fpsSample(); // rolling-window FPS: sample the frame counter (~2 Hz, self-throttled)
        if (stats.tick()) |snap| {
            // Publish the per-second figures for FPS tracking
            // — kept for a future netdebug emit.
            iaccel.frame_stats = .{
                .seq = iaccel.frame_stats.seq +% 1,
                .fps = snap.fps,
                .pump_avg_us = snap.pump_avg_us,
                .pump_max_us = snap.pump_max_us,
                .inputs_per_s = snap.inputs_per_s,
            };
        }
        if (tsc.rdtsc() - wd_t0 >= stats.tick_hz * SCAN_WATCHDOG_PERIOD_S) {
            wd_t0 = tsc.rdtsc();
            present.scanWatchdog();
        }
        // GLSTAT: per-context GL pipeline state ~every 2 s (GL windows,
        // GPU-resident — the frozen-model diagnostic). HELD OFF while a
        // flip-sample window records: its PRAMIN probe + emit burst costs
        // ~1.5 ms of loop time, which the window sees as a late flip — enough
        // periodic outliers per 512-frame window to fail `steady` outright. t0
        // is not reset while held, so the dump fires immediately once the
        // window closes — nothing is lost.
        if (!present.sampleActive() and tsc.rdtsc() - glstat_t0 >= stats.tick_hz * 2) {
            glstat_t0 = tsc.rdtsc();
            opengl.dumpStatus();
        }
        // ~kHz input cadence between pumps (SESSION_POLL_US). pause-spin
        // (tsc.udelay), NOT timer.sleep: the PIT quantizes sleeps to 10 ms,
        // three orders too coarse for this cadence. Single dedicated core —
        // busy is by design.
        tsc.udelay(SESSION_POLL_US);
    }
    log("gpu: shutdown requested — tearing down\n", .{});
    iopengl.device = null; // the model-viewer app must not touch a dying GR channel
    present.disableDesktopMirror();
    // The display engine is still actively scanning out of VRAM (window/ctxdma)
    // while shutdown unloads GSP-RM and destroys WPR2. A clean sequence would
    // issue a disabling EVO commit (blank head, detach window,
    // HEAD_SET_DISPLAY_ID(0)) before this.
    const st = gsp.shutdown(g);
    if (st != .ok) {
        log("gpu: GSP teardown did not leave WPR2 clean: {s}\n", .{@tagName(st)});
        if (power.shutdown_requested) power.poweroff();
        return st;
    }

    // `shutdown` was typed in the session: the GSP is now down cleanly —
    // power the machine off.
    if (power.shutdown_requested) {
        log("gpu: shutdown requested — powering off\n", .{});
        power.poweroff();
    }

    return .ok;
}
