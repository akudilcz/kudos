//! SMP Application-Processor bring-up: copy the real-mode trampoline to low
//! memory and walk each discovered AP through INIT-SIPI-SIPI into long mode.
//!
//! Only compiled into the kudos-smp variant. The BSP runs this after the shared
//! single-core init (interrupts enabled, heap up) so it can allocate per-AP
//! stacks and use the PIT for the INIT/SIPI waits.

const std = @import("std");
const buildinfo = @import("buildinfo");
const klog = @import("../debug/klog.zig");
const acpi = @import("../acpi/acpi.zig");
const lapic = @import("../apic/lapic.zig");
const ioapic = @import("../apic/ioapic.zig");
const cpu = @import("../cpu/cpu.zig");
const mmio = @import("../../drivers/io/mmio.zig");
const tsc = @import("../cpu/tsc.zig");
const timer = @import("../timer/timer.zig");
const heap = @import("../memory/heap.zig");
const percpu = @import("../sched/percpu.zig");
const sched = @import("../sched/sched.zig");
const schedsleep = @import("../sched/sleep.zig");
const idt = @import("../interrupts/idt.zig");
const isr = @import("../interrupts/isr.zig");
const pic = @import("../interrupts/pic.zig");
const counter = @import("../debug/counter.zig");
const crashlog = @import("../debug/crashlog.zig");

// The flat trampoline blob (nasm -f bin), embedded by build.zig.
const trampoline_bin = @embedFile("trampoline_bin");

// Must match trampoline.asm. The blob is assembled `org TRAMPOLINE_BASE` and
// copied verbatim to this physical address (page-aligned, < 1 MiB).
const TRAMPOLINE_BASE: u64 = 0x8000;
const HANDOFF_OFF: u64 = 0x0F00;
const HAND_CR3: u64 = TRAMPOLINE_BASE + HANDOFF_OFF + 0x00;
const HAND_STACK: u64 = TRAMPOLINE_BASE + HANDOFF_OFF + 0x08;
const HAND_ENTRY: u64 = TRAMPOLINE_BASE + HANDOFF_OFF + 0x10;
const HAND_ALIVE: u64 = TRAMPOLINE_BASE + HANDOFF_OFF + 0x18;
const HANDOFF_SIZE: u64 = 0x20; // 3×dq + dd alive + dd pad (trampoline.asm `handoff:`)

comptime {
    // trampoline.asm keeps its own copies of TRAMPOLINE_BASE/HANDOFF_OFF (a flat
    // real-mode blob cannot import Zig constants). The blob is padded so the
    // handoff block is its LAST content — its total size is exactly
    // HANDOFF_OFF + HANDOFF_SIZE. If either side moves the offset (or grows the
    // block) without the other, this fails the build instead of silently writing
    // handoff fields into the middle of trampoline code.
    if (trampoline_bin.len != HANDOFF_OFF + HANDOFF_SIZE)
        @compileError("trampoline.asm layout disagrees with smp.zig: blob size != HANDOFF_OFF + HANDOFF_SIZE");
}

const AP_STACK_SIZE: usize = 16 * 1024;

// AP bring-up timing (TSC busy-waits, not timer.sleep — the BSP is on the
// interrupt-sensitive boot path).
const SIPI_DELAY_US: u64 = 200; // inter-SIPI gap (the protocol needs only a minimum; under KVM the AP starts almost immediately)
const INIT_SETTLE_US: u64 = 10_000; // 10 ms after INIT, before the first SIPI
const AP_ALIVE_POLL_US: u64 = 10_000; // one 10 ms step while polling HAND_ALIVE
const AP_ALIVE_POLL_STEPS: u32 = 10; // up to ~100 ms (10 × 10 ms) for an AP to signal
const AP_COUNT_POLL_US: u64 = 1_000; // one 1 ms step while waiting for alive APs to count in
const AP_COUNT_POLL_STEPS: u32 = 100; // up to ~100 ms for cores_online to reach the alive count

// Count of cores that have reached long mode (BSP + each AP that signalled). The
// BSP counts itself; each AP increments this in apEntry after its alive flag.
var cores_online: u32 = 1;

// Next sequential core index handed to APs (0 = BSP, reserved). Each AP claims
// the next index atomically in apEntry so per-CPU blocks are densely numbered.
var next_cpu_index: u32 = 1;

// ── fault containment (KRN-006) ─────────────────────────────────────────────
//
// A panicking/faulting AP retires ITSELF: it records the task it was running,
// sets its bit here, and parks. The desktop drains the record and closes the
// window of whatever session that task belonged to; the core is never handed
// work again — retired, not recycled. The desktop and every other session
// continue untouched.
//
// The TASK is what is recorded, not just the core. A task may run on any core
// and may have arrived on the faulting one an instant earlier (KRN-011), so the
// core number no longer identifies whose work died.

var faulted_mask: u64 = 0;
var faulted_task: [percpu.MAX_CPUS]?*sched.Task = [_]?*sched.Task{null} ** percpu.MAX_CPUS;
var cnt_session_faults = counter.Counter{ .mod = .smp, .name = "session_faults" };
var cnt_faults_registered = false;

/// Called ON the faulting core, from the panic/fault handler. Lock-free and
/// allocation-free — the caller is about to park a broken core.
pub fn reportFault(core: u32) void {
    // Published BEFORE the mask bit, so a drainer that observes the bit is
    // guaranteed to see the task that goes with it.
    @atomicStore(?*sched.Task, &faulted_task[core], percpu.self().current, .release);
    _ = @atomicRmw(u64, &faulted_mask, .Or, @as(u64, 1) << @intCast(core), .acq_rel);
    cnt_session_faults.inc();
}

/// Contain a panic or CPU fault on a non-BSP core (KRN-006) — shared by the
/// panic handler (src/main_root.zig) and the fault dispatcher (isr.zig): report the
/// task so the desktop retires its session and closes its window, seal this
/// core's crash record, then park the broken core with interrupts masked.
/// Returns (a no-op) on the bootstrap core and on the single-core build, where
/// the caller owns the crash-hold + reboot path. Like every fatal path this
/// writes only to the crash record, never the trace bus (crashlog.zig); the
/// sealed record is passive state ANY live core's drain ships, so it depends
/// neither on this core nor on where the system task happens to be hosted
/// (KRN-011 — it may be right here).
pub fn containIfAp() void {
    if (comptime !buildinfo.smp) return;
    // Before this core's per-CPU block exists, `index()` would dereference
    // whatever GS base the firmware left — a recursive fault inside the fault
    // path. A pre-percpu exception is a boot-path failure on the bootstrap
    // core: return and let the caller's crash-hold + reboot run.
    if (!percpu.selfLive()) return;
    if (percpu.index() == 0) return;
    reportFault(percpu.index());
    // Retire the core from scheduling BEFORE parking it. Otherwise placement
    // keeps choosing it — preferentially, if it was idle when it died — and every
    // task sent there is stranded on a processor that will never run again.
    sched.markOffline(percpu.index());
    // And from the tick rotation: a tick aimed at a parked core is never
    // serviced and never rotates onward — tick delivery (timer.now, and the
    // tick-paced leg of sleep) would stall on this core's corpse. The wall
    // clock itself is TSC-derived (timer.millis via uptime.zig) and survives.
    ioapic.dropFromRotation(percpu.self().lapic_id);
    // Name what was lost: "contained" retires the CORE, but it also buries the
    // TASK that was aboard — and if that task is the system loop or the
    // cmd-worker, the desktop is NOT unaffected; it is dead (the drain-pump
    // deadman then says so machine-wide). The honest record names the corpse.
    crashlog.puts(percpu.index(), "*** AP fault contained: core retired; task lost: ");
    if (percpu.self().current) |t| crashlog.puts(percpu.index(), t.nameSlice()) else crashlog.puts(percpu.index(), "?");
    crashlog.puts(percpu.index(), "\n");
    crashlog.seal(percpu.index());
    cpu.parkMasked();
}

/// Drain one faulted core (clears its bit), or null when none.
pub fn takeFaultedCore() ?u32 {
    while (true) {
        const m = @atomicLoad(u64, &faulted_mask, .acquire);
        if (m == 0) return null;
        const core: u6 = @intCast(@ctz(m));
        const bit = @as(u64, 1) << core;
        if (@cmpxchgWeak(u64, &faulted_mask, m, m & ~bit, .acq_rel, .acquire) == null)
            return core;
    }
}

/// Drain one faulted core and report the TASK it was running, or null when none
/// is pending. What the desktop needs in order to close the right window: the
/// core number identifies nothing now that tasks move between cores. A faulted
/// core with no recorded task (it faulted before its scheduler was up) is
/// skipped rather than reported as a null task, so the caller never has to
/// distinguish "no fault" from "a fault by nobody".
pub fn takeFaultedTask() ?*sched.Task {
    while (takeFaultedCore()) |core| {
        if (@atomicLoad(?*sched.Task, &faulted_task[core], .acquire)) |t| {
            @atomicStore(?*sched.Task, &faulted_task[core], null, .release);
            return t;
        }
    }
    return null;
}

/// Register the fault counter (core 0, once, at SMP bring-up).
pub fn registerFaultCounter() void {
    if (!cnt_faults_registered) {
        cnt_faults_registered = true;
        counter.register(&cnt_session_faults);
    }
}

/// Number of cores online (BSP + APs that reached long mode). The terminal cap.
pub fn coresOnline() u32 {
    return @atomicLoad(u32, &cores_online, .acquire);
}

// Scheduling quantum (preemption slice), in milliseconds — the tickless
// TSC-deadline slice.
const QUANTUM_MS: u64 = 10;

/// One-time clock setup on the BSP, before any AP arms its timer: learn the TSC
/// frequency and enable tickless TSC-deadline preemption. The PIT remains the
/// wall-clock (timer.now/millis/sleep). TSC-deadline is REQUIRED — the target CPU
/// has it (CPUID.1:ECX[24]); if it is ever absent we panic rather than run a
/// degraded timer.
fn setupTimers() void {
    tsc.init(); // tsc_hz via CPUID 0x15/0x16 or PIT measurement
    if (!tsc.deadlineSupported()) {
        @panic("CPU lacks the TSC-deadline timer (CPUID.1:ECX[24]); required for preemption");
    }
    schedsleep.enableTickless(QUANTUM_MS);
    klog.puts("lapic: tickless TSC-deadline preemption\n");
}

/// Arm this core's scheduler timer (called once per core at scheduler start): put
/// the LVT timer into TSC-deadline mode and arm the first quantum.
fn armCoreTimer() void {
    lapic.useTscDeadline(isr.LAPIC_TIMER_VECTOR);
    tsc.armDeadline(tsc.rdtsc() + tsc.msTicks(QUANTUM_MS));
}

/// Bring the per-core scheduler up on the current core: per-CPU block, IDT,
/// LAPIC timer preemption, an idle task, and the supervisor task. Never returns.
fn startCoreScheduler(cpu_index: u32, lapic_id: u32, is_bsp: bool) noreturn {
    _ = percpu.init(cpu_index, lapic_id, is_bsp);

    // Idle task: hlt-loops when the run queue is empty.
    const idle = sched.spawnOn(cpu_index, "idle", idleLoop) catch @panic("smp: failed to spawn idle task");
    percpu.self().idle = idle;

    // Start the per-core LAPIC timer so preemption fires on THIS core, then run.
    armCoreTimer();
    // IF stays OFF until the first task enables it itself (taskBootstrap does
    // `sti`; idle's loop is `sti; hlt`). A pre-start `sti` would open a window for
    // the LAPIC deadline to fire between start()'s `started = true` and its
    // switchContext, and that schedule() would clobber idle's primed context with
    // a mid-bootstrap RSP.
    sched.start(idle);
}

/// The idle task's body: run when a core's run queue is empty. Halts the core
/// until the next interrupt (wakeup IPI, timer, or device IRQ) so an unloaded
/// core sits at ~0% instead of busy-spinning.
fn idleLoop() void {
    // `sti` and `hlt` MUST be adjacent: if a wakeup
    // IPI or timer event is asserted in the window just before the
    // halt, x86 makes `hlt` return immediately (an interrupt pending at `hlt` wakes
    // it). `sti` then re-mask is unnecessary — once the handler reschedules to a
    // runnable task we never return here; if we do return here the core had nothing
    // to run, so we simply halt again. Keeping `sti` each iteration guarantees IF
    // is on regardless of how we were entered.
    while (true) asm volatile ("sti; hlt" ::: .{ .memory = true });
}

/// Minimal core-0 scheduler for the trace-only scaffold: per-CPU block, idle
/// task, the caller's synthetic system task (`system_entry` — main_smp's
/// minSystemTask) and the #0 supervisor — no cmd-worker, no real input, so the
/// scheduler + cross-core terminal path can be isolated over the trace bus
/// without USB (src/main_smp_root.zig runMinimal). Never returns.
pub fn startBspMinimal(system_entry: *const fn () void) noreturn {
    _ = cpu.irqSave(); // same pre-start clobber window as startBspScheduler
    const lapic_id = lapic.id();
    _ = percpu.init(0, lapic_id, true);
    klog.puts("MIN: BSP percpu.init done\n");

    const idle = sched.spawnOn(0, "idle", idleLoop) catch @panic("smp: failed to spawn idle task");
    percpu.self().idle = idle;
    sched.dispatchDeferred(); // anything the boot path dispatched pre-scheduler
    // The BSP runs a system-like task: drains every session's req ring, renders,
    // and injects synthetic keystrokes to exercise the terminal path over the
    // trace (no USB). Terminal tasks are spawned by session.open() as windows
    // appear. Like every non-idle task it has no core of its own — the
    // dispatcher places it (KRN-009); on this single-scheduled-core minimal
    // scaffold that is core 0 by arithmetic, not by reservation.
    const sys = sched.spawn("min-system", system_entry) catch @panic("smp: failed to spawn min-system task");
    sched.dispatch(sys);
    klog.puts("MIN: BSP tasks spawned; starting LAPIC timer + scheduler\n");

    armCoreTimer();
    // No `sti` before start — see startCoreScheduler for the clobber window.
    sched.start(idle);
}

/// Move the wall-clock tick (PIT, ISA IRQ0) off the legacy PIC/LINT0 path —
/// which can only ever reach the BSP — and onto the IO-APIC, rotating across
/// every online core so no core owns the clock interrupt (KRN-012, ARCH-016).
/// Runs on the BSP with IF=0, after every core's scheduler state exists.
/// Ordering: silence BOTH legacy deliveries first, then unmask the IO-APIC
/// entry, so the same PIT edge can never arrive twice. On a machine with no
/// IO-APIC (or APIC ids an RTE cannot address) the PIC path simply stays — a
/// system boundary, reported, not papered over.
fn routeTickToAllCores() void {
    if (!ioapic.available()) {
        klog.puts("ioapic: none discovered; tick stays on the PIC (BSP)\n");
        return;
    }
    // Membership is join-based: every AP enrolled itself in sched.start once
    // its per-CPU state was published, and this core (the BSP) joins in its own
    // sched.start moments from now — so the rotation never captures an
    // uninitialized LAPIC id, and a straggler core still joins later.
    const isa_irq0 = ioapic.isaRoute(0);
    pic.setMask(0);
    lapic.maskLint0();
    if (ioapic.enableTickRotation(isa_irq0.gsi, ioapic.TICK_VECTOR, isa_irq0.active_low, isa_irq0.level_triggered)) {
        var msg: [64]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&msg, "ioapic: tick on gsi {d} rotating over the online cores\n", .{isa_irq0.gsi}) catch "ioapic: tick rotating\n");
    } else {
        // Put the legacy path back rather than losing the clock: unmask the PIC
        // line and restore LINT0's ExtINT delivery — narrowly, NOT a full
        // lapic.enable, which would also mask the LVT timer out from under the
        // deadline armCoreTimer is about to (or already did) program.
        lapic.extIntLint0();
        pic.clearMask(0);
        klog.puts("ioapic: tick routing failed; tick stays on the PIC (BSP)\n");
    }
}

/// Turn the BSP (core 0) into a scheduled core, symmetric with the APs: per-CPU
/// block, idle task, the SYSTEM task (`system_entry`, the system process loop),
/// and the command worker. Terminal tasks belong to sessions (session.open())
/// and float across cores like everything else (KRN-009). Never returns. Called
/// by the SMP root after bringUpAps.
pub fn startBspScheduler(system_entry: *const fn () void, command_worker: *const fn () void) noreturn {
    // Interrupts OFF for the whole bring-up, exactly like an AP (which arrives
    // from the trampoline with IF=0): the APs are already online, so from the
    // moment sched.start publishes this core in the masks a wakeup IPI could
    // otherwise land between the online-store and switchContext and clobber the
    // primed idle context (the documented pre-start window — it is only closed
    // if IF really is 0 here). The first task's own `sti` re-enables.
    _ = cpu.irqSave();
    klog.puts("smp/diag: startBspScheduler entered\n");
    const lapic_id = lapic.id();
    _ = percpu.init(0, lapic_id, true);
    klog.puts("smp/diag: BSP percpu.init done; spawning core-0 tasks\n");

    const idle = sched.spawnOn(0, "idle", idleLoop) catch @panic("smp: failed to spawn idle task");
    percpu.self().idle = idle;

    // First place anything the boot path dispatched before the scheduler
    // existed (the boot layout's terminal session task).
    sched.dispatchDeferred();

    // The system task (the "system process"): owns rendering, input, drivers.
    // It floats like any task (KRN-009/ARCH-016) — the devices it pumps are
    // MMIO, reachable from every core; nothing it does is core-0 work. The APs
    // are already online, so it may well start there before this core's
    // scheduler even runs.
    const sys = sched.spawn("system", system_entry) catch @panic("smp: failed to spawn system task");
    sched.dispatch(sys);

    // The command worker: runs pending shell commands for every terminal,
    // yielding during command waits so the system task keeps rendering. Floats
    // for the same reason.
    const worker = sched.spawn("cmd-worker", command_worker) catch @panic("smp: failed to spawn cmd-worker task");
    sched.dispatch(worker);

    klog.puts("smp/diag: core-0 tasks spawned; starting LAPIC timer + scheduler\n");
    routeTickToAllCores();
    armCoreTimer();
    // No `sti` before start — see startCoreScheduler for the clobber window.
    sched.start(idle);
}

/// Yield this core's CPU to the scheduler (the system task calls this instead of
/// `hlt` so core 0's #0> terminal task also runs). Thin re-export of sched.yield.
pub fn yieldCpu() void {
    sched.yield();
}

// Topology discovered by init(), consumed by bringUpAps(). Stored here so the
// shared run() body can drive bring-up without threading it through the call.
var topology: acpi.Topology = undefined;
var have_topology: bool = false;

/// Discover topology and enable the BSP's LAPIC. Called by the SMP root before
/// the shared bring-up. Logs the discovered cores. Safe before heap/interrupts
/// (pure physical reads + MSR writes).
pub fn init() void {
    registerFaultCounter();
    // Tick waits yield through the scheduler once it is live (waitYield gates
    // per call, so installing at bring-up is safe): the hook, not an import, is
    // what keeps the timer below the scheduler in the layering.
    timer.wait_hook = &sched.waitYield;
    if (acpi.discover()) |topo| {
        topology = topo;
        have_topology = true;
        ioapic.init(&topology);
        lapic.enable(topo.lapic_address, true); // BSP: keep PIC delivery via LINT0 until the IO-APIC takes over
        var msg: [80]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&msg, "lapic: BSP id={d} mode={s}\n", .{
            lapic.id(), if (lapic.isX2()) "x2apic" else "xapic",
        }) catch "lapic: BSP enabled\n");
        klog.puts(std.fmt.bufPrint(&msg, "smp: {d} usable cores discovered\n", .{
            topo.usableCount(),
        }) catch "smp: ? cores\n");
    } else {
        klog.puts("smp: ACPI unavailable; running single-core (BSP only)\n");
    }
}

/// Bring up APs using the topology discovered by init(). No-op if discovery
/// failed (single-core fallback at a true system boundary — no ACPI tables).
pub fn start() void {
    if (have_topology) bringUpAps(&topology);
}

/// The 64-bit entry every AP reaches from the trampoline. Sets up this core's
/// LAPIC, then runs the per-core scheduler; from that point the core takes any
/// runnable task the dispatcher sends it (KRN-009).
export fn apEntry() callconv(.c) noreturn {
    // The trampoline already set the alive flag (so the BSP can release the
    // handoff slot); enable this core's LAPIC and count in. APs mask LINT0 (they
    // service no legacy PIC IRQs).
    lapic.enable(topology.lapic_address, false);
    const lapic_id = lapic.id();
    const cpu_index = @atomicRmw(u32, &next_cpu_index, .Add, 1, .acq_rel);
    _ = @atomicRmw(u32, &cores_online, .Add, 1, .acq_rel);

    // Load the (shared, BSP-built) IDT on this core so it can take its LAPIC
    // timer interrupt, then run the per-core preemptive scheduler. Never returns.
    idt.init();
    startCoreScheduler(cpu_index, lapic_id, false);
}

/// Bring every usable AP from the topology online. Runs on the BSP.
pub fn bringUpAps(topo: *const acpi.Topology) void {
    // Calibrate the LAPIC timer once (against the PIT) before the APs need it.
    setupTimers();

    // Copy the trampoline blob to its fixed low-memory home (identity-mapped).
    const dst: [*]u8 = @ptrFromInt(TRAMPOLINE_BASE);
    @memcpy(dst[0..trampoline_bin.len], trampoline_bin);

    const cr3 = cpu.readCr3();
    const entry_addr = @intFromPtr(&apEntry);
    const bsp_id = lapic.id();
    const a = heap.allocator();

    const tramp_page: u8 = @intCast(TRAMPOLINE_BASE >> 12); // SIPI vector

    var aps_started: u32 = 0; // APs that signalled alive (each must also count in)
    for (topo.cpus[0..topo.cpu_count]) |ap| {
        if (!ap.usable) continue;
        if (ap.apic_id == bsp_id) continue; // skip ourselves (the BSP)

        // Allocate this AP's stack; hand off CR3, stack top, entry, clear alive.
        // OOM here is a boot-time misconfiguration (heap too small for the
        // discovered topology), not a runtime condition to degrade around — a
        // silently missing core is indistinguishable from a hardware fault
        // (a missing AP is not a degraded mode).
        const stack = a.alloc(u8, AP_STACK_SIZE) catch
            @panic("smp: OOM allocating AP stack");
        const stack_top = @intFromPtr(stack.ptr) + AP_STACK_SIZE;
        mmio.write64(HAND_CR3, cr3);
        mmio.write64(HAND_STACK, stack_top);
        mmio.write64(HAND_ENTRY, entry_addr);
        mmio.write32(HAND_ALIVE, 0);

        // INIT (assert+deassert) -> 10 ms -> SIPI -> 200 µs -> second SIPI -> wait.
        // All delays are TSC busy-waits (tsc.udelay), NOT timer.sleep: we are on the
        // BSP bring-up path where entering the scheduler / relying on the PIT tick +
        // IF=1 during this interrupt-sensitive window is unsafe, and the TSC is
        // already calibrated (setupTimers, above).
        lapic.sendInit(ap.apic_id);
        tsc.udelay(INIT_SETTLE_US); // 10 ms post-INIT
        lapic.sendStartup(ap.apic_id, tramp_page);
        tsc.udelay(SIPI_DELAY_US); // inter-SIPI gap

        if (mmio.read32(HAND_ALIVE) == 0) {
            lapic.sendStartup(ap.apic_id, tramp_page); // second SIPI
            // Wait up to ~100 ms for the AP to reach long mode and signal alive,
            // in 10 ms TSC-busy steps (same reason as above — no timer.sleep here).
            var waited: u32 = 0;
            while (mmio.read32(HAND_ALIVE) == 0 and waited < AP_ALIVE_POLL_STEPS) : (waited += 1) tsc.udelay(AP_ALIVE_POLL_US);
        }

        var msg: [64]u8 = undefined;
        if (mmio.read32(HAND_ALIVE) != 0) {
            klog.puts(std.fmt.bufPrint(&msg, "smp: core apic={d} online\n", .{ap.apic_id}) catch "smp: core online\n");
            aps_started += 1;
        } else {
            // A discovered-usable AP that never reached long mode is a boot
            // failure, not a degraded mode: panicking here
            // reports it loudly over the trace instead of shipping a desktop
            // that is mysteriously one terminal short.
            klog.puts(std.fmt.bufPrint(&msg, "smp: core apic={d} FAILED to start\n", .{ap.apic_id}) catch "smp: core failed\n");
            @panic("smp: an AP failed to start (see apic id above)");
        }
    }

    // Wait for every alive AP to finish counting in (the window between the
    // trampoline's alive store and apEntry's cores_online increment). A BOUNDED
    // TSC-timed poll on the counter itself — not a fixed pause-spin, which is
    // CPU-frequency-dependent and synchronizes nothing. Busy-wait (not
    // timer.sleep): still on the BSP boot path, no per-CPU GS yet, must not
    // enter the scheduler.
    const expected: u32 = 1 + aps_started; // BSP + every AP that signalled alive
    var settle: u32 = 0;
    while (@atomicLoad(u32, &cores_online, .acquire) < expected and settle < AP_COUNT_POLL_STEPS) : (settle += 1)
        tsc.udelay(AP_COUNT_POLL_US);
    if (@atomicLoad(u32, &cores_online, .acquire) < expected)
        @panic("smp: an alive AP never counted in (hung between trampoline and apEntry)");
    var msg: [48]u8 = undefined;
    klog.puts(std.fmt.bufPrint(&msg, "smp: {d} cores online\n", .{
        @atomicLoad(u32, &cores_online, .acquire),
    }) catch "smp: ? cores online\n");
}
