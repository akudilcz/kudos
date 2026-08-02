//! Kernel heap: an address-ordered free-list allocator with
//! coalescing over a contiguous arena taken from the PMM. Exposes a
//! std.mem.Allocator.
//!
//! The allocator core is `FreeListHeap`, parameterized over its arena so the
//! kernel (PMM span) and the host tests (a stack buffer, in-file `test` blocks
//! below) drive the SAME logic — one owner, no test-only fork.
//!
//! SMP: the kudos-smp build allocates from MULTIPLE cores (each AP spawns its
//! scheduler tasks, terminals allocate, etc.), so the free list is guarded by an
//! IRQ-safe spinlock. The single-core build compiles the lock out entirely (the
//! comptime `smp` gate) and stays lock-free.

const std = @import("std");
const buildinfo = @import("buildinfo");
const pmm = @import("pmm.zig");
const klog = @import("../debug/klog.zig");
const cpu = @import("../cpu/cpu.zig");
const algn = @import("algn"); // the ONE alignment home (named module: see build.zig)
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

const Alignment = std.mem.Alignment;

// Guards the free list across cores in the SMP build. IRQ-safe because the
// scheduler/timer IRQ paths can allocate; a plain spinlock could self-deadlock.
var lock: SpinLock = .{};

/// Acquire the free-list lock in the SMP build (IRQ-safe); a no-op returning
/// false in the single-core build so the lock compiles out. Pair with unlockHeap.
inline fn lockHeap() bool {
    return if (buildinfo.smp) lock.acquireIrqSave() else false;
}
/// Release the free-list lock and restore the interrupt flag captured by lockHeap.
inline fn unlockHeap(if_was: bool) void {
    if (buildinfo.smp) lock.releaseIrqRestore(if_was);
}

// 512 MiB arena. The GPU desktop's working set alone is ~60 MiB at ultrawide
// native (compositor back buffer 19.8 + wallpaper 19.8 + two half-screen boot
// windows ~19), and maximising a window transiently needs old + new buffers
// live at once, so a full-screen window needs well over that. The machine has
// 64+ GiB; be generous.
const ARENA_FRAMES = 131072;

/// The allocator core: free-list state + arena bounds, no locking and no
/// hardware — the kernel wrappers below hold the heap lock around every call.
/// Corruption (double free / overlapping free) is reported as an error so the
/// host tests can assert it; the kernel's freeFn turns it into a panic (fail
/// loud — heap corruption is not a recoverable condition).
pub const FreeListHeap = struct {
    pub const HEADER = 16; // bytes reserved before each payload (size + backref fit here)
    pub const MIN_SPLIT = 32; // don't leave fragments smaller than this

    /// A free block. Allocated blocks instead store {total size @ base, base ptr @ P-8}.
    const FreeBlock = struct {
        size: usize, // total bytes of this block
        next: ?*FreeBlock,
    };

    free_list: ?*FreeBlock,
    arena_base: usize, // for the invariant checker (blocks must stay in the arena)
    arena_size: usize, // also the cap the overflow guard in allocImpl rejects against

    /// Seed a heap over the `[base, base+size)` arena: the whole span becomes one
    /// free block. `base` must be at least pointer-aligned (the kernel passes a
    /// page-aligned PMM span; the tests pass an align(16) stack buffer).
    pub fn seed(base: usize, size: usize) FreeListHeap {
        const blk: *FreeBlock = @ptrFromInt(base);
        blk.* = .{ .size = size, .next = null };
        return .{ .free_list = blk, .arena_base = base, .arena_size = size };
    }

    pub const FreeError = error{ OverlapPrev, OverlapNext };

    /// Return the `[base, base+size)` span to the address-ordered free list and
    /// coalesce with any adjacent free blocks, keeping the arena from fragmenting.
    /// Errors on a detected double free / overlap (see the guard below); the
    /// kernel caller panics on it.
    pub fn insertFree(self: *FreeListHeap, base: usize, size: usize) FreeError!void {
        var prev: ?*FreeBlock = null;
        var cur = self.free_list;
        while (cur) |c| {
            if (@intFromPtr(c) > base) break;
            prev = c;
            cur = c.next;
        }

        // Double-free / corruption guard: the block being freed must not overlap any
        // free block already on the list. A double free would otherwise insert the
        // same address twice, forming a self-referential `next` cycle (allocImpl then
        // loops forever) or an inflated coalesced size handing out overlapping memory.
        // `cur` is the first free block after `base`, `prev` the last before it, so an
        // overlap can only be with one of those two. Fail loud — this is heap
        // corruption, not a recoverable condition (project "fail loudly" rule).
        // Runs under the heap lock (freeFn holds it).
        if (prev) |p| {
            if (@intFromPtr(p) + p.size > base) return error.OverlapPrev;
        }
        if (cur) |c| {
            if (base + size > @intFromPtr(c)) return error.OverlapNext;
        }

        const blk: *FreeBlock = @ptrFromInt(base);
        blk.* = .{ .size = size, .next = null };
        blk.next = cur;
        if (prev) |p| p.next = blk else self.free_list = blk;

        if (blk.next) |nx| {
            if (base + blk.size == @intFromPtr(nx)) {
                blk.size += nx.size;
                blk.next = nx.next;
            }
        }
        if (prev) |p| {
            if (@intFromPtr(p) + p.size == base) {
                p.size += blk.size;
                p.next = blk.next;
            }
        }
    }

    /// Where a failed allocation reports itself (wired to klog by the kernel's
    /// heap init; null on the host, where the analyzed core has no kernel log).
    /// A hook, not an import: the host test suite analyzes FreeListHeap without
    /// the kernel around it, so the core must not name kernel modules.
    pub var fail_log: ?*const fn ([]const u8) void = null;

    /// First-fit allocate `n` bytes aligned to `a` from the free list. Splits the
    /// chosen block (leaving the remainder free) unless the leftover would be below
    /// MIN_SPLIT, in which case the whole block is consumed. Stores the total block
    /// size at the base and a backref just before the payload so `free` can recover
    /// the block. Returns null if nothing fits.
    pub fn allocImpl(self: *FreeListHeap, n: usize, a: usize) ?[*]u8 {
        // Reject any request the arena can never satisfy BEFORE the alignment math below.
        // `used = align_up((payload-base)+n, 16)` would otherwise overflow for an `n`
        // near usize-max — wrapping `used` to a tiny value that passes `used <= fs`, so
        // the block returned is far smaller than requested and the caller writes past it.
        // Nothing legitimate exceeds the arena, so cap there and fail cleanly (null).
        if (n > self.arena_size) return null;
        var prev: ?*FreeBlock = null;
        var cur = self.free_list;
        while (cur) |c| {
            const base = @intFromPtr(c);
            const fs = c.size;
            const payload = algn.up(base + HEADER, a);
            var used = algn.up((payload - base) + n, 16);
            if (used <= fs) {
                const after = c.next;
                if (fs - used >= MIN_SPLIT) {
                    const rem: *FreeBlock = @ptrFromInt(base + used);
                    rem.* = .{ .size = fs - used, .next = after };
                    if (prev) |p| p.next = rem else self.free_list = rem;
                } else {
                    used = fs; // consume the whole block
                    if (prev) |p| p.next = after else self.free_list = after;
                }
                @as(*usize, @ptrFromInt(base)).* = used; // total size for free()
                @as(*usize, @ptrFromInt(payload - 8)).* = base; // backref to block base
                return @ptrFromInt(payload);
            }
            prev = c;
            cur = c.next;
        }
        // A failed allocation is never silent: name the request and what the
        // arena could actually offer, so "out of memory" is attributable to
        // exhaustion vs fragmentation from the one log line.
        const s = self.stats();
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "heap: alloc {} KiB FAILED (free {} KiB, largest block {} KiB)\n", .{ n / 1024, s.free / 1024, s.largest / 1024 })) |line| {
            if (fail_log) |hook| hook(line);
        } else |_| {}
        return null;
    }

    /// What the arena looks like right now. One walk of the free list answers
    /// every question a caller has about the heap: how much is left, whether it
    /// is in one piece, and how badly the list has fragmented. The allocation
    /// failure path above reports the same numbers, so the log line and the
    /// display can never disagree.
    pub fn stats(self: *const FreeListHeap) Stats {
        var free: usize = 0;
        var largest: usize = 0;
        var blocks: usize = 0;
        var walk = self.free_list;
        while (walk) |w| {
            free += w.size;
            largest = @max(largest, w.size);
            blocks += 1;
            walk = w.next;
        }
        return .{
            .arena = self.arena_size,
            .free = free,
            .used = self.arena_size - free,
            .largest = largest,
            .free_blocks = blocks,
        };
    }

    /// A snapshot of the arena. Bytes throughout.
    pub const Stats = struct {
        /// Total arena the heap was seeded with.
        arena: usize,
        /// Bytes on the free list.
        free: usize,
        /// Arena minus free — allocations plus their headers.
        used: usize,
        /// Largest single allocation the free list could still satisfy.
        largest: usize,
        /// Free blocks the list holds. One block means no fragmentation at all;
        /// many small ones with a small `largest` is a heap that has free bytes
        /// it cannot hand out.
        free_blocks: usize,
    };

    pub const InvariantError = error{
        BadBlockSize, // a free block smaller than a FreeBlock header
        BlockOutOfArena, // a free block outside [arena_base, arena_base+arena_size)
        NotAddressOrdered, // list not strictly ascending (or overlapping blocks)
        AdjacentNotCoalesced, // two touching free blocks that insertFree should have merged
        ListCycle, // more blocks than the arena can hold — a `next` cycle
    };

    /// Verify the free-list structural invariants: every block inside the arena,
    /// addresses strictly ascending, no overlap, fully coalesced (no two adjacent
    /// free blocks), no cycle. Test-only diagnostics; never called by the kernel.
    pub fn checkInvariants(self: *const FreeListHeap) InvariantError!void {
        const max_blocks = self.arena_size / @sizeOf(FreeBlock) + 1;
        var count: usize = 0;
        var prev_end: usize = 0;
        var first = true;
        var cur = self.free_list;
        while (cur) |c| {
            count += 1;
            if (count > max_blocks) return error.ListCycle;
            const base = @intFromPtr(c);
            if (c.size < @sizeOf(FreeBlock)) return error.BadBlockSize;
            if (base < self.arena_base or base + c.size > self.arena_base + self.arena_size)
                return error.BlockOutOfArena;
            if (!first) {
                if (base < prev_end) return error.NotAddressOrdered;
                if (base == prev_end) return error.AdjacentNotCoalesced;
            }
            prev_end = base + c.size;
            first = false;
            cur = c.next;
        }
    }
};

// ── kernel wiring: one module-global heap over the PMM arena ─────────────────

var state: FreeListHeap = .{ .free_list = null, .arena_base = 0, .arena_size = 0 };

/// Seed the heap with its arena: grab ARENA_FRAMES contiguous frames from the
/// PMM and make the whole span one free block. Fails loudly if the PMM cannot
/// satisfy the arena — the kernel cannot run without a heap.
pub fn init() void {
    const base = pmm.allocContiguous(ARENA_FRAMES) orelse {
        klog.puts("FATAL: heap arena allocation failed\n");
        cpu.park();
    };
    state = FreeListHeap.seed(base, ARENA_FRAMES * pmm.FRAME_SIZE);
    FreeListHeap.fail_log = klog.puts;
}

/// Recover an allocation's block base and total size from a payload pointer,
/// using the backref at `ptr-8` and the size stored at the block base (written by
/// allocImpl). Reads only this allocation's own immutable header, so no lock.
fn blockOf(ptr: [*]u8) struct { base: usize, total: usize } {
    const p = @intFromPtr(ptr);
    const base = @as(*usize, @ptrFromInt(p - 8)).*;
    const total = @as(*usize, @ptrFromInt(base)).*;
    return .{ .base = base, .total = total };
}

/// std.mem.Allocator.alloc hook: take the heap lock and delegate to allocImpl.
fn allocFn(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const s = lockHeap();
    defer unlockHeap(s);
    return state.allocImpl(len, alignment.toByteUnits());
}

/// std.mem.Allocator.resize hook: in-place resize, succeeding only when `new_len`
/// still fits within the payload capacity of the existing block (grow within the
/// block or shrink). Never moves the allocation.
fn resizeFn(_: *anyopaque, buf: []u8, _: Alignment, new_len: usize, _: usize) bool {
    // blockOf reads only this allocation's own header (immutable while the buffer
    // is live), so no free-list lock is needed for the capacity check.
    const b = blockOf(buf.ptr);
    const capacity = b.total - (@intFromPtr(buf.ptr) - b.base);
    return new_len <= capacity; // grow within the block or shrink in place
}

/// std.mem.Allocator.remap hook: this allocator never relocates, so a remap is
/// just an in-place resize — return the same pointer on success, null otherwise.
fn remapFn(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (resizeFn(ctx, buf, alignment, new_len, ra)) buf.ptr else null;
}

/// std.mem.Allocator.free hook: recover the block from the payload pointer, then
/// return it to the free list under the heap lock. Corruption detected by
/// insertFree is fatal here (fail loud) — the tests assert the error paths.
///
/// The header is VALIDATED before it is believed. blockOf reads the block base
/// from `ptr-8` and the span from `*base`; a single scribbled word there would
/// otherwise turn this legitimate free into an arbitrary-span free that
/// swallows LIVE neighbouring allocations into the free list — the worst
/// corruption in the tree, because the victims fail much later and far away.
/// Every check is O(1); a violation is fatal at the violator's own call site,
/// where the backtrace still names it.
fn freeFn(_: *anyopaque, buf: []u8, _: Alignment, _: usize) void {
    const b = blockOf(buf.ptr);
    const p = @intFromPtr(buf.ptr);
    const arena_end = state.arena_base + state.arena_size;
    if (b.base < state.arena_base or b.base >= arena_end or
        b.base % @alignOf(usize) != 0 or
        b.base >= p or p - b.base > b.total or
        b.total > state.arena_size or b.base + b.total > arena_end or
        p + buf.len > b.base + b.total)
    {
        @panic("heap: corrupt allocation header on free");
    }
    const s = lockHeap();
    defer unlockHeap(s);
    state.insertFree(b.base, b.total) catch |e| switch (e) {
        error.OverlapPrev => @panic("heap: double free / overlapping free (prev)"),
        error.OverlapNext => @panic("heap: double free / overlapping free (next)"),
    };
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocFn,
    .resize = resizeFn,
    .remap = remapFn,
    .free = freeFn,
};

/// The kernel-wide std.mem.Allocator backed by this heap. Stateless (all state is
/// in module globals), so `ptr` is unused.
pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}

/// A snapshot of the kernel heap, taken under the free-list lock. This is the
/// only way in: the arena state is module-private, and a reader that walked the
/// list without the lock could follow a `next` pointer another core was in the
/// middle of rewriting.
///
/// It costs one walk of the free list, so it belongs on a sampling path (the
/// heads-up display's half-second tick, spec HUD-011), never inside an
/// allocation loop.
pub fn stats() FreeListHeap.Stats {
    const if_was = lockHeap();
    defer unlockHeap(if_was);
    return state.stats();
}

/// Bytes the heap arena was seeded with.
pub fn arenaBytes() usize {
    return state.arena_size;
}

/// Bytes currently handed out (including per-allocation headers).
pub fn usedBytes() usize {
    return stats().used;
}

/// Bytes on the free list.
pub fn freeBytes() usize {
    return stats().free;
}
