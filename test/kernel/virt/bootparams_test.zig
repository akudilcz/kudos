//! Host tests of src/kernel/virt/bootparams.zig — byte-exact zero-page offsets.

const std = @import("std");
const bootparams = @import("bootparams");
const layout = bootparams.layout;
const e820 = bootparams.e820;
const expectEqual = std.testing.expectEqual;

fn rd32(p: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}
fn rd64(p: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

// A minimal image whose setup header carries a recognizable byte and a valid
// header-end marker so bootparams copies a known range.
fn makeImage(buf: []u8) void {
    @memset(buf, 0);
    buf[0x201] = 0x70; // header ends at 0x272
    buf[0x1F1] = 4; // setup_sects, copied into the zero page's header
    buf[0x1F5] = 0x99; // a header byte we can assert was copied
}

fn testLayout() layout.Layout {
    return .{
        .ram_bytes = 128 * 1024 * 1024,
        .kernel_gpa = 0x100_0000,
        .entry_rip = 0x100_0200,
        .kernel_end = 0x180_0000,
        .initrd_gpa = 0x700_0000,
        .initrd_len = 0x10_0000,
        .cmdline_gpa = layout.CMDLINE_GPA,
        .cmdline_len = 20,
        .boot_params_gpa = layout.ZERO_PAGE_GPA,
        .gdt_gpa = layout.GDT_GPA,
        .pml4_gpa = layout.PT_PML4_GPA,
        .acpi_gpa = layout.ACPI_GPA,
    };
}

test "the zero page carries loader fields at their ABI offsets" {
    var image: [0x1000]u8 = undefined;
    makeImage(&image);
    var e820_buf: [8]e820.Entry = undefined;
    const entries = e820.forRam(128 * 1024 * 1024, &e820_buf);

    var zp: [4096]u8 = undefined;
    bootparams.build(&zp, &image, testLayout(), entries);

    try expectEqual(@as(u8, 0xFF), zp[0x210]); // type_of_loader = undefined
    try expectEqual(@as(u8, 1), zp[0x211] & 0x01); // LOADED_HIGH set
    try expectEqual(@as(u8, 0x99), zp[0x1F5]); // setup header byte copied through
    try expectEqual(layout.CMDLINE_GPA, @as(u64, rd32(&zp, 0x228))); // cmd_line_ptr
    try expectEqual(@as(u32, 0x700_0000), rd32(&zp, 0x218)); // ramdisk_image
    try expectEqual(@as(u32, 0x10_0000), rd32(&zp, 0x21C)); // ramdisk_size
}

test "the E820 table is written at 0x2D0 with the entry count at 0x1E8" {
    var image: [0x1000]u8 = undefined;
    makeImage(&image);
    var e820_buf: [8]e820.Entry = undefined;
    const entries = e820.forRam(128 * 1024 * 1024, &e820_buf);

    var zp: [4096]u8 = undefined;
    bootparams.build(&zp, &image, testLayout(), entries);

    try expectEqual(@as(u8, 2), zp[0x1E8]); // e820_entries
    // First entry: {addr=0, size=LOW_RAM_TOP, type=RAM}.
    try expectEqual(@as(u64, 0), rd64(&zp, 0x2D0));
    try expectEqual(e820.LOW_RAM_TOP, rd64(&zp, 0x2D0 + 8));
    try expectEqual(e820.E820_RAM, rd32(&zp, 0x2D0 + 16));
    // Second entry starts 20 bytes later.
    try expectEqual(e820.HIGH_RAM_BASE, rd64(&zp, 0x2D0 + 20));
}
