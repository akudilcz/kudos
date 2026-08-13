//! PIT channel 0 timer. Drives a millisecond-ish tick.

const io = @import("../io/io.zig");
const isr = @import("../interrupts/isr.zig");
const tsc = @import("../cpu/tsc.zig");
const cpu = @import("../cpu/cpu.zig");
const uptime = @import("uptime.zig");

/// The kernel tick rate: PIT channel 0 fires IRQ0 at this frequency (10 ms per
/// tick). The single owner every tick-denominated cadence derives from.
pub const TICK_HZ: u32 = 100;

/// Scheduler seam for tick waits, installed at SMP bring-up (smp.init points it
/// at sched.waitYield): when set, a sleep's wait step yields this core so its
/// other tasks run; when null (single-core build, SMP never initialised) the
/// wait falls back to hlt/pause. A hook rather than an import — the timer sits
/// below the scheduler and must not call up the stack (the same pattern as
/// power.flush_hook and net.wait_hook).
pub var wait_hook: ?*const fn () void = null;

/// Set once if a `sleep` ever hit its TSC backstop — i.e. the IRQ0 tick stopped
/// advancing while the free-running TSC kept climbing. Latched, never cleared:
/// the moment this is true, every tick-driven timeout in the kernel is a lie and
/// the next diagnosis should start here. Reported by the netdebug heartbeat.
var tick_stalled: bool = false;

/// Set once if `sleep` was ever called with interrupts MASKED — a caller bug (the
/// tick cannot advance, so the sleep is served from the TSC instead of hanging).
/// Latched and reported by the heartbeat, because the symptom on a real machine
/// is an indefinite silent hang with no other evidence.
var slept_irqs_off: bool = false;

pub fn tickStalled() bool {
    return @atomicLoad(bool, &tick_stalled, .monotonic);
}

pub fn sleptIrqsOff() bool {
    return @atomicLoad(bool, &slept_irqs_off, .monotonic);
}

const PIT_HZ: u32 = 1193182;
const CHANNEL0: u16 = 0x40;
const COMMAND: u16 = 0x43;

// The PIT tick counter. Written only by the IRQ0 handler, read by everything that
// waits on wall-clock time. Every access goes through an atomic op (relaxed): the
// counter changes ASYNCHRONOUSLY from an interrupt, so a plain `var` load in a
// busy-wait loop (sleep, and the TSC calibration in cpu/tsc.zig) is free to be
// hoisted out by a ReleaseFast build and spin forever on a cached value. The atomic
// forces the compiler to re-issue the load each iteration — the kernel equivalent
// of Linux's `READ_ONCE(jiffies)`. `.monotonic` is enough: the counter carries no
// ordering obligation to other memory — a reader needs only SOME recent value to
// compare against, and on x86 the RMW's lock prefix makes each increment visible
// machine-wide (the tick may be serviced by any core once the IO-APIC fans it
// out, KRN-012).
var ticks: u64 = 0;
var hz: u32 = 0;

/// Tick handler: bump the tick counter by one. The only writer of `ticks`; the
/// atomic RMW pairs with the relaxed loads in `now`/`millis` (see `ticks`).
/// Registered on the legacy PIC line at init; once the IO-APIC takes over
/// delivery (SMP bring-up), isrDispatch's tick arm calls it directly on
/// whichever core the rotation aimed at.
pub fn tick() void {
    _ = @atomicRmw(u64, &ticks, .Add, 1, .monotonic);
}

/// The 16-bit PIT channel-0 reload value producing the TICK_HZ tick. Comptime:
/// overflowing u16 (a rate below ~19 Hz) fails the build rather than programming
/// a wrong divisor.
const PIT_DIVISOR: u16 = PIT_HZ / TICK_HZ;

/// Program PIT channel 0 for the TICK_HZ square-wave tick and register the IRQ0
/// handler (which unmasks the line). Until this runs, `millis`/`frequency`
/// report 0 (no tick source yet).
pub fn init() void {
    hz = TICK_HZ;
    io.outb(COMMAND, 0x36); // channel 0, lo/hi byte, mode 3 (square wave generator)
    io.outb(CHANNEL0, @truncate(PIT_DIVISOR));
    io.outb(CHANNEL0, @truncate(PIT_DIVISOR >> 8));
    isr.registerIrq(0, tick);
}

/// The raw PIT tick count since boot. Relaxed atomic load so the compiler
/// re-issues it each iteration of a busy-wait (see `ticks`).
pub fn now() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

/// The PIT tick frequency in Hz (ticks per second), as configured by init().
pub fn frequency() u32 {
    return hz;
}

/// Milliseconds since boot — THE wall clock, every ms-denominated timeout's
/// time base. Defined by uptime.ms, whose invariant this call site inherits:
/// no single core's failure can stop the wall clock. Once the TSC is
/// calibrated the value derives from that free-running counter with no
/// interrupt delivery involved, so a core that captures the rotating tick
/// with interrupts masked (KRN-012's delivery path) stalls tick DELIVERY —
/// `now()` — never time itself. Before calibration the tick counter stands in
/// (single-core boot, PIC delivery on the BSP: nothing to capture).
pub fn millis() u64 {
    return uptime.ms(tsc.millis(), @atomicLoad(u64, &ticks, .monotonic), hz);
}

/// Busy-wait at least `ms` milliseconds against the PIT tick. Requires
/// interrupts enabled (the tick advances from IRQ0); used by drivers that need
/// real wall-clock delays — e.g. USB enumeration timing. `hlt`
/// between checks so the wait doesn't peg the CPU.
///
/// The PIT ticks at TICK_HZ (10 ms resolution), so a request is rounded UP to
/// a whole number of ticks and always waits ≥1 tick. That floor is fine for USB:
/// every USB delay is a *minimum* (TRSTRCY ≥10ms, set-address recovery ≥2ms,
/// debounce ≥100ms), so waiting a little longer is always safe.
pub fn sleep(ms: u64) void {
    // INTERRUPTS MASKED → THE TICK CANNOT ADVANCE. Sleeping on the tick here would
    // wait on a counter that nothing can increment, and the `hlt` in the wait step
    // below would park the core with interrupts off — a halt that no interrupt can ever end.
    // That is not a slow sleep. It is a machine that needs its power cut.
    //
    // Sleeping with interrupts masked is always a caller bug (typically a lock held
    // across a code path that sleeps). But the delay itself CAN still be served: the
    // TSC free-runs and needs no interrupt. So honour the delay from the TSC, and latch
    // the mistake for the heartbeat to report — loud and alive beats correct and dead.
    if (!cpu.interruptsEnabled()) {
        @atomicStore(bool, &slept_irqs_off, true, .monotonic);
        if (tsc.hz() != 0) {
            tsc.udelay(ms * 1000);
        } else {
            // Earliest boot: no TSC calibration yet either. A crude bounded spin
            // still beats halting forever.
            var spins: u64 = ms * 100_000;
            while (spins > 0) : (spins -= 1) asm volatile ("pause");
        }
        return;
    }

    const start = now();
    // Round up: (ms*hz + 999)/1000, and never less than one tick.
    var target = (ms * hz + 999) / 1000;
    if (target == 0) target = 1;

    // TSC BACKSTOP — this loop must not be able to wait forever.
    //
    // `now()` only advances from IRQ0, so a stopped tick makes this loop wait
    // forever. The ms-denominated safety nets (millis-deadline budgets, the
    // deadman fuse) ride the TSC and survive a dead tick; this loop is the one
    // wait still paced by raw ticks, so it carries its own bound.
    //
    // The TSC is free-running and cannot stop, so bound the wait by it as well.
    // The bound is deliberately loose (4x the request + 50 ms) so it will not
    // pre-empt a healthy sleep — it is a backstop, not a second timer. When it
    // trips, a dead tick degrades to "sleeps return early, loudly" and the kernel
    // keeps running and stays reachable (KMR1/OP_REBOOT) instead of dying.
    const deadline = if (tsc.hz() != 0) tsc.rdtsc() + tsc.msTicks(ms * 4 + 50) else 0;

    while (now() -% start < target) {
        if (deadline != 0) {
            if (tsc.rdtsc() >= deadline) {
                @atomicStore(bool, &tick_stalled, true, .monotonic);
                return;
            }
            // PAUSE-SPIN, not `hlt`, on the single-core image: `hlt` parks the CPU
            // until an interrupt arrives, so if the tick is what died, we would
            // halt forever and never re-check the deadline above — the backstop
            // would be unreachable precisely when it is needed. Under SMP, the
            // installed wait_hook yields to the scheduler (it does not halt), so
            // the loop keeps turning and the check still runs.
            if (wait_hook) |h| h() else asm volatile ("pause");
        } else {
            // Pre-TSC-calibration (boot's first moments): no trustworthy backstop
            // clock exists yet, so keep the original hlt/yield behavior.
            if (wait_hook) |h| h() else asm volatile ("hlt");
        }
    }
}
