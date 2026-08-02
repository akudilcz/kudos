//! Host tests of src/kernel/virt/linuxload.zig — a full load into a RAM buffer.
//!
//! This exercises the whole boot-path pure layer end to end: parse → plan → place
//! kernel/initrd/cmdline → zero page → E820 → GDT → page tables → entry state, all
//! over an ordinary allocation with no hypervisor.

const std = @import("std");
const linuxload = @import("testroot").kernel.linuxload;
const layout = linuxload.layout;
const expectEqual = std.testing.expectEqual;

const SETUP_BYTES = 2560; // (4+1)*512
const PM_MARKER = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

/// A synthetic bzImage: valid header + a protected-mode payload that starts with a
/// recognizable marker so we can assert it landed at the load address.
fn makeImage(buf: []u8, init_size: u32) void {
    @memset(buf, 0);
    buf[0x1F1] = 4; // setup_sects → setup area = 2560 bytes
    std.mem.writeInt(u16, buf[0x1FE..][0..2], 0xAA55, .little); // boot_flag
    std.mem.writeInt(u32, buf[0x202..][0..4], 0x53726448, .little); // "HdrS"
    std.mem.writeInt(u16, buf[0x206..][0..2], 0x020F, .little); // version
    buf[0x201] = 0x70; // header end marker
    std.mem.writeInt(u32, buf[0x22C..][0..4], 0x7FFF_FFFF, .little); // initrd_addr_max
    std.mem.writeInt(u16, buf[0x236..][0..2], 0x0001, .little); // XLF_KERNEL_64
    std.mem.writeInt(u32, buf[0x238..][0..4], 0x7FF, .little); // cmdline_size
    std.mem.writeInt(u64, buf[0x258..][0..8], 0x100_0000, .little); // pref_address
    std.mem.writeInt(u32, buf[0x260..][0..4], init_size, .little);
    @memcpy(buf[SETUP_BYTES..][0..PM_MARKER.len], &PM_MARKER); // start of pm kernel
}

test "load places everything and returns a 64-bit entry state" {
    const alloc = std.testing.allocator;
    const ram = try alloc.alloc(u8, 64 * 1024 * 1024);
    defer alloc.free(ram);
    @memset(ram, 0);

    var image: [SETUP_BYTES + 0x1000]u8 = undefined;
    makeImage(&image, 0x40_0000); // 4 MiB init_size, fits in 64 MiB

    const initrd = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const cmdline = "console=ttyS0 rdinit=/init";

    const es = try linuxload.load(ram, &image, &initrd, cmdline);

    // Entry state for a 64-bit boot.
    try expectEqual(@as(u64, 0x100_0200), es.rip); // pref_address + 0x200
    try expectEqual(layout.ZERO_PAGE_GPA, es.rsi); // boot_params pointer
    try expectEqual(layout.PT_PML4_GPA, es.cr3);
    try std.testing.expect(es.cr0 & (1 << 31) != 0); // PG
    try std.testing.expect(es.cr0 & 1 != 0); // PE
    try std.testing.expect(es.cr4 & (1 << 5) != 0); // PAE
    try std.testing.expect(es.efer & (1 << 8) != 0); // LME
    try std.testing.expect(es.efer & (1 << 10) != 0); // LMA
    try expectEqual(layout.GDT_GPA, es.gdtr_base);

    // The protected-mode kernel landed at the load address.
    try std.testing.expectEqualSlices(u8, &PM_MARKER, ram[0x100_0000..][0..PM_MARKER.len]);

    // The command line landed, NUL-terminated.
    try std.testing.expectEqualSlices(u8, cmdline, ram[layout.CMDLINE_GPA..][0..cmdline.len]);
    try expectEqual(@as(u8, 0), ram[layout.CMDLINE_GPA + cmdline.len]);

    // The zero page has the HdrS magic copied through (proves the header copy).
    try expectEqual(@as(u32, 0x53726448), std.mem.readInt(u32, ram[layout.ZERO_PAGE_GPA + 0x202 ..][0..4], .little));
}

test "load rejects a bad image before touching RAM" {
    const alloc = std.testing.allocator;
    const ram = try alloc.alloc(u8, 64 * 1024 * 1024);
    defer alloc.free(ram);
    var image: [SETUP_BYTES + 0x1000]u8 = undefined;
    makeImage(&image, 0x40_0000);
    std.mem.writeInt(u16, image[0x1FE..][0..2], 0, .little); // clobber boot_flag
    try std.testing.expectError(error.BadMagic, linuxload.load(ram, &image, &[_]u8{}, "x"));
}
