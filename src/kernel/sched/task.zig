//! The task VALUE: the struct a schedulable task IS — its saved context, stack,
//! state, labels, links, and the per-task lock — and the fixed sizes those carry.
//! Nothing here schedules: the locking, placement, and context-switch machinery
//! that make these values move between cores live in sched.zig, which is also the
//! public surface (`sched.Task`); this file exists so the value definitions read
//! on their own and the engine file stays within its budget.

const SpinLock = @import("../sync/spinlock.zig").SpinLock;

/// Per-task stack.
///
/// Sized by the deepest path any task can take, which is the TLS 1.3 handshake
/// (NET-010), not the desktop. Two of its frames are live at once — the client
/// `init` and the key-share `init` it calls `.never_inline` — and each is over
/// 50 KiB of handshake buffers on its own; the Kyber and RSA frames underneath
/// add ~40 KiB more, and the agent, HTTP and JSON frames sit above all of it.
/// The desktop's own worst case (the model loader's decompression frame, ~75 KiB)
/// fits comfortably inside the same budget.
///
/// Re-measure after a toolchain or TLS-vendoring change — the frames come from
/// the compiler, not from this repository:
///
///     objdump -d build/netboot/kernel.elf | grep -E '^[0-9a-f]+ <|sub .*,%rsp'
///
/// An overflow here is NOT an error return: these stacks are heap-allocated and
/// carry no guard page, so running off the end silently corrupts the heap below
/// and surfaces later as a wild jump — a #UD at a mid-instruction address, with a
/// backtrace pointing anywhere but the cause. The headroom is the mitigation
/// until a guard page makes it a fault (MEM-010 covers the mechanism; scheduler
/// stacks do not use it yet).
///
/// Stacks are heap-allocated, so this costs per live task, not per core.
pub const STACK_SIZE: usize = 512 * 1024;

/// Fixed width (bytes) of a task's `name` and `activity` label buffers. Task and
/// TaskInfo copy these buffers by value between each other, so both structs must
/// use the same width — this is the single source of that size. Long enough for
/// the short task/command labels `ps` shows (zero-padded, NUL-terminated).
pub const TASK_LABEL_LEN: usize = 16;

/// Saved callee-saved register context for a cooperative switch (System V AMD64:
/// RBX, RBP, R12-R15, plus RSP), and the address space the task runs in. RIP is
/// implicit — it is the return address on the stack when switchContext returns
/// into the other task.
///
/// `cr3` is loaded by switchContextImpl BEFORE the stack swap when it differs
/// from the running value (MEM-009: a compare and a register move, nothing
/// allocated): a session task's stack lives in its own space's arena, so the
/// incoming space must be active before the incoming RSP is dereferenced.
/// Kernel tasks carry the boot identity map's CR3.
pub const Context = extern struct {
    rsp: u64 = 0,
    cr3: u64 = 0,
};

pub const TaskState = enum { runnable, running, blocked, dead };

pub const Task = struct {
    context: Context = .{},
    stack: []u8,
    state: TaskState = .runnable,
    name: [TASK_LABEL_LEN]u8 = [_]u8{0} ** TASK_LABEL_LEN,
    // What the task is currently DOING, if it is running a named long activity
    // (e.g. a `prime` search inline on its core). Empty (activity_len == 0) when
    // the task is just doing its normal job. `ps` shows it next to the task name
    // so a running command is visible even though it isn't a separate task.
    // Set/cleared only by the task itself.
    activity: [TASK_LABEL_LEN]u8 = [_]u8{0} ** TASK_LABEL_LEN,
    activity_len: usize = 0,
    // Cumulative TSC ticks this task has been on-CPU since it was spawned — the
    // exact per-task CPU time (KRN-005). accountElapsed charges every
    // reschedule's whole elapsed delta to the outgoing task, so the value is
    // measured, not sampled; only the currently-running (not yet rescheduled)
    // slice is unflushed. Written only by the task's own core at reschedule;
    // read cross-core by snapshotTasks (an aligned u64 load cannot tear on
    // x86-64).
    cpu_tsc: u64 = 0,
    /// The core this task last ran on. A hint, not a home: placement starts its
    /// search here so a task returns to a still-free core and keeps its cache
    /// warm, but any online core may take it (KRN-011).
    cpu_index: u32,
    /// The one core this task may run on, or null to run anywhere. Null is the
    /// rule (KRN-009); a value is a HARDWARE seam and must be justified as one:
    /// a core's idle task, which is that core's fallback and belongs to nothing
    /// else, and a guest's virtual processor, whose VMCS is bound to the physical
    /// core it was loaded on. The system and command-worker tasks carry one too
    /// while they still own device registers no other core may touch; that is
    /// a bring-up debt, not a seam, and it goes when driver ownership moves to
    /// locks.
    affinity: ?u32 = null,
    /// Guards this task's own state transitions, so two cores waking it at once
    /// cannot both decide they are the one to place it. Also held across the
    /// wait for `on_cpu` in `wake`, which is why it is IRQ-safe: the timer
    /// interrupt wakes deadline sleepers.
    lock: SpinLock = .{},
    /// Whether `stack` is the reaper's to free. False for a session task, whose
    /// stack is a slice of its session's arena (memory/sessionspace.zig) — the
    /// arena outlives the task and is freed by the session teardown (MEM-007).
    stack_owned: bool = true,
    /// Called by the reaper just before the task's memory is freed — the LAST
    /// moment the task provably will never run again (its stack is dead). The
    /// session layer installs this to retire the session slot safely; the fault
    /// path reaches it too, so a task killed by a memory fault (MEM-006) is
    /// detached exactly like one that returned. `exit_ctx` rides along.
    exit_hook: ?*const fn (u64) void = null,
    exit_ctx: u64 = 0,
    /// True from the moment a core switches TO this task until the moment the
    /// NEXT task on that core observes the switch complete. While it is set the
    /// task's registers may still be live in a core's CPU rather than saved on
    /// its stack, so no other core may resume it — `wake` waits this out rather
    /// than racing it. Written only by the core running the task; read by any.
    on_cpu: bool = false,
    /// A wake that arrived before this task had actually blocked. Checked under
    /// `lock` by `block` before it commits to sleeping, so a wake can never be
    /// lost in the window between "decided to block" and "blocked".
    wake_pending: bool = false,
    bootstrap_entry: u64 = 0, // entry fn addr; taskBootstrap jumps here
    next: ?*Task = null, // run-queue link
    // Sleeper-list link and absolute wake deadline (sleepUntilTsc). `sleep_core`
    // records WHICH core's list the entry is on: a sleeper woken early may be
    // running on a different core by the time it removes itself.
    sleep_next: ?*Task = null,
    sleep_deadline: u64 = 0,
    sleep_core: u32 = 0,
    // Cooperative cancellation: set by requestCancel() (cross-core), polled by
    // the task itself via cancelled(). Lets a long compute
    // loop be stopped when its terminal closes. Cleared when the task takes on new
    // work so a reused per-core task doesn't inherit a stale request.
    cancelled: bool = false,

    /// The task's name as a slice up to its NUL terminator (the fixed `name` buffer
    /// is zero-padded), for `ps`/diagnostics.
    pub fn nameSlice(self: *const Task) []const u8 {
        var n: usize = 0;
        while (n < self.name.len and self.name[n] != 0) n += 1;
        return self.name[0..n];
    }
};
