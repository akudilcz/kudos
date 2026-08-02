//! Host tests of src/kernel/virt/bzimage.zig — synthetic setup headers.

const std = @import("std");
const bzimage = @import("bzimage");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

/// Build a minimal well-formed bzImage head with the given knobs. setup_sects = 4
/// (a 2560-byte setup area) plus a small protected-mode payload.
fn makeImage(
    buf: []u8,
    opts: struct {
        version: u16 = 0x020F,
        xlf: u16 = 0x0001, // XLF_KERNEL_64
        boot_flag: u16 = 0xAA55,
        magic: u32 = 0x53726448, // "HdrS"
        setup_sects: u8 = 4,
        pref_address: u64 = 0x100_0000,
        init_size: u32 = 0x80_0000,
        initrd_addr_max: u32 = 0x7FFF_FFFF,
        cmdline_size: u32 = 0x7FF,
    },
) void {
    @memset(buf, 0);
    buf[0x1F1] = opts.setup_sects;
    std.mem.writeInt(u16, buf[0x1FE..][0..2], opts.boot_flag, .little);
    std.mem.writeInt(u32, buf[0x202..][0..4], opts.magic, .little);
    std.mem.writeInt(u16, buf[0x206..][0..2], opts.version, .little);
    buf[0x201] = 0x70; // header end marker → 0x202 + 0x70 = 0x272
    std.mem.writeInt(u32, buf[0x22C..][0..4], opts.initrd_addr_max, .little);
    std.mem.writeInt(u16, buf[0x236..][0..2], opts.xlf, .little);
    std.mem.writeInt(u32, buf[0x238..][0..4], opts.cmdline_size, .little);
    std.mem.writeInt(u64, buf[0x258..][0..8], opts.pref_address, .little);
    std.mem.writeInt(u32, buf[0x260..][0..4], opts.init_size, .little);
}

const IMAGE_LEN = 2560 + 4096; // setup area (5*512) + a small pm payload

test "parse a well-formed 64-bit bzImage header" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{});
    const bz = try bzimage.parse(&buf);
    try expectEqual(@as(usize, 2560), bz.setup_bytes); // (4+1)*512
    try expectEqual(@as(u16, 0x020F), bz.version);
    try expectEqual(true, bz.xlf_kernel_64);
    try expectEqual(@as(u64, 0x100_0000), bz.pref_address);
    try expectEqual(@as(u32, 0x80_0000), bz.init_size);
    try expectEqual(@as(u32, 0x7FFF_FFFF), bz.initrd_addr_max);
    try expectEqual(@as(u32, 0x7FF), bz.cmdline_size);
}

test "setup_sects of 0 means 4 sectors" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .setup_sects = 0 });
    const bz = try bzimage.parse(&buf);
    try expectEqual(@as(usize, 2560), bz.setup_bytes);
}

test "a bad boot flag is rejected" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .boot_flag = 0x1234 });
    try expectError(error.BadMagic, bzimage.parse(&buf));
}

test "a missing HdrS magic is rejected" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .magic = 0xDEADBEEF });
    try expectError(error.BadMagic, bzimage.parse(&buf));
}

test "an old protocol version is rejected" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .version = 0x0205 });
    try expectError(error.TooOld, bzimage.parse(&buf));
}

test "a 32-bit-only image (no XLF_KERNEL_64) is rejected" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .xlf = 0x0000 });
    try expectError(error.Not64Bit, bzimage.parse(&buf));
}

test "a truncated image is rejected" {
    var buf: [0x100]u8 = undefined;
    @memset(&buf, 0);
    try expectError(error.Truncated, bzimage.parse(&buf));
}

test "effective cmdline max floors at 255 for a zero field" {
    var buf: [IMAGE_LEN]u8 = undefined;
    makeImage(&buf, .{ .cmdline_size = 0 });
    const bz = try bzimage.parse(&buf);
    try expectEqual(@as(usize, 255), bzimage.effectiveCmdlineMax(bz));
}
