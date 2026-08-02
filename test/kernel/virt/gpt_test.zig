//! Host tests of src/kernel/virt/gpt.zig — build the guest tables, then walk them.

const std = @import("std");
const gpt = @import("gpt");
const layout = gpt.layout;
const expectEqual = std.testing.expectEqual;

fn rd64(ram: []const u8, gpa: u64) u64 {
    return std.mem.readInt(u64, ram[@intCast(gpa)..][0..8], .little);
}

test "buildGdt writes null, 64-bit code, and data descriptors" {
    var ram: [0x10_0000]u8 = undefined;
    @memset(&ram, 0xAA);
    gpt.buildGdt(&ram);
    try expectEqual(@as(u64, 0), rd64(&ram, layout.GDT_GPA));
    // Code descriptor has the long-mode (L) bit set in the flags nibble.
    const code = rd64(&ram, layout.GDT_GPA + 8);
    try std.testing.expect(code & (@as(u64, 1) << 53) != 0); // L bit
    // Data descriptor is present and writable.
    const data = rd64(&ram, layout.GDT_GPA + 16);
    try std.testing.expect(data & (@as(u64, 1) << 47) != 0); // present
}

test "buildIdentity maps guest-physical pages to themselves with 2 MiB pages" {
    var ram: [0x10_0000]u8 = undefined;
    @memset(&ram, 0);
    const map_bytes: u64 = 128 * 1024 * 1024;
    gpt.buildIdentity(&ram, map_bytes);

    // PML4[0] → PDPT.
    const pml4e = rd64(&ram, layout.PT_PML4_GPA);
    try expectEqual(layout.PT_PDPT_GPA, pml4e & ~@as(u64, 0xFFF));
    try std.testing.expect(pml4e & 1 != 0); // present

    // PDPT[0] → PD[0].
    const pdpte = rd64(&ram, layout.PT_PDPT_GPA);
    try expectEqual(layout.PT_PD_BASE_GPA, pdpte & ~@as(u64, 0xFFF));

    // PD[0] and PD[1] are identity 2 MiB huge pages.
    const pde0 = rd64(&ram, layout.PT_PD_BASE_GPA);
    try expectEqual(@as(u64, 0), pde0 & ~@as(u64, 0x1FFFFF)); // maps GPA 0
    try std.testing.expect(pde0 & (1 << 7) != 0); // huge-page (PS) bit
    try std.testing.expect(pde0 & 1 != 0); // present
    const pde1 = rd64(&ram, layout.PT_PD_BASE_GPA + 8);
    try expectEqual(gpt.PAGE_2M, pde1 & ~@as(u64, 0x1FFFFF)); // maps GPA 2 MiB
}

test "pages beyond map_bytes are left absent" {
    var ram: [0x10_0000]u8 = undefined;
    @memset(&ram, 0);
    gpt.buildIdentity(&ram, 4 * 1024 * 1024); // only 2 huge pages
    const pde2 = rd64(&ram, layout.PT_PD_BASE_GPA + 16); // 3rd entry, beyond the map
    try expectEqual(@as(u64, 0), pde2);
}
