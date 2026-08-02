//! Per-session virtual address spaces (MEM-002..MEM-008): the kernel half of
//! the builder in vspace.zig. Each open terminal session gets its own space —
//! an identity map mirroring the kernel's, minus holes over every OTHER live
//! session's private region (MEM-003/004) and minus its own stack guard page
//! (MEM-010). The session's private region (its arena) backs the session task's
//! stack and anything a loaded module allocates (MOD-006), so a stray pointer
//! from one session cannot reach another's memory, and a stack overflow faults
//! instead of overwriting a neighbour.
//!
//! The KERNEL address space (the boot trampoline's identity map) is untouched:
//! `host-physical == kernel-virtual` is a load-bearing invariant for guest
//! memory slicing, the GPU shim, DMA rings and the backtracer, so the kernel
//! keeps its full view and only session spaces are restricted. Isolation stops
//! stray pointers, not deliberate CR3 writes — the ring-3 privilege boundary is
//! deliberately out of scope.

const std = @import("std");
const buildinfo = @import("buildinfo");
const vspace = @import("vspace.zig");
const pmm = @import("pmm.zig");
const percpu = @import("../sched/percpu.zig");
const sched = @import("../sched/sched.zig");
const lapic = @import("../apic/lapic.zig");
const cpu = @import("../cpu/cpu.zig");
const tsc = @import("../cpu/tsc.zig");
const counter = @import("../debug/counter.zig");
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

/// Vector the TLB-shootdown IPI is delivered on: after a space is reshaped
/// (a hole punched or healed), every core that may hold a stale translation
/// reloads CR3. Above the tick (0x42, ioapic.TICK_VECTOR); below the MSI range.
pub const TLB_VECTOR: u8 = 0x43;

/// A session's private region. Sized to hold the task stack, its guard page,
/// a loaded module image, and the module arena (abi.APP_ARENA_MAX_BYTES = 16 MiB),
/// with headroom — one fixed shape so open/close cannot fragment the PMM.
pub const SESSION_ARENA_BYTES: usize = 24 * 1024 * 1024;

/// Table pages per space: identity base (2 with 1 GiB leaves, 6 without), the
/// guard hole's splits (a PD + a PT), and — with 2 MiB-aligned arenas — at most
/// two PDs per neighbour punch (a 1 GiB straddle), REUSED across churn once a
/// gigabyte's PD exists. Sized with slack over the worst case anyway; a full
/// pool fails a session open as a value, never silently.
const SPACE_TABLE_PAGES: usize = 96;

const ARENA_FRAMES: usize = SESSION_ARENA_BYTES / pmm.FRAME_SIZE;
// The arena is 2 MiB-ALIGNED so every neighbour punch/heal lands on whole
// 2 MiB leaves: no per-punch PT splits, so a long-lived session's pool cannot
// ratchet toward exhaustion as neighbours churn. The PMM hands out 4 KiB
// alignment, so we over-allocate by one leaf and trim the misaligned edges.
const ALIGN_SLACK_FRAMES: usize = vspace.PAGE_2M / pmm.FRAME_SIZE;

/// Access to a memory address no space maps — the fault counter MEM-005
/// requires (surfaced in diagnostics, DIAG-002).
var cnt_space_faults = counter.Counter{ .mod = .mem, .name = "space_faults" };
/// Heals dropped for want of tables — a session space left unable to reach a
/// range that returned to general kernel use (see destroy). Distinct from a
/// fault: nothing crashed, but reachability was silently narrowed.
var cnt_heal_dropped = counter.Counter{ .mod = .mem, .name = "heal_dropped" };
/// TLB shootdowns whose remote acknowledgement wait timed out (a target went
/// offline mid-wait, or worse) — the flush may not have landed everywhere.
var cnt_shootdown_timeouts = counter.Counter{ .mod = .mem, .name = "shootdown_timeouts" };
var counters_registered = false;

/// One live session space. `arena` is the private region (frames tagged to this
/// session — MEM-008's accounting is this length); `pool` holds its page tables.
pub const SessionSpace = struct {
    id: u32,
    cr3: u64,
    arena_base: usize,
    pool_base: usize,
    pool: vspace.TablePool,
    space: vspace.Space,
};

// The live spaces, indexed by session id (same scale as the session table).
// Guarded by `spaces_lock`: open/close punch and heal EACH OTHER'S tables, so
// two concurrent opens must serialize. The fault classifier reads `live` bits
// without the lock — a bit is set only after the space is fully built and
// cleared before it is torn down, both under the lock, and classification only
// ever compares CR3 values.
var spaces: [percpu.MAX_CPUS]SessionSpace = undefined;
var live: [percpu.MAX_CPUS]bool = [_]bool{false} ** percpu.MAX_CPUS;
var spaces_lock: SpinLock = .{};

// Sessions whose space took a memory fault (MEM-006): a bitmask the desktop
// drains to close the faulted session's window, exactly parallel to
// smp.takeFaultedTask for kernel faults — but the core survives.
var faulted_mask: u64 = 0;

/// Build session `id`'s address space and private arena. Returns the space, or
/// an error with NOTHING allocated (acquisition failure is a value; partial
/// state is unwound). Runs on a kernel-space task (the desktop opening a
/// terminal), never on a session task.
pub fn create(id: u32) !*SessionSpace {
    if (!counters_registered) {
        counters_registered = true;
        counter.register(&cnt_space_faults);
        counter.register(&cnt_heal_dropped);
        counter.register(&cnt_shootdown_timeouts);
    }
    // Over-allocate, take the 2 MiB-aligned window, hand back the trim.
    const raw = pmm.allocContiguous(ARENA_FRAMES + ALIGN_SLACK_FRAMES) orelse return error.OutOfMemory;
    const arena_base = std.mem.alignForward(usize, raw, vspace.PAGE_2M);
    const head = (arena_base - raw) / pmm.FRAME_SIZE;
    if (head != 0) pmm.freeContiguous(raw, head);
    pmm.freeContiguous(arena_base + SESSION_ARENA_BYTES, ALIGN_SLACK_FRAMES - head);
    errdefer pmm.freeContiguous(arena_base, ARENA_FRAMES);
    const pool_base = pmm.allocContiguous(SPACE_TABLE_PAGES) orelse return error.OutOfMemory;
    errdefer pmm.freeContiguous(pool_base, SPACE_TABLE_PAGES);

    const if_was = spaces_lock.acquireIrqSave();
    errdefer spaces_lock.releaseIrqRestore(if_was);

    const s = &spaces[id];
    s.* = .{
        .id = id,
        .cr3 = 0,
        .arena_base = arena_base,
        .pool_base = pool_base,
        .pool = .{
            .tables = @as([*]vspace.Table, @ptrFromInt(pool_base))[0..SPACE_TABLE_PAGES],
            .base_pa = pool_base,
        },
        .space = undefined,
    };
    s.space = try vspace.create(&s.pool);
    // Mirror the boot trampoline's kernel map exactly (boot/boot.asm): 512 GiB
    // of 1 GiB pages when the CPU has them, else 4 GiB of 2 MiB pages. Same
    // reach as the kernel, so device MMIO and DMA state stay usable from a
    // session task; the holes below are the only difference.
    if (pmm.has1GiBPages()) {
        try vspace.mapIdentity(&s.pool, s.space, 0, 512 * vspace.PAGE_1G, .g1);
    } else {
        try vspace.mapIdentity(&s.pool, s.space, 0, 4 * vspace.PAGE_1G, .m2);
    }
    // Its own guard page: the arena's first page is unmapped in the OWN space,
    // so the stack that starts right above it faults on overflow (MEM-010)
    // instead of scribbling on whatever the PMM handed out below.
    try vspace.punch(&s.pool, s.space, arena_base, vspace.PAGE_4K);
    // Mutual invisibility with every other live session (MEM-003/004): their
    // arena vanishes from this space, and this arena from theirs. On a failure
    // partway, the punches ALREADY landed in neighbours must be healed — this
    // arena's frames go back to the PMM on unwind, and a neighbour left unable
    // to reach reissued kernel memory would fault on it much later with no
    // diagnosis path.
    errdefer for (&spaces, 0..) |*o, i| {
        if (!live[i]) continue;
        vspace.heal(&o.pool, o.space, arena_base, SESSION_ARENA_BYTES) catch {
            cnt_heal_dropped.inc();
        };
    };
    for (&spaces, 0..) |*o, i| {
        if (!live[i]) continue;
        try vspace.punch(&s.pool, s.space, o.arena_base, SESSION_ARENA_BYTES);
        try vspace.punch(&o.pool, o.space, arena_base, SESSION_ARENA_BYTES);
    }
    s.cr3 = s.pool.pa(s.space.pml4);
    live[id] = true;
    spaces_lock.releaseIrqRestore(if_was);
    // The punches above narrowed live spaces: no core may keep a stale
    // translation into this arena (it would read another session's memory
    // through a TLB entry the tables no longer back). Outside the lock: the
    // shootdown waits for remote acknowledgements.
    shootdown();
    return s;
}

/// Tear session `id`'s space down and return its memory (MEM-007): heal the
/// arena back into every other live space FIRST — its frames return to general
/// kernel use, so neighbours must be able to reach them again BEFORE the PMM
/// can reissue them — then free the arena and the tables. The session's task
/// must already be reaped (the caller owns that ordering; the stack lives in
/// this arena).
pub fn destroy(id: u32) void {
    const if_was = spaces_lock.acquireIrqSave();
    const s = &spaces[id];
    if (!live[id]) {
        spaces_lock.releaseIrqRestore(if_was);
        return;
    }
    live[id] = false;
    // A fault recorded against this id must not outlive the space: the id will
    // be reused, and a stale bit would close the NEXT session's window.
    _ = @atomicRmw(u64, &faulted_mask, .And, ~(@as(u64, 1) << @intCast(id)), .acq_rel);
    for (&spaces, 0..) |*o, i| {
        if (!live[i]) continue;
        // With 2 MiB-aligned arenas a heal rewrites existing PD entries and
        // allocates nothing, so this cannot fail in practice; if it ever does
        // (a future shape change), the drop is counted under its own name —
        // it is a reachability hole, not a memory fault.
        vspace.heal(&o.pool, o.space, s.arena_base, SESSION_ARENA_BYTES) catch {
            cnt_heal_dropped.inc();
        };
    }
    spaces_lock.releaseIrqRestore(if_was);
    shootdown();
    pmm.freeContiguous(s.arena_base, ARENA_FRAMES);
    pmm.freeContiguous(s.pool_base, SPACE_TABLE_PAGES);
}

/// The CR3 value session `id`'s task runs under.
pub fn cr3Of(id: u32) u64 {
    return spaces[id].cr3;
}

/// The session task's stack: the arena pages right above the guard page. The
/// scheduler's usual stack size, so a session task gets the headroom every
/// other task gets — just guarded.
pub fn taskStack(id: u32) []u8 {
    const s = &spaces[id];
    return @as([*]u8, @ptrFromInt(s.arena_base + vspace.PAGE_4K))[0..sched.STACK_SIZE];
}

/// The private region left above the stack: what `run` carves a module image
/// and its arena from (MOD-006). Only the session's own task touches it.
pub fn moduleRegion(id: u32) []u8 {
    const s = &spaces[id];
    const off = vspace.PAGE_4K + sched.STACK_SIZE;
    return @as([*]u8, @ptrFromInt(s.arena_base + off))[0 .. SESSION_ARENA_BYTES - off];
}

/// The physical memory session `id` holds (MEM-008): its arena plus its page
/// tables. Zero for a slot that is not live, so a caller may sweep the table.
pub fn bytesHeld(id: u32) usize {
    const if_was = spaces_lock.acquireIrqSave();
    defer spaces_lock.releaseIrqRestore(if_was);
    if (id >= live.len or !live[id]) return 0;
    return SESSION_ARENA_BYTES + SPACE_TABLE_PAGES * pmm.FRAME_SIZE;
}

/// The physical memory ALL live sessions hold, and how many are live
/// (MEM-008). One sweep of the table under one lock: reporting a total that
/// mixes two instants would show memory appearing or vanishing that never did.
pub fn heldTotal() struct { bytes: usize, sessions: u32 } {
    const if_was = spaces_lock.acquireIrqSave();
    defer spaces_lock.releaseIrqRestore(if_was);
    var bytes: usize = 0;
    var n: u32 = 0;
    for (live) |is_live| {
        if (!is_live) continue;
        bytes += SESSION_ARENA_BYTES + SPACE_TABLE_PAGES * pmm.FRAME_SIZE;
        n += 1;
    }
    return .{ .bytes = bytes, .sessions = n };
}

/// Software-walk session `id`'s space for `va` — null when the space does not
/// map it. How the verification harness checks at runtime what the host tests
/// check on the builder: another session's arena does not resolve (MEM-003/004)
/// and the guard page does not resolve (MEM-010).
pub fn resolveIn(id: u32, va: u64) ?u64 {
    // Under the lock: an unlocked walk could chase pool frames destroy() has
    // already returned to the PMM.
    const if_was = spaces_lock.acquireIrqSave();
    defer spaces_lock.releaseIrqRestore(if_was);
    if (id >= live.len or !live[id]) return null;
    const s = &spaces[id];
    return vspace.resolve(&s.pool, s.space, va);
}

/// Session `id`'s arena base — the address the isolation assertions probe.
pub fn arenaBase(id: u32) ?usize {
    const if_was = spaces_lock.acquireIrqSave();
    defer spaces_lock.releaseIrqRestore(if_was);
    if (id >= live.len or !live[id]) return null;
    return spaces[id].arena_base;
}

/// The live session whose space the calling task is running in, or null when
/// running in the kernel space. How `run` finds the arena a module image and
/// its allocator must come from (MOD-006): the module executes on the session's
/// own task, so the current CR3 IS the session's identity.
pub fn currentSessionId() ?u32 {
    if (comptime !buildinfo.smp) return null;
    const current = cpu.readCr3();
    for (&spaces, 0..) |*s, i| {
        if (live[i] and s.cr3 == current) return @intCast(i);
    }
    return null;
}

/// Classify the CURRENT fault: if this core's CR3 is a live session space, the
/// fault is that session's (MEM-005/006) — count it, record the session for the
/// desktop to close, and return true so the handler kills the task instead of
/// the core. A kernel-space fault returns false and takes the kernel path.
pub fn containCurrentFault() bool {
    if (comptime !buildinfo.smp) return false;
    const current = cpu.readCr3();
    for (&spaces, 0..) |*s, i| {
        if (!live[i] or s.cr3 != current) continue;
        cnt_space_faults.inc();
        _ = @atomicRmw(u64, &faulted_mask, .Or, @as(u64, 1) << @intCast(i), .acq_rel);
        return true;
    }
    return false;
}

/// Drain one faulted session id (clears its bit), or null when none — the
/// desktop closes that session's window (MEM-006 keeps the rest untouched).
pub fn takeFaulted() ?u32 {
    while (true) {
        const m = @atomicLoad(u64, &faulted_mask, .acquire);
        if (m == 0) return null;
        const id: u6 = @intCast(@ctz(m));
        if (@cmpxchgWeak(u64, &faulted_mask, m, m & ~(@as(u64, 1) << id), .acq_rel, .acquire) == null)
            return id;
    }
}

// Acknowledgement counter for the shootdown handshake: each remote handler
// increments it; the sender waits for its expected count. One shootdown at a
// time (`shootdown_lock`), so a plain shared counter suffices.
var shootdown_acks: u64 = 0;
var shootdown_lock: SpinLock = .{};

/// How long a shootdown waits for every remote core to acknowledge before
/// giving up (counted): far beyond any real IPI latency, short enough that a
/// core dying mid-wait cannot wedge the sender.
const SHOOTDOWN_ACK_BUDGET_US: u64 = 5000;

/// Flush every core's TLB after tables changed: reload CR3 here, IPI every
/// other online core (the handler in isrDispatch), and WAIT for their
/// acknowledgements — until they land, a core may still translate into memory
/// the tables no longer back, so create/destroy must not proceed to reuse it.
/// A core that goes offline mid-wait (fault containment) never acks; the
/// budget converts that into a counted timeout instead of a wedge.
fn shootdown() void {
    cpu.writeCr3(cpu.readCr3());
    if (comptime !buildinfo.smp) return;
    if (!percpu.bspLive()) return; // boot path: one core, no stale TLBs elsewhere
    const sd_if = shootdown_lock.acquireIrqSave();
    defer shootdown_lock.releaseIrqRestore(sd_if);
    @atomicStore(u64, &shootdown_acks, 0, .release);
    const self_idx = percpu.index();
    var expected: u64 = 0;
    var i: u32 = 0;
    while (i < percpu.MAX_CPUS) : (i += 1) {
        if (i == self_idx or !sched.coreOnline(i)) continue;
        lapic.sendFixedIpi(percpu.at(i).lapic_id, TLB_VECTOR);
        expected += 1;
    }
    if (expected == 0) return;
    const deadline = tsc.rdtsc() + tsc.usTicks(SHOOTDOWN_ACK_BUDGET_US);
    while (@atomicLoad(u64, &shootdown_acks, .acquire) < expected) {
        if (tsc.rdtsc() >= deadline) {
            cnt_shootdown_timeouts.inc();
            return;
        }
        asm volatile ("pause");
    }
}

/// The TLB-shootdown IPI handler body: drop every non-global translation by
/// reloading CR3, then acknowledge so the sender may proceed. Called from
/// isrDispatch on TLB_VECTOR (LAPIC EOI is the dispatcher's).
pub fn flushLocal() void {
    cpu.writeCr3(cpu.readCr3());
    _ = @atomicRmw(u64, &shootdown_acks, .Add, 1, .acq_rel);
}
