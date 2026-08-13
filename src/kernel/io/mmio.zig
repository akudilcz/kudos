//! Memory-mapped I/O load/store primitives. Single source of truth for volatile
//! MMIO register access (cf. io/io.zig for port I/O, cpu/cpu.zig for MSR/CR/CPUID).
//!
//! Every driver that touches device registers (LAPIC, xHCI, the Intel NICs, the
//! SMP trampoline handoff) reads/writes through these helpers rather than
//! re-spelling the `@as(*volatile u32, @ptrFromInt(addr)).*` cast. Drivers keep
//! only their own `base + offset` wrapper on top.

/// Read a 32-bit register at absolute address `addr`.
pub inline fn read32(addr: usize) u32 {
    return @as(*align(4) volatile u32, @ptrFromInt(addr)).*;
}

/// Write a 32-bit register at absolute address `addr`.
pub inline fn write32(addr: usize, val: u32) void {
    @as(*align(4) volatile u32, @ptrFromInt(addr)).* = val;
}

/// Write a 64-bit register as two 32-bit halves (low then high) — the portable
/// way to program a 64-bit MMIO register on x86 without assuming a 64-bit store.
///
/// This lo-then-hi pair is **not atomic**: for a fleeting instant the register
/// holds the new low dword with the OLD high dword. That is only harmless when the
/// high dword does not actually change between the two calls — e.g. when every
/// value programmed keeps the same (typically zero) high dword. The xHCI driver
/// programs CRCR / DCBAAP / ERSTBA / ERDP through this and relies on all its DMA
/// physical addresses staying below 4 GiB (high dword == 0), which it enforces
/// with an assert at its allocation site (the low-memory DMA
/// invariant). Callers that could program a genuinely 64-bit-wide value while the
/// hardware is live must not use this helper.
pub inline fn write64(addr: usize, val: u64) void {
    write32(addr, @truncate(val));
    write32(addr + 4, @truncate(val >> 32));
}
