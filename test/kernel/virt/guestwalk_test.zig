//! Host tests of src/kernel/virt/guestwalk.zig — the software walk of a
//! guest's own 4-level page tables, against tables hand-built in a buffer:
//! leaf sizes, non-present entries at every level, table frames outside guest
//! RAM, CR3 flag-bit masking, and page-crossing fetches.

const std = @import("std");
const guestwalk = @import("guestwalk");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;

const PTE_P: u64 = 1 << 0;
const PTE_PS: u64 = 1 << 7;

// Table frames inside the buffer.
const PML4: u64 = 0x1000;
const PDPT: u64 = 0x2000;
const PD: u64 = 0x3000;
const PT: u64 = 0x4000;

/// A Linux-kernel-half text address: PML4 index 511, PDPT 510, PD 8, PT 0.
const KVADDR: u64 = 0xFFFF_FFFF_8100_0000;

const Fixture = struct {
    ram: [RAM_LEN]u8 = [_]u8{0} ** RAM_LEN,

    fn setEntry(self: *Fixture, table: u64, index: u64, val: u64) void {
        std.mem.writeInt(u64, self.ram[@intCast(table + index * 8)..][0..8], val, .little);
    }

    /// Wire the full 4-level chain for KVADDR down to a 4 KiB leaf at `frame`.
    fn map4k(self: *Fixture, frame: u64) void {
        self.setEntry(PML4, 511, PDPT | PTE_P);
        self.setEntry(PDPT, 510, PD | PTE_P);
        self.setEntry(PD, 8, PT | PTE_P);
        self.setEntry(PT, 0, frame | PTE_P);
    }
};

test "4 KiB leaf resolves with the page offset applied" {
    var f = Fixture{};
    f.map4k(0x5000);
    try expectEqual(@as(?u64, 0x5000), guestwalk.translate(&f.ram, PML4, KVADDR));
    try expectEqual(@as(?u64, 0x5123), guestwalk.translate(&f.ram, PML4, KVADDR + 0x123));
}

test "2 MiB leaf at the PD level resolves with the large-page offset" {
    var f = Fixture{};
    f.setEntry(PML4, 511, PDPT | PTE_P);
    f.setEntry(PDPT, 510, PD | PTE_P);
    f.setEntry(PD, 8, 0x40_0000 | PTE_P | PTE_PS);
    const off: u64 = 0x1_2345; // inside the 2 MiB page
    try expectEqual(@as(?u64, 0x40_0000 + off), guestwalk.translate(&f.ram, PML4, KVADDR + off));
}

test "1 GiB leaf at the PDPT level resolves with the huge-page offset" {
    var f = Fixture{};
    f.setEntry(PML4, 511, PDPT | PTE_P);
    f.setEntry(PDPT, 510, 0x4000_0000 | PTE_P | PTE_PS);
    // KVADDR sits 8 PD slots (16 MiB) into its 1 GiB region.
    const in_page = KVADDR & (0x4000_0000 - 1);
    try expectEqual(@as(?u64, 0x4000_0000 + in_page), guestwalk.translate(&f.ram, PML4, KVADDR));
}

test "a non-present entry at any level fails the walk" {
    // Build the full chain, then knock out one level at a time.
    var f = Fixture{};
    f.map4k(0x5000);
    f.setEntry(PT, 0, 0x5000); // leaf not present
    try expectEqual(@as(?u64, null), guestwalk.translate(&f.ram, PML4, KVADDR));
    f.map4k(0x5000);
    f.setEntry(PD, 8, PT); // PD entry not present
    try expectEqual(@as(?u64, null), guestwalk.translate(&f.ram, PML4, KVADDR));
    f.map4k(0x5000);
    f.setEntry(PDPT, 510, PD);
    try expectEqual(@as(?u64, null), guestwalk.translate(&f.ram, PML4, KVADDR));
    f.map4k(0x5000);
    f.setEntry(PML4, 511, PDPT);
    try expectEqual(@as(?u64, null), guestwalk.translate(&f.ram, PML4, KVADDR));
}

test "a table frame outside guest RAM fails the walk instead of reading wild" {
    var f = Fixture{};
    f.setEntry(PML4, 511, (RAM_LEN + 0x1000) | PTE_P);
    try expectEqual(@as(?u64, null), guestwalk.translate(&f.ram, PML4, KVADDR));
}

test "CR3 flag and PCID bits are stripped before the PML4 is read" {
    var f = Fixture{};
    f.map4k(0x5000);
    const cr3 = PML4 | 0xABC; // PWT/PCD/PCID clutter in bits 11:0
    try expectEqual(@as(?u64, 0x5000), guestwalk.translate(&f.ram, cr3, KVADDR));
}

test "fetch crosses a page boundary, translating each page separately" {
    var f = Fixture{};
    // Two consecutive virtual pages onto two non-adjacent physical frames.
    f.setEntry(PML4, 511, PDPT | PTE_P);
    f.setEntry(PDPT, 510, PD | PTE_P);
    f.setEntry(PD, 8, PT | PTE_P);
    f.setEntry(PT, 0, 0x5000 | PTE_P);
    f.setEntry(PT, 1, 0x7000 | PTE_P);
    for (0..4) |i| f.ram[0x5FFC + i] = @intCast(0xA0 + i); // tail of page 0
    for (0..4) |i| f.ram[0x7000 + i] = @intCast(0xB0 + i); // head of page 1
    var out: [8]u8 = undefined;
    try expect(guestwalk.fetch(&f.ram, PML4, KVADDR + 0xFFC, &out));
    try expectEqual([8]u8{ 0xA0, 0xA1, 0xA2, 0xA3, 0xB0, 0xB1, 0xB2, 0xB3 }, out);
}

test "fetch fails when the run crosses into an unmapped page" {
    var f = Fixture{};
    f.map4k(0x5000); // page 0 mapped, page 1 absent
    var out: [8]u8 = undefined;
    try expect(!guestwalk.fetch(&f.ram, PML4, KVADDR + 0xFFC, &out));
}

test "fetch fails when the leaf points past guest RAM" {
    var f = Fixture{};
    f.map4k(RAM_LEN); // translates fine, but the bytes are not ours to read
    var out: [4]u8 = undefined;
    try expect(!guestwalk.fetch(&f.ram, PML4, KVADDR, &out));
}
