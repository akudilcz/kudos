//! Kernel entry. Called from boot/boot.asm in 64-bit long mode with the
//! multiboot2 info pointer in the first argument.

const std = @import("std");

/// std.crypto's randomness (TLS session keys) comes straight from hardware
/// RDRAND — the randomness seam's one real implementation
/// (kernel/cpu/entropy.zig). `crypto_always_getrandom` is REQUIRED: without
/// it std caches CSPRNG state in threadlocal storage, and this kernel sets up
/// no thread-local ABI, so the first `std.crypto.random` use faults.
pub const std_options: std.Options = .{};
const buildinfo = @import("buildinfo");
const klog = @import("kernel/debug/klog.zig");
const debug = @import("kernel/debug/debug.zig");
const mb = @import("kernel/boot/multiboot2.zig");
const framebuffer = @import("ui/screen/framebuffer.zig");
const pmm = @import("kernel/memory/pmm.zig");
const heap = @import("kernel/memory/heap.zig");
const idt = @import("kernel/interrupts/idt.zig");
const pic = @import("kernel/interrupts/pic.zig");
const timer = @import("kernel/timer/timer.zig");
const wallclock = @import("kernel/timer/wallclock.zig");
const keyboard = @import("drivers/input/keyboard.zig");
const imouse = @import("imouse");
const pci = @import("drivers/pci/pci.zig");
const ramdisk = @import("drivers/storage/ramdisk.zig");
const vfs = @import("vfs");
const fat = @import("drivers/storage/fat.zig");
const bootlog = @import("drivers/storage/bootlog.zig");
const usbshot = @import("drivers/gpu/usbshot.zig");
const net = @import("drivers/net/stack/net.zig");
const netdebug = @import("drivers/net/debug/netdebug.zig");
const fileserv = @import("drivers/net/debug/fileserv.zig");
const agenttools = @import("console/agenttools.zig");
const session = @import("console/session.zig");
const xhci = @import("drivers/usb/xhci.zig");
const gate = @import("kernel/debug/gate.zig");
const backtrace = @import("kernel/debug/backtrace.zig");
const crashlog = @import("kernel/debug/crashlog.zig");
const percpu = @import("kernel/sched/percpu.zig");
const Desktop = @import("ui/desktop/desktop.zig").Desktop;
const hud = @import("ui/desktop/hud.zig"); // the F1 heads-up display (spec HUD-001)
const devices = @import("drivers/devices.zig"); // publishes the peripheral seam the display reads
const typeface = @import("typeface"); // the scalable face the HUD sets its figures in
const smp = @import("kernel/smp/smp.zig");
const sched = @import("kernel/sched/sched.zig");
const jobs = @import("kernel/sched/jobs.zig");
const verifyscript = @import("console/verifyscript.zig");
const cpu = @import("kernel/cpu/cpu.zig");
const tsc = @import("kernel/cpu/tsc.zig");
const counter = @import("kernel/debug/counter.zig");
const virt = @import("kernel/virt/virt.zig");
const gueststage = @import("kernel/virt/gueststage.zig"); // the guests this build carries
const ivirt = @import("ivirt");
const gpu = @import("drivers/gpu/gpu.zig");
const idraw = @import("idraw"); // the draw seam — the desktop renders through gles onto it
const softdisplay = @import("drivers/gl/softdisplay.zig"); // publishes the CPU rasteriser (-Dsoft-display)
const prof = @import("drivers/gpu/prof.zig");
const power = @import("kernel/power/reboot.zig");
const dbg = @import("kernel/debug/debug.zig");
const iaccel = @import("iaccel"); // the GPU-acceleration seam (iface/iaccel.zig)
const pump = @import("boot/pump.zig");

extern var __kernel_start: u8;
extern var __kernel_end: u8;

/// Diagnostic panic handler: the default freestanding panic executes `ud2` with
/// no output, so a panic shows up only as an opaque #UD in the CPU-exception
/// dump. This builds the panic record — message, return address, RBP-chain
/// backtrace — in this core's crash record and seals it. Like every fatal path
/// it writes only through crashlog, never the trace bus: the panic may have
/// unwound out of klog with the bus lock held on this very core, and a fatal
/// path that touched the bus could then spin on its own lock forever with no
/// output at all (crashlog.zig owns that invariant). flushNow ships the sealed
/// record to the LAN before the reset — a native-boot panic is otherwise a
/// silent black screen ("Panic backtrace").
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    const slot = percpu.indexOrZero();
    crashlog.puts(slot, "\n*** KERNEL PANIC: ");
    crashlog.puts(slot, msg);
    crashlog.puts(slot, "\n*** return address: ");
    crashlog.putHex(slot, ret_addr orelse 0);
    crashlog.puts(slot, "\n");
    // Call-stack backtrace: seed at the panic site's RBP, bound to the current
    // stack. Symbolize offline against the ELF (addr2line) — we emit raw addresses.
    crashlog.puts(slot, "*** backtrace (rbp chain; addr2line against the ELF):\n");
    if (crashlog.emitBacktrace(slot, backtrace.here(), backtrace.rsp()) == 0)
        crashlog.puts(slot, "*** BT (no frames — frame pointer omitted or stack corrupt)\n");
    // An AP panic seals this record and parks the panicking core (contained,
    // spec R59) — any surviving core's drain ships it; on core 0 this returns
    // and the crash path below runs.
    smp.containIfAp();
    crashlog.puts(slot, "*** crash held, then reboot (one-shot -> fallback OS)\n");
    crashlog.seal(slot);
    netdebug.flushNow(); // best-effort: get the record off the box first
    bootlog.flushNow(); // …and onto the stick, so the panic survives the reset
    power.crashReboot();
}

// DHCP-at-boot retry shape (see the "boot: net dhcp" block). 3 attempts with 6 s
// gaps spans ~30 s worst case — comfortably past the I226's ~10 s post-link dead
// zone, while QEMU pays nothing (first attempt lands). Bounded on purpose: with no
// DHCP server the boot must report `net: DOWN` and continue, never wait forever.
const DHCP_ATTEMPTS: u32 = 3;
const DHCP_RETRY_GAP_MS: u64 = 6_000;

/// The steady loop's network servicing, callable from the long BOOT-time driver
/// paths (xhci.service_hook). Drains queued netdebug onto the wire and answers
/// KMR1 — so remote control (crucially OP_REBOOT) exists during bring-up and not
/// only once the desktop is up. Deliberately just these three: no rendering, no
/// scheduling, nothing that a half-initialised kernel cannot support.
fn bootPump() void {
    netdebug.drain();
    net.pump();
    fileserv.service();
}

/// Guards netKeepalive against re-entry: fileserv.service() can act on a queued
/// request (a spawn, a reboot) and must never recurse back through a net wait.
var in_keepalive: bool = false;

/// The net stack's wait-time keepalive (wired to net.wait_hook): drain queued
/// netdebug onto the wire and answer KMR1 while a fetch blocks in
/// tcp.connect/send/pumpUntil. Those loops already call net.pump() (which moves
/// the TCP bytes), but NOT these two — so without this a multi-second transfer
/// goes trace-silent and stops answering remote status/reboot, looking wedged.
/// No rendering here: a fetch on the desktop thread still freezes the compositor
/// (a separate follow-up), but the machine stays observable and controllable.
fn netKeepalive() void {
    if (in_keepalive) return;
    in_keepalive = true;
    defer in_keepalive = false;
    netdebug.drain();
    fileserv.service();
}

// -Dheartbeat run length. 30 s is long enough that a 1 Hz host driver collects
// ~30 replies (a real sample: gaps, tick drift, a lease that dies mid-run all
// show up), and short enough that a failed run costs half a minute rather than a
// walk to the machine.
const HEARTBEAT_RUN_MS: u64 = 30_000;

/// The `-Dheartbeat` image (see build.zig): the smallest kudos that can prove it
/// is alive. Network is up; nothing else has been touched — no USB enumeration,
/// no desktop, no GSP. Answer KMR1 pings for a fixed run, then reset.
///
/// The deadline rides the TSC, never the IRQ0 tick, and that is the whole point:
/// the tick is the clock that has actually died on us, and a timeout measured on
/// a dead clock never expires. The TSC is free-running — nothing in software can
/// stop it — so this run ends even if interrupts never fire again. If the TSC
/// somehow failed to calibrate we fall back to the tick and say so, because a
/// silent fallback to a clock that may be dead is exactly the trap being avoided.
///
/// The reboot at the end is load-bearing twice over: it returns lemon to Ubuntu
/// (the GRUB entry is one-shot) with no human in the loop, and it is the FIRST
/// real test of power.reboot() on this silicon — if the machine does not come
/// back on the network, the reset path itself is what to fix next.
fn heartbeatMode() noreturn {
    klog.puts("boot: HEARTBEAT MODE — net + USB, no desktop/GPU\n");
    // THE LOG GATE IS THE CONFIGURATION OF WHAT THIS IMAGE SAYS, and run()'s
    // gate.enable() lives further down the normal boot — past the point we branch
    // here. Without this the whole USB pipeline is silent and a perfectly healthy
    // enumeration looks identical to a dead controller (CLAUDE.md warns about
    // exactly this: "a GPU produced no presents" is almost always the gate).
    gate.enable(&.{ .usb, .net, .boot });
    netdebug.flushNow();

    // USB bring-up, INSIDE the bounded run. Enumeration is the phase most able to wedge
    // a machine, which is precisely why this image should exercise it: if it wedges, the
    // run still ends on its own and the machine still comes back to Ubuntu.
    //
    // service_hook keeps the network answered DURING enumeration. Without it, a slow or
    // stuck bring-up takes the box off the air entirely — and "unreachable" and "slow"
    // then look identical from outside, though only one of them needs a person to walk
    // over and power-cycle it.
    klog.puts("boot: heartbeat — xhci init (keyboard / mouse / usbdisk)\n");
    xhci.service_hook = &bootPump;
    _ = xhci.init();
    klog.puts("boot: heartbeat — xhci init returned\n");
    netdebug.flushNow();

    const use_tsc = tsc.hz() != 0;
    if (!use_tsc) klog.puts("heartbeat: TSC NOT CALIBRATED — falling back to the IRQ0 tick for the deadline\n");
    const t0_tsc = tsc.rdtsc();
    const t0_ms = timer.millis();

    var last_report_s: u64 = 0;
    while (true) {
        const elapsed_ms = if (use_tsc) tsc.elapsedMs(t0_tsc) else timer.millis() -% t0_ms;
        if (elapsed_ms >= HEARTBEAT_RUN_MS) break;

        bootPump(); // drain netdebug, run the net stack, answer the ping
        xhci.poll(); // HID reports + port changes; the kbd_rep/mouse_rep counters move here

        // One line a second on the netdebug stream, from the kudos side. The host
        // driver's view and this must agree; where they disagree is the bug.
        const s = elapsed_ms / 1000;
        if (s != last_report_s) {
            last_report_s = s;
            var buf: [160]u8 = undefined;
            const u = xhci.deviceStatus();
            klog.puts(std.fmt.bufPrint(&buf, "hb {d}s: ticks={d} usbdev={d} kbd={d} mouse={d} usbdisk={d} | addrfail usbsts={x} evdeq={d} evcyc={d} evctrl={x}\n", .{
                s,                     timer.now(),
                u.devices,             @intFromBool(u.keyboard),
                @intFromBool(u.mouse), @intFromBool(u.usbdisk),
                xhci.dbg_addr_usbsts,  xhci.dbg_addr_evdeq,
                xhci.dbg_addr_evcyc,   xhci.dbg_addr_evctrl,
            }) catch "hb: format failed\n");
        }

        tsc.udelay(200); // don't spin the NIC's registers flat out
    }

    var buf: [128]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&buf, "heartbeat: run complete after {d} ms — {d} pings answered, REBOOTING\n", .{
        HEARTBEAT_RUN_MS, fileserv.pingCount(),
    }) catch "heartbeat: run complete — REBOOTING\n");
    netdebug.flushNow(); // the last words have to be on the wire BEFORE the reset
    power.reboot();
}

comptime {
    // `kmain` (the symbol boot/boot.asm calls) is exported by exactly one root.
    // In the single-core `kudos` build this file is the root and owns it. In the
    // `kudos-smp` build this file is imported by src/main_smp_root.zig — which owns
    // `kmain` there — so we must NOT also export it, or the two collide. The
    // comptime `smp` flag (injected per variant by build.zig) selects which.
    if (!buildinfo.smp) @export(&kmain, .{ .name = "kmain" });
}

/// The C-ABI entry symbol boot/boot.asm jumps to (single-core build only; see the
/// comptime export above). Just forwards to the shared bring-up path.
fn kmain(mb_info: u64) callconv(.c) noreturn {
    run(mb_info);
}

/// Single-core kernel bring-up + main loop. This is the shared BSP path: the
/// `kudos` root (the `kmain` above) and the `kudos-smp` root (src/main_smp_root.zig)
/// both run it, so the boot/init sequence lives in exactly one place.
/// The SMP root additionally brings APs online
/// around this body; here `buildinfo.smp` is comptime-known per variant.
pub fn run(mb_info: u64) noreturn {
    // Stamp the boot clock at the earliest kudos instruction: the boot-to-first-
    // present budget (spec PERF-002) is measured from here to the first GPU
    // present. Raw TSC — tsc.init() calibrates the frequency later; the delta is
    // computed at the first present, by which time tsc.hz() is known.
    tsc.boot_entry_tsc = tsc.rdtsc();

    klog.init();
    klog.installLogSink(); // leaf UI modules log via iface/ilog.zig
    crashlog.init(); // register the crash-record counters (fatal paths only bump)
    klog.puts("hello from kudos kernel (64-bit)\n");

    // Build identity: which image this is, so a developer can
    // confirm the running machine matches what they just built. buildinfo is
    // injected by build.zig from BUILD_NUMBER + the git commit.
    var banner: [64]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&banner, "kudos build #{d} (g{s})\n", .{
        buildinfo.build_number, buildinfo.git_hash,
    }) catch "kudos build #? (g?)\n");

    // SMP variant: discover topology + enable the BSP's LAPIC now, before the
    // rest of the bring-up (the APs themselves start later — smp.start() below).
    // Lives HERE, not in main_smp_root.zig, so the boot/init sequence has exactly one
    // owner for both variants.
    if (buildinfo.smp) {
        klog.puts("kudos-smp: SMP variant (BSP)\n");
        smp.init();
    }

    // The framebuffer is OPTIONAL: under GPU passthrough we boot with `-vga none`
    // (the emulated QEMU VGA device makes the passed-through 4090's GSP PMU fault
    // during init — verified by A/B against nouveau; scripts/vm/run.sh --passthrough).
    // With no VGA, GRUB provides no framebuffer tag, so we run headless (trace +
    // GPU bring-up only, no desktop). A normal run still has the framebuffer.
    // A firmware framebuffer tag distinguishes the two boot contexts:
    //   • tag present → NATIVE boot (GRUB on the physical machine) or a plain
    //     QEMU dev run. On native the 4090 is live/GOP-initialized, so the GPU
    //     path must bus-reset it before GSP boot (gpu.bootAtInit(native)).
    //   • tag absent → GPU passthrough (`-vga none`): QEMU handed us a freshly
    //     reset card; boot the GSP directly.
    const maybe_fb = mb.framebuffer(mb_info);
    const native_boot = maybe_fb != null;
    if (maybe_fb) |fb| {
        // DIAG: report exactly what GRUB handed us, so we can tell whether the
        // mode/address are what QEMU's VGA device actually scans out.
        var fbm: [96]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&fbm, "fb: tag {d}x{d}x{d}bpp addr=0x{x} pitch={d} fbtype={d}\n", .{
            fb.width, fb.height, fb.bpp, fb.addr, fb.pitch, fb.fb_type,
        }) catch "fb: tag (fmt err)\n");
        framebuffer.init(fb, mb_info);
    } else {
        // GPU passthrough: no firmware framebuffer, but the desktop still runs —
        // into a VIRTUAL framebuffer (logical size only, no physical copy). The
        // GPU present path mirrors it onto the 4090's monitors and raises the
        // logical size to the primary panel's native mode once the GSP is up.
        klog.puts("fb: no multiboot2 framebuffer tag — virtual framebuffer (GPU passthrough)\n");
        framebuffer.initVirtual(1280, 800);
    }

    // "boot:" breadcrumbs — one ungated klog line BEFORE each bring-up step,
    // so the LAST line of any capture (netdebug backlog replay,
    // /usbdisk/bootlog.txt) names the step that hung. Steps that
    // already announce themselves (fb:, netdebug:, usbdisk:, net:) aren't doubled.
    klog.puts("boot: pmm+heap\n");
    pmm.init(mb_info, @intFromPtr(&__kernel_start), @intFromPtr(&__kernel_end));
    heap.init();
    const a = heap.allocator();

    // Bake the scalable typeface (spec RND-009) before anything draws: outlines
    // in, one packed coverage sheet out. A failure here costs the HUD its text
    // and nothing else, so it is reported and boot continues.
    klog.puts("boot: typeface\n");
    typeface.init(a) catch klog.puts("typeface: bake FAILED — scalable text unavailable\n");

    klog.puts("boot: pci scan\n");
    pci.init();
    klog.puts("boot: ramdisk+vfs\n");
    ramdisk.init(a);
    seedRamdisk();
    fileserv.init(ramdisk.fs()); // netdebug file server reads through the iramdisk seam
    agenttools.initMcpServer(); // serve the agent's tool registry as MCP over netdebug (AGT-011/AGT-013)
    // Let the agent run a compiled module in a session of its own (AGT-008).
    // Single-core kudos has no session spaces, so it never offers one — and
    // apprun refuses the run rather than executing a module uncontained.
    if (buildinfo.smp) session.publishSandbox();
    net.wait_hook = &netKeepalive; // a long fetch must not blind netdebug/KMR1 (see netKeepalive)
    net.publish(); // apps reach the network through iface/inet.zig, never the stack itself
    devices.publish(); // …and the peripherals through iface/idevices.zig
    vfs.mount("ramdisk", ramdisk.fileSys()); // /ramdisk (vfs.zig; /usbdisk joins with USB storage)

    // Orderly-exit flush (spec R51): every reboot/poweroff — shell command,
    // KMR1 remote, GPU-teardown path — drains the trace and syncs pending
    // storage writes through this hook before the machine goes down.
    power.flush_hook = &pump.orderlyFlush;

    // Hand the GPU module the boot-info pointer so the GSP boot can locate the
    // firmware boot modules (no device work here).
    gpu.init(mb_info);

    klog.puts("boot: idt+pic+timer+kbd\n");
    idt.init();
    pic.remap();
    timer.init();
    wallclock.init();
    keyboard.init();
    // kudos has no legacy PS/2 input. All keyboard and pointer input comes from
    // USB HID (xhci): a boot keyboard + mouse on real hardware, a tablet in the
    // QEMU GUI. (The 8042 controller survives only as a reset mechanism — see
    // kernel/power/reboot.zig.)
    idt.enableInterrupts();

    // Calibrate the TSC now that interrupts are up (the PIT-fallback path measures
    // rdtsc against IRQ0 ticks). Single owner for BOTH builds — the SMP path's
    // setupTimers calls tsc.init() again but it is idempotent. Done BEFORE GSP boot
    // so the falcon bring-up can use real sub-µs TSC delays (tsc.udelay) instead of
    // fixed MMIO-read busy-loops that overshoot massively under vfio.
    klog.puts("boot: tsc calibrate\n");
    tsc.init();

    // Probe hardware virtualization (VT-x). Never fails boot; the `vm` command and
    // the VM console app report availability.
    virt.init();

    // PIT aliveness probe. Everything wall-clock in this kernel (timer.sleep, USB
    // debounce, DHCP timeouts) rides the 8254 tick — and modern boards are allowed
    // to CLOCK-GATE the 8254 (no counting, no IRQ0), which QEMU never does. If the
    // PIT is dead here, every later sleep is an infinite hlt and the boot will die
    // somewhere that looks unrelated. Measure it NOW, against the TSC (which is
    // calibrated and PIT-independent), and say so while the saying works.
    // Emitted with klog.puts, NOT through dbg: gate.enable() does not run until ~30
    // lines below, and every dbg.set* before it is silently DROPPED. klog is
    // UNGATED (and netdebug is a sink on it), so a klog line survives even here.
    {
        const t0 = timer.now();
        tsc.udelay(50_000); // 50 ms: ≥5 ticks at 100 Hz, unambiguous
        const delta = timer.now() - t0;
        klog.puts("boot: PIT ticks in 50ms = ");
        klog.putHex(delta);
        klog.putc('\n');
        if (delta == 0) {
            klog.puts("boot: PIT IS DEAD (0 ticks/50ms) — every timer.sleep will HANG FOREVER\n");
        }
    }

    // Network bring-up FIRST — as early as the NIC can run (needs PCI + timer +
    // interrupts, all up by here): netdebug puts the trace bus on the LAN
    // as UDP broadcast ("Netdebug"), so every phase that
    // follows — desktop, USB enumeration, the GPU takeover that darkens the
    // screen — reports its issues live on a native boot with no screen.
    // Starting this early also gives PHY autoneg + the switch port their settle
    // time while the desktop/USB bring-up runs; netdebug.drain() (system + GPU
    // session loops) replays the boot log once the path is proven. Only the NIC
    // link comes up here (the channel is lease-free); DHCP stays deferred.
    klog.puts("boot: netdebug nic claim\n");
    _ = netdebug.start();

    // Take a DHCP lease as early as possible — with RETRIES, because early is
    // exactly when the wire lies. The ordering is load-bearing:
    //
    // TAKE THE LEASE BEFORE ANYTHING THAT CAN HANG. The trace bus is UDP broadcast and
    // needs no address, but the remote-control channel is unicast and cannot answer
    // without one. Get the order wrong and you build the most confusing failure there
    // is: a machine that streams its entire boot log while being completely unreachable
    // — you can watch it die and you cannot reboot it.
    //
    // So the lease comes first, ahead of the desktop and USB, which are the phases that
    // actually hang.
    //
    // Why retries and not a fixed pre-wait: on real hardware (lemon's I226) PHY
    // autoneg + the switch port swallow every frame for ~10 s after link-up, so a
    // single early DISCOVER just vanishes — measured: a mute, unreachable boot.
    // In QEMU the first attempt succeeds instantly, so retries cost nothing there;
    // a fixed wait would tax every emulated boot for lemon's benefit. Each attempt
    // is itself bounded inside dhcp.zig (~6 s), each gap drains the netdebug
    // backlog so telemetry starts the moment the link is real, and the whole loop
    // is bounded — no DHCP server must never hang the boot.
    klog.puts("boot: net dhcp\n");
    if (buildinfo.heartbeat) {
        // The DEBUG image brings the network up SYNCHRONOUSLY, before anything else,
        // so netdebug/KMR1 telemetry has its best chance of being live before a later
        // phase that has hung a real machine. A lost first DISCOVER is covered by the
        // bounded retry loop. This latency is the price of trying first — paid only by
        // -Dheartbeat.
        var lease = net.init();
        var tries: u32 = 1;
        while (!lease and tries < DHCP_ATTEMPTS) : (tries += 1) {
            var waited: u64 = 0;
            while (waited < DHCP_RETRY_GAP_MS) : (waited += 100) {
                netdebug.drain();
                timer.sleep(100);
            }
            klog.puts("net: dhcp retry\n");
            lease = net.init();
        }
        if (lease) {
            klog.puts("net: up, lease ");
            net.logConfig();
        } else {
            klog.puts("net: DOWN (no NIC or DHCP failed) — KMR1 remote control UNAVAILABLE\n");
        }
        // The lease is up and the link is proven bidirectional, so blast the whole
        // boot backlog onto the wire now, before the phases that have hung a machine.
        // (flushNow bypasses the path-proven gate — only safe once the link delivers.)
        netdebug.flushNow();
    } else {
        // Normal boot: KICK OFF DHCP and move straight on — the desktop must not wait
        // ~13 s for a lease (a DISCOVER sent before the PHY has carrier is lost, and
        // the retry gap covers it at ~13 s of dead boot). net.pump() commits the lease
        // in the background: it runs from the USB service hook (bootPump) all through
        // xhci.init and then from the GPU session loop, so the lease typically binds
        // DURING enumeration — telemetry is up before GSP boot, with none of the wait.
        //
        // Do NOT flushNow() here: the link has NO carrier yet (autoneg is still
        // running), and flushNow bypasses the path-proven gate — it would blast the
        // whole early-boot backlog into a dead link and lose it (the banner, the USB
        // enumeration, "KEYBOARD ready"). The metered drain() holds the backlog in the
        // 16k FIFO and ships it in order the instant pathProven() latches (the lease
        // binds, or the link settles), so nothing early is lost.
        if (net.startAsync()) {
            klog.puts("net: DHCP kicked off (async — binds in the background)\n");
        } else {
            klog.puts("net: no NIC — KMR1 remote control UNAVAILABLE\n");
        }
    }

    // The bring-up image stops HERE — the network is the last thing that has been
    // brought up, and everything past this point (desktop, USB, GSP) is a phase
    // that has hung a real machine. heartbeatMode never returns.
    if (buildinfo.heartbeat) heartbeatMode();

    // Module debug gate ("Module debug gate"): logging is
    // off by default; this one list IS the configuration of what this image
    // logs. Enabling `.usb` lights up the whole USB HID pipeline — controller
    // enumeration, transfer rings, HID reports, and the controller's own
    // PCI/MSI setup (all emitted from xhci.zig under `.usb`) — so a native boot
    // reports exactly where the keyboard/mouse pipeline stalls. Everything else
    // (the GPU `.gpu` chatter, `.net`) stays silent. Panics, CPU exceptions and
    // the boot banner are never gated.
    // A `-Dflip-sample` measurement build force-enables `.gpu` too: the FLIPSTAT
    // verdict it exists to produce emits under that gate, and a measurement run
    // with the verdict silently gated off is the #1 diagnosis trap (a "GPU
    // produced no presents" read that is really just this list).
    // GR/3D bring-up: `.gpu` stays ON so
    // GR channel/promote/GRBEAT records reach netdebug on every run.
    // A `-Dtest-hooks` integration-test build force-enables `.term` and `.ui`
    // too: the terminal-output mirror (terminal.zig putChar) emits under `.term`
    // and the WM state mirror (desktop.zig emitWmState) under `.ui`, so the
    // harness can read back command output and window focus/geometry — same
    // rationale as flip-sample/`.gpu` above (the instrumentation is worthless if
    // its records are gated off).
    // The set is wide on purpose. On bare metal the network is the only window into
    // this machine — there is no serial port, and a boot that fails before the desktop
    // appears leaves nothing on screen to read. So the subsystems that report at init
    // and on events (`.net .pci .mem .boot`, and the terminal/window-manager mirrors
    // `.term`/`.ui`) stay enabled even in a non-test build: they are the only evidence
    // that the machine got as far as it did. None of them sits in a hot path.
    //
    // The hot ones (`.irq .sched .smp .cpu .acpi`) are NOT enabled. Turn one on
    // deliberately, for one question, and turn it back off.
    gate.enable(&.{ .usb, .gpu, .term, .ui, .net, .pci, .mem, .boot });

    // NOTE: the GSP boot (gpu.bootAtInit) happens AFTER the desktop is up —
    // see below. The GPU display-hold phase pumps desktop frames through
    // iaccel.compositor.pump, so the desktop must exist first.

    // Bring the desktop up and paint it FIRST — before net/USB bring-up — so the
    // diagnostics console is on screen even if a later driver hangs. Without
    // this, a hang in xhci.init() leaves a blank screen with nothing to read; now
    // the bring-up log streams onto the already-visible console.
    //
    // kudos is GPU-ONLY: on hardware `idraw.device` is published only by the GPU
    // bring-up, and nothing shows until that first present. A `-Dsoft-display`
    // build also offers the CPU rasteriser when no GPU is coming, so an emulated
    // boot is visible; settled HERE, before any window exists, since a window
    // never migrates between draw devices.
    _ = softdisplay.publish(a, .{
        .gpu_coming = gpu.willBoot(),
        .scanout_ready = framebuffer.linearTarget() != null,
    }, &bootPump);

    klog.puts("boot: desktop create\n");
    const desktop = createBootDesktop(a);
    klog.puts("desktop ready\n");
    desktop.render();

    // Net + USB are NOT brought up here: their init blocks (DHCP can spin for
    // seconds, xhci enumeration polls), and doing it on the boot stack — before
    // the render loop runs — leaves the screen frozen on a single boot frame the
    // whole time (QEMU's display only re-samples on a present, so it shows black).
    // Instead the system loop runs them once, after the screen is already live
    pump.desktop = desktop;
    g_native_boot = native_boot; // the SMP system task reads this to drive bootAtInit

    // Register the frame pump, then boot the GSP (interrupts/timer are up; the
    // falcon bring-up uses timer delays). The GPU display-hold phase drives
    // desktop frames through the pump so the mirror has content to present.
    // No-op if the 4090 / firmware aren't present.
    iaccel.compositor.pump = &pump.desktopPump;
    iaccel.compositor.poll_input = &pump.pollInputOnly;

    // Keep kudos reachable THROUGH enumeration. xhci runs before the steady loop,
    // so without this it neither ships telemetry nor answers KMR1 while it works —
    // and a USB device that never completes (lemon's port 5) therefore takes the
    // whole machine off the air with no way back but a power cycle. With the hook,
    // a stuck enumeration is merely a bad boot we can reboot out of remotely.
    xhci.service_hook = &bootPump;

    // USB first: the GPU display-hold pump polls HID input, so the xhci must
    // be enumerated BEFORE the GSP boot. (`.usb` logging enabled above.)
    klog.puts("boot: xhci\n");
    _ = xhci.init();

    // /usbdisk: if enumeration found + probed THE stick (capacity whitelist,
    // msc.zig), mount its FAT volume into the VFS. Loud on every failure —
    // a stick that doesn't appear must say why, never silently miss.
    // service_hook stays installed through the mount: fat.mount walks the FAT
    // over USB transfers (xhci.awaitXfer → serviceHost → this hook), and a big
    // or slow stick must not open an unserviced — unreachable, dead-man-tripping
    // — gap between enumeration and the steady loop.
    if (xhci.blockDev()) |bd| {
        if (fat.mount(heap.allocator(), bd)) |vol| {
            vfs.mount("usbdisk", vol.fileSys());
            klog.puts("usbdisk: FAT volume mounted at /usbdisk\n");
            // Boot-log recorder: mirror the trace stream to /usbdisk/bootlog.txt
            // (the flight recorder — survives a crash + a host power-cycle). Needs
            // a pre-seeded bootlog.txt on the stick; absent → skipped, loud, and
            // the trace bus is unaffected. Registers itself as a klog sink.
            if (bootlog.init(vol, buildinfo.build_number)) {
                klog.puts("bootlog: recording to /usbdisk/bootlog.txt\n");
            } else {
                klog.puts("bootlog: /usbdisk/bootlog.txt open/create FAILED — not recording\n");
            }
            // Screenshot sink: /usbdisk/shots/SHOTnnnn.PNG (creates /shots
            // itself; unique name per capture across boots). Additional to the
            // ramdisk copy; loud + skipped on failure.
            if (usbshot.init(vol)) {
                klog.puts("usbshot: captures also saved to /usbdisk/shots/\n");
            } else {
                klog.puts("usbshot: /usbdisk/shots unavailable — stick captures off\n");
            }
        } else |e| {
            klog.puts("usbdisk: FAT mount FAILED: ");
            klog.puts(@errorName(e));
            klog.puts(" — /usbdisk absent this boot\n");
        }
    } else {
        klog.puts("usbdisk: no usable USB stick (absent or refused) — /usbdisk absent\n");
    }
    // service_hook STAYS INSTALLED FOR THE WHOLE RUN — do not null it here.
    //
    // It is tempting to clear it once enumeration is done, on the grounds that the
    // steady loop owns the pumping from here. That is wrong whenever USB does long work
    // INSIDE the session: any port change makes xhci.poll() re-enumerate, and
    // enumeration can spend its entire budget before it returns to the loop.
    //
    // For that whole stretch nothing drains the trace bus, nothing pumps the network,
    // nothing answers a remote reboot and nothing pets the dead-man. The machine goes
    // off the air while being perfectly alive — and a few dead root ports flapping is
    // enough to hold it there indefinitely.
    //
    // The hook costs a handful of early-out checks. Leave it in for good.

    // USB enumeration is done: NOW let the async DHCP bind put frames on the wire
    // (no-op on the -Dheartbeat blocking path, which already has a lease). Held off
    // until here so a DISCOVER broadcast never contended with the IRQ-less xHCI
    // transfer timing mid-bus-walk — that contention tipped lemon's keyboard into
    // never enumerating. The lease now binds during the GPU phase below, before the
    // first present's cadence window, so its backlog ships clear of both.
    net.armDhcp();

    // Ship whatever trace is queued before the GPU phase (SBR + GSP boot on native)
    // where a wedge would otherwise strand the whole queued log. One metered pass;
    // the bring-up pump points keep it flowing from here.
    netdebug.drain();

    if (buildinfo.smp) {
        // SMP: start the schedulers FIRST, then the system task performs the
        // GSP boot + GPU session loop (gpu.bootAtInit, inside systemTask) on
        // whichever core the dispatcher gave it. Doing bootAtInit on the boot
        // stack HERE instead would never reach startBspScheduler: on a native
        // boot bootAtInit enters the GPU session loop and NEVER RETURNS, so the
        // schedulers would stay unstarted and every terminal session would go
        // unscheduled, with keystrokes queued but never drained. smp.start()
        // brings the APs online; startBspScheduler never returns.
        smp.start();
        smp.startBspScheduler(systemTask, commandWorkerTask);
    }

    // Single-core kudos: GSP boot on the boot stack (runs the native session loop
    // until shutdown, or returns immediately on an emulated boot), then run the
    // system loop directly (the N=1 case, unchanged).
    klog.puts(if (native_boot) "boot: gpu bootAtInit (fb-tag/native)\n" else "boot: gpu bootAtInit (no-fb/passthrough)\n");
    gpu.bootAtInit(native_boot);
    pump.systemLoop();
}

/// Create the desktop and its boot layout, failing LOUD: a failure here on
/// native hardware is otherwise a permanent black screen with zero netdebug
/// output, so each path traces a FATAL line and force-flushes it onto the LAN
/// before parking ("Bring-up flush points" — the park means the metered drain
/// never runs, so this is the one chance; this early the PHY may not have
/// settled and the frames can still be lost, but a silent park is guaranteed
/// loss). Shared by both roots: run() above and main_smp_root.runMinimal.
pub fn createBootDesktop(a: std.mem.Allocator) *Desktop {
    const desktop = Desktop.create(a) catch {
        klog.puts("FATAL: desktop init failed\n");
        netdebug.flushNow();
        cpu.park();
    };
    desktop.spawnBootLayout() catch {
        klog.puts("FATAL: boot layout failed\n");
        netdebug.flushNow();
        cpu.park();
    };
    return desktop;
}

// native_boot (firmware-framebuffer present) computed in run(); the SMP system
// task needs it to drive gpu.bootAtInit but takes no args, so it reads it here.
var g_native_boot: bool = false;

/// Scheduler-task wrapper around the system loop (SMP build): the system task's
/// entry, scheduled on whichever core is free like any task. Never returns.
fn systemTask() void {
    klog.puts("smp/diag: system task scheduled\n");
    // Optional self-checking verification task (gated by buildinfo.verify_script).
    // Spawned here so it starts with the scheduler + desktop already up; a no-op
    // in normal builds.
    verifyscript.spawn(pump.desktop);
    // GSP boot + the GPU session loop run HERE, as the scheduled system task;
    // terminal tasks time-share the machine with it under preemption. On a
    // native boot bootAtInit never returns (runs the session loop until
    // shutdown); on an emulated boot it returns and systemLoop drives the desktop.
    klog.puts(if (g_native_boot) "boot: gpu bootAtInit (fb-tag/native, smp)\n" else "boot: gpu bootAtInit (no-fb/passthrough, smp)\n");
    gpu.bootAtInit(g_native_boot);
    pump.systemLoop();
}

/// The command-worker task (SMP): runs any pending shell command for every
/// terminal, yielding between scans so the system task keeps rendering. Because
/// shell.execute itself yields during its waits (timer.sleep, net polls), a slow
/// command on one terminal blocks neither the other terminals' commands nor the
/// UI. Never returns.
fn commandWorkerTask() void {
    // Liveness must be observable (a dead worker silently orphans every
    // terminal's commands): scans and completed commands are surfaced in the
    // periodic dbg dump. The scan count is throttled to one publish per
    // WORKER_PULSE_SCANS iterations — the loop spins far too fast to publish
    // every pass.
    var scans: u64 = 0;
    var cmds: u64 = 0;
    var last_pulse_ms: u64 = 0;
    const self_task = sched.currentTask().?;
    while (true) {
        scans += 1;
        // Self-check: this task's own struct must still describe it. Checking
        // from the victim's own loop brackets any stray write into live Task
        // memory to within one scan of the serialized trace.
        if (self_task.name[0] != 'c' or @atomicLoad(sched.TaskState, &self_task.state, .monotonic) != .running) {
            klog.puts("WORKER TASK OVERWRITTEN mid-run: name0=");
            klog.putHex(self_task.name[0]);
            klog.puts(" state=");
            klog.putHex(@intFromEnum(@atomicLoad(sched.TaskState, &self_task.state, .monotonic)));
            klog.puts("\n");
            while (true) asm volatile ("pause");
        }
        if (pump.desktop.runPendingCommands()) {
            cmds += 1;
            debug.setNum(.ui, "worker.cmds", cmds);
        }
        const now_ms = timer.millis();
        if (now_ms -% last_pulse_ms >= WORKER_PULSE_MS) {
            last_pulse_ms = now_ms;
            debug.setNum(.ui, "worker.scans", scans);
        }
        smp.yieldCpu();
    }
}

/// Worker scan-counter publish period — coarse on purpose: the value exists to
/// answer "is the worker still scanning at all", not to measure its rate.
const WORKER_PULSE_MS: u64 = 5_000;

/// The files the system boots with, baked into the kernel image and copied into the
/// ramdisk at startup.
///
/// This lives in main, not in the storage driver: which files a system ships with is a
/// decision about this system, and a ramdisk that hard-codes a 3D model is a ramdisk
/// that cannot be reused for anything else. A failure here means the heap is already
/// broken at early boot, so it panics rather than booting on with files silently
/// missing.
fn seedRamdisk() void {
    const seeds = .{
        .{ "welcome.txt", @embedFile("ui/assets/welcome.txt") },
        .{ "motd.txt", @embedFile("ui/assets/motd.txt") },
        // The Utah teapot is the boot window's model; the Khronos duck carries an
        // embedded PNG, so it exercises the textured path out of the box.
        .{ "teapot.glb", @embedFile("ui/assets/teapot.glb") },
        .{ "duck.glb", @embedFile("ui/assets/duck.glb") },
        // The default desktop wallpaper (spec R23) — the desktop reads it back
        // through the VFS at GL init, same path a user-chosen image takes.
        .{ "background.png", @embedFile("background_png") },
        // Something to compile the moment the machine is up: `compile hello.zig
        // hello` sends this to the factory (ARCH-012) and `run hello` executes
        // what comes back. It is the same source the host factory tests use, so
        // the sample the user compiles and the sample the gate compiles are one
        // file.
        .{ "hello.zig", @embedFile("hello_zig") },
    };
    inline for (seeds) |s| {
        ramdisk.put(s[0], s[1]) catch @panic("ramdisk: seeding a boot file failed (heap broken at init)");
    }

    // The guest images this build carries (-Dbake), under /ramdisk/virt/<id>/,
    // so a baked guest is a thing the user can SEE and copy rather than a claim
    // the `vm` list makes. Seeded BORROWED (putStatic): the bytes already live
    // in the kernel image and are hundreds of megabytes — a heap copy would pay
    // for them twice and change nothing about them.
    inline for (gueststage.BAKEABLE) |id| {
        if (gueststage.bakedFor(id)) |b| {
            ramdisk.putStatic("virt/" ++ id ++ "/bzImage", b.bzimage) catch
                @panic("ramdisk: seeding a baked guest failed (heap broken at init)");
            ramdisk.putStatic("virt/" ++ id ++ "/initramfs.cpio.gz", b.initramfs) catch
                @panic("ramdisk: seeding a baked guest failed (heap broken at init)");
        }
    }
}
