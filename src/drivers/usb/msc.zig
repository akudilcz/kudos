//! USB Mass Storage Class — Bulk-Only Transport + the SCSI subset
//! (Linux include/linux/usb/storage.h + drivers/usb/storage/transport.c).
//! This module is PURE (std + iblockdev only, host-tested in-file): descriptor
//! picking, CBW/CSW wire codec, CDB builders, and the BOT command engine over
//! an injected `Transport` — the xhci glue (xhci.zig setupMsc) supplies the
//! real bulk pipes; the tests a fake serving an in-memory disk.
//!
//! THE STORAGE ACCESS SCOPE: this is the only block-device driver in kudos
//! (no NVMe/AHCI exists, so onboard disks are not reachable by any code path
//! present today), and probe() REFUSES any device whose READ CAPACITY falls
//! outside (CAP_MIN_BYTES, CAP_MAX_BYTES); `refused_bytes` records the size that
//! was turned away. The ceiling is the build's `-Dusb-max-gb`: a USB device
//! larger than it is assumed to be somebody's disk rather than the kudos stick,
//! and is never opened. Size it below any USB-attached drive you own.
//! WRITE(10) exists but is NARROW: the sole writer is the boot-log ring
//! (bootlog.zig), which rewrites the data clusters of ONE pre-sized file in
//! place and never touches FAT metadata.
//! Every write is followed by SYNCHRONIZE CACHE, asking the device to commit it
//! to media rather than leaving it in a volatile cache.

const std = @import("std");
const buildinfo = @import("buildinfo");
pub const iblockdev = @import("iblockdev");

/// The accepted capacity window. The floor is the smallest medium that can hold
/// a FAT volume worth mounting, so a phantom or zero-capacity unit is refused
/// rather than mounted empty. The ceiling comes from the build (`-Dusb-max-gb`,
/// GB as the drive industry counts them, 10^9 bytes): it is the line between a
/// stick kudos may use and a drive it must leave alone, and a device reporting
/// the clamped 0xFFFFFFFF last-LBA of a >2 TiB disk computes to 2 TiB and is
/// refused by it without READ CAPACITY(16).
pub const CAP_MIN_BYTES: u64 = 8 * 1024 * 1024;
pub const CAP_MAX_BYTES: u64 = @as(u64, buildinfo.usb_max_gb) * 1_000_000_000;

/// Per-READ(10) transfer cap, sectors (32 KiB — one Normal TRB's worth).
pub const MAX_XFER_SECTORS: u32 = 64;

/// Attempts per READ(10)/WRITE(10) chunk: the first, plus recover-and-retry
/// rounds. A real link drops the occasional transfer, and a multi-megabyte
/// file is a hundred chunks — one transient must not fail the file. A
/// persistently dead pipe still fails loudly once this stated budget is spent.
pub const XFER_CHUNK_TRIES: u32 = 3;

const SECTOR = iblockdev.SECTOR;

// ── configuration-descriptor pick (class 08/06/50 + its two bulk pipes) ──

pub const EpPick = struct {
    iface: u8,
    in_addr: u8, // endpoint address (bit 7 set)
    in_mps: u16,
    out_addr: u8,
    out_mps: u16,
};

/// Walk a configuration descriptor for the first Mass Storage interface —
/// class 0x08, subclass 0x06 (SCSI transparent), protocol 0x50 (BOT) — and
/// its bulk IN + OUT endpoints. Other subclasses/protocols (UFI, CBI) are
/// not picked (the device is then skipped loudly by the caller).
pub fn pickBulkEndpoints(cfg: []const u8) ?EpPick {
    var off: usize = if (cfg.len > 0) cfg[0] else 0;
    var in_msc_iface = false;
    var pick = EpPick{ .iface = 0, .in_addr = 0, .in_mps = 0, .out_addr = 0, .out_mps = 0 };
    while (off + 2 <= cfg.len and cfg[off] != 0) : (off += cfg[off]) {
        const len = cfg[off];
        const dtype = cfg[off + 1];
        if (off + len > cfg.len) break;
        if (dtype == 4 and len >= 9) { // interface descriptor
            if (in_msc_iface and pick.in_addr != 0 and pick.out_addr != 0) return pick;
            in_msc_iface = cfg[off + 5] == 0x08 and cfg[off + 6] == 0x06 and cfg[off + 7] == 0x50;
            if (in_msc_iface) {
                pick = .{ .iface = cfg[off + 2], .in_addr = 0, .in_mps = 0, .out_addr = 0, .out_mps = 0 };
            }
        } else if (dtype == 5 and len >= 7 and in_msc_iface) { // endpoint
            const addr = cfg[off + 2];
            const attrs = cfg[off + 3] & 0x3;
            const mps = @as(u16, cfg[off + 4]) | (@as(u16, cfg[off + 5]) << 8);
            if (attrs == 2) { // bulk
                if (addr & 0x80 != 0 and pick.in_addr == 0) {
                    pick.in_addr = addr;
                    pick.in_mps = mps;
                } else if (addr & 0x80 == 0 and pick.out_addr == 0) {
                    pick.out_addr = addr;
                    pick.out_mps = mps;
                }
            }
        }
    }
    return if (in_msc_iface and pick.in_addr != 0 and pick.out_addr != 0) pick else null;
}

// ── the BOT wire codec (bulk_cb_wrap / bulk_cs_wrap, storage.h) ──────────

pub const CBW_LEN: usize = 31;
pub const CSW_LEN: usize = 13;

pub fn buildCbw(buf: *[CBW_LEN]u8, tag: u32, data_len: u32, dir_in: bool, cdb: []const u8) void {
    std.debug.assert(cdb.len >= 1 and cdb.len <= 16);
    std.mem.writeInt(u32, buf[0..4], 0x43425355, .little); // 'USBC'
    std.mem.writeInt(u32, buf[4..8], tag, .little);
    std.mem.writeInt(u32, buf[8..12], data_len, .little);
    buf[12] = if (dir_in) 0x80 else 0; // US_BULK_FLAG_IN
    buf[13] = 0; // LUN 0
    buf[14] = @intCast(cdb.len);
    @memset(buf[15..31], 0);
    @memcpy(buf[15 .. 15 + cdb.len], cdb);
}

pub const Csw = struct {
    residue: u32,
    status: u8, // 0 ok, 1 failed, 2 phase error
};

/// Validate + parse a CSW; null on bad signature/length/tag (protocol
/// violation → the caller runs the reset ladder).
pub fn parseCsw(bytes: []const u8, expect_tag: u32) ?Csw {
    if (bytes.len != CSW_LEN) return null;
    if (std.mem.readInt(u32, bytes[0..4], .little) != 0x53425355) return null; // 'USBS'
    if (std.mem.readInt(u32, bytes[4..8], .little) != expect_tag) return null;
    return .{
        .residue = std.mem.readInt(u32, bytes[8..12], .little),
        .status = bytes[12],
    };
}

// ── the SCSI subset (big-endian data) ──

pub fn cdbTestUnitReady() [6]u8 {
    return .{ 0, 0, 0, 0, 0, 0 };
}
pub fn cdbInquiry() [6]u8 {
    return .{ 0x12, 0, 0, 0, 36, 0 };
}
pub fn cdbReadCapacity10() [10]u8 {
    return .{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}
pub fn cdbRead10(lba: u32, nblocks: u16) [10]u8 {
    var cdb = [_]u8{0} ** 10;
    cdb[0] = 0x28;
    std.mem.writeInt(u32, cdb[2..6], lba, .big);
    std.mem.writeInt(u16, cdb[7..9], nblocks, .big);
    return cdb;
}
/// WRITE(10) (SBC-3 §5.32) — same field layout as READ(10), opcode 0x2A.
pub fn cdbWrite10(lba: u32, nblocks: u16) [10]u8 {
    var cdb = [_]u8{0} ** 10;
    cdb[0] = 0x2A;
    std.mem.writeInt(u32, cdb[2..6], lba, .big);
    std.mem.writeInt(u16, cdb[7..9], nblocks, .big);
    return cdb;
}
/// SYNCHRONIZE CACHE(10) (SBC-3 §5.20) — LBA=0, count=0 flushes the WHOLE
/// medium's write cache to non-volatile storage, so a preceding WRITE(10) is
/// durable before we return (the flight-recorder's crash-survival guarantee).
pub fn cdbSyncCache10() [10]u8 {
    return .{ 0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}

// ── the transport seam (real: xhci.zig bulk pipes; fake: the tests) ──────

pub const Transport = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Make the whole BOT transaction atomic against the HID poll loop
        /// (the xhci impl takes its IRQ-off event lock; fakes no-op).
        begin: *const fn (ctx: *anyopaque) void,
        end: *const fn (ctx: *anyopaque) void,
        /// One bulk-OUT transfer of the 31-byte CBW. False = transport failure.
        bulkOut: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
        /// One bulk-OUT DATA phase (the sectors of a WRITE(10)) — larger than a
        /// CBW, so a distinct method the transport can chunk to its staging DMA.
        /// False = transport failure. (The boot-log ring is the only writer.)
        bulkOutData: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
        /// One bulk-IN transfer into `buf`; returns bytes actually
        /// transferred (short is legal mid-protocol), null = failure/stall
        /// beyond recovery.
        bulkIn: *const fn (ctx: *anyopaque, buf: []u8) ?u32,
        /// The BOT error ladder: clear both pipes' halts (+ Bulk-Only Reset
        /// where the impl supports it) so the next command can run.
        recover: *const fn (ctx: *anyopaque) bool,
    };
};

// ── the device: BOT command engine + IBlockDev ───────────────────────────

pub const ProbeError = error{
    MscTransport, // CBW/CSW transfer failed beyond recovery
    MscProtocol, // bad CSW / phase error persisted
    MscNotReady, // TEST UNIT READY never succeeded
    MscBadBlockSize, // READ CAPACITY block size != 512
    MscCapacityRefused, // outside the (CAP_MIN, CAP_MAX) whitelist
};

pub const Device = struct {
    t: Transport,
    tag: u32 = 1,
    nblocks: u64 = 0, // valid after probe()
    /// Filled by probe() for the log line: INQUIRY vendor+product (ASCII).
    ident: [24]u8 = [_]u8{' '} ** 24,
    /// Why probe refused, for the owner's loud log.
    refused_bytes: u64 = 0,
    /// Chunks that needed a recover-and-retry to complete (rates are counters:
    /// a link going marginal shows here long before it fails outright).
    io_retries: u32 = 0,

    /// One full BOT command: CBW → optional IN data → CSW (with the
    /// one CSW retry the spec allows). Returns the data bytes received.
    fn command(self: *Device, cdb: []const u8, data_in: ?[]u8) ProbeError!u32 {
        self.t.vtable.begin(self.t.ctx);
        defer self.t.vtable.end(self.t.ctx);

        self.tag +%= 1;
        var cbw: [CBW_LEN]u8 = undefined;
        const want: u32 = if (data_in) |d| @intCast(d.len) else 0;
        buildCbw(&cbw, self.tag, want, true, cdb);
        if (!self.t.vtable.bulkOut(self.t.ctx, &cbw)) {
            _ = self.t.vtable.recover(self.t.ctx);
            return ProbeError.MscTransport;
        }
        var got: u32 = 0;
        if (data_in) |d| {
            got = self.t.vtable.bulkIn(self.t.ctx, d) orelse blk: {
                // A stalled data phase is legal — recover and read the CSW.
                if (!self.t.vtable.recover(self.t.ctx)) return ProbeError.MscTransport;
                break :blk 0;
            };
        }
        var csw_buf: [CSW_LEN]u8 = undefined;
        var n = self.t.vtable.bulkIn(self.t.ctx, &csw_buf);
        if (n == null) {
            // Spec: clear the halt and retry the CSW read exactly once.
            if (!self.t.vtable.recover(self.t.ctx)) return ProbeError.MscTransport;
            n = self.t.vtable.bulkIn(self.t.ctx, &csw_buf);
        }
        const csw_n = n orelse return ProbeError.MscTransport;
        const csw = parseCsw(csw_buf[0..csw_n], self.tag) orelse return ProbeError.MscProtocol;
        if (csw.status == 2) {
            _ = self.t.vtable.recover(self.t.ctx);
            return ProbeError.MscProtocol;
        }
        if (csw.status != 0) return ProbeError.MscNotReady; // CHECK CONDITION
        return got;
    }

    /// One full BOT command with an OUT data phase (WRITE(10)) OR no data phase
    /// (SYNCHRONIZE CACHE, `data_out == null`): CBW → optional OUT data → CSW.
    /// The mirror of `command`, but the data flows guest→device. The ONLY caller
    /// is the boot-log ring (there is no general filesystem write).
    fn commandOut(self: *Device, cdb: []const u8, data_out: ?[]const u8) ProbeError!void {
        self.t.vtable.begin(self.t.ctx);
        defer self.t.vtable.end(self.t.ctx);

        self.tag +%= 1;
        var cbw: [CBW_LEN]u8 = undefined;
        const want: u32 = if (data_out) |d| @intCast(d.len) else 0;
        buildCbw(&cbw, self.tag, want, false, cdb); // dir_in = false
        if (!self.t.vtable.bulkOut(self.t.ctx, &cbw)) {
            _ = self.t.vtable.recover(self.t.ctx);
            return ProbeError.MscTransport;
        }
        if (data_out) |d| {
            if (!self.t.vtable.bulkOutData(self.t.ctx, d)) {
                if (!self.t.vtable.recover(self.t.ctx)) return ProbeError.MscTransport;
            }
        }
        var csw_buf: [CSW_LEN]u8 = undefined;
        var n = self.t.vtable.bulkIn(self.t.ctx, &csw_buf);
        if (n == null) {
            if (!self.t.vtable.recover(self.t.ctx)) return ProbeError.MscTransport;
            n = self.t.vtable.bulkIn(self.t.ctx, &csw_buf);
        }
        const csw_n = n orelse return ProbeError.MscTransport;
        const csw = parseCsw(csw_buf[0..csw_n], self.tag) orelse return ProbeError.MscProtocol;
        if (csw.status == 2) {
            _ = self.t.vtable.recover(self.t.ctx);
            return ProbeError.MscProtocol;
        }
        if (csw.status != 0) return ProbeError.MscNotReady; // CHECK CONDITION
    }

    /// Bring the unit up and apply the capacity whitelist. On success the
    /// device is usable as an IBlockDev.
    pub fn probe(self: *Device) ProbeError!void {
        // TEST UNIT READY until the medium settles (fresh sticks answer
        // CHECK CONDITION/UNIT ATTENTION at first). Bounded, no sleep — the
        // caller may re-probe later; real sticks settle within a few tries.
        var ready = false;
        var tries: u32 = 0;
        while (tries < 8) : (tries += 1) {
            const tur = cdbTestUnitReady();
            if (self.command(&tur, null)) |_| {
                ready = true;
                break;
            } else |e| switch (e) {
                ProbeError.MscNotReady => {}, // sense would say UNIT ATTENTION
                else => return e,
            }
        }
        if (!ready) return ProbeError.MscNotReady;

        var inq: [36]u8 = undefined;
        const inq_cdb = cdbInquiry();
        const inq_n = try self.command(&inq_cdb, inq[0..]);
        if (inq_n >= 32) @memcpy(self.ident[0..24], inq[8..32]);

        var cap: [8]u8 = undefined;
        const cap_cdb = cdbReadCapacity10();
        const cap_n = try self.command(&cap_cdb, cap[0..]);
        if (cap_n != 8) return ProbeError.MscProtocol;
        const last_lba = std.mem.readInt(u32, cap[0..4], .big);
        const block_size = std.mem.readInt(u32, cap[4..8], .big);
        if (block_size != SECTOR) return ProbeError.MscBadBlockSize;
        // A >2 TiB device reports last_lba 0xFFFFFFFF (READ CAPACITY(16)
        // territory) — that still computes 2 TiB, above the ceiling for any
        // sane -Dusb-max-gb, so such devices are refused without needing RC(16).
        const nblocks: u64 = @as(u64, last_lba) + 1;

        // THE CAPACITY GATE: a device outside the window is not kudos storage.
        const bytes = nblocks * SECTOR;
        if (bytes <= CAP_MIN_BYTES or bytes >= CAP_MAX_BYTES) {
            self.refused_bytes = bytes;
            return ProbeError.MscCapacityRefused;
        }
        self.nblocks = nblocks;
    }

    // ── iblockdev.IBlockDev ──────────────────────────────────────────

    fn vtRead(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) iblockdev.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        if (lba + count > self.nblocks) return iblockdev.Error.BlockOutOfRange;
        var done: u32 = 0;
        while (done < count) {
            const n: u32 = @min(count - done, MAX_XFER_SECTORS);
            const cdb = cdbRead10(@intCast(lba + done), @intCast(n));
            const want: u32 = n * @as(u32, SECTOR);
            const dst = buf[@as(usize, done) * SECTOR ..][0..want];
            var attempt: u32 = 1;
            const got = while (true) : (attempt += 1) {
                if (self.command(&cdb, dst)) |g| {
                    break g;
                } else |_| {
                    if (attempt == XFER_CHUNK_TRIES) return iblockdev.Error.BlockIoFailed;
                    self.io_retries += 1;
                    if (!self.t.vtable.recover(self.t.ctx)) return iblockdev.Error.BlockIoFailed;
                }
            };
            if (got != want) return iblockdev.Error.BlockIoFailed; // short read is loud
            done += n;
        }
    }
    fn vtWrite(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) iblockdev.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        if (lba + count > self.nblocks) return iblockdev.Error.BlockOutOfRange;
        var done: u32 = 0;
        while (done < count) {
            const n: u32 = @min(count - done, MAX_XFER_SECTORS);
            const cdb = cdbWrite10(@intCast(lba + done), @intCast(n));
            const bytes: u32 = n * @as(u32, SECTOR);
            const src = buf[@as(usize, done) * SECTOR ..][0..bytes];
            var attempt: u32 = 1;
            while (true) : (attempt += 1) {
                if (self.commandOut(&cdb, src)) |_| {
                    break;
                } else |_| {
                    if (attempt == XFER_CHUNK_TRIES) return iblockdev.Error.BlockIoFailed;
                    self.io_retries += 1;
                    if (!self.t.vtable.recover(self.t.ctx)) return iblockdev.Error.BlockIoFailed;
                }
            }
            done += n;
        }
        // NO SYNCHRONIZE CACHE here — the caller (boot-log ring) syncs on its own
        // cadence (flushNow/panic), so steady bulk writes ride the device cache.
    }
    fn vtSync(ctx: *anyopaque) iblockdev.Error!void {
        const self: *Device = @ptrCast(@alignCast(ctx));
        const sync = cdbSyncCache10(); // whole medium, no data phase
        self.commandOut(&sync, null) catch return iblockdev.Error.BlockIoFailed;
    }
    fn vtNblocks(ctx: *anyopaque) u64 {
        const self: *Device = @ptrCast(@alignCast(ctx));
        return self.nblocks;
    }
    const blockdev_vtable = iblockdev.IBlockDev.VTable{ .read = vtRead, .write = vtWrite, .sync = vtSync, .nblocks = vtNblocks };

    pub fn blockDev(self: *Device) iblockdev.IBlockDev {
        return .{ .ctx = self, .vtable = &blockdev_vtable };
    }
};
