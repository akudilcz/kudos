//! Real-time deadline sleeps and the tickless preemption timer (KRN-007/008):
//! the per-core sorted sleeper lists, the absolute-deadline sleep primitive,
//! and the LAPIC TSC-deadline arming every reschedule performs. Split from
//! sched.zig along the timer seam: everything here exists to fire the right
//! interrupt at the right TSC value; sched.zig owns what happens when it does.

const sched = @import("sched.zig");
const armpolicy = @import("armpolicy.zig");
const percpu = @import("percpu.zig");
const lockorder = @import("lockorder.zig");
const tsc = @import("../cpu/tsc.zig");
const cpu = @import("../cpu/cpu.zig");

const Task = sched.Task;
const rdtsc = tsc.rdtsc;

// --- TSC-deadline timer arming (see module doc) ------------

/// Preemption quantum in TSC ticks (a few ms). 0 until enableTickless() runs,
/// which is also the guard that armPreemption uses to no-op before the timer is
/// set up (schedule() can run during early bring-up).
var quantum_tsc: u64 = 0;

/// Enable tickless TSC-deadline preemption with a `quantum_ms` slice. Called once
/// at boot (after tsc.init). Sets the quantum every core's armPreemption uses.
pub fn enableTickless(quantum_ms: u64) void {
    quantum_tsc = tsc.msTicks(quantum_ms);
}

/// Arm the next preemption deadline for the core now running `next`. Tickless
/// only:
///   - the idle task arms nothing — the core sleeps until a wakeup IPI or device
///     IRQ (zero polling);
///   - a runnable task gets a fresh `now + quantum` deadline so it is preempted for
///     fairness — UNLESS the task has a nearer real-time deadline still in the
///     future (`next_deadline_tsc`, set by sleepUntilTsc), in which case that wins.
/// `next_deadline_tsc` is honoured only while it is in the future; a past value is
/// stale (its interrupt already fired) and is ignored, so it can never re-arm a
/// deadline in the past and storm the core.
pub fn armPreemption(pc: *percpu.PerCpu, next: *Task) void {
    if (quantum_tsc == 0) return; // timer not set up yet (early bring-up)
    const now = rdtsc();
    // The earliest sleeper's wake time on this core, or 0 for none. Maintained
    // under `timer_lock`, read here without it: a stale value costs at most one
    // timer interrupt that finds nothing due, and taking a lock on every context
    // switch to avoid that would cost far more.
    const rt = @atomicLoad(u64, &pc.next_deadline_tsc, .acquire);
    // The idle-vs-runnable arming rules — including why an already-due sleeper
    // still arms — live in armpolicy.choose, where the host tests hold them.
    switch (armpolicy.choose(next == pc.idle, now, rt, quantum_tsc)) {
        .disarm => tsc.disarmDeadline(),
        .arm => |dl| tsc.armDeadline(dl),
    }
}

/// Remove `t` from whatever sleeper list still links it — the fault path's
/// teardown. A task killed by exitFromFault can die inside sleepUntilTsc's
/// windows (after `insert`, before its own removal); freeing the Task while a
/// timer list links it would hand a later tick's popDue freed memory. Attempted
/// removal is a no-op when the task is on no list, so this is safe to call for
/// every fault death.
pub fn abandonSleeper(t: *Task) void {
    const home = percpu.at(t.sleep_core);
    const if_was = home.timer_lock.acquireIrqSave();
    lockorder.acquired(.timer);
    if (home.sleepers.remove(t)) {
        @atomicStore(u64, &home.next_deadline_tsc, home.sleepers.earliest() orelse 0, .release);
    }
    lockorder.released(.timer);
    home.timer_lock.releaseIrqRestore(if_was);
}

// --- real-time periodic sleep ----------------------------------------------

/// Sleep the current task until the TSC reaches absolute `deadline_tsc`. With the
/// scheduler live the task BLOCKS (leaves the run queue, the core halts) and the
/// LAPIC TSC-deadline timer wakes it within microseconds — the basis for a
/// drift-free periodic task. On the single-core build (no per-core scheduler) it
/// busy-waits to the same absolute deadline: still drift-free (the deadline is
/// absolute), just without halting the core.
pub fn sleepUntilTsc(deadline_tsc: u64) void {
    if (rdtsc() >= deadline_tsc) return; // already past — don't sleep
    if (!sched.schedulerLive()) {
        while (rdtsc() < deadline_tsc) asm volatile ("pause");
        return;
    }
    // Mask FIRST, then read which core we are on and which task we are. Both
    // reads must see the same instant: with interrupts on, this task could be
    // moved between them and we would enrol a stranger's task in the sleeper list
    // of a core we no longer occupy.
    const if_was = cpu.irqSave();
    const pc = percpu.self();
    const cur = pc.current.?;
    {
        // Join this core's sleeper list. Any number of tasks may be on it — the
        // list is sorted and unbounded — so there is no slot to find occupied and
        // no earlier sleeper to strand. Under `timer_lock` because this core's
        // own timer ISR walks the same list, and because a task sleeping here may
        // later remove itself from another core.
        pc.timer_lock.acquire(); // interrupts already masked
        lockorder.acquired(.timer);
        cur.sleep_core = pc.cpu_index;
        pc.sleepers.insert(cur, deadline_tsc);
        @atomicStore(u64, &pc.next_deadline_tsc, pc.sleepers.earliest().?, .release);
        lockorder.released(.timer);
        pc.timer_lock.release();
    }
    // No armDeadline here. The reschedule that block() is about to perform arms
    // this core's timer from `next_deadline_tsc` (armPreemption) — and it is the
    // one that runs on the core we actually end up on. Arming here would program
    // the LAPIC of whichever core we happen to be executing on, which after a
    // migration need not be the core holding the list entry.
    cpu.irqRestore(if_was);
    sched.block(deadline_tsc, deadlineReached);
    // We are runnable again — by our deadline (the timer already took our entry
    // off the list) or by an unrelated wake, such as the cancel a closing window
    // sends. The teardown runs either way, because the sleeper cannot tell which
    // happened; `remove` reports whether there was anything to remove.
    //
    // The entry is on the core we SLEPT on, which after a wake need not be the
    // core we are running on now — hence `sleep_core` rather than `self()`.
    // Leaving it would let the timer dereference a task that has since died and
    // been freed.
    const home = percpu.at(cur.sleep_core);
    const home_if_was = home.timer_lock.acquireIrqSave();
    lockorder.acquired(.timer);
    if (home.sleepers.remove(cur)) {
        // The armed deadline is now possibly earlier than anything left on the
        // list. That costs at most one timer interrupt that finds nothing due —
        // cheaper than an inter-processor round trip to re-arm a remote core.
        @atomicStore(u64, &home.next_deadline_tsc, home.sleepers.earliest() orelse 0, .release);
    }
    lockorder.released(.timer);
    home.timer_lock.releaseIrqRestore(home_if_was);
}

/// `block` predicate for sleepUntilTsc: true once the TSC has reached the
/// sleeper's absolute wake deadline — OR the task has been cancelled. Without
/// the cancel clause, a requestCancel wake would re-evaluate this predicate,
/// find the deadline unreached, and re-block until it fires: a window close
/// would then take up to the full sleep period to be observed.
fn deadlineReached(deadline_tsc: u64) bool {
    if (sched.cancelled()) return true;
    return rdtsc() >= deadline_tsc;
}

/// Wake every task on this core whose deadline has passed — this is the interrupt
/// their deadlines armed. All of them, not just the earliest: several can come due
/// between two interrupts, and leaving the rest until the next one is exactly the
/// drift a deadline sleep exists to avoid (KRN-008).
///
/// Each woken sleeper is then PLACED like any other runnable task, so a periodic
/// task is not tied to the core it happened to fall asleep on.
pub fn releaseDueSleepers(pc: *percpu.PerCpu) void {
    if (@atomicLoad(u64, &pc.next_deadline_tsc, .acquire) == 0) return; // nobody sleeping
    const now = rdtsc();
    const if_was = pc.timer_lock.acquireIrqSave();
    lockorder.acquired(.timer);
    while (pc.sleepers.popDue(now)) |t| sched.wake(t);
    @atomicStore(u64, &pc.next_deadline_tsc, pc.sleepers.earliest() orelse 0, .release);
    lockorder.released(.timer);
    pc.timer_lock.releaseIrqRestore(if_was);
}
