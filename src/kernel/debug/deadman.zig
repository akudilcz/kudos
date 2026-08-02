//! Deadman — the machine reports WHERE it is wedged, from the timer interrupt.
//!
//! A core stuck in an unbounded spin is the worst diagnostic case kudos has: the
//! netdebug drain is pumped by the very loops that are now stuck, so the trace goes
//! silent and the machine is indistinguishable from powered-off. From outside,
//! answering the one question that matters — "what address is it spinning at?" —
//! costs emulator register dumps or a bisect over hardware boots.
//!
//! The deadman answers it from inside: the steady loops prove liveness by pumping
//! the trace drain (netdebug.drain calls `alive`), and the timer interrupt — which
//! keeps firing while a loop spins, as long as interrupts are enabled — notices the
//! silence and logs the interrupted instruction pointer plus the frame-pointer
//! backtrace of the wedged code. One line on the wire replaces the bisect.
//!
//! CLOCK: the fuse reads its own time — tsc.millis, inside `alive` and
//! `checkFromIrq` — so no caller can clock it, by construction. A measurement
//! must never be clocked by the quantity it measures: the deadman watches
//! stalled loops, the interrupt-driven tick is itself a thing that stalls
//! (a core can capture the rotating IO-APIC delivery with interrupts masked),
//! and a fuse fed tick-derived time would be blinded by exactly the failure
//! class it exists to report. The free-running TSC cannot stall. Before
//! calibration tsc.millis reads 0 and the fuse stays disarmed — there is no
//! trustworthy window to arm.
//!
//! LIMITS, stated plainly: a wedge with interrupts masked (cli + spin, or a stuck
//! MMIO read) never fires the timer, so this reports nothing — the heartbeat's
//! "lines stopped entirely" signature remains the diagnosis for that case. And the
//! report leaves the box only best-effort (see `distress` below).

const klog = @import("klog.zig");
const backtrace = @import("backtrace.zig");
const tsc = @import("../cpu/tsc.zig");

/// How long a core may go without proving liveness before it is presumed wedged.
/// Long enough that a legitimate long frame or a timer.sleep-heavy bring-up phase
/// (whose waits pump the drain) never trips it.
pub const WEDGE_AFTER_MS: u64 = 2_000;
/// Minimum spacing between wedge reports for one core — the spin is still there
/// on every tick; one line a second documents it without flooding the FIFO.
pub const REPORT_EVERY_MS: u64 = 1_000;

/// Staleness policy — pure (time is passed in), host-tested below.
pub const Policy = struct {
    last_alive_ms: u64 = 0,
    last_report_ms: u64 = 0,
    /// Never report before the first alive(): a core that has not started its
    /// steady loop yet (boot, an AP that never runs one) is not wedged.
    armed: bool = false,

    pub fn alive(self: *Policy, now_ms: u64) void {
        self.armed = true;
        self.last_alive_ms = now_ms;
    }

    /// Should a wedge report fire now? True at most once per REPORT_EVERY_MS
    /// while the core has been silent for WEDGE_AFTER_MS. Mutates the report
    /// clock on true — the caller must actually report.
    pub fn due(self: *Policy, now_ms: u64) bool {
        if (!self.armed) return false;
        if (now_ms -% self.last_alive_ms < WEDGE_AFTER_MS) return false;
        if (self.last_report_ms != 0 and now_ms -% self.last_report_ms < REPORT_EVERY_MS) return false;
        self.last_report_ms = now_ms;
        return true;
    }
};

// Per-core policy slots, sized to the topology cap (acpi.MAX_CPUS is the owner)
// so a high core index is never silently ignored — a watchdog that skips cores
// watches nothing.
const MAX_CORES = @import("../acpi/acpi.zig").MAX_CPUS;
var cores: [MAX_CORES]Policy = .{Policy{}} ** MAX_CORES;

/// Best-effort push of the queued report onto the wire, installed by netdebug
/// (its distressFlush: skip if a normal-context send is mid-flight, else blast
/// the FIFO). Null until netdebug starts — the report still lands in the diag
/// ring and ships whenever anything next drains.
pub var distress: ?*const fn () void = null;

// The drain-pump service watch. The trace drain is pumped by ONE floating
// task (the system loop); its silence means the machine has lost heartbeats,
// counters, KMR1 service, and rendering — a machine-wide fact, not a property
// of whichever core happens to notice. Watched separately from the per-core
// policies so the report names the right entity: a per-core policy alone would
// name whichever core noticed (an idle loop's rip) rather than the dead pump task,
// which may have been on a since-retired core.
//
// NOT a `Policy`: this state is written by the pump task on one core and read
// by every other core's timer interrupt, so each fact is a single atomic —
// 0 = not yet armed. Plain multi-field state would let the report line re-read a
// value the pump has refreshed past the checker's `now`, printing a negative
// quiet_ms for a machine that is fine.
var pump_last_alive_ms: u64 = 0;
var pump_last_report_ms: u64 = 0;
/// The core the pump last ran on — the report's one locating clue.
var pump_last_core: usize = 0;

/// A core's scheduler proves the core is alive: called from `sched.schedule()`
/// on every reschedule, which every core reaches at least once per tick-
/// rotation interval (idle cores included — the rotating wall tick enters the
/// scheduler). Arms EVERY core, so `checkFromIrq`'s per-core report means
/// exactly "this core takes timer interrupts but cannot reach schedule()" —
/// and then the interrupted RIP on this core IS the wedged site.
pub fn aliveCore(core: usize) void {
    const now_ms = tsc.millis();
    if (now_ms == 0) return; // pre-calibration: no window origin to arm
    if (core >= cores.len) return;
    cores[core].alive(now_ms);
}

/// The drain pump proves the SERVICE is alive. Called from netdebug.drain —
/// wherever the pumping task is running (`core` records the location for the
/// report, nothing more). Time comes from the TSC, in here (CLOCK note above).
pub fn alivePump(core: usize) void {
    const now_ms = tsc.millis();
    if (now_ms == 0) return; // pre-calibration; 0 is the unarmed sentinel
    pump_last_core = core;
    @atomicStore(u64, &pump_last_alive_ms, now_ms, .release);
}

/// Timer-interrupt check, two independent verdicts:
///  - this CORE silent past the fuse (never reached schedule()): log the
///    interrupted RIP + backtrace — the wedged code is what the timer
///    interrupted on THIS core, so the attribution is exact;
///  - the drain PUMP silent past the fuse: one machine-wide report naming the
///    service and where it last ran — never the reporting core's frame, which
///    is unrelated to the pump by construction.
/// Bounded: a few klog lines, at most once per REPORT_EVERY_MS per verdict.
pub fn checkFromIrq(core: usize, rip: u64, rbp: u64, rsp: u64) void {
    const now_ms = tsc.millis();
    if (now_ms == 0) return; // pre-calibration: no clock to judge silence by
    if (core >= cores.len) return;
    if (cores[core].due(now_ms)) {
        klog.puts("wedge: core=");
        klog.putHex(core);
        klog.puts(" quiet_ms=");
        klog.putHex(now_ms -% cores[core].last_alive_ms);
        klog.puts(" rip=");
        klog.putHex(rip);
        klog.puts(" rsp=");
        klog.putHex(rsp);
        klog.putc('\n');
        _ = backtrace.emitKlog(@intCast(rbp), @intCast(rsp));
        if (distress) |d| d();
    }
    // The pump verdict may be reached from any core's interrupt. ONE snapshot
    // load feeds both the judgement and the printed figure (never re-read —
    // the pump may refresh between the two); a snapshot at or ahead of this
    // core's clock means the pump just ran (or clocks are skewed) — alive
    // either way; and a cmpxchg on the report clock elects exactly one
    // reporting core per REPORT_EVERY_MS.
    const last = @atomicLoad(u64, &pump_last_alive_ms, .acquire);
    if (last == 0 or now_ms <= last) return; // unarmed, or provably alive
    const quiet = now_ms - last;
    if (quiet < WEDGE_AFTER_MS) return;
    const rep = @atomicLoad(u64, &pump_last_report_ms, .acquire);
    if (rep != 0 and now_ms -% rep < REPORT_EVERY_MS) return;
    if (@cmpxchgStrong(u64, &pump_last_report_ms, rep, now_ms, .acq_rel, .acquire) != null) return;
    klog.puts("wedge: drain-pump quiet_ms=");
    klog.putHex(quiet);
    klog.puts(" last_core=");
    klog.putHex(pump_last_core);
    klog.puts(" (heartbeats/counters/KMR1 ride this service)\n");
    if (distress) |d| d();
}

// ── tests (host: `zig build test`) ────────────────────────────────────────
const std = @import("std");
