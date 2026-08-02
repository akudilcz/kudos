//! Host tests of src/kernel/virt/vmsr.zig.

const std = @import("std");
const vmsr = @import("vmsr");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

fn expectValue(expected: u64, msr: u32) !void {
    switch (vmsr.read(msr)) {
        .value => |v| try expectEqual(expected, v),
        .gp => return error.TestUnexpectedGp,
    }
}

test "classify: APIC-base and the whole x2APIC MSR range route to the x2APIC model" {
    try expectEqual(vmsr.Class.apic, vmsr.classify(0x1B));
    try expectEqual(vmsr.Class.apic, vmsr.classify(0x800)); // first x2APIC register
    try expectEqual(vmsr.Class.apic, vmsr.classify(0x830)); // ICR, the hot one
    try expectEqual(vmsr.Class.apic, vmsr.classify(0x83F)); // last x2APIC register
    try expectEqual(vmsr.Class.gp, vmsr.classify(0x7FF)); // just below the range
    try expectEqual(vmsr.Class.gp, vmsr.classify(0x840)); // just above the range
}

test "classify: TSC-deadline routes to the x2APIC timer" {
    try expectEqual(vmsr.Class.tsc_deadline, vmsr.classify(0x6E0));
}

test "classify: EFER, the segment bases and SYSENTER are VMCS-guest-field resident" {
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0xC000_0080)); // EFER
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0xC000_0100)); // FS_BASE
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0xC000_0101)); // GS_BASE
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0x174)); // SYSENTER_CS
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0x175)); // SYSENTER_ESP
    try expectEqual(vmsr.Class.guest_field, vmsr.classify(0x176)); // SYSENTER_EIP
}

test "classify: the SYSCALL MSRs and KERNEL_GS_BASE ride the MSR-load area" {
    try expectEqual(vmsr.Class.auto_msr, vmsr.classify(0xC000_0081)); // STAR
    try expectEqual(vmsr.Class.auto_msr, vmsr.classify(0xC000_0082)); // LSTAR
    try expectEqual(vmsr.Class.auto_msr, vmsr.classify(0xC000_0083)); // CSTAR
    try expectEqual(vmsr.Class.auto_msr, vmsr.classify(0xC000_0084)); // FMASK
    try expectEqual(vmsr.Class.auto_msr, vmsr.classify(0xC000_0102)); // KERNEL_GS_BASE
}

test "classify: the fixed-value benign MSRs are handled here" {
    const benign = [_]u32{
        0x10, // IA32_TIME_STAMP_COUNTER
        0xCE, // IA32_PLATFORM_INFO
        0x10A, // IA32_ARCH_CAPABILITIES
        0x179, 0x17A, // IA32_MCG_CAP/STATUS
        0x1A0, // IA32_MISC_ENABLE
        0x1D9, // IA32_DEBUGCTL
        0x277, // IA32_PAT
    };
    for (benign) |msr| {
        try expectEqual(vmsr.Class.handled_here, vmsr.classify(msr));
    }
}

test "classify: anything else takes #GP" {
    try expectEqual(vmsr.Class.gp, vmsr.classify(0xDEAD));
    try expectEqual(vmsr.Class.gp, vmsr.classify(0x0)); // IA32_P5_MC_ADDR — not modeled
    try expectEqual(vmsr.Class.gp, vmsr.classify(0x2FF)); // IA32_MTRR_DEF_TYPE — no MTRRs
    try expectEqual(vmsr.Class.gp, vmsr.classify(0xC000_0103)); // IA32_TSC_AUX — not modeled
}

test "read: PAT returns the exact power-on default" {
    try expectValue(0x0007040600070406, 0x277);
}

test "read: MISC_ENABLE reports fast-strings only" {
    try expectValue(1, 0x1A0);
}

test "read: the zero-valued benign MSRs read as zero" {
    try expectValue(0, 0x10); // TSC placeholder (machine model substitutes rdtsc)
    try expectValue(0, 0xCE);
    try expectValue(0, 0x10A);
    try expectValue(0, 0x179);
    try expectValue(0, 0x17A);
    try expectValue(0, 0x1D9);
}

test "read: a guest-field / auto MSR is not a fixed-value read" {
    // These persist through the VMCS field or MSR-load area, so `read` (the
    // fixed-value policy) declines them — the caller routes by `classify` instead.
    try expectEqual(vmsr.RdResult.gp, vmsr.read(0xC000_0080)); // EFER
    try expectEqual(vmsr.RdResult.gp, vmsr.read(0xC000_0082)); // LSTAR
    try expectEqual(vmsr.RdResult.gp, vmsr.read(0x174)); // SYSENTER_CS
}

// VIRT-009: an unmodelled MSR faults the guest rather than reading a silent
// zero — a guest must never be told a lie about the machine.
test "read: an unknown MSR takes #GP" {
    try expectEqual(vmsr.RdResult.gp, vmsr.read(0xDEAD));
}

test "write: benign MSRs accept and discard, the passthrough TSC refuses" {
    try expectEqual(vmsr.WrResult.ok, vmsr.write(0x277, 0x0007040600070406)); // PAT
    try expectEqual(vmsr.WrResult.ok, vmsr.write(0x1D9, 0xFFFF)); // DEBUGCTL
    try expectEqual(vmsr.WrResult.gp, vmsr.write(0x10, 0)); // passthrough TSC
    try expectEqual(vmsr.WrResult.gp, vmsr.write(0xDEAD, 0)); // unknown
}

// --- guest-field write-through -------------------------------------------

test "guestFieldRead names the VMCS field the RDMSR reads back" {
    try expect(vmsr.guestFieldRead(0xC000_0080) != null); // EFER
    try expect(vmsr.guestFieldRead(0xC000_0100) != null); // FS_BASE
    try expect(vmsr.guestFieldRead(0xC000_0101) != null); // GS_BASE
    try expect(vmsr.guestFieldRead(0xC000_0082) == null); // LSTAR is auto, not a field
}

test "guestFieldWrite: FS/GS base and SYSENTER addresses must be canonical" {
    const ctx = vmsr.WriteCtx{ .efer = 0x500, .cr0 = 0x8000_0000 };
    // A canonical high-half kernel base writes through.
    switch (vmsr.guestFieldWrite(0xC000_0100, 0xFFFF_8000_1234_0000, ctx)) {
        .write => |w| try expectEqual(@as(u64, 0xFFFF_8000_1234_0000), w.value),
        .gp => return error.TestUnexpectedGp,
    }
    // A non-canonical base (bit 47 not sign-extended) is rejected like a real WRMSR.
    try expectEqual(vmsr.FieldWrite.gp, vmsr.guestFieldWrite(0xC000_0101, 0x0001_0000_0000_0000, ctx));
    try expectEqual(vmsr.FieldWrite.gp, vmsr.guestFieldWrite(0x175, 0x0080_0000_0000_0000, ctx)); // SYSENTER_ESP
}

test "guestFieldWrite: SYSENTER_CS keeps its 32-bit field" {
    const ctx = vmsr.WriteCtx{ .efer = 0x500, .cr0 = 0x8000_0000 };
    switch (vmsr.guestFieldWrite(0x174, 0xDEAD_BEEF_0000_0010, ctx)) {
        .write => |w| try expectEqual(@as(u64, 0x0000_0010), w.value),
        .gp => return error.TestUnexpectedGp,
    }
}

// --- EFER validation ------------------------------------------------------

test "eferWrite: setting NXE keeps the long-mode bits and forces LMA" {
    // The common guest write during boot: enable NX on top of long mode.
    switch (vmsr.eferWrite(0x500, 0xD01, true)) { // LME|LMA=0x500 current, write SCE|LME|NXE
        .value => |v| try expectEqual(vmsr.EFER_SCE | vmsr.EFER_LME | vmsr.EFER_LMA | vmsr.EFER_NXE, v),
        .gp => return error.TestUnexpectedGp,
    }
}

test "eferWrite: a reserved bit is rejected" {
    try expectEqual(vmsr.EferWrite.gp, vmsr.eferWrite(0x500, 0x1_0000, true)); // bit 16 reserved
}

test "eferWrite: clearing LME while paging is on is rejected" {
    // The guest runs with paging on, so it cannot toggle long-mode enable.
    try expectEqual(vmsr.EferWrite.gp, vmsr.eferWrite(0x500, 0x0, true));
}

test "eferWrite: LMA is forced to LME-and-paging, never taken from the write" {
    // A guest that writes LME=1 but LMA=0 still gets LMA set (it is processor-managed).
    switch (vmsr.eferWrite(0x500, vmsr.EFER_LME, true)) {
        .value => |v| try expect((v & vmsr.EFER_LMA) != 0),
        .gp => return error.TestUnexpectedGp,
    }
}

// --- auto MSRs ------------------------------------------------------------

test "autoIndexOf maps each auto MSR to a distinct area slot" {
    try expectEqual(@as(?usize, 0), vmsr.autoIndexOf(0xC000_0081)); // STAR
    try expectEqual(@as(?usize, 1), vmsr.autoIndexOf(0xC000_0082)); // LSTAR
    try expectEqual(@as(?usize, 4), vmsr.autoIndexOf(0xC000_0102)); // KERNEL_GS_BASE
    try expectEqual(@as(?usize, null), vmsr.autoIndexOf(0x277)); // PAT is not an auto MSR
    try expectEqual(@as(usize, 5), vmsr.AUTO_MSRS.len);
}

test "autoWrite: LSTAR/CSTAR/KERNEL_GS_BASE need a canonical address; STAR/FMASK do not" {
    // A canonical LSTAR passes.
    switch (vmsr.autoWrite(0xC000_0082, 0xFFFF_FFFF_8100_0000)) {
        .value => |v| try expectEqual(@as(u64, 0xFFFF_FFFF_8100_0000), v),
        .gp => return error.TestUnexpectedGp,
    }
    // A non-canonical LSTAR / KERNEL_GS_BASE is rejected.
    try expectEqual(vmsr.AutoWrite.gp, vmsr.autoWrite(0xC000_0082, 0x0001_0000_0000_0000));
    try expectEqual(vmsr.AutoWrite.gp, vmsr.autoWrite(0xC000_0102, 0x0001_0000_0000_0000));
    // STAR (selectors) and FMASK (flag mask) take any value.
    switch (vmsr.autoWrite(0xC000_0081, 0x0023_0010_0000_0000)) {
        .value => |v| try expectEqual(@as(u64, 0x0023_0010_0000_0000), v),
        .gp => return error.TestUnexpectedGp,
    }
    switch (vmsr.autoWrite(0xC000_0084, 0x4700)) {
        .value => |v| try expectEqual(@as(u64, 0x4700), v),
        .gp => return error.TestUnexpectedGp,
    }
}

test "isCanonical: boundary of the 48-bit canonical form" {
    try expect(vmsr.isCanonical(0x0000_7FFF_FFFF_FFFF)); // top of the low half
    try expect(!vmsr.isCanonical(0x0000_8000_0000_0000)); // first non-canonical
    try expect(vmsr.isCanonical(0xFFFF_8000_0000_0000)); // bottom of the high half
    try expect(!vmsr.isCanonical(0x0001_0000_0000_0000));
}
