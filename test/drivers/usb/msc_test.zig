//! Host tests of src/drivers/usb/msc.zig.

const std = @import("std");
const msc = @import("msc");
const CBW_LEN = msc.CBW_LEN;
const CSW_LEN = msc.CSW_LEN;
const Csw = msc.Csw;
const Device = msc.Device;
const EpPick = msc.EpPick;
const ProbeError = msc.ProbeError;
const Transport = msc.Transport;
const buildCbw = msc.buildCbw;
const cdbRead10 = msc.cdbRead10;
const iblockdev = msc.iblockdev;
const parseCsw = msc.parseCsw;
const pickBulkEndpoints = msc.pickBulkEndpoints;

/// Fake transport: a scripted BOT device over an in-memory disk image.
/// Parses each CBW like a real stick and answers INQUIRY / TEST UNIT READY
/// (optionally failing the first N) / READ CAPACITY / READ(10).
const FakeStick = struct {
    image: []u8, // the "medium" (mutable — WRITE(10) rewrites it)
    report_blocks: u64, // what READ CAPACITY claims (whitelist tests)
    tur_fail_left: u32 = 0,
    pending: ?struct { cdb: [16]u8, cdb_len: u8, tag: u32, want: u32 } = null,
    data_sent: u32 = 0,
    fail_status: u8 = 0,
    /// Transient-link script: fail this many READ(10) data phases at the
    /// transport level (bulkIn null — the whole command dies), then behave.
    data_fail_left: u32 = 0,
    recovers: u32 = 0,

    fn begin(_: *anyopaque) void {}
    fn end(_: *anyopaque) void {}
    fn bulkOut(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *FakeStick = @ptrCast(@alignCast(ctx));
        if (bytes.len != CBW_LEN) return false;
        if (std.mem.readInt(u32, bytes[0..4], .little) != 0x43425355) return false;
        var cdb: [16]u8 = undefined;
        @memcpy(&cdb, bytes[15..31]);
        self.pending = .{
            .cdb = cdb,
            .cdb_len = bytes[14],
            .tag = std.mem.readInt(u32, bytes[4..8], .little),
            .want = std.mem.readInt(u32, bytes[8..12], .little),
        };
        self.data_sent = 0;
        self.fail_status = 0;
        return true;
    }
    fn bulkOutData(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *FakeStick = @ptrCast(@alignCast(ctx));
        const p = &(self.pending orelse return false);
        if (p.cdb[0] != 0x2A) return false; // only WRITE(10) has an OUT data phase
        const lba = std.mem.readInt(u32, p.cdb[2..6], .big);
        const off = @as(usize, lba) * 512;
        if (off + bytes.len > self.image.len) {
            self.fail_status = 1;
            return true; // CSW will report failure
        }
        @memcpy(self.image[off..][0..bytes.len], bytes);
        self.data_sent = @intCast(bytes.len);
        return true;
    }
    fn bulkIn(ctx: *anyopaque, buf: []u8) ?u32 {
        const self: *FakeStick = @ptrCast(@alignCast(ctx));
        const p = &(self.pending orelse return null);
        // Data phase?
        if (self.data_sent == 0 and p.want > 0 and buf.len == p.want) {
            switch (p.cdb[0]) {
                0x12 => { // INQUIRY
                    @memset(buf, 0);
                    @memcpy(buf[8..24], "kudosfke MS70   ");
                    self.data_sent = 36;
                    return 36;
                },
                0x25 => { // READ CAPACITY(10)
                    std.mem.writeInt(u32, buf[0..4], @intCast(self.report_blocks - 1), .big);
                    std.mem.writeInt(u32, buf[4..8], 512, .big);
                    self.data_sent = 8;
                    return 8;
                },
                0x28 => { // READ(10)
                    if (self.data_fail_left > 0) {
                        self.data_fail_left -= 1;
                        self.pending = null; // the failed transfer aborts the command
                        return null;
                    }
                    const lba = std.mem.readInt(u32, p.cdb[2..6], .big);
                    const n = std.mem.readInt(u16, p.cdb[7..9], .big);
                    const off = @as(usize, lba) * 512;
                    const len = @as(usize, n) * 512;
                    if (off + len > self.image.len) {
                        self.fail_status = 1;
                        self.data_sent = 1; // no data; CSW will say failed
                        return 0;
                    }
                    @memcpy(buf[0..len], self.image[off..][0..len]);
                    self.data_sent = @intCast(len);
                    return @intCast(len);
                },
                else => return null,
            }
        }
        // CSW phase.
        if (buf.len == CSW_LEN) {
            var status: u8 = self.fail_status;
            if (p.cdb[0] == 0 and self.tur_fail_left > 0) { // TEST UNIT READY
                self.tur_fail_left -= 1;
                status = 1;
            }
            std.mem.writeInt(u32, buf[0..4], 0x53425355, .little);
            std.mem.writeInt(u32, buf[4..8], p.tag, .little);
            std.mem.writeInt(u32, buf[8..12], p.want - self.data_sent, .little);
            buf[12] = status;
            self.pending = null;
            return CSW_LEN;
        }
        return null;
    }
    fn recover(ctx: *anyopaque) bool {
        const self: *FakeStick = @ptrCast(@alignCast(ctx));
        self.recovers += 1;
        return true;
    }
    const vtable = Transport.VTable{ .begin = begin, .end = end, .bulkOut = bulkOut, .bulkOutData = bulkOutData, .bulkIn = bulkIn, .recover = recover };
    fn transport(self: *FakeStick) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const GB: u64 = 1_000_000_000;

test "pickBulkEndpoints finds the 08/06/50 interface and both pipes" {
    // config(9) + wrong iface (HID) + its ep + the MSC iface + IN/OUT eps.
    const cfg = [_]u8{
        9, 2, 55, 0, 2, 1, 0, 0x80, 50, // configuration
        9, 4, 0, 0, 1, 3, 1, 2, 0, // interface 0: HID
        7, 5, 0x81, 3, 8, 0, 10, // its interrupt-IN ep
        9, 4, 1, 0, 2, 8, 6, 0x50, 0, // interface 1: mass storage BOT
        7, 5, 0x82, 2, 0, 2, 0, // bulk IN, mps 512
        7, 5, 0x03, 2, 0, 2, 0, // bulk OUT, mps 512
    };
    const p = pickBulkEndpoints(&cfg).?;
    try std.testing.expectEqual(@as(u8, 1), p.iface);
    try std.testing.expectEqual(@as(u8, 0x82), p.in_addr);
    try std.testing.expectEqual(@as(u8, 0x03), p.out_addr);
    try std.testing.expectEqual(@as(u16, 512), p.in_mps);

    // A UFI/CBI device (wrong subclass/protocol) is not picked.
    var ufi = cfg;
    ufi[9 + 9 + 7 + 6] = 0x04; // subclass -> UFI
    try std.testing.expectEqual(@as(?EpPick, null), pickBulkEndpoints(&ufi));
}

test "CBW golden bytes and CSW parse/validation" {
    var cbw: [CBW_LEN]u8 = undefined;
    const cdb = cdbRead10(0x11223344, 8);
    buildCbw(&cbw, 0xAABBCCDD, 8 * 512, true, &cdb);
    try std.testing.expectEqualSlices(u8, &.{ 0x55, 0x53, 0x42, 0x43 }, cbw[0..4]); // 'USBC'
    try std.testing.expectEqualSlices(u8, &.{ 0xDD, 0xCC, 0xBB, 0xAA }, cbw[4..8]);
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, cbw[8..12], .little));
    try std.testing.expectEqual(@as(u8, 0x80), cbw[12]);
    try std.testing.expectEqual(@as(u8, 10), cbw[14]);
    try std.testing.expectEqual(@as(u8, 0x28), cbw[15]);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, cbw[17..21]); // big-endian LBA
    try std.testing.expectEqual(@as(u8, 8), cbw[23]); // nblocks lo (big-endian u16)

    var csw = [CSW_LEN]u8{ 0x55, 0x53, 0x42, 0x53, 0xDD, 0xCC, 0xBB, 0xAA, 0, 0, 0, 0, 0 };
    const ok = parseCsw(&csw, 0xAABBCCDD).?;
    try std.testing.expectEqual(@as(u8, 0), ok.status);
    try std.testing.expectEqual(@as(?Csw, null), parseCsw(&csw, 0x12345678)); // tag mismatch
    csw[0] = 'X';
    try std.testing.expectEqual(@as(?Csw, null), parseCsw(&csw, 0xAABBCCDD)); // bad signature
}

test "the capacity floor never rules out an ordinary stick" {
    // The gate exists to keep kudos off somebody's DRIVE, so only its ceiling is
    // a policy — configurable per build (-Dusb-max-gb). The floor is not: it
    // rejects a phantom unit too small to hold a filesystem and nothing more, so
    // the smallest stick anyone would plug in still mounts. A floor that
    // designates one particular device (the 1 TB stick this driver grew up on)
    // is the failure this pins.
    try std.testing.expect(msc.CAP_MIN_BYTES <= 1 * GB);
    try std.testing.expect(msc.CAP_MIN_BYTES < msc.CAP_MAX_BYTES);
}

test "probe: TUR settle, INQUIRY ident, capacity gate takes ordinary sticks" {
    var image = [_]u8{0} ** (4 * 512);
    // In-window stick that fails TEST UNIT READY twice before settling.
    var stick = FakeStick{ .image = &image, .report_blocks = 931 * GB / 512, .tur_fail_left = 2 };
    var dev = Device{ .t = stick.transport() };
    try dev.probe();
    try std.testing.expectEqual(@as(u64, 931 * GB / 512), dev.nblocks);
    try std.testing.expectEqualStrings("kudosfke MS70   ", dev.ident[0..16]);

    // A stick of ANY ordinary size is kudos storage: the gate tells a stick from
    // somebody's drive, it does not name one designated device. The sizes are
    // derived from the window itself, so this holds for any -Dusb-max-gb the
    // kernel is built with rather than pinning today's default.
    inline for (.{ msc.CAP_MIN_BYTES * 2, msc.CAP_MAX_BYTES / 2 }) |bytes| {
        var ok = FakeStick{ .image = &image, .report_blocks = bytes / 512 };
        var d3 = Device{ .t = ok.transport() };
        try d3.probe();
        try std.testing.expectEqual(bytes / 512, d3.nblocks);
    }

    // Below the floor (a phantom unit with nothing on it) and above the ceiling
    // (somebody's drive) both refuse, and the refused size is recorded. Just
    // over the ceiling, not double it: a size past 2 TiB is unrepresentable in
    // READ CAPACITY(10)'s 32-bit last-LBA and would arrive back CLAMPED, which
    // is the separate case below.
    inline for (.{ msc.CAP_MIN_BYTES / 2, msc.CAP_MAX_BYTES + 512 * 1024 }) |bytes| {
        var s2 = FakeStick{ .image = &image, .report_blocks = bytes / 512 };
        var d2 = Device{ .t = s2.transport() };
        try std.testing.expectError(ProbeError.MscCapacityRefused, d2.probe());
        try std.testing.expectEqual(@as(u64, bytes), d2.refused_bytes);
    }

    // A device larger than READ CAPACITY(10) can express answers with every
    // last-LBA bit set, which computes to exactly 2 TiB. That is above any
    // ceiling a stick would be given, so RC(16) is never needed to refuse it.
    var huge = FakeStick{ .image = &image, .report_blocks = @as(u64, 0xFFFF_FFFF) + 1 };
    var dh = Device{ .t = huge.transport() };
    try std.testing.expectError(ProbeError.MscCapacityRefused, dh.probe());
    try std.testing.expectEqual(@as(u64, 2) * 1024 * 1024 * 1024 * 1024, dh.refused_bytes);
}

test "reads: chunked READ(10), bounds, short-read loudness" {
    var image: [1024 * 512]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i * 31 + (i >> 9));
    var stick = FakeStick{ .image = &image, .report_blocks = 931 * GB / 512 };
    var dev = Device{ .t = stick.transport() };
    dev.nblocks = 1024; // skip probe; the fake medium is 1024 sectors

    const bd = dev.blockDev();
    var buf: [130 * 512]u8 = undefined; // > MAX_XFER_SECTORS forces chunking
    try bd.read(3, 130, &buf);
    try std.testing.expectEqualSlices(u8, image[3 * 512 ..][0 .. 130 * 512], &buf);

    var one: [512]u8 = undefined;
    try bd.read(1023, 1, &one);
    try std.testing.expectEqualSlices(u8, image[1023 * 512 ..][0..512], &one);
    try std.testing.expectError(iblockdev.Error.BlockOutOfRange, bd.read(1024, 1, &one));
}

test "a transient chunk failure recovers and the read completes" {
    var image: [256 * 512]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i * 7 + 1);
    var stick = FakeStick{ .image = &image, .report_blocks = 931 * GB / 512 };
    var dev = Device{ .t = stick.transport() };
    dev.nblocks = 256;

    // One transport-level data-phase failure: the chunk's command dies, the
    // device recovers, the retry succeeds, the file read is whole.
    stick.data_fail_left = 1;
    const bd = dev.blockDev();
    var buf: [130 * 512]u8 = undefined; // > MAX_XFER_SECTORS: several chunks
    try bd.read(0, 130, &buf);
    try std.testing.expectEqualSlices(u8, image[0 .. 130 * 512], &buf);
    try std.testing.expectEqual(@as(u32, 1), dev.io_retries);
    try std.testing.expect(stick.recovers >= 1);
}

test "a persistently dead pipe fails loudly after the stated chunk budget" {
    var image: [64 * 512]u8 = undefined;
    @memset(&image, 0xEE);
    var stick = FakeStick{ .image = &image, .report_blocks = 931 * GB / 512 };
    var dev = Device{ .t = stick.transport() };
    dev.nblocks = 64;

    stick.data_fail_left = std.math.maxInt(u32); // never heals
    const bd = dev.blockDev();
    var buf: [512]u8 = undefined;
    try std.testing.expectError(iblockdev.Error.BlockIoFailed, bd.read(0, 1, &buf));
    // Every attempt in the budget was spent; the retries counter says so.
    try std.testing.expectEqual(msc.XFER_CHUNK_TRIES - 1, dev.io_retries);
}

test "the full stack: MSC fake → fat.mount → read (wired in fat_test.zig)" {
    // The FAT-over-MSC integration lives in test/drivers/storage/fat_test.zig (it owns the
    // image fixtures); this placeholder documents where to look.
}

test "writes: chunked WRITE(10) lands in the image, then SYNCHRONIZE CACHE flushes" {
    var image: [256 * 512]u8 = undefined;
    @memset(&image, 0);
    var stick = FakeStick{ .image = &image, .report_blocks = 931 * GB / 512 };
    var dev = Device{ .t = stick.transport() };
    dev.nblocks = 256;

    const bd = dev.blockDev();
    var src: [130 * 512]u8 = undefined; // > MAX_XFER_SECTORS forces chunking
    for (&src, 0..) |*b, i| b.* = @truncate(i * 13 + 5);
    try bd.write(3, 130, &src);
    try std.testing.expectEqualSlices(u8, &src, image[3 * 512 ..][0 .. 130 * 512]);
    try std.testing.expectEqual(@as(u32, 0), dev.io_retries);
    // The durability half: SYNCHRONIZE CACHE is a no-data command that must
    // round-trip its CSW (the flight recorder's crash-survival guarantee).
    try bd.sync();
    try std.testing.expectError(iblockdev.Error.BlockOutOfRange, bd.write(256, 1, src[0..512]));
}

test "the WRITE(10) golden bytes carry lba and count big-endian" {
    const cdb = msc.cdbWrite10(0x00A1B2C3, 7);
    try std.testing.expectEqual(@as(u8, 0x2A), cdb[0]);
    try std.testing.expectEqual(@as(u32, 0x00A1B2C3), std.mem.readInt(u32, cdb[2..6], .big));
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, cdb[7..9], .big));
}
