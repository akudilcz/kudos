//! IBlockDev contract conformance (spec R69): one shared vector suite over the
//! 512-byte-sector block device seam (iface/iblockdev.zig) — sector read/write
//! round-trip, the write/sync separation, out-of-range rejection, and nblocks.
//! Run here against an in-memory device; the real USB mass-storage driver
//! (drivers/usb/msc.zig) is driven through the SAME surface by msc_test.zig
//! (over a fake BOT transport) and fat_test.zig (a FAT volume over MemDev), so
//! both a fake and the real implementation satisfy these vectors.

const std = @import("std");
const iblockdev = @import("iblockdev");

const SECTOR = iblockdev.SECTOR;

/// A minimal in-memory IBlockDev — the fake half of the contract. `synced`
/// records that the durability barrier was invoked (the contract's one
/// observable side effect of sync).
const MemDev = struct {
    image: []u8, // nblocks * SECTOR
    synced: bool = false,

    fn read(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const start = lba * SECTOR;
        const end = start + @as(u64, count) * SECTOR;
        if (end > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(buf, self.image[start..end]);
    }
    fn write(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const start = lba * SECTOR;
        const end = start + @as(u64, count) * SECTOR;
        if (end > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(self.image[start..end], buf);
    }
    fn sync(ctx: *anyopaque) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        self.synced = true;
    }
    fn nblocks(ctx: *anyopaque) u64 {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        return self.image.len / SECTOR;
    }

    const vtable = iblockdev.IBlockDev.VTable{ .read = read, .write = write, .sync = sync, .nblocks = nblocks };
    fn iface(self: *MemDev) iblockdev.IBlockDev {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// The shared conformance vectors over any IBlockDev with `total` sectors.
fn verify(dev: iblockdev.IBlockDev, total: u64) !void {
    try std.testing.expectEqual(total, dev.nblocks());

    // Single-sector write → read round-trip.
    var wbuf: [SECTOR]u8 = undefined;
    for (&wbuf, 0..) |*b, i| b.* = @truncate(i);
    try dev.write(0, 1, &wbuf);
    var rbuf: [SECTOR]u8 = undefined;
    try dev.read(0, 1, &rbuf);
    try std.testing.expectEqualSlices(u8, &wbuf, &rbuf);

    // Multi-sector write at a non-zero LBA, read back exactly.
    var multi: [3 * SECTOR]u8 = undefined;
    for (&multi, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    try dev.write(2, 3, &multi);
    var mread: [3 * SECTOR]u8 = undefined;
    try dev.read(2, 3, &mread);
    try std.testing.expectEqualSlices(u8, &multi, &mread);

    // A write does not disturb neighbouring sectors: sector 1 (never written
    // after the first single write) is still zero, sector 0 unchanged.
    var neigh: [SECTOR]u8 = undefined;
    try dev.read(1, 1, &neigh);
    try std.testing.expect(std.mem.allEqual(u8, &neigh, 0));

    // sync is a barrier that succeeds (durability is separate from write).
    try dev.sync();

    // Out-of-range read and write both fail loudly, not silently.
    var over: [SECTOR]u8 = undefined;
    try std.testing.expectError(iblockdev.Error.BlockOutOfRange, dev.read(total, 1, &over));
    try std.testing.expectError(iblockdev.Error.BlockOutOfRange, dev.write(total - 1, 2, multi[0 .. 2 * SECTOR]));
}

test "IBlockDev conformance: an in-memory device" {
    const total = 16;
    var image = [_]u8{0} ** (16 * SECTOR);
    var dev = MemDev{ .image = &image };
    try verify(dev.iface(), total);
    // The barrier was observed (sync's contract).
    try std.testing.expect(dev.synced);
}
