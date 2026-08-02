//! The read-only view of tasks and cores (KRN-005): per-task CPU accounting in
//! human units, per-core utilization since the last look, and the consistent
//! per-core task snapshot `ps`, the heads-up display and the verification
//! harness all read. Split from sched.zig along the read seam: nothing here
//! mutates scheduling state beyond the utilization snapshot baselines.

const sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const lockorder = @import("lockorder.zig");
const cpustat = @import("cpustat.zig");
const tsc = @import("../cpu/tsc.zig");

const Task = sched.Task;
const TaskState = sched.TaskState;
const TASK_LABEL_LEN = sched.TASK_LABEL_LEN;

/// This core's CPU utilization as a whole percent (0..100) over the interval
/// **since the previous call** for this core — recent load, not the lifetime
/// average. Reads the monotonic busy/idle **TSC** counters (written only by
/// `pc`'s own reschedule path), differences them against the snapshot from the
/// last call, then advances the snapshot. Called
/// only from core 0's `ps` path, so the snapshot fields have a single writer here.
///
/// Returns `Δbusy / (Δbusy + Δidle)` as a whole percent: a ratio of two TSC
/// deltas, so the (uncalibrated) TSC frequency cancels — no conversion to real
/// time is needed. Because it sums *measured* on-CPU time rather than sampling at
/// the tick, a fully-pegged core reads ~100% regardless of cadence.
///
/// The counters are 64-bit monotonic and read on a different core than the one
/// writing them; a torn read on x86-64 is not possible for an aligned u64. The
/// current task's unflushed slice is excluded (see `taskCpuMs`), which over an
/// inter-`ps` window spanning many quanta is a negligible boundary effect.
pub fn cpuPercentSince(pc: *percpu.PerCpu) u32 {
    const busy = pc.busy_tsc;
    const idle = pc.idle_tsc;
    const pct = cpustat.busyPercent(busy - pc.ps_prev_busy, idle - pc.ps_prev_idle);
    pc.ps_prev_busy = busy;
    pc.ps_prev_idle = idle;
    return pct;
}

/// A snapshot of one task for the `ps` listing.
pub const TaskInfo = struct {
    core: u32,
    name: [TASK_LABEL_LEN]u8,
    activity: [TASK_LABEL_LEN]u8,
    activity_len: usize,
    state: TaskState,
    is_current: bool,
    /// Cumulative on-CPU time in milliseconds, as `taskCpuMs` defines it.
    cpu_ms: u64,

    /// The snapshotted task name up to its NUL terminator, for the `ps` listing.
    pub fn nameSlice(self: *const TaskInfo) []const u8 {
        var n: usize = 0;
        while (n < self.name.len and self.name[n] != 0) n += 1;
        return self.name[0..n];
    }

    /// The current activity label, or empty if the task has none. The length
    /// is CLAMPED to the array: the snapshot copies from a live task that
    /// another core may be mid-writing, so a torn activity_len may cost at
    /// most one garbled label — never a slice running past the array into
    /// whatever memory follows.
    pub fn activitySlice(self: *const TaskInfo) []const u8 {
        return self.activity[0..@min(self.activity_len, self.activity.len)];
    }
};

/// A task's cumulative on-CPU time in milliseconds (its `cpu_tsc` at the
/// calibrated TSC frequency; exact accounting, KRN-005). `cpu_tsc` is flushed at
/// each reschedule, so the slice a running task is mid-way through — at most one
/// quantum — is not yet charged.
pub fn taskCpuMs(t: *const Task) u64 {
    return cpustat.tscToMs(t.cpu_tsc, tsc.hz());
}

/// Snapshot the tasks on core `core_index` into `out`, returning the count. Walks
/// the core's current task, run-queue, deadline sleepers, and idle task — what
/// `ps` prints and what the heads-up display reads per core. Sleepers are part
/// of the listing because a task blocked on a deadline is still alive and owed a
/// wake: hiding it would make a lost sleeper indistinguishable from a finished
/// one.
///
/// Taken under that core's timer lock then run lock (the documented order:
/// `timer_lock` → `run_lock`), so the walk sees consistent chains rather than
/// ones a concurrent enqueue is halfway through splicing. Holding a remote
/// core's locks from a display path is only acceptable because the critical
/// sections they contend with are a few instructions long; the walk itself does
/// no work beyond copying fixed-size fields.
pub fn snapshotTasks(core_index: u32, out: []TaskInfo) usize {
    // A retired core may have faulted while holding its own run lock, which it
    // will now never release. Reading it would hang this core with interrupts
    // masked — the desktop dying of another core's fault, the precise outcome
    // containment exists to prevent. A dead core reports no tasks.
    if (!sched.coreOnline(core_index)) return 0;
    const pc = percpu.at(core_index);
    var n: usize = 0;
    const tif_was = pc.timer_lock.acquireIrqSave();
    lockorder.acquired(.timer);
    defer {
        lockorder.released(.timer);
        pc.timer_lock.releaseIrqRestore(tif_was);
    }
    const if_was = pc.run_lock.acquireIrqSave();
    lockorder.acquired(.run);
    defer {
        lockorder.released(.run);
        pc.run_lock.releaseIrqRestore(if_was);
    }
    const cur = pc.current;

    // current (running) task first.
    if (cur) |c| {
        if (n < out.len) {
            out[n] = .{ .core = core_index, .name = c.name, .activity = c.activity, .activity_len = c.activity_len, .state = c.state, .is_current = true, .cpu_ms = cpustat.tscToMs(c.cpu_tsc, tsc.hz()) };
            n += 1;
        }
    }
    // run-queue (runnable) tasks.
    var t = pc.run_queue.head;
    while (t) |task| : (t = task.next) {
        if (task == cur) continue;
        if (n >= out.len) break;
        out[n] = .{ .core = core_index, .name = task.name, .activity = task.activity, .activity_len = task.activity_len, .state = task.state, .is_current = false, .cpu_ms = cpustat.tscToMs(task.cpu_tsc, tsc.hz()) };
        n += 1;
    }
    // Deadline sleepers (blocked, owed a wake by this core's timer).
    var s = pc.sleepers.head;
    while (s) |task| : (s = task.sleep_next) {
        if (task == cur) continue;
        if (n >= out.len) break;
        out[n] = .{ .core = core_index, .name = task.name, .activity = task.activity, .activity_len = task.activity_len, .state = task.state, .is_current = false, .cpu_ms = cpustat.tscToMs(task.cpu_tsc, tsc.hz()) };
        n += 1;
    }
    // idle task, if not already listed as current.
    if (pc.idle) |idle| {
        if (idle != cur and n < out.len) {
            out[n] = .{ .core = core_index, .name = idle.name, .activity = idle.activity, .activity_len = idle.activity_len, .state = idle.state, .is_current = false, .cpu_ms = cpustat.tscToMs(idle.cpu_tsc, tsc.hz()) };
            n += 1;
        }
    }
    return n;
}
