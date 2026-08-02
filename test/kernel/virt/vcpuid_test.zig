//! Host tests of src/kernel/virt/vcpuid.zig.

const std = @import("std");
const vcpuid = @import("vcpuid");
const Regs = vcpuid.Regs;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const TSC_HZ: u64 = 2_800_000_000; // the calibrated frequency fed to filter()

/// A host result with recognizable, distinct register values.
const host_regs = Regs{ .eax = 0x000A_0655, .ebx = 0x0010_0800, .ecx = 0x7FFA_FBFF, .edx = 0xBFEB_FBFF };

test "leaf 1 ECX: hypervisor, x2APIC and TSC-deadline set; VMX cleared" {
    // Host with VMX on and all three virtual-platform bits off.
    const host = Regs{ .eax = 0, .ebx = 0, .ecx = 1 << 5, .edx = 0 };
    const g = vcpuid.filter(host, 1, 0, TSC_HZ);
    try expect(g.ecx & (1 << 31) != 0); // hypervisor present
    try expect(g.ecx & (1 << 21) != 0); // x2APIC
    try expect(g.ecx & (1 << 24) != 0); // TSC-deadline
    try expect(g.ecx & (1 << 5) == 0); // VMX hidden
}

test "leaf 1 EDX: MCE, MCA, ACPI and MTRR cleared; APIC kept" {
    const host = Regs{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0xFFFF_FFFF };
    const g = vcpuid.filter(host, 1, 0, TSC_HZ);
    try expect(g.edx & (1 << 7) == 0); // MCE
    try expect(g.edx & (1 << 14) == 0); // MCA
    try expect(g.edx & (1 << 22) == 0); // ACPI thermal MSRs
    try expect(g.edx & (1 << 12) == 0); // MTRR
    try expect(g.edx & (1 << 9) != 0); // APIC stays
}

test "leaf 1: unrelated host bits pass through" {
    const g = vcpuid.filter(host_regs, 1, 0, TSC_HZ);
    try expectEqual(host_regs.eax, g.eax); // family/model/stepping untouched
    try expect(g.edx & (1 << 0) != 0); // FPU survives
    try expect(g.ecx & (1 << 0) != 0); // SSE3 survives
}

test "leaf 1 ECX: the XSAVE feature set is hidden" {
    const host = Regs{ .eax = 0, .ebx = 0, .ecx = (1 << 26) | (1 << 27), .edx = 0 };
    const g = vcpuid.filter(host, 1, 0, TSC_HZ);
    try expect(g.ecx & (1 << 26) == 0); // XSAVE hidden (guards XSETBV/XSAVES)
    try expect(g.ecx & (1 << 27) == 0); // OSXSAVE hidden
}

test "leaf 1 EBX: the initial APIC ID is forced to 0" {
    const host = Regs{ .eax = 0, .ebx = 0x0300_0800, .ecx = 0, .edx = 0 }; // host core APIC ID 3
    const g = vcpuid.filter(host, 1, 0, TSC_HZ);
    try expectEqual(@as(u32, 0), g.ebx >> 24); // sole vCPU is APIC ID 0
    try expectEqual(@as(u32, 0x08), (g.ebx >> 8) & 0xFF); // CLFLUSH size preserved
}

test "leaf 7 subleaf 0: the features needing an unset VMX control are hidden" {
    const host = Regs{ .eax = 0, .ebx = 0xFFFF_FFFF, .ecx = 0xFFFF_FFFF, .edx = 0 };
    const g = vcpuid.filter(host, 7, 0, TSC_HZ);
    try expect(g.ebx & (1 << 10) == 0); // INVPCID hidden
    // WAITPKG hidden: with it advertised, Linux's delay loop is TPAUSE, which
    // #UDs without the "enable user wait and pause" secondary control.
    try expect(g.ecx & (1 << 5) == 0);
    try expect(g.ebx & (1 << 0) != 0); // FSGSBASE survives (guest-controllable via CR4)
    try expect(g.ecx & (1 << 4) != 0); // a neighbouring ECX flag is untouched
}

test "leaf 7 subleaf 1: passes through unchanged" {
    const host = Regs{ .eax = 0xABCD, .ebx = 0xFFFF_FFFF, .ecx = 0, .edx = 0 };
    const g = vcpuid.filter(host, 7, 1, TSC_HZ);
    try expectEqual(host, g); // only subleaf 0 carries the masked EBX flags
}

test "leaf 0x80000001 EDX: RDTSCP is hidden, long mode survives" {
    const host = Regs{ .eax = 0, .ebx = 0, .ecx = 0, .edx = (1 << 27) | (1 << 29) };
    const g = vcpuid.filter(host, 0x8000_0001, 0, TSC_HZ);
    try expect(g.edx & (1 << 27) == 0); // RDTSCP hidden
    try expect(g.edx & (1 << 29) != 0); // long mode (LM) survives
}

// VIRT-008: the guest is told the truth about the machine's timebase — leaf
// 0x15 must reproduce the host's calibrated TSC exactly.
test "leaf 0x15 ECX: a TSC beyond 32 bits saturates instead of wrapping" {
    const g = vcpuid.filter(host_regs, 0x15, 0, 5_000_000_000);
    try expectEqual(@as(u32, 0xFFFF_FFFF), g.ecx);
}

test "leaf 0x15: 1/1 ratio with the crystal at tsc_hz" {
    const g = vcpuid.filter(host_regs, 0x15, 0, TSC_HZ);
    try expectEqual(@as(u32, 1), g.eax); // denominator
    try expectEqual(@as(u32, 1), g.ebx); // numerator
    try expectEqual(@as(u32, 2_800_000_000), g.ecx); // crystal Hz == TSC Hz
    try expectEqual(@as(u32, 0), g.edx);
    // The guest's derivation: crystal * numerator / denominator == tsc_hz.
    try expectEqual(TSC_HZ, @as(u64, g.ecx) * g.ebx / g.eax);
}

test "leaf 0x16: base and max MHz from tsc_hz, 100 MHz bus" {
    const g = vcpuid.filter(host_regs, 0x16, 0, TSC_HZ);
    try expectEqual(@as(u32, 2800), g.eax); // base MHz
    try expectEqual(@as(u32, 2800), g.ebx); // max MHz
    try expectEqual(@as(u32, 100), g.ecx); // bus MHz
    try expectEqual(@as(u32, 0), g.edx);
}

test "leaf 0x40000000 spells the signature a Linux guest searches for" {
    const g = vcpuid.filter(host_regs, 0x4000_0000, 0, TSC_HZ);
    // The feature leaf is the highest one that means anything.
    try expectEqual(@as(u32, 0x4000_0001), g.eax);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], g.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], g.ecx, .little);
    std.mem.writeInt(u32, vendor[8..12], g.edx, .little);
    // Spelled out rather than compared against the module's own constant:
    // this is the byte string Linux's hypervisor probe memcmps against, and a
    // test that reads the constant back cannot notice it changing.
    try expect(std.mem.eql(u8, "KVMKVMKVM\x00\x00\x00", &vendor));
    try expect(std.mem.eql(u8, vcpuid.HYPERVISOR_VENDOR, &vendor));
}

test "the feature leaf and the rest of the hypervisor range are zeroed" {
    const zero = Regs{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 };
    // Zero features: every paravirtual service a guest could ask for is
    // gated on a bit here, so a clear leaf is what makes the signature safe.
    try expectEqual(zero, vcpuid.filter(host_regs, 0x4000_0001, 0, TSC_HZ));
    try expectEqual(zero, vcpuid.filter(host_regs, 0x4000_FFFF, 0, TSC_HZ));
}

test "unknown leaves pass the host result through unchanged" {
    try expectEqual(host_regs, vcpuid.filter(host_regs, 0x0, 0, TSC_HZ));
    try expectEqual(host_regs, vcpuid.filter(host_regs, 0x8000_0002, 0, TSC_HZ));
    try expectEqual(host_regs, vcpuid.filter(host_regs, 0x4001_0000, 0, TSC_HZ)); // past the hypervisor range
}
