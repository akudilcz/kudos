//! Pure, device-independent computations for the GPU bring-up path: MSI message
//! composition, MTRR/WC ranges, and pitch math. No hardware dependency, so the
//! hardware files call in here and the host tests exercise the same code the kernel runs.
//!
//! Alignment does NOT live here. Its one home is `kernel/memory/align.zig`, reachable
//! from any pure module as the `algn` named module.

// --- MSI message composition ------------------------------------------------

/// x86 MSI message address for physical destination to one LAPIC:
/// `0xFEE00000 | (apic_id << 12)` (redirection-hint and destination-mode = 0).
pub fn msiAddress(apic_id: u32) u32 {
    return 0xFEE0_0000 | (apic_id << 12);
}

/// x86 MSI message data for edge-triggered, fixed delivery: the vector number in
/// the low byte (delivery_mode=000, trigger=0 ⇒ data == vector).
pub fn msiData(vector: u8) u16 {
    return vector;
}

// MSI vector→handler-slot mapping is NOT here: it is `vector - isr.MSI_VECTOR_BASE`,
// owned by src/kernel/interrupts/isr.zig (registerMsi / isrDispatch) as the single source
// of truth for the interrupt-vector layout. Duplicating it here would risk the two
// drifting apart.

// --- MTRR variable-range encoding -------------------------------------------
//
// NOTE: cpu.zig's addMtrr() owns the live MTRR programming (it predates this and
// also serves the framebuffer, so the layering is cpu <- gpu, not the
// reverse). These functions mirror that exact encoding so it can be host-tested
// independently — if cpu.zig's algorithm changes, these tests must change with
// it. They are a verification companion, not the call path.

/// Smallest power-of-two >= span, floor 4 KiB (one MTRR pair covers a single
/// naturally-aligned power-of-two region).
pub fn mtrrSize(span: u64) u64 {
    var size: u64 = 1 << 12;
    while (size < span) size <<= 1;
    return size;
}

/// PHYSBASE value: base aligned down to `size`, low bits = memory type.
pub fn mtrrPhysBase(phys: u64, size: u64, mem_type: u8) u64 {
    const base = phys & ~(size - 1);
    return (base & ~@as(u64, 0xFFF)) | mem_type;
}

/// PHYSMASK value: mask selecting [base, base+size), V (valid) bit set, clamped
/// to the CPU's physical-address width.
pub fn mtrrPhysMask(size: u64, phys_addr_bits: u6) u64 {
    const addr_mask: u64 = (@as(u64, 1) << phys_addr_bits) - 1;
    return (~(size - 1) & addr_mask & ~@as(u64, 0xFFF)) | (1 << 11);
}

// --- tests ------------------------------------------------------------------
