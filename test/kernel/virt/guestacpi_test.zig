//! Host tests of src/kernel/virt/acpi.zig — the ACPI tables the guest is given.
//! The property that matters: a real ACPI parser must accept them, which means
//! signatures, lengths, cross-pointers and BOTH RSDP checksums have to be right.

const std = @import("std");
const acpi = @import("testroot").kernel.guestacpi;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;

/// Where a caller would place the block; the tables carry absolute pointers,
/// so the tests use a non-zero base to catch "forgot to add gpa" mistakes.
const GPA: u64 = 0x1_0000;

fn buildAt(buf: []u8) usize {
    return acpi.build(buf, GPA, 0);
}

fn sum(bytes: []const u8) u8 {
    var s: u8 = 0;
    for (bytes) |b| s = s +% b;
    return s;
}

fn rd32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn rd64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

/// The table the XSDT's `index`-th entry points at, as a slice of `buf`. Every
/// test that reaches a table goes through here, so the XSDT's entry order is
/// stated once rather than spelled as an offset at each use.
fn xsdtEntry(buf: []const u8, index: usize) []const u8 {
    const xsdt = buf[rd64(buf, 24) - GPA ..];
    return buf[rd64(xsdt, 36 + index * 8) - GPA ..];
}

const FADT_INDEX: usize = 0;
const MADT_INDEX: usize = 1;

test "the RSDP is findable and both of its checksums sum to zero" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    try expectEqualSlices(u8, "RSD PTR ", buf[0..8]);
    try expectEqual(@as(u8, 2), buf[15]); // revision 2 => an XSDT is present
    try expectEqual(@as(u32, acpi.RSDP_BYTES), rd32(&buf, 20));
    // v1 checksum covers the first 20 bytes; the extended one covers all 36.
    try expectEqual(@as(u8, 0), sum(buf[0..20]));
    try expectEqual(@as(u8, 0), sum(buf[0..acpi.RSDP_BYTES]));
}

test "the RSDP points at an XSDT that points at the FADT and MADT" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    const xsdt_gpa = rd64(&buf, 24);
    try expect(xsdt_gpa > GPA); // an absolute address, not an offset
    const xsdt = buf[xsdt_gpa - GPA ..];
    try expectEqualSlices(u8, "XSDT", xsdt[0..4]);
    const xsdt_len = rd32(xsdt, 4);
    try expectEqual(@as(u8, 0), sum(xsdt[0..xsdt_len]));
    // Two entries, and the header accounts for exactly them.
    try expectEqual(@as(u32, 36 + 2 * 8), xsdt_len);

    const fadt = xsdtEntry(&buf, FADT_INDEX);
    try expectEqualSlices(u8, "FACP", fadt[0..4]);
    try expectEqual(@as(u8, 0), sum(fadt[0..rd32(fadt, 4)]));

    const madt_gpa = rd64(xsdt, 36 + MADT_INDEX * 8);
    const madt = buf[madt_gpa - GPA ..];
    try expectEqualSlices(u8, "APIC", madt[0..4]);
    const madt_len = rd32(madt, 4);
    try expectEqual(@as(u8, 0), sum(madt[0..madt_len]));
    // Both pointed-at tables must lie inside the block we wrote.
    try expect(madt_gpa - GPA + madt_len <= acpi.TOTAL_BYTES);
}

test "the FADT points at a DSDT that parses, by both of its address fields" {
    // An interpreter loading a namespace reaches for the DSDT at a fixed index
    // in its root table list. With no FADT there is no such entry, and older
    // ACPICA dereferences the empty descriptor anyway: "unable to handle kernel
    // paging request" in acpi_tb_load_namespace, before the guest has a chance
    // to say anything else.
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    const fadt = xsdtEntry(&buf, FADT_INDEX);
    const dsdt_32 = rd32(fadt, 40);
    const dsdt_64 = rd64(fadt, 140);
    // Both fields must name the same table: an interpreter may read either.
    try expectEqual(@as(u64, dsdt_32), dsdt_64);
    try expect(dsdt_64 > GPA);
    const dsdt = buf[dsdt_64 - GPA ..];
    try expectEqualSlices(u8, "DSDT", dsdt[0..4]);
    const dsdt_len = rd32(dsdt, 4);
    try expectEqual(@as(u8, 0), sum(dsdt[0..dsdt_len]));
    // A header and nothing else: this machine has no ACPI-described devices, so
    // its definition block is empty rather than absent.
    try expectEqual(@as(u32, 36), dsdt_len);
    try expect(dsdt_64 - GPA + dsdt_len <= acpi.TOTAL_BYTES);
}

test "the FADT describes a machine with no PM hardware and a real CMOS clock" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    const fadt = xsdtEntry(&buf, FADT_INDEX);
    try expectEqual(@as(u8, 6), fadt[8]); // ACPI 6.x revision
    const flags = rd32(fadt, 112);
    try expect(flags & (1 << 20) != 0); // HW_REDUCED_ACPI: no SCI, no PM1, no PM timer
    try expect(flags & (1 << 0) != 0); // WBINVD works as architected
    // The century register index, which must be the one the emulated clock
    // actually answers on, or the guest's year is a century out.
    try expectEqual(@as(u8, 0x32), fadt[108]);
    // …and the boot-architecture flags say what is absent, so the guest does
    // not probe for it. The CMOS RTC bit (5) stays CLEAR: there really is one.
    const boot_arch = std.mem.readInt(u16, fadt[109..111], .little);
    try expect(boot_arch & (1 << 2) != 0); // no VGA
    try expect(boot_arch & (1 << 3) != 0); // no MSI
    try expectEqual(@as(u16, 0), boot_arch & (1 << 5));
    // Every PM register block is zero — the honest description of hardware
    // that is not there, and what HW_REDUCED_ACPI tells the guest to expect.
    for (fadt[48..88]) |b| try expectEqual(@as(u8, 0), b);
}

test "the MADT describes the LAPIC base, the 8259 pair, and one enabled processor" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    const madt = xsdtEntry(&buf, MADT_INDEX);
    try expectEqual(acpi.LAPIC_MMIO_BASE, rd32(madt, 36));
    try expectEqual(@as(u32, 1), rd32(madt, 40) & 1); // PCAT_COMPAT: the 8259s exist
    const entry = madt[44..];
    try expectEqual(@as(u8, 0), entry[0]); // type 0: Processor Local APIC
    try expectEqual(@as(u8, 8), entry[1]); // its length
    try expectEqual(@as(u8, 0), entry[3]); // APIC id 0 — what MSR_APIC_ID reports
    try expectEqual(@as(u32, 1), rd32(entry, 4) & 1); // enabled
}

test "the APIC id the caller asks for is the id the MADT reports" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = acpi.build(&buf, GPA, 3);
    const madt = xsdtEntry(&buf, MADT_INDEX);
    try expectEqual(@as(u8, 3), madt[44 + 3]);
    try expectEqual(@as(u8, 0), sum(madt[0..rd32(madt, 4)])); // checksum still valid
}

test "the build reports its size and writes nothing past it" {
    var buf: [acpi.TOTAL_BYTES + 16]u8 = undefined;
    @memset(&buf, 0xAA);
    const written = buildAt(&buf);
    try expectEqual(acpi.TOTAL_BYTES, written);
    for (buf[acpi.TOTAL_BYTES..]) |b| try expectEqual(@as(u8, 0xAA), b);
}

test "moving the block moves every pointer with it" {
    var a: [acpi.TOTAL_BYTES]u8 = undefined;
    var b: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = acpi.build(&a, 0x1_0000, 0);
    _ = acpi.build(&b, 0x9_0000, 0);
    try expectEqual(rd64(&a, 24) + 0x8_0000, rd64(&b, 24));
    // …and the checksums still hold at the new address.
    try expectEqual(@as(u8, 0), sum(b[0..acpi.RSDP_BYTES]));
}

test "the tables are placed where the ACPI specification says an RSDP lives" {
    // 0xE0000–0xFFFFF, the window a kernel scans when it has nowhere else to
    // look. `boot_params.acpi_rsdp_addr` only exists from Linux 5.0, so for
    // anything older this placement is the ONLY way the RSDP is found — and a
    // guest that finds no MADT concludes it has no topology and reads its APIC
    // through memory instead. It is also above the last usable low-RAM byte, so
    // the guest's own allocator can never hand the page out from under it.
    const lay = acpi.layout;
    try expect(lay.ACPI_GPA >= 0xE_0000);
    try expect(lay.ACPI_GPA + acpi.TOTAL_BYTES <= 0x10_0000);
    // 16-byte aligned, which the RSDP search step requires.
    try expectEqual(@as(u64, 0), lay.ACPI_GPA % 16);
}

test "the MADT reports the local-APIC address the guest map actually serves" {
    var buf: [acpi.TOTAL_BYTES]u8 = undefined;
    _ = buildAt(&buf);
    const madt = xsdtEntry(&buf, MADT_INDEX);
    // One home for the address: a MADT that named a different window than the
    // one the hypervisor serves would send a guest's APIC accesses into a hole.
    try expectEqual(@as(u32, @intCast(acpi.layout.LAPIC_GPA)), rd32(madt, 36));
}
