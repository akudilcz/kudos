//! VRAM allocator + CPU access for driver-owned surfaces (scanout, instmem).
//!
//! kudos has exactly one VRAM consumer — the display path — and a statically
//! known reserved top (`fblayout` carves `[heap][wpr2][nonwpr_heap]` from the top
//! of VRAM; the GSP-RM's own heap lives *inside* WPR2). So instead of parsing the
//! RM's `fbRegion[]` heap map (nouveau's general-purpose path), kudos bump-allocates
//! from VRAM base 0 upward through the free region `[0, nonwpr_heap.addr)`, which is
//! disjoint from the RM's reserved region as `fblayout` computes it. Simpler, RPC-free, and trivially
//! checkable against `fblayout.free`.
//!
//! CPU pixel access uses the BAR0 PRAMIN window (nouveau `nv50_instmem`/`gh100`):
//! point a 64 KiB window at a VRAM phys address, then read/write through the
//! aperture. Slow (one MMIO per dword + a repoint per 64 KiB) but needs no BAR1/VMM
//! — right for first light. A direct BAR1 WC aperture is the faster follow-up.

const mmio = @import("../base/mmio.zig");
const fblayout = @import("../base/fblayout.zig");
const log = @import("../base/log.zig").gpu;

/// BAR0 PRAMIN window: `wr32(WIN_SEL, addr>>16)` selects a 64 KiB VRAM window;
/// access goes through `[WIN_APERTURE + (addr & 0xffff)]` (nouveau nv50.c:398,
/// Ada gh100.c:10 — same shift/semantics).
const WIN_SEL: u64 = 0x001700;
const WIN_APERTURE: u64 = 0x700000;
const WIN_SIZE: u64 = 0x10000; // 64 KiB

/// A bump allocator over the free VRAM region. Hands out physical VRAM byte
/// addresses; never frees (the display path allocates a fixed set of surfaces once).
pub const Allocator = struct {
    base: u64, // free region start (0)
    limit: u64, // free region end (exclusive)
    top: u64, // next free byte

    /// Start the bump allocator over `layout.free` — the VRAM region below the
    /// RM's reserved top, below `nonwpr_heap.addr` as `fblayout` computes it.
    pub fn init(layout: fblayout.FbLayout) Allocator {
        return .{ .base = layout.free.addr, .limit = layout.free.addr + layout.free.size, .top = layout.free.addr };
    }

    /// Carve `size` bytes at `alignment`. Returns the physical VRAM byte address,
    /// usable directly as a surface/instmem address and as a PRAMIN target.
    pub fn alloc(self: *Allocator, size: u64, alignment: u64) !u64 {
        const a = (self.top + alignment - 1) & ~(alignment - 1);
        if (a + size > self.limit) {
            log("gpu.vram: OOM: need 0x{x}@0x{x}, limit 0x{x}\n", .{ size, a, self.limit });
            return error.VramOutOfMemory;
        }
        self.top = a + size;
        return a;
    }
};

/// Write one dword to VRAM `phys` via the PRAMIN window. Repoints the window each
/// call (correct but slow); `fill`/`blit` repoint once per 64 KiB chunk instead.
pub fn write32(regs: mmio.Mapping, phys: u64, data: u32) void {
    regs.write32(WIN_SEL, @truncate(phys >> 16));
    regs.write32(WIN_APERTURE + (phys & 0xffff), data);
}

/// Read one dword from VRAM `phys` via the PRAMIN window.
pub fn read32(regs: mmio.Mapping, phys: u64) u32 {
    regs.write32(WIN_SEL, @truncate(phys >> 16));
    return regs.read32(WIN_APERTURE + (phys & 0xffff));
}

/// Fill `[phys, phys+len)` (len a multiple of 4) with `value`, repointing the
/// PRAMIN window only when crossing a 64 KiB boundary — far fewer window writes
/// than per-dword `write32`.
pub fn fill(regs: mmio.Mapping, phys: u64, len: u64, value: u32) void {
    var w = Writer.init(regs, phys);
    var off: u64 = 0;
    while (off < len) : (off += 4) w.put(value);
}

/// Write a byte buffer `data` (length a multiple of 4) to VRAM `[phys, phys+len)`
/// through the PRAMIN window, packing little-endian dwords via the bulk Writer.
/// Used for the OLUT buffer (u16 triplets) and other small VRAM structures.
pub fn writeBytes(regs: mmio.Mapping, phys: u64, data: []const u8) void {
    var w = Writer.init(regs, phys);
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        const word: u32 = @as(u32, data[i]) | (@as(u32, data[i + 1]) << 8) |
            (@as(u32, data[i + 2]) << 16) | (@as(u32, data[i + 3]) << 24);
        w.put(word);
    }
}

/// A sequential VRAM dword writer that repoints the PRAMIN window only when the
/// address crosses a 64 KiB boundary — for bulk surface writes (test patterns,
/// compositor present) it cuts window selects from one-per-dword to one-per-64KiB.
pub const Writer = struct {
    regs: mmio.Mapping,
    addr: u64,
    win: u64 = ~@as(u64, 0), // current window selector (force select on first put)

    /// Start a bulk writer at VRAM `phys`; the first `put` forces a window select.
    pub fn init(regs: mmio.Mapping, phys: u64) Writer {
        return .{ .regs = regs, .addr = phys };
    }

    /// Write one dword at the cursor and advance by 4.
    pub fn put(self: *Writer, val: u32) void {
        const sel = self.addr >> 16;
        if (sel != self.win) {
            self.regs.write32(WIN_SEL, @truncate(sel));
            self.win = sel;
        }
        self.regs.write32(WIN_APERTURE + (self.addr & 0xffff), val);
        self.addr += 4;
    }

    /// Reposition the cursor to an arbitrary VRAM address.
    pub fn seek(self: *Writer, phys: u64) void {
        self.addr = phys;
    }
};
