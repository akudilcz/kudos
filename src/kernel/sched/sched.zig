//! Preemptive scheduler: every core equal, work to whichever core is free.
//!
//! Each core has its own run queue, current task, and idle task (held in its
//! PerCpu block), but a task belongs to no core: it is placed on whichever core
//! can run it soonest (KRN-009), moved to an idle core the moment one exists
//! (KRN-010), and may run on a different core each time it is scheduled
//! (KRN-011). The placement policy itself is pure and lives in dispatch.zig; the
//! queue and sleeper structures are pure and live in runqueue.zig. What remains
//! here is the part that cannot be pure: locking, context switching, and the
//! ordering that makes moving a live task between cores safe.
//!
//! A voluntary `yield()` switches via the small callee-saved context switch; the
//! LAPIC timer preempts by calling `tick()` from its IRQ, which schedules at the
//! IRQ return.
//!
//! Lock order, machine-wide, never taken in any other sequence:
//!   `PerCpu.timer_lock` → `Task.lock` → `PerCpu.run_lock`
//! The timer walks sleepers, wakes them, and their wakes place them; nothing ever
//! holds a run lock and then reaches for a task lock, which is what keeps the
//! graph acyclic.

const std = @import("std");
const buildinfo = @import("buildinfo");
const cpu = @import("../cpu/cpu.zig");
const percpu = @import("percpu.zig");
const lockorder = @import("lockorder.zig");
const cpustat = @import("cpustat.zig");
const placement = @import("dispatch.zig");
const runqueue = @import("runqueue.zig");
const heap = @import("../memory/heap.zig");
const klog = @import("../debug/klog.zig");
const deadman = @import("../debug/deadman.zig");
const lapic = @import("../apic/lapic.zig");
const tsc = @import("../cpu/tsc.zig");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;
const counter = @import("../debug/counter.zig");
const stackcanary = @import("stackcanary.zig");
const ioapic = @import("../apic/ioapic.zig");

const task_value = @import("task.zig");

/// The task value definitions (task.zig) — re-exported here because sched IS the
/// public surface of the scheduling layer; callers say `sched.Task`, never
/// reach the value module directly.
pub const STACK_SIZE = task_value.STACK_SIZE;
pub const TASK_LABEL_LEN = task_value.TASK_LABEL_LEN;
pub const Context = task_value.Context;
pub const TaskState = task_value.TaskState;
pub const Task = task_value.Task;

/// Bind the calling task to the core it is running on, and report which that is.
///
/// For work that becomes tied to a processor only once it starts: a guest's
/// virtual processor is placed like any other task (VIRT-021, KRN-009), but the
/// instant its VMCS is loaded it belongs to that physical core and may never move
/// (Intel SDM: a VMCS is current on one logical processor at a time). Calling this
/// before the load is what turns "wherever the scheduler put me" into "here, from
/// now on" — the placement stays free, the binding is the hardware's.
///
/// Interrupts are masked across the read-and-set: without that, this task could
/// be moved between learning which core it is on and recording it, and would then
/// pin itself to a core it is not running on.
pub fn pinHere() u32 {
    const if_was = cpu.irqSave();
    defer cpu.irqRestore(if_was);
    const pc = percpu.self();
    const cur = pc.current.?;
    cur.affinity = pc.cpu_index;
    return pc.cpu_index;
}

/// The task running on the calling core.
///
/// `percpu.self()` yields a pointer to a SPECIFIC core's block, and dereferencing
/// it a moment later is sound only if this task cannot have changed cores in
/// between. It can (KRN-011): a timer interrupt landing between the two loads can
/// hand this task to another processor, and the block we then read belongs to the
/// core we LEFT — whose `current` is by now some other task. Masking interrupts
/// across both loads is what makes "which task am I?" answerable at all.
///
/// Every read of the calling task goes through here. A bare
/// `percpu.self().current` with interrupts enabled is a bug.
pub fn currentTask() ?*Task {
    const if_was = cpu.irqSave();
    defer cpu.irqRestore(if_was);
    return percpu.self().current;
}

/// Mark the calling core's current task as running activity `name` (shown by
/// `ps`). Truncated to the activity buffer. Pair every call with `clearActivity`
/// (a `defer` at the call site) so the label does not outlive the activity.
pub fn setActivity(name: []const u8) void {
    if (!schedulerLive()) return; // no per-CPU scheduler state on single-core
    const cur = currentTask() orelse return;
    const n = @min(name.len, cur.activity.len);
    @memcpy(cur.activity[0..n], name[0..n]);
    cur.activity_len = n;
}

/// Clear the calling core's current task's activity label.
pub fn clearActivity() void {
    if (!schedulerLive()) return;
    const cur = currentTask() orelse return;
    cur.activity_len = 0;
}

/// One core's FIFO of runnable tasks, and its deadline-ordered sleepers. Both
/// structures are pure (runqueue.zig) so their ordering rules host-test on their
/// own; the locking that makes them safe across cores is this file's business —
/// `PerCpu.run_lock` for the queue, `PerCpu.timer_lock` for the sleepers.
pub const RunQueue = runqueue.RunQueue(Task);
pub const SleeperList = runqueue.SleeperList(Task);

// --- machine-wide placement masks (dispatch.zig decides; these are the input) --
//
// One bit per core. `online_mask` is set by a core as its scheduler starts, so
// the scheduler learns the machine from the cores that join it rather than
// importing the SMP layer that brings them up (which imports this one).
// `idle_mask` says which of those cores are currently running nothing — each bit
// written only under that core's own `run_lock`, together with the queue state
// that justifies it.
var online_mask: u64 = 0;
var idle_mask: u64 = 0;

/// Publish that core `core` has a scheduler and may be given work.
fn markOnline(core: u32) void {
    _ = @atomicRmw(u64, &online_mask, .Or, placement.bit(core), .acq_rel);
}

/// Retire core `core`: it has faulted and parked itself with interrupts masked
/// forever, so it must never be given work again.
///
/// Clearing BOTH bits matters. Leaving the online bit would let placement keep
/// choosing a core that will never run anything — every task sent there is
/// stranded silently. Leaving the idle bit is worse: placement PREFERS idle
/// cores, so a dead core would attract work in preference to live ones.
///
/// Called from the faulting core itself, immediately before it parks, so no
/// further scheduling decision on this core can follow.
pub fn markOffline(core: u32) void {
    const bit = placement.bit(core);
    _ = @atomicRmw(u64, &idle_mask, .And, ~bit, .acq_rel);
    _ = @atomicRmw(u64, &online_mask, .And, ~bit, .acq_rel);
}

/// Whether core `core` still has a live scheduler. Diagnostics ask before
/// reading a core's queues: a core that faulted inside `schedule()` holds its own
/// run lock forever, and a reader that waited for it would hang too — taking the
/// desktop down with the core, which is exactly what containment must not do
/// (KRN-006).
pub fn coreOnline(core: u32) bool {
    return (@atomicLoad(u64, &online_mask, .acquire) & placement.bit(core)) != 0;
}

// --- context switch --------------------------------------------------------

/// Switch the current core from `from` to `to`: push callee-saved regs, save RSP
/// into from.rsp (Context.rsp is the first/only field), load to.rsp, pop
/// callee-saved regs, ret — the classic stack-swap. The `ret` lands wherever
/// `to` last called switchContext (or, for a brand-new task, the bootstrap
/// trampoline its stack was primed with).
///
/// Naked so there is NO compiler prologue/epilogue to perturb rsp: the System V
/// ABI hands `from` in rdi and `to` in rsi, and the final `ret` consumes the
/// return address the stack swap exposes.
///
/// Zig cannot call a `naked` function directly, so the implementation is exported
/// under a symbol and invoked through the `switchContext` extern (.C) prototype.
export fn switchContextImpl() callconv(.naked) void {
    // The CR3 load sits BETWEEN saving the old RSP and loading the new one: the
    // incoming task's stack may exist only in the incoming address space (a
    // session task's stack is arena-backed), so the space must be live before
    // its stack is touched. Loaded only when it differs — a CR3 write flushes
    // the TLB, and kernel→kernel switches (the overwhelming majority) must not
    // pay that. RAX/RCX are caller-saved and dead across the call.
    asm volatile (
        \\ push %rbx
        \\ push %rbp
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, (%rdi)
        \\ mov 8(%rsi), %rax
        \\ mov %cr3, %rcx
        \\ cmp %rcx, %rax
        \\ je 1f
        \\ mov %rax, %cr3
        \\1:
        \\ mov (%rsi), %rsp
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbp
        \\ pop %rbx
        \\ ret
    );
}
extern fn switchContext(from: *Context, to: *Context) callconv(.c) void;
comptime {
    @export(&switchContextImpl, .{ .name = "switchContext" });
}

/// Trampoline a fresh task starts at: the new stack is primed so the first
/// switch's `ret` lands here, which then calls the task's entry. If the entry
/// returns, the task is marked dead and the scheduler is re-entered.
fn taskBootstrap() callconv(.c) void {
    // Enter with interrupts ENABLED. A task's first instruction is reached by a
    // switchContext out of schedule(), which always runs with interrupts off — a
    // cooperative yield() masks them around the switch, and a preemptive switch
    // happens inside the LAPIC-timer IRQ (IF cleared by the interrupt gate).
    // switchContext only swaps the stack; it does not touch RFLAGS. So without
    // this a task begins running with IF=0 and nothing to re-enable it, and the
    // first thing that waits on the PIT tick (any timer.sleep — GSP bring-up, USB
    // debounce, the DHCP/DNS waits) blocks forever on a clock that can no longer
    // advance. Only the idle task is exempt, because its own loop does `sti; hlt`.
    // A brand-new task is reached by the same switchContext every other task is,
    // so it owes the core it was switched onto the same debt: publish that the
    // outgoing task's context is saved, and complete any handover it left behind.
    const pc = percpu.self();
    finishSwitch(pc);
    // Read our own identity BEFORE enabling interrupts. After the `sti` this task
    // is preemptible and may be moved to another core; `percpu.self().current`
    // would then name whichever task the core we left picked up — and we would
    // call ITS entry point and later mark IT dead.
    const t = pc.current.?;
    const entry: *const fn () void = @ptrFromInt(t.bootstrap_entry);
    // Births and deaths are traced: a task that dies unexpectedly (its entry
    // returning when it never should) is otherwise invisible — the reaper
    // silently frees it and every consumer of its work just starves.
    klog.puts("task: born ");
    klog.puts(t.name[0 .. std.mem.indexOfScalar(u8, &t.name, 0) orelse t.name.len]);
    klog.puts(" @");
    klog.putHex(@intFromPtr(t));
    klog.puts("\n");
    asm volatile ("sti" ::: .{ .memory = true });
    entry();
    t.state = .dead;
    klog.puts("task: entry returned, dying: ");
    klog.puts(t.name[0 .. std.mem.indexOfScalar(u8, &t.name, 0) orelse t.name.len]);
    klog.puts("\n");
    yield(); // never returns to this task
}

/// Prod every online core to pass through schedule() once. What release paths
/// waiting on a task's REAP use: a zombie is freed on its core's next
/// reschedule, which on an idle core would otherwise wait for the next timer
/// tick — this converts that bound into microseconds. The wakeup vector's
/// handler is exactly a reschedule, so no new vector is needed.
pub fn rescheduleAll() void {
    if (comptime !buildinfo.smp) return;
    if (!percpu.bspLive()) return;
    const self_idx = percpu.indexOrBsp();
    var i: u32 = 0;
    while (i < percpu.MAX_CPUS) : (i += 1) {
        if (i == self_idx or !coreOnline(i)) continue;
        lapic.sendFixedIpi(percpu.at(i).lapic_id, lapic.WAKEUP_VECTOR);
    }
}

/// Kill the CURRENT task from a fault handler: a session task whose address
/// space took a memory fault (MEM-005) dies here so the fault is contained to
/// its session (MEM-006) while the core lives on. Interrupts are already off
/// (exception gate). The interrupted context is abandoned — the task is dead
/// and its iret frame will never be resumed; the reaper frees it and fires its
/// exit hook exactly as if its entry had returned.
pub fn exitFromFault() noreturn {
    const pc = percpu.self();
    const t = pc.current.?;
    // The fault may have landed inside sleepUntilTsc's windows, with this task
    // still linked on a sleeper list the timer will walk after the Task is
    // freed — unlink first (a no-op when it is on no list).
    sleep.abandonSleeper(t);
    t.state = .dead;
    schedule();
    unreachable; // a dead task is never switched back to
}

// --- task creation ---------------------------------------------------------

/// Build a task that runs `entry` on any core (KRN-009). The stack is
/// hand-crafted so the first switchContext `ret` jumps to taskBootstrap, which
/// calls `entry`. The caller places it with `dispatch`; until then it is in no
/// queue.
pub fn spawn(name: []const u8, entry: *const fn () void) !*Task {
    return spawnWithAffinity(null, name, entry);
}

/// Build a task that may run ONLY on core `core`. For the two cases where a task
/// is bound to a particular processor rather than merely started on one: a core's
/// own idle task, and work holding processor state that cannot move (see
/// `Task.affinity`). Everything else uses `spawn`.
pub fn spawnOn(core: u32, name: []const u8, entry: *const fn () void) !*Task {
    return spawnWithAffinity(core, name, entry);
}

/// Tasks dropped because their bound core went offline (dispatch's affinity
/// check) — a loss that must not be silent.
var cnt_stranded = counter.Counter{ .mod = .sched, .name = "stranded_tasks" };
var cnt_stranded_registered = false;

// The kernel address space's CR3 (the boot trampoline's identity map), captured
// at the first spawn — which always happens on the boot path or a kernel task,
// where it is the running value. Every task starts in it; a session task is
// re-pointed by setAddressSpace before it is dispatched.
var kernel_cr3: u64 = 0;

/// The kernel address space's CR3 — what the fault classifier compares against
/// and what every non-session task runs under.
pub fn kernelCr3() u64 {
    return kernel_cr3;
}

/// Run `t` in the address space `cr3` names (a session space). Must be called
/// after spawn and before dispatch — a running task's space cannot be changed.
pub fn setAddressSpace(t: *Task, cr3: u64) void {
    t.context.cr3 = cr3;
}

fn spawnWithAffinity(affinity: ?u32, name: []const u8, entry: *const fn () void) !*Task {
    const a = heap.allocator();
    const stack = try a.alloc(u8, STACK_SIZE);
    errdefer a.free(stack);
    return spawnOnStack(affinity, name, entry, stack, true);
}

/// Spawn on a caller-provided stack the reaper must NOT free — how a session
/// task runs on its arena-backed, guard-paged stack (MEM-010). The caller owns
/// the stack's lifetime and must keep it until the task is reaped (its
/// exit_hook is the signal).
pub fn spawnStacked(name: []const u8, entry: *const fn () void, stack: []u8) !*Task {
    return spawnOnStack(null, name, entry, stack, false);
}

/// Task stacks that overflowed into their canary (spec MEM-011). Any non-zero
/// value is a defect, not a statistic. The detection itself lives in the pure
/// `stackcanary` module, where it is tested rather than trusted.
var cnt_stack_overflow = counter.Counter{ .mod = .sched, .name = "stack.overflow" };
var cnt_stack_overflow_registered = false;

fn armCanary(stack: []u8) void {
    if (!cnt_stack_overflow_registered) {
        cnt_stack_overflow_registered = true;
        counter.register(&cnt_stack_overflow);
    }
    stackcanary.arm(stack);
}

fn spawnOnStack(affinity: ?u32, name: []const u8, entry: *const fn () void, stack: []u8, stack_owned: bool) !*Task {
    const a = heap.allocator();
    const t = try a.create(Task);
    errdefer a.destroy(t);
    if (kernel_cr3 == 0) kernel_cr3 = cpu.readCr3();
    t.* = .{
        .stack = stack,
        .stack_owned = stack_owned,
        // The spawning core is the initial placement hint. On the boot stack —
        // before the BSP's per-CPU block exists — there is no GS to ask, and
        // the spawner IS the bootstrap core, so the hint is core 0 by identity.
        .cpu_index = affinity orelse (if (percpu.bspLive()) percpu.indexOrBsp() else 0),
        .affinity = affinity,
    };
    t.context.cr3 = kernel_cr3;
    t.bootstrap_entry = @intFromPtr(entry);
    armCanary(stack);
    const n = @min(name.len, t.name.len - 1);
    @memcpy(t.name[0..n], name[0..n]);

    // Build the initial stack: top-down, a frame switchContext will pop.
    //
    // ABI alignment: the System V AMD64 ABI requires rsp+8 to be 16-byte aligned
    // on entry to a function (the state right after a `call` pushes an 8-byte
    // return address). switchContext reaches taskBootstrap via `ret`, so we must
    // prime the stack so that AFTER that ret, rsp ≡ 8 (mod 16) — else the first
    // 16-byte `movaps` to the stack frame #GPs. We align the top to 16 then drop
    // 8 so the return-address slot lands the post-ret rsp at the required offset.
    const top = (@intFromPtr(stack.ptr) + stack.len) & ~@as(usize, 0xF);
    // Place taskBootstrap's address at a 16-aligned slot so that after the `ret`
    // pops it, rsp = (slot + 8) ≡ 8 (mod 16) — exactly the post-`call` state the
    // ABI requires at function entry.
    var sp = top - 16;
    @as(*u64, @ptrFromInt(sp)).* = @intFromPtr(&taskBootstrap);
    // Six callee-saved registers popped by switchContext (r15,r14,r13,r12,rbp,rbx).
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        sp -= 8;
        @as(*u64, @ptrFromInt(sp)).* = 0;
    }
    t.context.rsp = sp;
    return t;
}

// --- placement (KRN-009/010/011) --------------------------------------------

/// Make `t` runnable on the best core available and, if that core may be halted,
/// prod it. This is the ONE way a task enters a run queue.
///
/// The choice is dispatch.zig's (an idle core if any exists, searching from the
/// task's own last core so a free home core keeps it); everything here is the
/// part that has to happen under a lock. Safe to call from any core, from task or
/// interrupt context, with interrupts in any state.
pub fn dispatch(t: *Task) void {
    // A dispatch from the boot stack (the boot layout opening the first
    // terminal) arrives before ANY per-CPU state exists on this core: the
    // placement masks are empty and the target's run_lock is uninitialized
    // memory. Park the task here; startBspScheduler drains the list once the
    // machine can actually hold a run queue. The task loses nothing — nothing
    // runs until the schedulers start anyway.
    if (comptime buildinfo.smp) {
        if (!percpu.bspLive()) {
            deferBootDispatch(t);
            return;
        }
    }
    const online = @atomicLoad(u64, &online_mask, .acquire);
    const target = if (t.affinity) |a| blk: {
        // A core-bound task whose core has been retired can never run again —
        // enqueueing it there would strand it on a queue nobody pops (and the
        // dead core's run_lock may be held forever by the fault that killed
        // it). Count the loss loudly instead of queueing into a corpse.
        if ((online & placement.bit(a)) == 0) {
            if (!cnt_stranded_registered) {
                cnt_stranded_registered = true;
                counter.register(&cnt_stranded);
            }
            cnt_stranded.inc();
            return;
        }
        break :blk a;
    } else blk: {
        const idle = @atomicLoad(u64, &idle_mask, .acquire);
        // No idle core is not "nowhere to run": the task queues behind existing
        // work — on its last core if that core is still online, else on the
        // nearest online one (the last core may have been retired by a fault).
        break :blk placement.pickCore(t.cpu_index, online, idle) orelse
            (placement.pickCore(t.cpu_index, online, online) orelse t.cpu_index);
    };
    enqueueOn(target, t);
}

// Tasks dispatched from the boot stack, parked until the BSP scheduler exists.
// Written only pre-scheduler (single-threaded boot path), drained exactly once
// by dispatchDeferred — no lock needed, and a fixed size because the boot
// layout is a fixed piece of policy (fail-loud if it ever grows past this).
const MAX_BOOT_DEFERRED = 8;
var boot_deferred: [MAX_BOOT_DEFERRED]*Task = undefined;
var boot_deferred_count: usize = 0;

fn deferBootDispatch(t: *Task) void {
    if (boot_deferred_count == MAX_BOOT_DEFERRED)
        @panic("sched: too many tasks dispatched before the scheduler started");
    boot_deferred[boot_deferred_count] = t;
    boot_deferred_count += 1;
}

/// Place every task that was dispatched before the scheduler existed. Called by
/// the SMP bring-up on the BSP, after percpu.init has made placement possible.
pub fn dispatchDeferred() void {
    var i: usize = 0;
    while (i < boot_deferred_count) : (i += 1) dispatch(boot_deferred[i]);
    boot_deferred_count = 0;
}

/// Put `t` on core `target`'s run queue and wake that core if it was idle.
///
/// The idle bit is cleared inside the same critical section as the push, which is
/// what closes the lost-wakeup window: a core marks itself idle only under this
/// same lock, and only after a pop that found nothing, so it cannot decide it has
/// nothing to do while this task is already waiting for it.
fn enqueueOn(target: u32, t: *Task) void {
    const pc = percpu.at(target);
    const if_was = pc.run_lock.acquireIrqSave();
    lockorder.acquired(.run);
    t.state = .runnable;
    t.cpu_index = target;
    pc.run_queue.push(t);
    const before = @atomicRmw(u64, &idle_mask, .And, ~placement.bit(target), .acq_rel);
    const was_idle = (before & placement.bit(target)) != 0;
    lockorder.released(.run);
    pc.run_lock.releaseIrqRestore(if_was);

    // Only a halted core needs prodding. A core that is running something will
    // reach this task at its next reschedule — at most one quantum away — and an
    // interrupt it does not need is pure interference on a real-time machine.
    // The IPI is sent AFTER the lock is dropped so the woken core never spins on
    // a lock its waker still holds.
    //
    // Skipping the self-IPI rests on "I am running, so I will reschedule". That
    // holds for task context and for the timer interrupt (`tick` reschedules on
    // the way out). It would NOT hold for a device interrupt that woke a task on
    // an idle-halted core: an idle core has its deadline disarmed, and that
    // handler's `iretq` would return straight to `hlt` with the task queued and
    // nothing left to wake it. Any future ISR that wakes a task must reschedule
    // before it returns.
    if (was_idle and target != percpu.indexOrBsp())
        lapic.sendFixedIpi(pc.lapic_id, lapic.WAKEUP_VECTOR);
}

/// Complete the switch this core has just performed, running as the INCOMING
/// task: publish that the outgoing task's context is saved, then place it if it
/// was being handed to another core.
///
/// The ordering is the whole point. `switchContext` stores the outgoing task's
/// stack pointer; only after it returns — which is here, on the other side, in the
/// incoming task — is that task's register state safely on its own stack and
/// therefore safe for another core to resume. Publishing `on_cpu = false` or
/// enqueueing it any earlier would let a second core run a task whose context had
/// not been saved.
fn finishSwitch(pc: *percpu.PerCpu) void {
    if (pc.prev_task) |p| {
        pc.prev_task = null;
        @atomicStore(bool, &p.on_cpu, false, .release);
    }
    if (pc.migrate_pending) |m| {
        pc.migrate_pending = null;
        enqueueOn(pc.migrate_target, m);
    }
}

// --- scheduling ------------------------------------------------------------

/// The TSC source for accounting and deadlines (cpu/tsc.zig). Invariant TSC ⇒
/// deltas are elapsed time.
const rdtsc = tsc.rdtsc;
const sleep = @import("sleep.zig");

/// Charge the TSC elapsed since this core's previous reschedule to the task that
/// was on-CPU over that interval (`prev`): its own `cpu_tsc` accumulator (the
/// exact per-task CPU time, KRN-005) AND the core's idle bucket if it was the
/// idle task, else the busy bucket. Called at every reschedule (preemptive via
/// tick(), cooperative via yield()), so all on-CPU time is measured — not
/// sampled. MUST run with this core's interrupts off (schedule() callers
/// guarantee it) so the read-and-attribute is atomic w.r.t. the LAPIC-timer IRQ.
fn accountElapsed(pc: *percpu.PerCpu, prev: *Task) void {
    const now = rdtsc();
    const delta = now - pc.last_tsc;
    pc.last_tsc = now;
    prev.cpu_tsc += delta;
    if (prev == pc.idle) {
        pc.idle_tsc += delta;
    } else {
        pc.busy_tsc += delta;
    }
}

/// Pick the next task on this core and switch to it. MUST be called with
/// interrupts disabled on this core (callers guarantee this) so the per-core run
/// queue and the context switch are atomic w.r.t. the LAPIC-timer IRQ. If the run
/// queue is empty, switches to the idle task.
pub fn schedule() void {
    // Interrupts OFF is this function's precondition, not a preference. It is
    // what makes the reschedule non-reentrant, and it is what keeps
    // `migrate_pending`/`prev_task` safe between the stores below and the
    // `finishSwitch` on the far side of the switch. A caller that arrived with
    // IF=1 would have them re-enabled by the run-lock release a few lines before
    // `switchContext`, letting a timer interrupt land on half-swapped state.
    if (cpu.interruptsEnabled()) @panic("sched: schedule() entered with interrupts enabled");
    const pc = percpu.self();
    const prev = pc.current.?;
    // Reaching the scheduler IS this core's liveness proof (the deadman's
    // per-core fuse): every core — idle ones included — re-enters here at
    // least once per tick-rotation interval, so a core whose fuse still blows
    // is one that takes timer interrupts but cannot schedule.
    deadman.aliveCore(pc.cpu_index);

    // Reap the PREVIOUS reschedule's zombie, if any:
    // a task whose entry returned goes .dead and is left for the FOLLOWING
    // schedule() call to free, never the one that observes it dead — at that
    // point this core has fully switched away from the zombie's stack (we are
    // executing on `prev`'s stack here, a different task), so freeing its stack
    // and the Task struct is safe. Nothing frees a task otherwise: repeated
    // spawn/exit cycles would leak STACK_SIZE + sizeOf(Task) per cycle forever.
    if (pc.zombie) |z| {
        pc.zombie = null;
        // Reaps are traced like births and deaths: a live task freed here by
        // mistake (a zombie pointer aliasing a running task) is otherwise the
        // least diagnosable failure in the tree — the victim simply stops
        // existing.
        klog.puts("task: reaped ");
        klog.puts(z.name[0 .. std.mem.indexOfScalar(u8, &z.name, 0) orelse z.name.len]);
        if (z.state != .dead) klog.puts(" STATE-NOT-DEAD");
        klog.puts("\n");
        // The exit hook fires HERE — the one point where the task provably
        // will never run again (this core switched off its stack a full
        // reschedule ago, and no queue holds it). The session layer uses it to
        // retire the session slot; it must stay quick and lock-light (we are
        // inside schedule(), interrupts off).
        if (z.exit_hook) |h| h(z.exit_ctx);
        const a = heap.allocator();
        if (z.stack_owned) a.free(z.stack);
        a.destroy(z);
    }

    // Charge the time this core just spent running `prev` before switching away
    // (time accounting for `ps`).
    accountElapsed(pc, prev);

    // The outgoing task's stack canary (spec MEM-011). Checked HERE because it
    // is the one moment we know `prev` is not running: the deepest frame it will
    // ever reach has already been reached. A heap task stack has no guard page,
    // so an overflow does not fault — it silently overwrites the allocation
    // below and surfaces later, somewhere unrelated, as a wild jump. This turns
    // that into one line naming the task, at the first switch after it happened.
    if (!stackcanary.intact(prev.stack)) {
        cnt_stack_overflow.inc();
        var buf: [96]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&buf, "sched: STACK OVERFLOW in task '{s}' — heap below it is corrupt\n", .{
            std.mem.sliceTo(&prev.name, 0),
        }) catch "sched: STACK OVERFLOW\n");
        // Re-arm so the next switch reports a NEW overflow rather than this one
        // again — the damage is already done and repeating it hides what follows.
        armCanary(prev.stack);
    }

    // Everything that touches this core's queue or its idle bit happens under one
    // lock — including the decision to go idle, which is only sound alongside the
    // pop that reached it.
    const if_was = pc.run_lock.acquireIrqSave();
    lockorder.acquired(.run);

    // Re-queue the outgoing task if it is still runnable — but NEVER the idle
    // task. Idle is the empty-queue fallback (the `orelse` below); it lives only
    // in `pc.idle`, never in the run queue. If it were enqueued it would compete
    // round-robin with real work and steal a 1/N share of the core — e.g. a tight
    // `prime` loop sharing the core 50/50 with idle and reading ~50% instead of
    // 100%.
    //
    // Where it goes is a placement decision (KRN-010): if this core has other work
    // waiting AND some other core is idle, the outgoing task is better off there
    // than queued behind us. It is NOT enqueued here in that case — see
    // finishSwitch for why the far side of the switch has to do it.
    // `.running` specifically, not "not blocked". A task that called block() set
    // itself `.blocked` and a concurrent wake may already have flipped it to
    // `.runnable` — and that waker is, at this instant, waiting on `on_cpu` to
    // place it. Neither value matches, so we leave it alone and the waker places
    // it exactly once. Testing `!= .blocked` here would enqueue it a second time
    // and splice this core's queue into the waker's.
    // A task's state byte must name a TaskState. Anything else is memory
    // corruption of a live Task, and the switch below would silently drop the
    // task on the floor (no branch requeues it) — the least diagnosable loss
    // in the tree. Fail loudly at the moment of detection instead.
    if (@intFromEnum(prev.state) > @intFromEnum(TaskState.dead)) {
        klog.puts("sched: CORRUPT TASK STATE on ");
        klog.putHex(@intFromPtr(prev));
        klog.puts(" state=");
        klog.putHex(@intFromEnum(prev.state));
        klog.puts("\n");
        @panic("sched: corrupt task state — live Task memory overwritten");
    }
    if (prev.state == .running and prev != pc.idle) {
        prev.state = .runnable;
        const handoff = if (prev.affinity != null) null else placement.handoff(
            pc.cpu_index,
            !pc.run_queue.isEmpty(),
            @atomicLoad(u64, &online_mask, .acquire),
            @atomicLoad(u64, &idle_mask, .acquire),
        );
        if (handoff) |target| {
            pc.migrate_pending = prev;
            pc.migrate_target = target;
        } else {
            pc.run_queue.push(prev);
        }
    } else if (prev.state == .dead) {
        // Queue for the NEXT schedule() call to free (see above) — not now, we
        // are about to switchContext using `prev.context` (embedded in the Task
        // struct we'd be freeing) as the FROM side of the swap.
        pc.zombie = prev;
    }

    const next = pc.run_queue.pop() orelse pc.idle.?;
    // Publish idleness under the same lock as the pop that decided it, so an
    // enqueuer either sees this core idle and prods it, or pushes before the pop
    // and is found by it. There is no third order (enqueueOn).
    //
    // The condition is "nothing left to run", not "we picked the idle task" —
    // those coincide only as long as nothing ever places the idle task in a run
    // queue, and this way the bit stays right even if something did.
    if (pc.run_queue.isEmpty()) {
        _ = @atomicRmw(u64, &idle_mask, .Or, placement.bit(pc.cpu_index), .acq_rel);
    } else {
        _ = @atomicRmw(u64, &idle_mask, .And, ~placement.bit(pc.cpu_index), .acq_rel);
    }
    next.state = .running;
    next.cpu_index = pc.cpu_index;
    pc.current = next;
    lockorder.released(.run);
    pc.run_lock.releaseIrqRestore(if_was);

    sleep.armPreemption(pc, next);
    if (next != prev) {
        // `on_cpu` says "this task's registers may still be in a CPU". Set it on
        // the incoming task before the switch and clear it on the outgoing one
        // only after (finishSwitch), so the two never overlap and no other core
        // can resume a task mid-save.
        @atomicStore(bool, &next.on_cpu, true, .release);
        pc.prev_task = prev;
        switchContext(&prev.context, &next.context);
        // Reached as the INCOMING task, once some later switch returns here.
        finishSwitch(percpu.self());
    }
}

/// Voluntarily give up the CPU (cooperative). Saves and restores this core's
/// interrupt flag around the switch: schedule() runs with IF=0 so a timer IRQ
/// cannot land mid-switch, which would re-enter schedule() on a half-updated run
/// queue / context and corrupt state. When we are switched back in, IF is restored
/// to whatever it was on entry — a caller that yields with interrupts already OFF
/// (e.g. from inside an IRQ-off critical section) must not have them silently
/// re-enabled on return, so never `sti` unconditionally here. Mirrors wake()'s
/// self-target path.
pub fn yield() void {
    const if_was_on = cpu.irqSave();
    schedule();
    cpu.irqRestore(if_was_on);
}

/// Cooperative yield from inside a long CPU-bound loop, but ONLY when this core's
/// scheduler is live (SMP, started). A tight compute loop (e.g. `prime`) calls
/// this periodically so it returns to the back of its core's FIFO often, letting a
/// co-scheduled render/system task take the core at low latency instead of waiting
/// a full round-robin cycle, which would otherwise stutter the desktop. No-op on
/// the single-core build and during early boot (no per-core scheduler), where the
/// loop simply runs to completion — same guard as `cancelled()`/`setActivity`.
pub fn yieldPeriodic() void {
    if (!schedulerLive()) return;
    yield();
}

// --- block / wake (event-driven sleep) -------------------------------------

/// Block the calling core's current task until `ready(ctx)` is true. The task
/// leaves the run queue (the core halts on idle if nothing else is runnable) and
/// resumes only when a `wake()` targets it. The predicate is re-checked on every
/// resume — a wake is a hint, never a guarantee of work. The task may resume on a
/// different core than it slept on (KRN-011).
///
/// Lost-wakeup-free, guarded by the task's own lock. The decision to sleep and
/// the publication of `.blocked` happen in ONE
/// critical section, and `wake` takes that same lock: a waker either arrives
/// before we commit — and leaves `wake_pending`, which we check inside the
/// section, so we do not sleep — or after, and finds `.blocked` and places us.
/// There is no interleaving in which both sides miss each other.
///
/// Interrupts are masked across the whole decision (a wake IPI arriving while we
/// are IF=0 latches in the LAPIC IRR and is delivered at idle's adjacent
/// `sti; hlt`), and the caller's own interrupt flag is restored on exit rather
/// than forced on — a caller that blocks from inside an IRQ-off critical section
/// must not have interrupts silently enabled underneath it.
pub fn block(ctx: anytype, comptime ready: anytype) void {
    const if_was = cpu.irqSave();
    const cur = percpu.self().current.?;
    while (true) {
        // Interrupts are already off, so the plain acquire is enough here; `wake`
        // is the side that has to mask.
        cur.lock.acquire();
        lockorder.acquired(.task);
        // The predicate is the ONLY exit. `wake_pending` says "do not sleep this
        // round", not "you may return" — a wake for an unrelated event, or one
        // left over from before this call, would otherwise return with the
        // caller's condition still false, and callers act on the return.
        if (ready(ctx)) {
            lockorder.released(.task);
            cur.lock.release();
            break;
        }
        if (cur.wake_pending) {
            cur.wake_pending = false;
            lockorder.released(.task);
            cur.lock.release();
            continue; // re-test the predicate rather than commit to sleeping
        }
        cur.state = .blocked;
        lockorder.released(.task);
        cur.lock.release();
        schedule(); // leaves the run queue; switches to next/idle (hlt)
        // --- resumed here, on whichever core `wake` placed us ---
    }
    cpu.irqRestore(if_was);
}

/// Make a blocked `task` runnable again and place it on a core (KRN-010). Callable
/// from any core, task or interrupt context, and idempotent: a task that is not
/// asleep is simply noted, never enqueued twice.
///
/// Two things have to be true before a task may be placed, and the task's lock is
/// what makes them so. First, exactly one waker may perform the
/// `blocked → runnable` transition, or two cores would each enqueue the same task
/// and splice one intrusive list into two. Second — and this is the subtle one —
/// a task that has published `.blocked` may still be ON a core, in the instants
/// between that store and the context switch that saves its registers. Placing it
/// then would let a second core resume a context that has not been written yet.
/// So we wait out `on_cpu`: a bounded spin of the few dozen instructions it takes
/// that core to reach `switchContext`, and the only place in the scheduler that
/// spins on another core at all.
pub fn wake(task: *Task) void {
    const if_was = task.lock.acquireIrqSave();
    lockorder.acquired(.task);
    defer {
        lockorder.released(.task);
        task.lock.releaseIrqRestore(if_was);
    }
    if (task.state != .blocked) {
        // Not asleep — either running, or between deciding to block and saying
        // so. Leave the note block() checks inside its own critical section.
        task.wake_pending = true;
        return;
    }
    task.state = .runnable;
    // `on_cpu` clears when the owning core's NEXT task completes the switch
    // (finishSwitch). If that core faulted and parked mid-switch, the bit never
    // clears — spinning here (with locks held, IRQs off) would wedge THIS core
    // on the corpse of that one, the exact spread containment exists to stop.
    // The task's context is unrecoverable in that case; leave it blocked and
    // stranded (its session is being torn down by the fault path anyway).
    while (@atomicLoad(bool, &task.on_cpu, .acquire)) {
        if (!coreOnline(task.cpu_index)) {
            task.state = .blocked;
            return;
        }
        asm volatile ("pause");
    }
    dispatch(task);
}

/// Wakeup-IPI handler body (runs ON the woken core, from isrDispatch). The ISR has
/// already EOI'd. The task that prompted the IPI is already in this core's run
/// queue — the waker put it there before sending — so all that is owed is a
/// reschedule, which takes it at the iret boundary. Mirrors tick()'s guards.
pub fn wakeDrain() void {
    const pc = percpu.self();
    if (!pc.started) return;
    if (pc.current == null) return; // scheduler mid-bringup on this core
    schedule();
}

// --- cooperative cancellation ----------------------------------------------

/// Request that `task` stop. Sets its `cancelled` flag (release) and wakes it, so
/// a task BLOCKED in block() also resumes to observe the request. Callable from
/// another core (e.g. core 0 closing a terminal whose core is running `prime`).
/// The task itself acts on it by polling cancelled(); the kernel does not unwind
/// a running stack.
pub fn requestCancel(task: *Task) void {
    @atomicStore(bool, &task.cancelled, true, .release);
    wake(task);
}

/// Whether the scheduler is live on the calling core: the per-CPU GS base is
/// installed (non-zero) AND this core's scheduler has started. The single-core
/// build never installs GS / starts a scheduler, so this is false there — callers
/// that touch per-CPU scheduler state (cancelled, sleepUntilTsc) gate on it and
/// fall back to a synchronous path. Per-core on purpose: a global "scheduler
/// live" flag would be wrong during AP bring-up — an AP would set it while the
/// BSP is still in bringUpAps(), before the BSP's own percpu.init, so a BSP
/// wait would yield with GS unset and fault. Gating on this core's GS base and
/// `started` flag cannot mis-report a neighbour's progress as our own.
pub fn schedulerLive() bool {
    if (comptime !buildinfo.smp) return false;
    return gsBase() != 0 and percpu.self().started;
}

/// Whether the CURRENT task has a pending cancellation. The single line a long
/// compute loop checks (`if (cancelled()) break;`). Cheap — one acquire load.
/// Returns false when the scheduler isn't live (single-core / early boot): there
/// is no other context to request a cancel, so the loop simply runs to completion.
pub fn cancelled() bool {
    if (!schedulerLive()) return false;
    const cur = currentTask() orelse return false;
    return @atomicLoad(bool, &cur.cancelled, .acquire);
}

/// Clear the current task's cancellation, called when it takes on fresh work so a
/// reused per-core task does not inherit a stale request.
pub fn clearCancel() void {
    const cur = currentTask() orelse return;
    @atomicStore(bool, &cur.cancelled, false, .release);
}

/// Called from the LAPIC timer IRQ on this core: preempt the running task. The
/// IRQ handler runs with IF=0 (interrupt gate) and has already EOI'd, so it
/// cannot land inside a cooperative `schedule()` — every caller of `schedule()`
/// masks interrupts for its whole duration, which is what makes the reschedule
/// path non-reentrant.
pub fn tick() void {
    const pc = percpu.self();
    if (!pc.started) return;
    if (pc.current == null) return; // scheduler mid-bringup on this core
    sleep.releaseDueSleepers(pc);
    // CPU-time accounting happens in schedule() (charges the elapsed TSC to the
    // outgoing task), so the tick just drives the reschedule.
    schedule();
}

/// Start the scheduler on this core: make `first` the current task and switch to
/// it. The idle task must already be set on the PerCpu. Never returns (control
/// continues inside the scheduled tasks).
pub fn start(idle_task: *Task) noreturn {
    const pc = percpu.self();
    // Everything from the first pop to the online/idle announcement happens
    // under this core's run lock: tasks may already have been placed here
    // before the scheduler came up, and another core could be enqueueing more
    // at this very moment — an unlocked pop would race the splice.
    const if_was = pc.run_lock.acquireIrqSave();
    lockorder.acquired(.run);
    // Take a queued task rather than switching into idle and waiting out a
    // whole quantum for the timer to notice it — this core is starting from the
    // same decision every later reschedule makes.
    const first = pc.run_queue.pop() orelse idle_task;
    pc.current = first;
    first.state = .running;
    first.on_cpu = true;
    pc.prev_task = null; // nothing preceded the first task on this core
    // Seed the time-accounting baseline so the first reschedule charges only the
    // time spent in `first`, not the whole since-boot TSC.
    pc.last_tsc = rdtsc();
    pc.started = true;
    // Announce this core to the machine, and — only if it is starting with
    // nothing queued — that it is idle, so the very first task dispatched to it
    // arrives with an IPI rather than waiting out a quantum for the timer.
    markOnline(pc.cpu_index);
    if (pc.run_queue.isEmpty())
        _ = @atomicRmw(u64, &idle_mask, .Or, placement.bit(pc.cpu_index), .acq_rel);
    lockorder.released(.run);
    pc.run_lock.releaseIrqRestore(if_was);
    // Enrol in the wall-clock tick rotation (KRN-012): only a core whose
    // scheduler is up may service the tick, and joining HERE — with our own
    // published lapic_id — is what keeps the rotation from picking up an
    // uninitialized id, however late this core comes up.
    if (comptime buildinfo.smp) ioapic.joinRotation(pc.lapic_id);
    // Switch from a throwaway context into the first task.
    var throwaway: Context = .{};
    switchContext(&throwaway, &first.context);
    unreachable;
}

/// Read this core's GS base MSR WITHOUT dereferencing GS — used by crash
/// instrumentation to catch when/where the per-CPU GS base gets clobbered.
pub fn gsBase() u64 {
    return cpu.rdmsr(percpu.IA32_GS_BASE);
}

/// Cooperative blocking primitive for wait-loops in the command path: when the
/// SMP scheduler is live, yield so core 0's system task keeps rendering/draining
/// while this task waits; otherwise (single-core, or early boot) `hlt` until the
/// next IRQ. This is what keeps a slow command (e.g. `net ping`) on one terminal
/// from freezing the whole UI.
pub fn waitYield() void {
    if (schedulerLive()) yield() else asm volatile ("hlt");
}
