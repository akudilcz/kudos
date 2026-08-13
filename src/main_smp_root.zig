//! SMP kernel entry (the `kudos-smp` variant). Called from boot/boot.asm in
//! 64-bit long mode with the multiboot2 info pointer in the first argument,
//! exactly like the single-core root.
//!
//! This root brings the Application Processors (APs) online and then runs the
//! shared BSP path. Core 0 (the BSP, "the system process") owns all hardware —
//! framebuffer, IRQs, drivers, compositor, input — and additionally runs its own
//! terminal; each AP runs exactly one terminal task pinned to its core and posts
//! draw/IO requests back to core 0 over a per-core ring.
//!
//! With no APs present this reduces to the single-core kernel — the N=1 case.

const std = @import("std");

/// std.crypto's randomness (TLS session keys) comes straight from hardware
/// RDRAND — the randomness seam's one real implementation
/// (kernel/cpu/entropy.zig). `crypto_always_getrandom` is REQUIRED: without
/// it std caches CSPRNG state in threadlocal storage, and this kernel sets up
/// no thread-local ABI, so the first `std.crypto.random` use faults.
pub const std_options: std.Options = .{};
const buildinfo = @import("buildinfo");
const klog = @import("kernel/debug/klog.zig");
const smp = @import("kernel/smp/smp.zig");
const main = @import("main_root.zig");

// Minimal-path imports: the bare subsystems needed to bring cores online and run
// a per-core scheduler over the trace bus — no framebuffer/desktop/net/usb.
const pmm = @import("kernel/memory/pmm.zig");
const heap = @import("kernel/memory/heap.zig");
const sched = @import("kernel/sched/sched.zig");
const cpu = @import("kernel/cpu/cpu.zig");
const idt = @import("kernel/interrupts/idt.zig");
const pic = @import("kernel/interrupts/pic.zig");
const timer = @import("kernel/timer/timer.zig");
const wallclock = @import("kernel/timer/wallclock.zig");
const mb = @import("kernel/boot/multiboot2.zig");
const framebuffer = @import("ui/screen/framebuffer.zig");
const Desktop = @import("ui/desktop/desktop.zig").Desktop;

extern var __kernel_start: u8;
extern var __kernel_end: u8;

comptime {
    // The two roots are distinguished by the comptime `smp` flag injected by
    // build.zig. If this root were ever built without it, the AP path below would
    // silently no-op — fail loudly instead (CLAUDE.md: no silent misconfig).
    if (!buildinfo.smp) @compileError("main_smp_root.zig must be built with buildinfo.smp = true");
}

/// SMP kernel entry, called from boot.asm in long mode with the multiboot2 info
/// pointer. Discovers topology, brings the APs online, then hands off to the
/// shared BSP path (or the trace-only scaffold when built smp_minimal). The
/// `kudos-smp` counterpart to the single-core `main.kmain`.
export fn kmain(mb_info: u64) callconv(.c) noreturn {
    if (comptime buildinfo.smp_minimal) {
        runMinimal(mb_info);
    }

    // Everything — the trace bus, the SMP topology + BSP LAPIC (smp.init), AP bring-up
    // and the shared BSP path — lives in main.run(), the single owner of the
    // boot/init sequence for both variants.
    main.run(mb_info);
}

/// Minimal trace-only SMP bring-up: NO framebuffer, desktop, net, or USB. Brings
/// the cores online and starts a per-core scheduler whose only task emits a
/// heartbeat over klog. The scaffold for isolating the scheduler — everything
/// else is added back one layer at a time. Never returns.
fn runMinimal(mb_info: u64) noreturn {
    // Self-sufficient: this scaffold bypasses main.run() entirely, so it owns its
    // own trace bring-up.
    klog.installLogSink();
    klog.puts("MIN: minimal SMP path\n");

    // LAYER: framebuffer (init from the multiboot tag, before pmm reserves it).
    const fb = mb.framebuffer(mb_info) orelse {
        klog.puts("MIN: FATAL no framebuffer tag\n");
        cpu.park();
    };
    framebuffer.init(fb, mb_info);
    klog.puts("MIN: framebuffer up\n");

    // Bare memory + interrupt bring-up (heap is needed for AP/task stacks).
    pmm.init(mb_info, @intFromPtr(&__kernel_start), @intFromPtr(&__kernel_end));
    heap.init();
    idt.init();
    pic.remap();
    timer.init();
    wallclock.init();
    idt.enableInterrupts();
    klog.puts("MIN: mem+idt+timer up, interrupts on\n");

    // LAYER: desktop (compositor + boot layout) — but DO NOT spawn terminals as
    // tasks; just bring up the windows so render() has something to draw. We
    // render it once here (pre-scheduler) and again from the BSP heartbeat to
    // test rendering from scheduler context. Create + boot layout + fail-loud
    // live in main.createBootDesktop, shared with the full root.
    const desktop = main.createBootDesktop(heap.allocator());
    desktop.render();
    klog.puts("MIN: desktop up + first render done\n");
    min_desktop = desktop;

    // Discover + enable BSP LAPIC, bring APs online (INIT-SIPI-SIPI).
    smp.init();
    smp.start();
    klog.puts("MIN: cores online; starting per-core scheduler\n");

    smp.startBspMinimal(minSystemTask);
}

/// Set by runMinimal so minSystemTask can render the desktop from scheduler
/// context — the layer under test.
var min_desktop: ?*Desktop = null;

/// Minimal system task: the core-0 "system process" for the scaffold. Drains
/// each terminal's req ring (applying echo/backspace/run to the grid), renders,
/// and injects a synthetic keystroke stream so the cross-core terminal path is
/// exercised deterministically over the trace without USB. Never returns.
fn minSystemTask() void {
    const desktop = min_desktop orelse {
        klog.puts("MIN: no desktop in minSystemTask\n");
        while (true) sched.yield();
    };

    // Spawn a second terminal so one lands on an AP (core 1), exercising the
    // cross-core ring. spawnApp claims the lowest free core.
    desktop.spawnApp(.term) catch |e| {
        var m: [48]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&m, "MIN: spawn term failed: {s}\n", .{@errorName(e)}) catch "MIN: spawn fail\n");
    };
    klog.puts("MIN: spawned a 2nd terminal (should be on an AP)\n");

    // The synthetic input we feed to the focused terminal, one char per tick.
    const script = "help\n";
    var si: usize = 0;
    var ticks: u64 = 0;
    while (true) {
        ticks += 1;

        // Inject one scripted keystroke into the focused terminal's core ring
        // (onKey routes it to that core in the SMP build, exactly like real input).
        if (si < script.len) {
            desktop.onKey(script[si]);
            si += 1;
        }

        // Drain rings + run any pending command + render (what the real system
        // task + command worker do, here folded into one loop for the scaffold).
        _ = desktop.tick();
        _ = desktop.runPendingCommands();
        desktop.render();

        if (ticks % 20 == 0) {
            var m: [48]u8 = undefined;
            klog.puts(std.fmt.bufPrint(&m, "MIN: system tick {d}\n", .{ticks}) catch "MIN: sys\n");
        }
        timer.sleep(50);
    }
}
