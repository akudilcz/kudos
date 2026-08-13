//! Physical frame allocator. Bitmap over the identity-mapped
//! range. 1 bit per 4 KiB frame; set bit == used.
//!
//! The bitmap state machine is `FrameBitmap`, parameterized over caller-provided
//! storage so the kernel (2 MiB .bss arrays) and the host tests (a few bytes,
//! test/kernel/memory/pmm_test.zig) drive the SAME logic — one owner, no test fork.

const buildinfo = @import("buildinfo");
const mb = @import("../boot/multiboot2.zig");
const klog = @import("../debug/klog.zig");
const cpu = @import("../cpu/cpu.zig");
const algn = @import("algn"); // the ONE alignment home (named module: see build.zig)
const SpinLock = @import("../sync/spinlock.zig").SpinLock;

// Guards the bitmap + free_frames + hint across cores in the SMP build. The
// PMM is reached at runtime from multiple cores (the GPU/USB/net drivers'
// allocContiguous calls for DMA buffers), and alloc's test-then-set plus
// setUsed/setFree's non-atomic read-modify-write on a shared bitmap byte and on
// free_frames race without it — two cores could hand out the same frame. IRQ-safe
// because a scheduler/timer IRQ path can allocate (self-deadlock otherwise), and
// comptime-gated so the single-core build compiles the lock out entirely and stays
// lock-free (mirrors src/kernel/memory/heap.zig).
var lock: SpinLock = .{};

/// Acquire the PMM lock in the SMP build (IRQ-safe); a no-op returning false in
/// the single-core build so the lock compiles out entirely. Pair with unlockPmm.
inline fn lockPmm() bool {
    return if (buildinfo.smp) lock.acquireIrqSave() else false;
}
/// Release the PMM lock and restore the interrupt flag captured by lockPmm.
inline fn unlockPmm(if_was: bool) void {
    if (buildinfo.smp) lock.releaseIrqRestore(if_was);
}

pub const FRAME_SIZE: usize = 4096;

/// The frame-bitmap state machine: used/reserved planes over caller-provided
/// storage slices plus the frame counters and the search hint. No locking and no
/// hardware — the kernel wrappers below hold the PMM lock around every call.
/// Capacity (max frames) is the storage size: `bitmap.len * 8`.
pub const FrameBitmap = struct {
    bitmap: []u8, // set bit == used
    // Frames that must NEVER be handed out or freed: the low 1 MiB, the kernel image,
    // the multiboot info, and the boot modules — set once at init via `reserve`. A
    // caller-supplied address to `free`/`freeContiguous` (e.g. a driver mistakenly
    // freeing an MMIO/BAR base or a bogus low address) computes a valid in-range frame;
    // without this plane, freeing such a frame would flip a reserved bit to free and let
    // the next `alloc` hand out the IVT/BIOS/kernel region — silent corruption of the
    // running kernel. `free` consults this to refuse a reserved frame.
    reserved: []u8,
    avail_frames: usize, // total available RAM frames discovered
    free_frames: usize, // currently free
    hint: usize, // search start for alloc

    /// Frame capacity of the provided storage: one bit per frame.
    pub inline fn maxFrames(self: *const FrameBitmap) usize {
        return self.bitmap.len * 8;
    }

    /// Start a bitmap over `bm`/`rs` (equal-length; one bit per frame): everything
    /// used until proven available, nothing reserved yet — `freeAvailableRange`
    /// then frees the RAM the memory map reports, `reserve` carves back the
    /// never-touch regions.
    pub fn init(bm: []u8, rs: []u8) FrameBitmap {
        @memset(bm, 0xFF);
        @memset(rs, 0x00);
        return .{ .bitmap = bm, .reserved = rs, .avail_frames = 0, .free_frames = 0, .hint = 0 };
    }

    /// Is frame `f` marked used? Reads the one bit for that frame from the bitmap.
    pub inline fn isUsed(self: *const FrameBitmap, f: usize) bool {
        return (self.bitmap[f >> 3] & (@as(u8, 1) << @intCast(f & 7))) != 0;
    }
    /// Mark frame `f` used, decrementing free_frames. Idempotent (guarded by isUsed)
    /// so the free-frame count stays accurate on a redundant call.
    inline fn setUsed(self: *FrameBitmap, f: usize) void {
        if (!self.isUsed(f)) {
            self.bitmap[f >> 3] |= (@as(u8, 1) << @intCast(f & 7));
            self.free_frames -= 1;
        }
    }
    /// Mark frame `f` free, incrementing free_frames. Idempotent (guarded by isUsed)
    /// so a double free of the same frame does not inflate the count.
    inline fn setFree(self: *FrameBitmap, f: usize) void {
        if (self.isUsed(f)) {
            self.bitmap[f >> 3] &= ~(@as(u8, 1) << @intCast(f & 7));
            self.free_frames += 1;
        }
    }

    /// Whether frame `f` is permanently reserved (never allocatable/freeable).
    pub inline fn isReserved(self: *const FrameBitmap, f: usize) bool {
        return (self.reserved[f >> 3] & (@as(u8, 1) << @intCast(f & 7))) != 0;
    }

    /// Free every whole frame inside the available-RAM byte range [addr, addr+len)
    /// that lies below `limit`, counting each NEWLY freed frame into avail_frames
    /// (the isUsed guard dedupes overlapping memory-map entries). This is the
    /// init-time mmap walk body; partial frames at either end stay used.
    pub fn freeAvailableRange(self: *FrameBitmap, addr: usize, len: usize, limit: usize) void {
        const start = algn.up(addr, FRAME_SIZE);
        const end = algn.down(addr + len, FRAME_SIZE);
        var a = start;
        while (a + FRAME_SIZE <= end and a < limit) : (a += FRAME_SIZE) {
            const f = a / FRAME_SIZE;
            if (self.isUsed(f)) {
                self.setFree(f);
                self.avail_frames += 1;
            }
        }
    }

    /// Mark every frame overlapping [start,end) as used AND permanently reserved, so a
    /// later stray `free` of one of these frames cannot un-reserve it.
    pub fn reserve(self: *FrameBitmap, start: usize, end: usize) void {
        var a = algn.down(start, FRAME_SIZE);
        const e = @min(algn.up(end, FRAME_SIZE), self.maxFrames() * FRAME_SIZE);
        while (a < e) : (a += FRAME_SIZE) {
            const f = a / FRAME_SIZE;
            self.setUsed(f);
            self.reserved[f >> 3] |= (@as(u8, 1) << @intCast(f & 7));
        }
    }

    /// Find the next frame at or after `from` (wrapping once at maxFrames) whose
    /// bit is clear, without dereferencing past `self.bitmap`. Scans WHOLE BYTES
    /// (not bits) once aligned, so a long run of used frames — the common case on
    /// a near-full bitmap — costs one byte compare per 8 frames instead of one
    /// bit-test per frame. This is the scan `alloc`/`allocContiguous` both use;
    /// it holds no lock and mutates nothing (RTOS: bounding the O(frames) IRQ-off
    /// scan this way is what keeps a large DMA allocContiguous call from stalling
    /// this core's timer/wake IPIs for milliseconds on a mostly-full bitmap).
    fn nextFree(self: *const FrameBitmap, from: usize) ?usize {
        const max = self.maxFrames();
        if (max == 0) return null;
        var f = from;
        var wrapped = false;
        while (true) {
            if (f >= max) {
                if (wrapped) return null;
                wrapped = true;
                f = 0;
            }
            // Byte-align, then skip whole 0xFF bytes (8 fully-used frames each) —
            // the win: a long used run costs 1 byte load instead of 8 bit-tests.
            if (f & 7 != 0) {
                if (!self.isUsed(f)) return f;
                f += 1;
                continue;
            }
            const byte_i = f >> 3;
            if (self.bitmap[byte_i] == 0xFF) {
                f += 8;
                continue;
            }
            // This byte has a free bit — find it (at most 8 bit-tests, not the
            // whole remaining bitmap).
            var b: usize = 0;
            while (b < 8) : (b += 1) {
                if (!self.isUsed(f + b)) return f + b;
            }
            f += 8; // unreachable given the 0xFF check above, but keeps f moving
        }
    }

    /// Allocate one frame; returns its physical address (== virtual here). The
    /// kernel wrapper holds the PMM lock around the whole scan+claim so the test
    /// (isUsed) and set (setUsed) are atomic w.r.t. another core — otherwise two
    /// cores can both see `f` free and both claim it.
    pub fn alloc(self: *FrameBitmap) ?usize {
        const f = self.nextFree(self.hint) orelse return null;
        self.setUsed(f);
        self.hint = f + 1;
        return f * FRAME_SIZE;
    }

    /// Allocate `n` contiguous frames; returns the base physical address. The
    /// find-run-and-claim runs under the kernel wrapper's lock so no other core
    /// can steal a frame in the run between the scan and the claim.
    pub fn allocContiguous(self: *FrameBitmap, n: usize) ?usize {
        if (n == 0) return null;
        var f: usize = 0;
        while (f + n <= self.maxFrames()) {
            // Fast-forward past a used frame at the run's start via the same
            // byte-skipping scan `alloc` uses, instead of testing it bit-by-bit
            // only to immediately restart the run one frame later.
            if (self.isUsed(f)) {
                f = self.nextFree(f) orelse return null;
                continue;
            }
            var k: usize = 0;
            while (k < n and !self.isUsed(f + k)) : (k += 1) {}
            if (k == n) {
                var i: usize = 0;
                while (i < n) : (i += 1) self.setUsed(f + i);
                return f * FRAME_SIZE;
            }
            f += k + 1; // skip past the used frame that broke the run
        }
        return null;
    }

    /// Free the single frame containing `addr` and pull the search hint back to it.
    /// Only for single-frame allocations from `alloc` — see `freeContiguous` for runs.
    pub fn free(self: *FrameBitmap, addr: usize) void {
        const f = addr / FRAME_SIZE;
        // `free` is the one bitmap mutator reachable with a caller-supplied address (a
        // driver mistakenly freeing an MMIO/BAR base or a bogus low address). Guard both
        // ends: an f past maxFrames would index past the bitmap; a RESERVED f (low
        // 1 MiB / kernel / mbi / modules) must not be un-reserved and later handed out,
        // corrupting the running kernel. A frame that was never allocated is simply not
        // freed (setFree is idempotent on an already-free frame).
        if (f >= self.maxFrames() or self.isReserved(f)) return;
        self.setFree(f);
        if (f < self.hint) self.hint = f;
    }

    /// Free an `n`-frame run allocated by `allocContiguous`. `free` releases only ONE
    /// frame, so freeing a multi-frame contiguous allocation with it leaks all but the
    /// first frame — callers of `allocContiguous(n)` must free with this, passing the
    /// same `n`.
    pub fn freeContiguous(self: *FrameBitmap, addr: usize, n: usize) void {
        const base = addr / FRAME_SIZE;
        // Bound the whole run against the bitmap (same rationale as `free`): a bad
        // base/n must not walk setFree past the bitmap.
        if (base >= self.maxFrames() or n > self.maxFrames() - base) return;
        var i: usize = 0;
        // Skip any reserved frame in the run — a real contiguous allocation never spans
        // one (reserved frames read as used, so allocContiguous can't return a crossing
        // run), so this only fires on a bad/stray free and protects those frames.
        while (i < n) : (i += 1) if (!self.isReserved(base + i)) self.setFree(base + i);
        if (base < self.hint) self.hint = base;
    }
};

// ── kernel wiring: 64 GiB bitmap storage in .bss + the multiboot2 init walk ──

// Static ceiling the bitmap is sized for: 64 GiB of managed RAM, 2 MiB of bitmap,
// ample headroom for the GSP/GPU path's DMA-coherent allocations on a 128 GiB
// machine. The *usable* ceiling is `mapped_limit`, set at init to what the boot
// trampoline actually identity-mapped: 64 GiB when the CPU has 1 GiB pages
// (boot/boot.asm .map_1gb), else the 2 MiB-page fallback's 4 GiB. Frames above
// the mapped limit are never freed, so a handed-out frame is always directly
// addressable.
const MAX_ADDR: usize = 64 * 1024 * 1024 * 1024;
const MAX_FRAMES: usize = MAX_ADDR / FRAME_SIZE; // 16,777,216
const FALLBACK_LIMIT: usize = 4 * 1024 * 1024 * 1024; // 2 MiB-page map covers 4 GiB

var bitmap_storage: [MAX_FRAMES / 8]u8 = undefined; // 2 MiB in .bss
var reserved_storage: [MAX_FRAMES / 8]u8 = undefined; // 2 MiB in .bss (reserved plane)
var state: FrameBitmap = undefined; // built over the two storages in init
var mapped_limit: usize = FALLBACK_LIMIT; // set in init from CPU page-size support

/// CPUID.80000001h:EDX.PDPE1GB (bit 26) — does the CPU support 1 GiB pages? Must
/// match the test boot/boot.asm uses to choose its identity map. Public because
/// a session address space (memory/sessionspace.zig) mirrors the same choice.
pub fn has1GiBPages() bool {
    const edx = asm volatile (
        \\mov $0x80000001, %%eax
        \\cpuid
        : [edx] "={edx}" (-> u32),
        :
        : .{ .eax = true, .ebx = true, .ecx = true });
    return (edx & (1 << 26)) != 0;
}

/// Build the frame bitmap from the multiboot2 memory map: start all-used, free
/// every available-RAM frame within the boot trampoline's mapped range, then
/// reserve the low 1 MiB, the kernel image, the boot info blob, and each boot
/// module so the allocator can never hand out memory that is still in use.
/// Runs before APs start, so it needs no lock.
pub fn init(info_addr: u64, kstart: usize, kend: usize) void {
    state = FrameBitmap.init(&bitmap_storage, &reserved_storage);

    // Only manage RAM the boot trampoline actually identity-mapped.
    mapped_limit = if (has1GiBPages()) MAX_ADDR else FALLBACK_LIMIT;

    var it = mb.mmap(info_addr) orelse {
        klog.puts("FATAL: no multiboot2 memory map\n");
        cpu.park();
    };
    while (it.next()) |e| {
        if (e.type != 1) continue; // available RAM only
        state.freeAvailableRange(@intCast(e.addr), @intCast(e.len), mapped_limit);
    }

    // Carve back regions that must never be handed out.
    state.reserve(0, 0x100000); // low 1 MiB (IVT, BIOS, VGA)
    state.reserve(kstart, kend); // kernel image + boot page tables/stack
    state.reserve(@intCast(info_addr), @as(usize, @intCast(info_addr)) + mb.totalSize(info_addr));

    // Boot modules (e.g. the GSP firmware blobs) live in RAM that GRUB claimed;
    // reserve each span so the allocator never overwrites a firmware image we
    // still need to read (GSP firmware provisioning).
    var mit = mb.modules(info_addr);
    while (mit.next()) |m| state.reserve(@intCast(m.start), @intCast(m.end));
}

/// Allocate one frame under the PMM lock; returns its physical address.
pub fn alloc() ?usize {
    const s = lockPmm();
    defer unlockPmm(s);
    return state.alloc();
}

/// Allocate `n` contiguous frames under the PMM lock; returns the base address.
pub fn allocContiguous(n: usize) ?usize {
    const s = lockPmm();
    defer unlockPmm(s);
    return state.allocContiguous(n);
}

/// The ceiling for DMA-visible physical memory: devices programmed through the
/// split lo/hi `write64` pair (kernel/io/mmio.zig) — and any firmware struct
/// with a 32-bit pointer field — cannot safely carry a >= 4 GiB address; the
/// high dword is published non-atomically (or not at all). Every DMA allocation
/// site asserts against this at the ALLOCATION, so a high frame fails loud
/// there instead of corrupting a ring pointer silently.
pub const DMA_LIMIT: usize = 4 * 1024 * 1024 * 1024;

/// allocContiguous with the DMA rail enforced: panics if the run would reach
/// past DMA_LIMIT. Use for every buffer a device will read or write.
pub fn allocContiguousDma(n: usize) ?usize {
    const p = allocContiguous(n) orelse return null;
    if (p + n * FRAME_SIZE > DMA_LIMIT)
        @panic("pmm: DMA allocation >= 4 GiB (devices cannot address it — see DMA_LIMIT)");
    return p;
}

/// Free the single frame containing `addr` under the PMM lock.
pub fn free(addr: usize) void {
    const s = lockPmm();
    defer unlockPmm(s);
    state.free(addr);
}

/// Free an `n`-frame run allocated by `allocContiguous`, under the PMM lock.
pub fn freeContiguous(addr: usize, n: usize) void {
    const s = lockPmm();
    defer unlockPmm(s);
    state.freeContiguous(addr, n);
}

/// Currently-free managed RAM, in bytes.
pub fn freeBytes() usize {
    return state.free_frames * FRAME_SIZE;
}
/// Total available managed RAM discovered at init, in bytes.
pub fn totalBytes() usize {
    return state.avail_frames * FRAME_SIZE;
}
/// Currently-allocated managed RAM (total minus free), in bytes.
pub fn usedBytes() usize {
    return (state.avail_frames - state.free_frames) * FRAME_SIZE;
}
