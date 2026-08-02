//! Host tests of src/drivers/gpu/base/gmmu_fmt.zig.

const std = @import("std");
const gmmu_fmt = @import("gmmu_fmt");
const PTE_SYSMEM = gmmu_fmt.PTE_SYSMEM;
const PTE_VRAM = gmmu_fmt.PTE_VRAM;
const decodePde = gmmu_fmt.decodePde;
const encodePde = gmmu_fmt.encodePde;
const encodePte = gmmu_fmt.encodePte;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const indices = gmmu_fmt.indices;
const pteValid = gmmu_fmt.pteValid;
const vaOutOfRange = gmmu_fmt.vaOutOfRange;

test "indices: extract L2/PD0/SPT from a VA" {
    // va = 0x2000_0000 (512 MiB) → L2=1, PD0=0, SPT=0.
    const a = indices(0x2000_0000);
    try expectEqual(@as(u64, 1), a.l2);
    try expectEqual(@as(u64, 0), a.pd0);
    try expectEqual(@as(u64, 0), a.spt);
    // va with bits in each field: L2=3, PD0=0x2A, SPT=0x105.
    const va = (@as(u64, 3) << 29) | (@as(u64, 0x2A) << 21) | (@as(u64, 0x105) << 12) | 0xabc;
    const b = indices(va);
    try expectEqual(@as(u64, 3), b.l2);
    try expectEqual(@as(u64, 0x2A), b.pd0);
    try expectEqual(@as(u64, 0x105), b.spt);
}

test "vaOutOfRange: within MVP vs above 4 GiB vs past PD0 slots" {
    try expect(!vaOutOfRange(0x2000_0000, 8)); // 512 MiB, L2=1 < 8
    try expect(!vaOutOfRange(0xFFFF_F000, 8)); // just under 4 GiB, L2=7 < 8
    try expect(vaOutOfRange(0x1_0000_0000, 8)); // 4 GiB → L2=8 not < 8
    try expect(vaOutOfRange(@as(u64, 1) << 38, 8)); // bit 38 set
    try expect(vaOutOfRange(0x2000_0000, 1)); // L2=1 not < pd0_len=1
}

test "encode/decode PTE + PDE round-trip" {
    // PTE: sysmem page at phys 0x1234_5000.
    const pte = encodePte(0x1234_5000, PTE_SYSMEM);
    try expectEqual(@as(u64, (0x1234_5000 >> 4) | PTE_SYSMEM), pte);
    try expect(pteValid(@truncate(pte))); // VALID bit0 set
    try expect(!pteValid(0)); // an empty slot is not valid
    // VRAM PTE has aperture 0 (only the VALID bit in the low nibble).
    try expectEqual(@as(u64, (0x8000 >> 4) | 1), encodePte(0x8000, PTE_VRAM));

    // PDE round-trip: encode a child table, split, decode back.
    const child: u64 = 0xDEAD_0000;
    const pde = encodePde(child);
    const lo: u32 = @truncate(pde);
    const hi: u32 = @truncate(pde >> 32);
    try expectEqual(child, decodePde(lo, hi));
    // A zero PDE decodes to 0 (no child yet).
    try expectEqual(@as(u64, 0), decodePde(0, 0));
}
