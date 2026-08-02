//! Host tests of src/kernel/virt/ept.zig — build a map, then software-walk it.
//!
//! The builder writes physical-address bit-fields the CPU will later walk in
//! hardware; a wrong shift or mask produces a map that faults only under real EPT.
//! Building an offset map and translating boundary GPAs back to the expected HPA
//! (with the right access bits and page size) proves the encoding on the host.

const std = @import("std");
const ept = @import("ept");
const vmxcaps = ept.vmxcaps;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const CAPS: vmxcaps.EptCaps = .{
    .execute_only = false,
    .walk_length_4 = true,
    .memtype_wb = true,
    .page_2m = true,
    .page_1g = true,
    .invept_supported = true,
    .ad_bits = true,
    .invept_single = true,
    .invept_all = true,
};

// A test pool whose base_hpa is chosen so the linear mapping is easy to reason
// about; `deref` recovers a table pointer from a stored host-physical address.
const TEST_BASE_HPA: u64 = 0x4000_0000; // 1 GiB, 2 MiB-aligned

var g_pool: ept.TablePool = undefined;

fn deref(hpa: u64) *const ept.Table {
    const i: usize = @intCast((hpa - g_pool.base_hpa) / ept.PAGE_SIZE);
    return &g_pool.tables[i];
}

test "tablePagesNeeded counts PML4 + PDPT + PDs" {
    try expectEqual(@as(usize, 3), ept.tablePagesNeeded(128 * 1024 * 1024)); // 1+1+1
    try expectEqual(@as(usize, 3), ept.tablePagesNeeded(ept.GIB)); // exactly 1 GiB
    try expectEqual(@as(usize, 4), ept.tablePagesNeeded(ept.GIB + 1)); // spills to a 2nd PD
}

test "buildOffsetMap then translate at boundaries (VIRT-002)" {
    const len: u64 = 128 * 1024 * 1024;
    var tables: [8]ept.Table = undefined;
    g_pool = .{ .tables = &tables, .base_hpa = TEST_BASE_HPA };

    const hpa_base: u64 = 0x1_0000_0000; // 4 GiB, 2 MiB-aligned
    const pml4_hpa = try ept.buildOffsetMap(&g_pool, hpa_base, len, CAPS);

    // gpa 0 → hpa_base, full RWX, 2 MiB page.
    const t0 = ept.translate(pml4_hpa, deref, 0).?;
    try expectEqual(hpa_base, t0.hpa);
    try expectEqual(true, t0.r and t0.w and t0.x);
    try expectEqual(ept.PAGE_2M, t0.page_bytes);

    // An offset inside the first 2 MiB page keeps the offset.
    try expectEqual(hpa_base + 0x1234, ept.translate(pml4_hpa, deref, 0x1234).?.hpa);

    // The byte just below the 2 MiB boundary, and the first byte of the next page.
    try expectEqual(hpa_base + 0x1F_FFFF, ept.translate(pml4_hpa, deref, 0x1F_FFFF).?.hpa);
    try expectEqual(hpa_base + 0x20_0000, ept.translate(pml4_hpa, deref, 0x20_0000).?.hpa);

    // The last mapped byte translates; one past the end is unmapped.
    try expectEqual(hpa_base + len - 1, ept.translate(pml4_hpa, deref, len - 1).?.hpa);
    try expectEqual(@as(?ept.Translation, null), ept.translate(pml4_hpa, deref, len));
}

test "buildOffsetMap uses no more tables than the sizer predicts" {
    const len: u64 = 128 * 1024 * 1024;
    var tables: [8]ept.Table = undefined;
    g_pool = .{ .tables = &tables, .base_hpa = TEST_BASE_HPA };
    _ = try ept.buildOffsetMap(&g_pool, 0x1_0000_0000, len, CAPS);
    try expectEqual(ept.tablePagesNeeded(len), g_pool.used);
}

test "buildOffsetMap rejects misalignment and missing large-page support" {
    var tables: [8]ept.Table = undefined;
    g_pool = .{ .tables = &tables, .base_hpa = TEST_BASE_HPA };
    try expectError(error.Misaligned, ept.buildOffsetMap(&g_pool, 0x1000, ept.PAGE_2M, CAPS));

    var no2m = CAPS;
    no2m.page_2m = false;
    try expectError(error.NoLargePages, ept.buildOffsetMap(&g_pool, 0x1_0000_0000, ept.PAGE_2M, no2m));
}

test "eptp encodes memory type, walk length, and PML4 address" {
    const pml4: u64 = 0x1234_5000;
    const p = ept.eptp(pml4, CAPS);
    try expectEqual(@as(u64, 6), p & 0x7); // WB
    try expectEqual(@as(u64, 3), (p >> 3) & 0x7); // 4-level walk (len−1)
    try expectEqual(@as(u64, 1), (p >> 6) & 1); // A/D enabled (caps.ad_bits)
    try expectEqual(pml4, p & 0x000F_FFFF_FFFF_F000);
}
