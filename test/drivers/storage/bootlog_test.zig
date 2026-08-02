//! Host tests of the flight recorder (src/drivers/storage/bootlog.zig): the
//! boot trace mirrored to a ring file on the USB volume (spec DIAG-014), run
//! against a REAL FAT volume on an in-memory block device — the same fixture
//! discipline as fat_test. What is asserted end-to-end: init adopts a seeded
//! ring, the boot banner reaches the FILE (not just RAM) on flush, the header
//! stays parseable, and a second boot continues the ring after the first.

const std = @import("std");
const testroot = @import("testroot");
const bootlog = testroot.storage.bootlog;
const fat = testroot.storage.fat;
const iblockdev = @import("iblockdev");

const MemDev = struct {
    image: []u8,

    fn read(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(buf[0..@intCast(len)], self.image[@intCast(off)..][0..@intCast(len)]);
    }
    fn write(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(self.image[@intCast(off)..][0..@intCast(len)], buf[0..@intCast(len)]);
    }
    fn sync(ctx: *anyopaque) iblockdev.Error!void {
        _ = ctx;
    }
    fn nblocks(ctx: *anyopaque) u64 {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        return self.image.len / iblockdev.SECTOR;
    }
    const vtable = iblockdev.IBlockDev.VTable{ .read = read, .write = write, .sync = sync, .nblocks = nblocks };
    fn iface(self: *MemDev) iblockdev.IBlockDev {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Decompress the FAT32 fixture and mount it (fat_test's discipline), then
/// seed a modest ring file so init adopts it rather than creating the full
/// 8 MiB product-sized ring the small fixture cannot hold.
const RING_BYTES: usize = 64 * 1024;

fn gunzip(ta: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var out = std.array_list.Managed(u8).init(ta);
    errdefer out.deinit();
    const window = try ta.alloc(u8, std.compress.flate.max_window_len);
    defer ta.free(window);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, window);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try dec.reader.readSliceShort(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
}

fn mountWithRing(ta: std.mem.Allocator, dev: *MemDev) !*fat.Volume {
    dev.image = try gunzip(ta, @embedFile("fixtures/fat32.img.gz"));
    const vol = try fat.mount(ta, dev.iface());
    var f = try vol.create(bootlog.PATH);
    const fill = [_]u8{'\n'} ** 4096;
    var left: usize = RING_BYTES;
    while (left > 0) {
        const n = @min(left, fill.len);
        try f.append(fill[0..n]);
        left -= n;
    }
    return vol;
}

test "the boot banner reaches the ring FILE on the volume, headered and parseable (DIAG-014)" {
    const ta = std.testing.allocator;
    var dev = MemDev{ .image = &.{} };
    const vol = try mountWithRing(ta, &dev);
    defer {
        if (vol.file_buf) |fb| ta.free(fb);
        ta.destroy(vol);
        ta.free(dev.image);
    }

    try std.testing.expect(bootlog.init(vol, 4242));
    bootlog.flushNow();

    var lf = try vol.openLog(bootlog.PATH);
    var head: [512]u8 = undefined;
    _ = try lf.readAt(0, &head);
    try std.testing.expect(std.mem.startsWith(u8, &head, "KUDOSLOG v1 seq="));

    var body: [RING_BYTES - 512]u8 = undefined;
    _ = try lf.readAt(512, &body);
    try std.testing.expect(std.mem.indexOf(u8, &body, "===== kudos boot #4242") != null);

    // A second boot continues the SAME ring: its banner lands after the first
    // boot's, and both survive in the file.
    try std.testing.expect(bootlog.init(vol, 4243));
    bootlog.flushNow();
    _ = try lf.readAt(512, &body);
    const first = std.mem.indexOf(u8, &body, "===== kudos boot #4242").?;
    const second = std.mem.indexOf(u8, &body, "===== kudos boot #4243").?;
    try std.testing.expect(second > first);

    // The trace itself arrives through the registered KLOG SINK — the same
    // path kernel puts() takes — and service() drains whole sectors without a
    // panic flush.
    var i: usize = 0;
    while (i < 40) : (i += 1)
        testroot.kernel.klog.puts("the quick brown fox jumps over the flight recorder\n");
    bootlog.service();
    _ = try lf.readAt(512, &body);
    try std.testing.expect(std.mem.indexOf(u8, &body, "quick brown fox") != null);

    // Feed more than the whole body ring: the cursor wraps and the header's
    // wrap sequence advances instead of the write running off the file.
    i = 0;
    while (i < 2048) : (i += 1)
        testroot.kernel.klog.puts("wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap.\n");
    bootlog.flushNow();
    _ = try lf.readAt(0, &head);
    try std.testing.expect(std.mem.startsWith(u8, &head, "KUDOSLOG v1 seq="));
    const seq_at = std.mem.indexOf(u8, &head, "seq=").? + 4;
    try std.testing.expect(head[seq_at] != '0'); // wrapped at least once
}

test "a corrupt header restarts the ring instead of trusting a wild cursor (DIAG-014)" {
    const ta = std.testing.allocator;
    var dev = MemDev{ .image = &.{} };
    const vol = try mountWithRing(ta, &dev);
    defer {
        if (vol.file_buf) |fb| ta.free(fb);
        ta.destroy(vol);
        ta.free(dev.image);
    }
    var lf = try vol.openLog(bootlog.PATH);
    const garbage = [_]u8{0xA5} ** 512;
    try lf.writeAt(0, &garbage);
    try std.testing.expect(bootlog.init(vol, 4244));
    bootlog.flushNow();
    var head: [512]u8 = undefined;
    _ = try lf.readAt(0, &head);
    try std.testing.expect(std.mem.startsWith(u8, &head, "KUDOSLOG v1 seq="));
}

test "an oversized trace burst truncates the diagnostic ring rather than growing it" {
    // Exercises klog's DIAG_CAP truncation arm (and floods the recorder's RAM
    // ring, whose overrun is a counter, never a block).
    const ta = std.testing.allocator;
    const big = try ta.alloc(u8, 1024 * 1024 + 4096);
    defer ta.free(big);
    @memset(big, 'y');
    testroot.kernel.klog.puts(big);
}

test "a fresh volume gets its ring file CREATED once, product-sized (DIAG-014)" {
    // No seeded ring: the first boot with this stick creates the fixed-size
    // ring file itself, and the header lands on the first flush.
    const ta = std.testing.allocator;
    var dev = MemDev{ .image = &.{} };
    dev.image = try gunzip(ta, @embedFile("fixtures/fat32.img.gz"));
    defer ta.free(dev.image);
    const vol = try fat.mount(ta, dev.iface());
    defer {
        if (vol.file_buf) |fb| ta.free(fb);
        ta.destroy(vol);
    }
    try std.testing.expect(bootlog.init(vol, 4245));
    bootlog.flushNow();
    var lf = try vol.openLog(bootlog.PATH);
    try std.testing.expect(lf.size > RING_BYTES); // product-sized, not the test seed
    var head: [512]u8 = undefined;
    _ = try lf.readAt(0, &head);
    try std.testing.expect(std.mem.startsWith(u8, &head, "KUDOSLOG v1 seq="));
}
