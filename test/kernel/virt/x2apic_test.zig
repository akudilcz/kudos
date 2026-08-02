//! Host tests of src/kernel/virt/x2apic.zig.

const std = @import("std");
const x2apic = @import("x2apic");
const Apic = x2apic.Apic;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

/// The vector `nextPending` would inject (dropping the source), for the tests
/// that only assert priority resolution.
fn vec(p: ?Apic.Pending) ?u8 {
    return if (p) |x| x.vector else null;
}

test "VERSION reads as an integrated APIC, and APIC_BASE resets in xAPIC mode" {
    var a = Apic{};
    try expectEqual(@as(?u64, 0x50014), a.msrRead(0x803));
    const base = a.msrRead(0x1B).?;
    try expectEqual(@as(u64, 0xFEE00000), base & 0xFFFF_F000);
    try expect(base & (1 << 8) != 0); // BSP
    try expect(base & (1 << 11) != 0); // globally enabled
    // NOT x2APIC: this is the state real firmware leaves, and the state every
    // kernel's APIC setup is written for. Claiming x2APIC here makes a guest log
    // "enabled by BIOS" and then read the memory-mapped ID register through an
    // APIC driver it has not switched over yet — a fault with no handler behind
    // it.
    try expectEqual(@as(u64, 0), base & (1 << 10));
}

test "the guest turns x2APIC on itself, and APIC_BASE then says so" {
    var a = Apic{};
    try expect(a.msrWrite(0x1B, 0xFEE0_0000 | (1 << 10) | (1 << 11)).? == .none);
    try expect(a.msrRead(0x1B).? & (1 << 10) != 0);
    // …and back off again: a kernel that decides it cannot use x2APIC (no
    // interrupt remapping) clears the bit and returns to the memory-mapped view.
    try expect(a.msrWrite(0x1B, 0xFEE0_0000 | (1 << 11)).? == .none);
    try expectEqual(@as(u64, 0), a.msrRead(0x1B).? & (1 << 10));
}

test "LVT timer supplies its vector only while unmasked" {
    var a = Apic{};
    try expectEqual(@as(?u8, null), a.timerVector()); // LVTs reset masked
    const w = a.msrWrite(0x832, 0x4_00EC).?; // TSC-deadline mode, vector 0xEC
    try expect(w == .none);
    try expectEqual(@as(?u8, 0xEC), a.timerVector());
    try expectEqual(@as(?u64, 0x4_00EC), a.msrRead(0x832));
    _ = a.msrWrite(0x832, 0x1_00EC); // masked
    try expectEqual(@as(?u8, null), a.timerVector());
}

test "raise, inject, and EOI walk a vector through IRR and ISR" {
    var a = Apic{};
    a.raise(0x35);
    try expectEqual(@as(?u64, 1 << 0x15), a.msrRead(0x821)); // IRR chunk 1
    try expectEqual(@as(?u8, 0x35), vec(a.nextPending(null)));
    a.accept(0x35);
    try expectEqual(@as(?u64, 0), a.msrRead(0x821)); // left IRR
    try expectEqual(@as(?u64, 1 << 0x15), a.msrRead(0x811)); // entered ISR
    try expectEqual(@as(?u8, null), vec(a.nextPending(null))); // own class blocks
    const w = a.msrWrite(0x80B, 0).?; // guest EOI
    try expect(w == .none);
    try expectEqual(@as(?u64, 0), a.msrRead(0x811));
    a.raise(0x35); // the line is serviceable again
    try expectEqual(@as(?u8, 0x35), vec(a.nextPending(null)));
}

test "a higher class preempts an in-service lower one; the same class waits" {
    var a = Apic{};
    a.raise(0x35);
    a.accept(0x35);
    a.raise(0x36); // same class 3 as the one in service
    try expectEqual(@as(?u8, null), vec(a.nextPending(null)));
    a.raise(0x81); // class 8 beats class 3
    try expectEqual(@as(?u8, 0x81), vec(a.nextPending(null)));
    a.accept(0x81);
    try expectEqual(@as(?u64, 1 << 1), a.msrRead(0x814)); // 0x81 in ISR chunk 4
    a.eoiPending(); // retires the highest in-service vector: 0x81
    try expectEqual(@as(?u64, 0), a.msrRead(0x814));
    try expectEqual(@as(?u8, null), vec(a.nextPending(null))); // 0x35 still holds 0x36
    a.eoiPending();
    try expectEqual(@as(?u8, 0x36), vec(a.nextPending(null)));
}

test "TPR gates injection by priority class" {
    var a = Apic{};
    _ = a.msrWrite(0x808, 0x80); // TPR class 8
    a.raise(0x35);
    try expectEqual(@as(?u8, null), vec(a.nextPending(null)));
    a.raise(0x91); // class 9 exceeds TPR
    try expectEqual(@as(?u8, 0x91), vec(a.nextPending(null)));
    try expectEqual(@as(?u64, 0x80), a.msrRead(0x808));
}

test "ExtINT via LINT0 delivers the 8259 vector below fixed interrupts" {
    var a = Apic{};
    // Reset: the APIC is software-disabled, so the PIC drives INTR directly
    // (virtual wire, SDM §11.4.7.2) and LINT0's reset mask does not gate it.
    try expectEqual(@as(?u8, 0x24), vec(a.nextPending(0x24)));
    // Software-enabled, LINT0's programming takes over — reset state is masked.
    _ = a.msrWrite(0x80F, 0x1FF); // SVR: software-enable (bit 8) + spurious vector
    try expectEqual(@as(?u8, null), vec(a.nextPending(0x24)));
    _ = a.msrWrite(0x835, 0x700); // delivery mode ExtINT, unmasked
    try expectEqual(@as(?u8, 0x24), vec(a.nextPending(0x24)));
    a.raise(0x35); // a fixed interrupt outranks the ExtINT line
    try expectEqual(@as(?u8, 0x35), vec(a.nextPending(0x24)));
    _ = a.msrWrite(0x835, 0x1_0700); // masked again
    a.accept(0x35);
    a.eoiPending();
    try expectEqual(@as(?u8, null), vec(a.nextPending(0x24)));
    _ = a.msrWrite(0x835, 0x30); // unmasked but fixed delivery, not ExtINT
    try expectEqual(@as(?u8, null), vec(a.nextPending(0x24)));
}

test "a fixed-delivery ICR write is a self-IPI on one vCPU" {
    var a = Apic{};
    const w = a.msrWrite(0x830, 0x40); // fixed delivery, vector 0x40
    try expectEqual(@as(u8, 0x40), w.?.inject);
    try expectEqual(@as(?u8, 0x40), vec(a.nextPending(null)));
    try expectEqual(@as(?u64, 0x40), a.msrRead(0x830)); // ICR reads back
}

test "SELF_IPI raises its vector" {
    var a = Apic{};
    const w = a.msrWrite(0x83F, 0xF2).?;
    try expectEqual(@as(u8, 0xF2), w.inject);
    try expectEqual(@as(?u8, 0xF2), vec(a.nextPending(null)));
}

test "a TSC-deadline write asks the machine model to arm the host timer" {
    var a = Apic{};
    const w = a.msrWrite(0x6E0, 123_456_789).?;
    try expectEqual(@as(u64, 123_456_789), w.arm_deadline);
    try expectEqual(@as(?u64, 123_456_789), a.msrRead(0x6E0));
    const disarm = a.msrWrite(0x6E0, 0).?;
    try expectEqual(@as(u64, 0), disarm.arm_deadline);
}

test "nextPending reports the source so the machine retires the right one" {
    var a = Apic{};
    _ = a.msrWrite(0x835, 0x700); // LINT0 ExtINT, unmasked
    const ext = a.nextPending(0x24).?;
    try expectEqual(Apic.Source.extint, ext.source);
    try expectEqual(@as(u8, 0x24), ext.vector);
    a.raise(0x35); // a fixed vector now outranks the ExtINT line
    const fixed = a.nextPending(0x24).?;
    try expectEqual(Apic.Source.apic, fixed.source);
    try expectEqual(@as(u8, 0x35), fixed.vector);
}

test "fireTimer disarms the deadline and raises the timer vector" {
    var a = Apic{};
    _ = a.msrWrite(0x832, 0x4_00EC); // TSC-deadline mode, vector 0xEC, unmasked
    _ = a.msrWrite(0x6E0, 123_456_789); // arm
    try expectEqual(@as(u64, 123_456_789), a.armedDeadline());
    a.fireTimer();
    try expectEqual(@as(u64, 0), a.armedDeadline()); // hardware disarms the MSR
    try expectEqual(@as(?u64, 0), a.msrRead(0x6E0)); // and RDMSR now reads 0
    try expectEqual(@as(?u8, 0xEC), vec(a.nextPending(null))); // vector latched in IRR
}

test "fireTimer with a masked LVT timer disarms but raises nothing" {
    var a = Apic{};
    _ = a.msrWrite(0x832, 0x1_00EC); // masked
    _ = a.msrWrite(0x6E0, 42);
    a.fireTimer();
    try expectEqual(@as(u64, 0), a.armedDeadline());
    try expectEqual(@as(?u8, null), vec(a.nextPending(null)));
}

test "a non-APIC MSR falls through as null" {
    var a = Apic{};
    try expectEqual(@as(?u64, null), a.msrRead(0xC000_0080)); // IA32_EFER
    try expectEqual(@as(?x2apic.Action, null), a.msrWrite(0xC000_0080, 1));
    try expectEqual(@as(?u64, null), a.msrRead(0x7FF)); // just below the range
    try expectEqual(@as(?u64, null), a.msrRead(0x840)); // just above the range
}

// ── the memory-mapped (xAPIC) view ──────────────────────────────────────────
// The same register file, reached the other way. What is tested here is the
// TRANSLATION: every offset must land on the register the MSR view calls the
// same thing, and the three that do not follow the stride rule must be right,
// because a guest that finds its APIC id or its ICR in the wrong place does not
// fail loudly — it delivers interrupts to nobody.

test "a memory-mapped register and its MSR are the same register" {
    var a = Apic{};
    // Write through MMIO (offset 0x080 = TPR), read back through the MSR.
    _ = a.mmioWrite(0x080, 0x30);
    try expectEqual(@as(?u64, 0x30), a.msrRead(0x808));
    // …and the other way: the spurious-vector register, MSR 0x80F ↔ 0x0F0.
    _ = a.msrWrite(0x80F, 0x1FF);
    try expectEqual(@as(u32, 0x1FF), a.mmioRead(0x0F0));
    // An LVT entry, MSR 0x832 ↔ offset 0x320.
    _ = a.mmioWrite(0x320, 0x4_00EC);
    try expectEqual(@as(?u64, 0x4_00EC), a.msrRead(0x832));
    try expectEqual(@as(?u8, 0xEC), a.timerVector());
}

test "the memory-mapped ID register keeps the APIC id in its top byte" {
    var a = Apic{};
    // x2APIC uses the whole 32-bit register; xAPIC uses bits 31:24. The sole
    // vCPU is id 0, so both read zero — what must NOT happen is the all-ones a
    // missing device would give, which a guest reads as CPU 255.
    try expectEqual(@as(u32, 0), a.mmioRead(0x020));
    // The id is not the guest's to set: a write is accepted and ignored, exactly
    // as the MSR view ignores a write to MSR_APIC_ID.
    _ = a.mmioWrite(0x020, 0x0F00_0000);
    try expectEqual(@as(u32, 0), a.mmioRead(0x020));
}

test "the two ICR halves compose the one 64-bit ICR, low half issuing it" {
    var a = Apic{};
    // Destination first. On its own it sends nothing.
    try expect(a.mmioWrite(0x310, 0x0100_0000) == .none);
    try expectEqual(@as(u32, 0x0100_0000), a.mmioRead(0x310));
    // Then the low half: fixed delivery of vector 0x41 raises it, as the MSR
    // path does for a single 64-bit write.
    const act = a.mmioWrite(0x300, 0x41);
    try expect(act == .inject);
    try expectEqual(@as(u8, 0x41), act.inject);
    // Both halves read back as the one register the model stores.
    try expectEqual(@as(u32, 0x41), a.mmioRead(0x300));
    try expectEqual(@as(u32, 0x0100_0000), a.mmioRead(0x310));
}

test "the destination-format register exists only in the memory-mapped view" {
    var a = Apic{};
    // Reset is all-ones (flat). Linux writes it when it picks flat routing, and
    // there is no x2APIC MSR to forward it to.
    try expectEqual(@as(u32, 0xFFFF_FFFF), a.mmioRead(0x0E0));
    _ = a.mmioWrite(0x0E0, 0x0FFF_FFFF);
    try expectEqual(@as(u32, 0x0FFF_FFFF), a.mmioRead(0x0E0));
}

test "an EOI written through memory retires the in-service vector" {
    var a = Apic{};
    a.raise(0x41);
    a.accept(0x41);
    try expectEqual(@as(?Apic.Pending, null), a.nextPending(null)); // in service, blocks itself
    _ = a.mmioWrite(0x0B0, 0); // EOI
    a.raise(0x41);
    const p = a.nextPending(null).?;
    try expectEqual(@as(u8, 0x41), p.vector);
}

test "an unaligned or out-of-window access is counted, never silently zero" {
    var a = Apic{};
    // The registers sit every 16 bytes; anything else is not a register.
    try expectEqual(@as(u64, 0), a.mmio_unmodelled);
    try expectEqual(@as(u32, 0), a.mmioRead(0x084));
    try expectEqual(@as(u64, 1), a.mmio_unmodelled);
    _ = a.mmioWrite(0x1004, 0);
    try expectEqual(@as(u64, 2), a.mmio_unmodelled);
    // A real register at a real offset does not touch the counter.
    _ = a.mmioRead(0x080);
    try expectEqual(@as(u64, 2), a.mmio_unmodelled);
}
