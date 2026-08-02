//! First-fit free-list allocator over one contiguous virtual-address region,
//! managing VA extents with a real free — pure (imports only `std`), so the
//! alloc/free/coalescing invariants are host-tested. Every request rounds up to
//! a page and the caller's region base is page-aligned, so extents stay
//! page-aligned and an allocation never leaves an unusable gap in front of
//! itself. Freeing coalesces with abutting extents so a released block rejoins
//! its neighbours instead of fragmenting the region.

const std = @import("std");

/// Extent granularity: one 4 KiB page.
const PAGE_BYTES: u64 = 0x1000;

/// One contiguous free range of the region.
pub const Extent = struct { va: u64, size: u64 };

pub const ExtentHeap = struct {
    /// Free-list capacity — far above the desktop's live resource count, so a
    /// full list is a bug worth reporting (see freeBlock), not a condition to
    /// size for.
    pub const CAP = 128;

    free: [CAP]Extent = undefined,
    n: usize = 0,

    /// A heap owning the single region `[base_va, base_va + size)`.
    pub fn init(base_va: u64, size: u64) ExtentHeap {
        var h = ExtentHeap{};
        h.free[0] = .{ .va = base_va, .size = size };
        h.n = 1;
        return h;
    }

    /// First-fit allocation of `want_bytes` rounded up to a page. Returns the
    /// extent's VA, or null when no free extent is large enough.
    pub fn alloc(self: *ExtentHeap, want_bytes: u64) ?u64 {
        const want = std.mem.alignForward(u64, want_bytes, PAGE_BYTES);
        for (self.free[0..self.n]) |*e| {
            if (e.size < want) continue;
            const va = e.va;
            if (e.size == want) {
                // The extent is spent — drop it by moving the last one into its slot.
                self.n -= 1;
                e.* = self.free[self.n];
            } else {
                e.va += want;
                e.size -= want;
            }
            return va;
        }
        return null;
    }

    /// Return `[va, va + size_bytes)` (rounded up to a page) to the heap,
    /// coalescing with any extent that abuts either end — repeatedly, so the
    /// freed block and both neighbours end as one extent. Returns null on
    /// success; when the free list is FULL, returns the (merged) block that
    /// could not be reinserted — it leaks rather than corrupting the list, and
    /// the caller logs it.
    pub fn freeBlock(self: *ExtentHeap, va: u64, size_bytes: u64) ?Extent {
        var va0 = va;
        var size = std.mem.alignForward(u64, size_bytes, PAGE_BYTES);
        var merged = true;
        while (merged) {
            merged = false;
            var i: usize = 0;
            while (i < self.n) {
                const e = self.free[i];
                if (e.va + e.size == va0) {
                    va0 = e.va;
                    size += e.size;
                } else if (va0 + size == e.va) {
                    size += e.size;
                } else {
                    i += 1;
                    continue;
                }
                self.n -= 1;
                self.free[i] = self.free[self.n];
                merged = true;
            }
        }
        if (self.n == CAP) return .{ .va = va0, .size = size };
        self.free[self.n] = .{ .va = va0, .size = size };
        self.n += 1;
        return null;
    }
};
