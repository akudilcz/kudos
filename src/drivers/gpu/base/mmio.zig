//! MMIO BAR mapping with explicit cache type — the kudos side of the RM's
//! `os_map_kernel_space`. kudos is identity-mapped, so a "mapping" is really
//! choosing the page cache type for a physical window:
//! UC for register BARs, WC for the BAR1 framebuffer aperture. The PAT/MTRR
//! effective type is the same machinery the WC framebuffer uses.
//!
//! The PAT/MTRR mechanism itself is owned by cpu/cpu.zig (single source of
//! truth); this file is GPU policy that calls cpu.mapMmio (the GPU
//! isolation invariant).

const cpu = @import("../../../kernel/cpu/cpu.zig");

/// Cache type for a mapped MMIO window. Matches the `mode` arg of
/// `os_map_kernel_space` (UC / WC / cached). `cached` (write-back) is the
/// identity map's default and needs no MTRR change.
pub const CacheType = enum { uc, wc, cached };

/// A mapped MMIO window. Because the address space is identity-mapped, `base`
/// is both the physical and virtual address; `cache` records the programmed
/// effective type so registers (UC) and apertures (WC) are not confused.
/// KTRACE: gated register tracer to byte-diff our BAR0 traffic against the
/// instrumented-nouveau reference (same KTRACE format + address ranges).
pub var ktrace_on: bool = false;
const log = @import("log.zig").gpu;

/// True if BAR0 offset `a` falls in a KTRACE-watched range — the falcon/GSP/PMC
/// register blocks we byte-diff against the instrumented-nouveau reference. Gates
/// the KTRACE log lines so the trace covers the same address ranges nouveau's does.
fn ktraceAddr(a: u64) bool {
    return (a >= 0x110000 and a < 0x850000) or
        (a >= 0x118000 and a < 0x118800) or
        (a >= 0x1fa000 and a < 0x1fb000) or
        (a >= 0x100000 and a < 0x100c00) or
        (a < 0x004000) or
        (a >= 0x625000 and a < 0x626000) or
        (a >= 0x820000 and a < 0x825000);
}

pub const Mapping = struct {
    base: u64,
    size: u64,
    cache: CacheType,

    /// Volatile 32-bit register read at byte `off` from the window base.
    pub fn read32(self: Mapping, off: u64) u32 {
        const p: *volatile u32 = @ptrFromInt(self.base + off);
        const v = p.*;
        if (ktrace_on and ktraceAddr(off)) log("KTRACE rd {x:0>6} = {x:0>8}\n", .{ off, v });
        return v;
    }

    /// Volatile 32-bit register write at byte `off` from the window base.
    pub fn write32(self: Mapping, off: u64, val: u32) void {
        if (ktrace_on and ktraceAddr(off)) log("KTRACE wr {x:0>6} = {x:0>8}\n", .{ off, val });
        const p: *volatile u32 = @ptrFromInt(self.base + off);
        p.* = val;
    }
};

/// Map a physical BAR window with the given cache type. kudos is identity-mapped,
/// so the base address is returned as-is after the window's effective cache type
/// is set via a variable MTRR (cpu.mapMmio). `cached` is the WB default and needs
/// no MTRR change. Interrupts must be off (single-CPU MTRR sequence) — true
/// during bring-up before idt.enableInterrupts().
pub fn map(phys: u64, size: u64, cache: CacheType) Mapping {
    switch (cache) {
        .uc => cpu.mapMmio(phys, size, .uc),
        .wc => cpu.mapMmio(phys, size, .wc),
        .cached => {}, // identity map is already write-back
    }
    return .{ .base = phys, .size = size, .cache = cache };
}
