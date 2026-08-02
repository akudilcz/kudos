//! Per-CPU data block, addressed via the GS base.
//!
//! Each core sets IA32_GS_BASE (MSR 0xC0000101) to point at its own PerCpu, so
//! `self()` returns this core's block with no lock and no core-index lookup. The
//! block holds the core's identity and its scheduler state: what it is running,
//! what is waiting to run, and what is sleeping on its timer. kudos is ring-0
//! only, so SWAPGS is never needed.
//!
//! Nothing here belongs to a particular piece of WORK: a task may run on any core
//! (KRN-009), so a terminal session's rings live with the session, not in a block.

const buildinfo = @import("buildinfo");
const sched = @import("sched.zig");
const cpu = @import("../cpu/cpu.zig");
const acpi = @import("../acpi/acpi.zig");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

/// The MSR that holds this core's GS base. The single named owner;
/// `sched.gsBase()` reads it through here too.
pub const IA32_GS_BASE: u32 = 0xC0000101;

/// One per core. Fixed-size .bss array indexed by core number; each core's GS
/// base is set to &blocks[i] at startup.
pub const PerCpu = struct {
    self_ptr: *PerCpu, // first field: GS-relative self reference
    cpu_index: u32, // 0 = BSP/core 0
    lapic_id: u32,
    is_bsp: bool,

    // Scheduler state (sched.zig owns the semantics).
    current: ?*sched.Task = null,
    idle: ?*sched.Task = null,
    run_queue: sched.RunQueue = .{},
    /// Guards `run_queue` AND this core's bit in the scheduler's idle mask —
    /// deliberately one lock over both. Any core may now enqueue onto any other
    /// core (KRN-009/010), so the queue can no longer be owner-only; and the
    /// decision "this core has nothing to run, mark it idle" must be atomic with
    /// the failed pop that reached it, or an enqueuer could push between the two
    /// and see a core that is not yet flagged idle while that core proceeds to
    /// halt. One lock over both facts is what leaves no such window.
    /// IRQ-safe: the timer and wakeup interrupts reschedule, so every acquisition
    /// from task context masks interrupts.
    run_lock: SpinLock = .{},
    started: bool = false, // scheduler running on this core
    // A task whose entry returned last reschedule (state == .dead), pending
    // stack+struct free. Freed at the START of the NEXT schedule() call on this
    // core — by then we have already switched away from its stack via
    // switchContext, so freeing it (and the Task struct that embeds its
    // Context) is safe; freeing it in the SAME schedule() call that
    // marks it dead would free memory still in use (this core is about to
    // switchContext INTO another task using stack space that may alias it, or
    // OUT of a task whose Context.rsp the free would then dangle). One slot is
    // enough: only one task can go .dead per reschedule.
    zombie: ?*sched.Task = null,

    // CPU utilization stats. TIME accounting, not tick sampling: at each
    // reschedule this core reads the TSC and adds the delta since `last_tsc` to
    // `busy_tsc` if a non-idle task
    // was on-CPU over that interval, else `idle_tsc`. These are MONOTONIC,
    // cumulative since boot — written only by this core (single writer). Measuring
    // real on-CPU time (not what the timer tick catches) makes a fully-pegged core
    // read ~100% regardless of its internal cadence; a tick sampler is
    // Nyquist-biased and can read 50%/0% for a busy core.
    busy_tsc: u64 = 0,
    idle_tsc: u64 = 0,
    // TSC at the previous reschedule on this core; the delta to `rdtsc()` now is
    // attributed to the task that was running over the interval. Written only by
    // this core (in schedule()/tick()); single writer.
    last_tsc: u64 = 0,
    // Tasks sleeping on this core until an absolute TSC deadline (sleepUntilTsc),
    // earliest first. Guarded by `timer_lock`, because a sleeper that wakes EARLY
    // (its terminal closed while it slept) may by then be running on a different
    // core and removes its entry from here across cores. Unbounded: any number of
    // this core's tasks may sleep at once.
    sleepers: sched.SleeperList = .{},
    timer_lock: SpinLock = .{},
    /// The earliest deadline in `sleepers`, or 0 for none — a cache of
    /// `sleepers.earliest()` maintained under `timer_lock`. The reschedule path
    /// reads it on every switch to decide how to arm the timer, and reads it with
    /// a plain atomic load rather than taking the lock: a u64 cannot tear, and a
    /// momentarily stale value only ever costs one early, harmless timer
    /// interrupt that finds nothing due.
    next_deadline_tsc: u64 = 0,
    // Snapshot of the two counters at the previous `ps` read on this core. `ps`
    // reports `Δbusy / (Δbusy + Δidle)` over the interval since the last `ps`, so
    // the figure is RECENT load, not the lifetime average. Written only by
    // core 0's `ps` path (cpuPercentSince); single writer.
    ps_prev_busy: u64 = 0,
    ps_prev_idle: u64 = 0,

    // The task this core has just switched AWAY from, and where it is going.
    // A task's registers live on its stack until switchContext has stored its
    // stack pointer, so the core it is leaving must not enqueue it — another core
    // could pop it and resume it on a context that has not been saved yet. It is
    // parked here instead, and the INCOMING task completes the handover from the
    // far side of the switch, where the save has provably happened (sched.zig,
    // finishSwitch).
    migrate_pending: ?*sched.Task = null,
    migrate_target: u32 = 0,
    /// The task that was on-CPU before the switch this core is completing, so the
    /// incoming task can publish that its context is saved (`Task.on_cpu`).
    prev_task: ?*sched.Task = null,
};

/// Hard cap on cores — the single owner is `acpi.MAX_CPUS` (topology is what
/// bounds the core count). Re-exported here so the fixed per-CPU `.bss` storage and
/// the topology stay in lockstep by construction rather than by a hand-kept "64".
pub const MAX_CPUS = acpi.MAX_CPUS;

var blocks: [MAX_CPUS]PerCpu = undefined;

// Whether the BSP's per-CPU block (and its GS base) is installed. Code that may
// run on the BOOT stack — before startBspScheduler's percpu.init — must check
// this before any GS-based read: pre-init the GS base is whatever the firmware
// left, and dereferencing it is a #GP whose exception dump then recurses (the
// dump itself asks which core it is on). Single-core builds never install GS
// and never read it (indexOrBsp shortcuts), so they count as live from boot.
var bsp_live: bool = !buildinfo.smp;

/// Whether per-CPU state may be read on the current execution path. True once
/// the BSP has run percpu.init; the APs run theirs before any code that asks.
pub fn bspLive() bool {
    return @atomicLoad(bool, &bsp_live, .acquire);
}

/// Whether THIS core's per-CPU block is installed — checked via the GS-base
/// MSR itself, never through GS (which is exactly what may not be valid).
/// The fault-containment path asks this before any `self()`/`index()` read: an
/// exception taken before this core's percpu.init would otherwise dereference
/// whatever GS base the firmware left and recurse inside the exception path.
pub fn selfLive() bool {
    if (comptime !buildinfo.smp) return false;
    const base = cpu.rdmsr(IA32_GS_BASE);
    const lo = @intFromPtr(&blocks[0]);
    const hi = @intFromPtr(&blocks[0]) + @sizeOf(@TypeOf(blocks));
    return base >= lo and base < hi;
}

/// Initialize core `index`'s block and install its GS base. Called once per core
/// (BSP for itself, each AP in apEntry). After this, `self()` works on that core.
pub fn init(cpu_index: u32, lapic_id: u32, is_bsp: bool) *PerCpu {
    const b = &blocks[cpu_index];
    b.* = .{
        .self_ptr = b,
        .cpu_index = cpu_index,
        .lapic_id = lapic_id,
        .is_bsp = is_bsp,
    };
    cpu.wrmsr(IA32_GS_BASE, @intFromPtr(b));
    if (is_bsp) @atomicStore(bool, &bsp_live, true, .release);
    return b;
}

/// This core's PerCpu, read through GS:[0] (the self_ptr field).
pub inline fn self() *PerCpu {
    return asm volatile ("mov %%gs:0, %[r]"
        : [r] "=r" (-> *PerCpu),
    );
}

/// This core's index (0 = BSP).
pub inline fn index() u32 {
    return self().cpu_index;
}

/// This core's index, or 0 on the single-core build — which installs no per-CPU
/// GS base, so `self()` cannot be read there and `index()` would fault. The one
/// safe way to ask "which core am I on?" from code compiled into both builds.
pub inline fn indexOrBsp() u32 {
    return if (buildinfo.smp) index() else 0;
}

/// This core's index for a FATAL path, safe whatever state GS is in: the index
/// when this core's block is provably installed (selfLive validates the GS-base
/// MSR without dereferencing it), else 0 — a pre-percpu fault is a boot-path
/// fault on the bootstrap core, which slot 0 names correctly, and the
/// single-core build has only core 0 to name.
pub fn indexOrZero() u32 {
    return if (selfLive()) index() else 0;
}

/// Another core's PerCpu block by index — how a core places work on a neighbour
/// (under that neighbour's `run_lock`) and how the diagnostics read every core's
/// state.
pub fn at(i: u32) *PerCpu {
    return &blocks[i];
}
