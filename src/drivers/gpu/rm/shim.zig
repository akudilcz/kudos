//! os-interface shim: the kudos implementation of the NVIDIA RM's `os_*` service
//! contract. The RM core calls these; we satisfy the M9-critical subset by
//! delegating to existing kudos subsystems through their public module paths.
//! Everything outside the subset returns a loud NotSupported until a later
//! milestone needs it (no silent stubs).
//!
//! Isolation invariant: this file READS other modules
//! (pci/memory/sync/timer/smp) but never modifies them. New primitives the RM
//! needs that kudos lacks live in sibling files (mmio.zig, msi.zig).

const log = @import("log.zig").gpu;
const pmm = @import("../../../kernel/memory/pmm.zig");
const heap = @import("../../../kernel/memory/heap.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const SpinLock = @import("../../../kernel/sync/spinlock.zig").SpinLock;
const pci = @import("../../pci/pci.zig");
const cpu = @import("../../../kernel/cpu/cpu.zig");
const tsc = @import("../../../kernel/cpu/tsc.zig");
const mmio = @import("mmio.zig");
const netdebug = @import("../../net/debug/netdebug.zig");
const net = @import("../../net/stack/net.zig");
const fileserv = @import("../../net/debug/fileserv.zig");

/// NV_STATUS subset we produce. Values mirror the RM's nvstatus.h; only those we
/// actually return are listed. Defined here once (single source of truth) and
/// referenced by gsp.zig / rm.zig.
pub const Status = enum(i32) {
    ok = 0,
    err_not_supported = 0x56,
    err_no_memory = 0x51,
    err_invalid_state = 0x57,
    err_timeout = 0x65,
};

// --- Memory (os_alloc_mem / os_free_mem / os_alloc_pages_node) -------------

/// os_alloc_mem: general kernel allocation -> kudos heap.
pub fn allocMem(size: u64) ?[*]u8 {
    const a = heap.allocator();
    const buf = a.alloc(u8, @intCast(size)) catch return null;
    return buf.ptr;
}

/// os_alloc_pages_node: contiguous *physical* pages for DMA. kudos PMM hands out
/// identity-mapped physical frames, which is exactly what the RM expects here.
pub fn allocPagesPhys(count: u32) ?u64 {
    // allocContiguousDma: everything allocated here is GSP/GPU-visible — a
    // firmware struct with a 32-bit pointer field truncates a high address
    // silently, so the <4 GiB DMA rail is asserted at the allocation.
    return pmm.allocContiguousDma(@intCast(count));
}

/// Free a `count`-page run from `allocPagesPhys`. Must pass the same `count` — the
/// underlying pmm allocation is contiguous and pmm.free would release only one frame.
pub fn freePagesPhys(phys: u64, count: u32) void {
    pmm.freeContiguous(@intCast(phys), @intCast(count));
}

/// Records the PERSISTENT DMA buffers a GSP bring-up hands to the device (image,
/// signature, bootloader, WPR meta, radix3 levels, shared queues, logs, rmargs,
/// libos) so `gsp.shutdown` can free every page. Transient falcon/FWSEC copies are
/// freed locally and are NOT tracked here. Fails loud on overflow rather than
/// silently dropping a buffer — a dropped entry is exactly the leak this prevents.
pub const DmaTracker = struct {
    const CAP = 24;
    entries: [CAP]struct { phys: u64, pages: u32 } = undefined,
    len: usize = 0,

    /// Allocate `count` pages and record them for later `freeAll`. Same failure
    /// contract as allocPagesPhys (null on OOM); panics if the tracker is full.
    pub fn alloc(self: *DmaTracker, count: u32) ?u64 {
        const phys = allocPagesPhys(count) orelse return null;
        if (self.len >= CAP) @panic("gpu.shim: DmaTracker capacity exceeded — raise CAP");
        self.entries[self.len] = .{ .phys = phys, .pages = count };
        self.len += 1;
        return phys;
    }

    /// Free every recorded buffer and reset. Idempotent (len -> 0).
    pub fn freeAll(self: *DmaTracker) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) freePagesPhys(self.entries[i].phys, self.entries[i].pages);
        self.len = 0;
    }
};

// --- MMIO mapping (os_map_kernel_space) ------------------------------------

/// os_map_kernel_space: map a BAR window with an explicit cache type.
pub fn mapKernelSpace(phys: u64, size: u64, cache: mmio.CacheType) mmio.Mapping {
    return mmio.map(phys, size, cache);
}

// --- PCI (os_pci_* ) --------------------------------------------------------

/// os_pci_read_dword: the RM "handle" is a *pci.Device.
pub fn pciReadDword(handle: pci.Device, offset: u8) u32 {
    return handle.read32(offset);
}
/// os_pci_write_dword: the RM "handle" is a *pci.Device.
pub fn pciWriteDword(handle: pci.Device, offset: u8, value: u32) void {
    handle.write32(offset, value);
}

// --- Locks (os_alloc_spinlock / acquire / release) -------------------------

/// os_acquire_spinlock returns saved IRQ flags as an NvU64; we mirror that with
/// the IRQ-safe spinlock's saved-flags bool.
pub fn acquireSpinlock(lock: *SpinLock) bool {
    return lock.acquireIrqSave();
}
/// os_release_spinlock: restore the IRQ state (`if_was`) that acquireSpinlock saved.
pub fn releaseSpinlock(lock: *SpinLock, if_was: bool) void {
    lock.releaseIrqRestore(if_was);
}

// --- Time (os_get_monotonic_time_ns / os_delay_us) -------------------------

/// os_get_monotonic_time_ns. The kudos timer is millisecond-resolution, so the
/// nanosecond value is scaled millis, not a finer clock.
pub fn monotonicTimeNs() u64 {
    return timer.millis() * 1_000_000;
}
/// os_delay_us: block for at least `us` microseconds.
///
/// Sub-tick delays go through the calibrated TSC (tsc.udelay). The PIT tick is
/// 1000/hz ms and timer.sleep rounds UP to a whole tick, so the old
/// timer.sleep-only path inflated every sub-tick cadence to ≥10 ms — GSP poll
/// budgets written as iterations × 1 ms (nouveau parity) really meant 10× their
/// documented wall-clock (a "2 s" GFW-boot budget was ~20 s). At or above one
/// tick, timer.sleep stays: it hlt-waits and, in the SMP build, yields the core
/// to other tasks — which a TSC busy-spin must not replace for long waits
/// (e.g. dp.zig's up-to-1 s link-retry backoff on the session path).
pub fn delayUs(us: u32) void {
    // Bring-up service point: the GSP/display bring-up poll loops funnel
    // through this delay, and the steady loops that normally service the
    // network only start AFTER bring-up. netKeepalive's callees are internally
    // gated / early-out when idle, so a kHz poll cadence stays cheap.
    netKeepalive();
    const hz = timer.frequency();
    if (hz == 0) @panic("shim.delayUs before timer.init");
    const tick_us: u64 = 1_000_000 / hz;
    if (us < tick_us) {
        tsc.udelay(us);
        return;
    }
    timer.sleep((@as(u64, us) + 999) / 1000);
}

// --- wait-time network keepalive -------------------------------------------

/// What the keepalive runs. A pub hook so the boot orchestration can
/// substitute a richer service function; the DEFAULT is the full trio and is
/// installed from day zero — the machine must keep answering OP_REBOOT (and
/// petting the dead-man) through GSP boot, display bring-up, and teardown, or
/// a hang in any of them takes it off the air. Owning the default here makes
/// shim the ONE gpu module that names the network layers.
pub var keepalive_hook: *const fn () void = &keepaliveTrio;

/// The full network-servicing trio: drain queued netdebug onto the wire, run
/// the net stack, answer KMR1 (fileserv). Not just the drain — remote
/// status/reboot rides on all three.
fn keepaliveTrio() void {
    netdebug.drain();
    net.pump();
    fileserv.step();
}

/// Run the wait-time network keepalive. The GPU group's long paths (delayUs
/// poll loops, the stick-shot writer) call this instead of naming the network
/// layers themselves.
pub fn netKeepalive() void {
    keepalive_hook();
}

// --- DMA coherency ---------------------------------------------------------

/// Make CPU-written DMA buffers (WPR meta, radix3 tables, message queues) visible
/// to the GPU/GSP, which DMA them from WB-cached sysmem. kudos has no IOMMU/DMA
/// API, so we write-back+invalidate all caches at the hand-off points. Delegates
/// to cpu.flushCaches (single owner of the wbinvd instruction).
pub fn flushDmaBuffers() void {
    cpu.flushCaches();
}

/// Flush a single cache line containing `addr` — cheap coherency for a polled
/// DMA pointer/value (push our write to RAM, or pull a device write). Use this in
/// hot loops instead of flushDmaBuffers (full wbinvd), which is ruinously slow
/// when a large device BAR is mapped. Delegates to cpu.clflush.
pub fn invalidateLine(addr: u64) void {
    cpu.clflush(addr);
}

/// Flush a specific buffer range out of cache (clflush each 64-byte line). Use
/// for a CPU-written DMA buffer before a device reads it. MUCH faster than
/// flushDmaBuffers (full wbinvd) — a single wbinvd with the 24GB GPU BAR + 64GB
/// RAM mapped costs ~seconds, which trips the timing-sensitive GSP-init watchdog.
pub fn flushRange(addr: u64, len: u64) void {
    // Flush every cache line the range TOUCHES: round the start down and the
    // end up to line size, or an unaligned tail line escapes the flush.
    const start = addr & ~@as(u64, 63);
    const end = (addr + len + 63) & ~@as(u64, 63);
    var a = start;
    while (a < end) : (a += 64) cpu.clflush(a);
}

// --- Unimplemented contract surface ----------------------------------------

/// The refusal for any os_* entry point outside the subset kudos implements:
/// fail loudly, so an unported dependency is never silently a no-op.
pub fn notSupported(comptime name: []const u8) Status {
    log("gpu.shim: os_{s} not implemented (beyond M9 subset)\n", .{name});
    return .err_not_supported;
}
