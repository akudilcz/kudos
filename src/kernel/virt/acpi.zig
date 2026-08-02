//! The guest's ACPI tables: an RSDP pointing at an XSDT pointing at a MADT.
//!
//! Small, but not optional. A stock distribution kernel that finds no MADT
//! leaves `smp_found_config` clear, and `init_bsp_APIC()` then programs the
//! local APIC through its **xAPIC MMIO** window — which, on a guest that took
//! the x2APIC path, is never mapped into its own page tables. The result is a
//! page fault inside `native_init_IRQ`, an oops before any console exists, and
//! a panic that spins in `mdelay` forever: a guest that looks hung and says
//! nothing. With a MADT present, `init_bsp_APIC` returns immediately (the
//! firmware is telling it the interrupt topology) and the guest stays on the
//! MSR-based x2APIC interface this hypervisor actually emulates.
//!
//! Pure builder: it writes tables into a caller-supplied buffer and returns
//! how many bytes it used, so it is host-tested (test/kernel/acpi/acpi_test.zig) with no
//! guest, no memory map and no hardware. The guest finds the RSDP through
//! `boot_params.acpi_rsdp_addr` (Linux ≥ 5.0), so no BIOS/EBDA scan region
//! has to be faked.
//!
//! Grounding: ACPI 6.4 §5.2.5 (RSDP), §5.2.8 (XSDT), §5.2.12 (MADT).

const std = @import("std");
/// The guest memory map, which owns both where these tables are placed and the
/// local-APIC address they report. Re-exported because both facts are part of
/// what this builder promises a guest.
pub const layout = @import("layout.zig");

/// ACPI signatures, spelled exactly as the tables carry them.
const SIG_RSDP = "RSD PTR ";
const SIG_XSDT = "XSDT";
const SIG_MADT = "APIC";
const SIG_FADT = "FACP";
const SIG_DSDT = "DSDT";

/// Who the tables claim to come from. Six and eight bytes, space-padded, as
/// the spec's fixed-width fields require.
const OEM_ID = "KUDOS ";
const OEM_TABLE_ID = "KUDOSVM ";
const OEM_REVISION: u32 = 1;
const CREATOR_ID = "KUDS";
const CREATOR_REVISION: u32 = 1;

/// Byte sizes of the structures (ACPI 6.4).
pub const RSDP_BYTES: usize = 36; // v2 RSDP: the 20-byte v1 prefix + the extension
const SDT_HEADER_BYTES: usize = 36; // the header every non-RSDP table starts with
const MADT_FIXED_BYTES: usize = 8; // LAPIC address + flags, after the header
const LAPIC_ENTRY_BYTES: usize = 8; // MADT type 0: Processor Local APIC
const FADT_BYTES: usize = 276; // the ACPI 6.x Fixed ACPI Description Table
const XSDT_ENTRIES: usize = 2; // the FADT and the MADT

/// Revisions we emit: RSDP revision 2 means "an XSDT is present" (ACPI 2.0+),
/// and MADT/FADT revisions match ACPI 6.x. The DSDT's revision 2 is what tells
/// an interpreter its integers are 64-bit.
const RSDP_REVISION: u8 = 2;
const XSDT_REVISION: u8 = 1;
const MADT_REVISION: u8 = 5;
const FADT_REVISION: u8 = 6;
const DSDT_REVISION: u8 = 2;

/// The local APIC's MMIO base, as the MADT must report it. The same address the
/// guest map leaves as a hole and the APIC model actually serves, so a guest
/// that maps it and reads it finds its APIC there.
pub const LAPIC_MMIO_BASE: u32 = @intCast(layout.LAPIC_GPA);

/// MADT flags (ACPI 6.4 Table 5.20): the system also has the legacy 8259 pair
/// the guest must mask before using the APIC — which kudos does emulate
/// (virt/i8259.zig), so this bit is the truth.
const MADT_FLAG_PCAT_COMPAT: u32 = 1 << 0;

/// MADT interrupt-controller structure types (ACPI 6.4 Table 5.21).
const MADT_TYPE_LOCAL_APIC: u8 = 0;

/// Processor Local APIC flags: bit 0 set means this processor is usable.
const LAPIC_FLAG_ENABLED: u32 = 1 << 0;

// ── FADT field offsets (ACPI 6.4 Table 5.9) ─────────────────────────────────
// Only the fields this machine has anything true to say about; the rest of the
// table is zero, which is the correct way to describe hardware that is absent.
const FADT_OFF_DSDT: usize = 40; // 32-bit DSDT address
const FADT_OFF_CENTURY: usize = 108; // CMOS index of the century register
const FADT_OFF_IAPC_BOOT_ARCH: usize = 109; // what legacy PC hardware exists
const FADT_OFF_FLAGS: usize = 112;
const FADT_OFF_MINOR_VERSION: usize = 131;
const FADT_OFF_X_DSDT: usize = 140; // 64-bit DSDT address

/// IA-PC boot architecture flags (ACPI 6.4 Table 5.11). Each SET bit here says
/// a piece of legacy hardware is ABSENT, so this is the guest being told not to
/// go looking: there is no VGA adapter (the display is virtio-gpu) and no PCI
/// bus for message-signalled interrupts to travel on. The CMOS RTC bit stays
/// clear, because virt/mc146818.zig means the guest really does have one.
const IAPC_VGA_NOT_PRESENT: u16 = 1 << 2;
const IAPC_MSI_NOT_SUPPORTED: u16 = 1 << 3;

/// FADT fixed feature flags (ACPI 6.4 Table 5.10).
///  - WBINVD: the processor's WBINVD instruction works as architected, which on
///    any x86-64 it does. An interpreter that is not told this looks for cache
///    flushing hardware that has not existed for decades.
///  - HW_REDUCED_ACPI: there is no SCI, no PM1 event/control block, no PM timer
///    and no SMI command port — which is the truth about this machine, and
///    tells the interpreter not to wait on registers nobody implements.
const FADT_FLAG_WBINVD: u32 = 1 << 0;
const FADT_FLAG_HW_REDUCED_ACPI: u32 = 1 << 20;

/// The CMOS register holding the century, as virt/mc146818.zig serves it. The
/// FADT is where an OS learns this index; without it a guest either guesses or
/// pivots a two-digit year.
const CMOS_CENTURY_INDEX: u8 = 0x32;

/// Everything the builder writes, for one single-vCPU guest.
pub const TOTAL_BYTES: usize = RSDP_BYTES +
    (SDT_HEADER_BYTES + XSDT_ENTRIES * 8) +
    FADT_BYTES +
    SDT_HEADER_BYTES + // the DSDT: a header and an empty definition block
    (SDT_HEADER_BYTES + MADT_FIXED_BYTES + LAPIC_ENTRY_BYTES);

/// Where each table lands inside the caller's block, as offsets from its base.
const XSDT_OFFSET: usize = RSDP_BYTES;
const FADT_OFFSET: usize = XSDT_OFFSET + SDT_HEADER_BYTES + XSDT_ENTRIES * 8;
const DSDT_OFFSET: usize = FADT_OFFSET + FADT_BYTES;
const MADT_OFFSET: usize = DSDT_OFFSET + SDT_HEADER_BYTES;

/// The one-byte sum-to-zero checksum every ACPI table carries.
fn checksum(bytes: []const u8) u8 {
    var sum: u8 = 0;
    for (bytes) |b| sum = sum +% b;
    return 0 -% sum;
}

fn wr16(b: []u8, off: usize, v: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], v, .little);
}

fn wr32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}

fn wr64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}

/// Write a standard table header. `len` is the table's total length including
/// this header; the caller fills the body and then checksums the whole table.
fn writeHeader(b: []u8, sig: []const u8, len: u32, revision: u8) void {
    @memcpy(b[0..4], sig);
    wr32(b, 4, len);
    b[8] = revision;
    b[9] = 0; // checksum, computed once the body is written
    @memcpy(b[10..16], OEM_ID);
    @memcpy(b[16..24], OEM_TABLE_ID);
    wr32(b, 24, OEM_REVISION);
    @memcpy(b[28..32], CREATOR_ID);
    wr32(b, 32, CREATOR_REVISION);
}

/// Build the RSDP, XSDT and MADT into `buf`, which the caller has placed at
/// guest-physical `gpa`. The tables carry absolute guest-physical pointers to
/// each other, so `gpa` must be where the guest will actually see them.
/// Returns the number of bytes written (always `TOTAL_BYTES`).
///
/// `apic_id` is the single vCPU's local-APIC id, which must match what the
/// guest reads from its APIC and from CPUID — one fact, told the same way
/// twice, or Linux reports a firmware bug and mis-describes its own topology.
pub fn build(buf: []u8, gpa: u64, apic_id: u8) usize {
    std.debug.assert(buf.len >= TOTAL_BYTES);
    @memset(buf[0..TOTAL_BYTES], 0);

    // ── MADT ────────────────────────────────────────────────────────────
    const madt_len: u32 = @intCast(SDT_HEADER_BYTES + MADT_FIXED_BYTES + LAPIC_ENTRY_BYTES);
    const madt = buf[MADT_OFFSET..][0..madt_len];
    writeHeader(madt, SIG_MADT, madt_len, MADT_REVISION);
    wr32(madt, SDT_HEADER_BYTES, LAPIC_MMIO_BASE);
    wr32(madt, SDT_HEADER_BYTES + 4, MADT_FLAG_PCAT_COMPAT);
    const lapic = madt[SDT_HEADER_BYTES + MADT_FIXED_BYTES ..];
    lapic[0] = MADT_TYPE_LOCAL_APIC;
    lapic[1] = LAPIC_ENTRY_BYTES;
    lapic[2] = 0; // ACPI processor UID
    lapic[3] = apic_id;
    wr32(lapic, 4, LAPIC_FLAG_ENABLED);
    madt[9] = checksum(madt);

    // ── DSDT: a valid header over an empty definition block ─────────────
    // This machine has no ACPI-described devices, so its AML is empty. The
    // table itself is not optional: an interpreter reaches for the DSDT by a
    // fixed index the moment it loads a namespace, and one that is not there
    // is a dereference of a table descriptor nobody filled in.
    const dsdt_len: u32 = @intCast(SDT_HEADER_BYTES);
    const dsdt = buf[DSDT_OFFSET..][0..dsdt_len];
    writeHeader(dsdt, SIG_DSDT, dsdt_len, DSDT_REVISION);
    dsdt[9] = checksum(dsdt);

    // ── FADT: mostly a description of what this machine does NOT have ───
    const fadt = buf[FADT_OFFSET..][0..FADT_BYTES];
    writeHeader(fadt, SIG_FADT, FADT_BYTES, FADT_REVISION);
    wr32(fadt, FADT_OFF_DSDT, @intCast(gpa + DSDT_OFFSET));
    wr64(fadt, FADT_OFF_X_DSDT, gpa + DSDT_OFFSET);
    fadt[FADT_OFF_CENTURY] = CMOS_CENTURY_INDEX;
    wr16(fadt, FADT_OFF_IAPC_BOOT_ARCH, IAPC_VGA_NOT_PRESENT | IAPC_MSI_NOT_SUPPORTED);
    wr32(fadt, FADT_OFF_FLAGS, FADT_FLAG_WBINVD | FADT_FLAG_HW_REDUCED_ACPI);
    fadt[FADT_OFF_MINOR_VERSION] = 0; // revision 6.0
    fadt[9] = checksum(fadt);

    // ── XSDT: the FADT and the MADT ─────────────────────────────────────
    const xsdt_len: u32 = @intCast(SDT_HEADER_BYTES + XSDT_ENTRIES * 8);
    const xsdt = buf[XSDT_OFFSET..][0..xsdt_len];
    writeHeader(xsdt, SIG_XSDT, xsdt_len, XSDT_REVISION);
    wr64(xsdt, SDT_HEADER_BYTES, gpa + FADT_OFFSET);
    wr64(xsdt, SDT_HEADER_BYTES + 8, gpa + MADT_OFFSET);
    xsdt[9] = checksum(xsdt);

    // ── RSDP: the root pointer, with BOTH checksums ─────────────────────
    const rsdp = buf[0..RSDP_BYTES];
    @memcpy(rsdp[0..8], SIG_RSDP);
    @memcpy(rsdp[9..15], OEM_ID);
    rsdp[15] = RSDP_REVISION;
    wr32(rsdp, 16, 0); // no RSDT: revision 2 guests use the XSDT
    wr32(rsdp, 20, RSDP_BYTES);
    wr64(rsdp, 24, gpa + XSDT_OFFSET);
    // The v1 checksum covers only the first 20 bytes; the extended checksum
    // covers the whole structure. Both must sum to zero, and the first must be
    // computed before the second sees it.
    rsdp[8] = checksum(rsdp[0..20]);
    rsdp[32] = checksum(rsdp[0..RSDP_BYTES]);

    return TOTAL_BYTES;
}
