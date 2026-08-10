//! Host tests of src/kernel/virt/virtio/blkdev.zig — the disk: a request is a
//! header, some data and a status byte, and what the device does with them is
//! read, write, or refuse.
//!
//! The security boundary is the one that matters most on a block device: a
//! request names a sector, and a sector is an index into host memory. A request
//! that runs off the end of the disk must be refused ENTIRELY — not clamped, not
//! served in part — because the bytes on the other side of the store belong to
//! the host or to another guest. Requests are encoded at the §5.2.6 wire offsets
//! by hand, so a mistake in the module's own idea of the layout cannot pass its
//! own test.

const std = @import("std");
const blkdev = @import("testroot").kernel.virtio_blkdev;
const virtq = blkdev.virtq;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;
const QSIZE: u16 = 8;

// Guest-physical layout of the fake machine.
const DESC_GPA: u64 = 0x100;
const AVAIL_GPA: u64 = 0x800;
const USED_GPA: u64 = 0xA00;
const HDR_GPA: u64 = 0x1000;
const DATA_GPA: u64 = 0x2000;
const DATA2_GPA: u64 = 0x3000; // a second, deliberately non-adjacent data segment
const STATUS_GPA: u64 = 0x4000;

const SECTOR = blkdev.SECTOR_BYTES;
/// Eight sectors of disk: small enough that every byte can be checked, and big
/// enough that "off the end" is a real address rather than the first one.
const DISK_SECTORS: u64 = 8;
const DISK_BYTES: usize = @intCast(DISK_SECTORS * SECTOR);

const T_IN: u32 = 0;
const T_OUT: u32 = 1;
const T_FLUSH: u32 = 4;
const T_GET_ID: u32 = 8;
const S_OK: u8 = 0;
const S_IOERR: u8 = 1;
const S_UNSUPP: u8 = 2;

var disk_mem: [DISK_BYTES]u8 = undefined;

const Fx = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    q: virtq.Virtq = undefined,
    dev: blkdev.BlkDev = .{},
    avail_idx: u16 = 0,
    submitted: u16 = 0,

    /// In place: the queue's `mem` points at THIS fixture's ram, so the fixture
    /// can never be initialized by copy.
    fn init(self: *Fx) void {
        self.* = .{};
        @memset(&disk_mem, 0);
        self.q = .{
            .mem = &self.ram,
            .size = QSIZE,
            .desc_gpa = DESC_GPA,
            .avail_gpa = AVAIL_GPA,
            .used_gpa = USED_GPA,
            .ready = true,
        };
        self.dev.bind(&disk_mem, &self.ram);
    }

    fn setDesc(self: *Fx, i: u16, addr: u64, len: u32, flags: u16, next: u16) void {
        const base: usize = @intCast(DESC_GPA + @as(u64, i) * 16);
        std.mem.writeInt(u64, self.ram[base..][0..8], addr, .little);
        std.mem.writeInt(u32, self.ram[base + 8 ..][0..4], len, .little);
        std.mem.writeInt(u16, self.ram[base + 12 ..][0..2], flags, .little);
        std.mem.writeInt(u16, self.ram[base + 14 ..][0..2], next, .little);
    }

    fn pushAvail(self: *Fx, head: u16) void {
        const slot: usize = @intCast(AVAIL_GPA + 4 + @as(u64, self.avail_idx % QSIZE) * 2);
        std.mem.writeInt(u16, self.ram[slot..][0..2], head, .little);
        self.avail_idx +%= 1;
        std.mem.writeInt(u16, self.ram[@intCast(AVAIL_GPA + 2)..][0..2], self.avail_idx, .little);
    }

    /// Write a §5.2.6 request header into guest RAM.
    fn header(self: *Fx, req_type: u32, sector: u64) void {
        const b: usize = @intCast(HDR_GPA);
        std.mem.writeInt(u32, self.ram[b..][0..4], req_type, .little);
        std.mem.writeInt(u32, self.ram[b + 4 ..][0..4], 0, .little); // reserved
        std.mem.writeInt(u64, self.ram[b + 8 ..][0..8], sector, .little);
    }

    const Outcome = struct { status: u8, written: u32 };

    /// One request: header, one data segment of `data_len`, status byte. `write`
    /// says which way the data travels, which decides the descriptor's flags.
    fn submit(self: *Fx, req_type: u32, sector: u64, data_len: u32, to_device: bool) Outcome {
        self.header(req_type, sector);
        self.ram[@intCast(STATUS_GPA)] = 0xFF; // never mistake "untouched" for OK
        self.setDesc(0, HDR_GPA, 16, virtq.F_NEXT, 1);
        self.setDesc(1, DATA_GPA, data_len, virtq.F_NEXT | (if (to_device) 0 else virtq.F_WRITE), 2);
        self.setDesc(2, STATUS_GPA, 1, virtq.F_WRITE, 0);
        self.pushAvail(0);
        self.dev.processQueue(&self.q);
        self.submitted += 1;
        const elem: usize = @intCast(USED_GPA + 4 + @as(u64, (self.submitted - 1) % QSIZE) * 8);
        return .{
            .status = self.ram[@intCast(STATUS_GPA)],
            .written = std.mem.readInt(u32, self.ram[elem + 4 ..][0..4], .little),
        };
    }
};

var fx: Fx = undefined;

test "capacity is the store's size in 512-byte sectors, in config space (VIRT-037)" {
    fx.init();
    try expectEqual(DISK_SECTORS, fx.dev.capacitySectors());
    // The guest reads it from config space rather than from the accessor.
    try expectEqual(DISK_SECTORS, std.mem.readInt(u64, fx.dev.config[0..8], .little));
}

test "a write lands in the store and a read brings it back (VIRT-037)" {
    fx.init();
    // Fill one sector's worth of guest buffer with a recognisable pattern.
    for (0..@intCast(SECTOR)) |i| fx.ram[@intCast(DATA_GPA + i)] = @truncate(i);

    const w = fx.submit(T_OUT, 2, @intCast(SECTOR), true);
    try expectEqual(S_OK, w.status);
    // A write moves no bytes INTO the guest, so the used length is the status
    // byte alone — reporting the data as written would tell the driver the
    // device had filled buffers it never touched.
    try expectEqual(@as(u32, 1), w.written);
    // It landed at the sector asked for, and nowhere else.
    try expect(std.mem.eql(u8, disk_mem[@intCast(2 * SECTOR)..][0..@intCast(SECTOR)], fx.ram[@intCast(DATA_GPA)..][0..@intCast(SECTOR)]));
    try expectEqual(@as(u8, 0), disk_mem[@intCast(SECTOR)]); // the sector below is untouched

    // Read it back into a cleared buffer.
    @memset(fx.ram[@intCast(DATA_GPA)..][0..@intCast(SECTOR)], 0);
    const r = fx.submit(T_IN, 2, @intCast(SECTOR), false);
    try expectEqual(S_OK, r.status);
    try expectEqual(@as(u32, SECTOR + 1), r.written); // data + status
    for (0..@intCast(SECTOR)) |i| try expectEqual(@as(u8, @truncate(i)), fx.ram[@intCast(DATA_GPA + i)]);
}

test "a request past the end of the disk is refused whole, not clamped (VIRT-038)" {
    fx.init();
    @memset(&disk_mem, 0xAB);
    @memset(fx.ram[@intCast(DATA_GPA)..][0..@intCast(SECTOR)], 0x11);

    // The last sector is DISK_SECTORS-1; asking for the one past it addresses
    // host memory beyond the store.
    const w = fx.submit(T_OUT, DISK_SECTORS, @intCast(SECTOR), true);
    try expectEqual(S_IOERR, w.status);
    try expectEqual(@as(u32, 1), w.written);
    // Nothing was written: not one byte of the store changed.
    for (disk_mem) |b| try expectEqual(@as(u8, 0xAB), b);
    try expect(fx.dev.errors > 0);

    // A read that starts inside the disk but runs off the end is refused for the
    // same reason — a partial answer would hand over whatever follows the store.
    const r = fx.submit(T_IN, DISK_SECTORS - 1, @intCast(SECTOR * 2), false);
    try expectEqual(S_IOERR, r.status);
    for (0..@intCast(SECTOR)) |i| try expectEqual(@as(u8, 0x11), fx.ram[@intCast(DATA_GPA + i)]);
}

test "a flush succeeds, because a memory-backed write is already durable (VIRT-037)" {
    fx.init();
    const f = fx.submit(T_FLUSH, 0, 0, true);
    try expectEqual(S_OK, f.status);
}

test "an unknown request type is refused as unsupported, not as an IO error (VIRT-037)" {
    fx.init();
    const u = fx.submit(0x5A5A, 0, @intCast(SECTOR), true);
    try expectEqual(S_UNSUPP, u.status);
}

test "data split across descriptors is one contiguous transfer (VIRT-037)" {
    fx.init();
    // Two half-sector segments at non-adjacent guest addresses, written as one
    // request: a driver may fragment a chain however it likes, and the sectors
    // they land on must still be consecutive.
    const half: u32 = @intCast(SECTOR / 2);
    @memset(fx.ram[@intCast(DATA_GPA)..][0..half], 0xC1);
    @memset(fx.ram[@intCast(DATA2_GPA)..][0..half], 0xC2);
    fx.header(T_OUT, 1);
    fx.ram[@intCast(STATUS_GPA)] = 0xFF;
    fx.setDesc(0, HDR_GPA, 16, virtq.F_NEXT, 1);
    fx.setDesc(1, DATA_GPA, half, virtq.F_NEXT, 2);
    fx.setDesc(2, DATA2_GPA, half, virtq.F_NEXT, 3);
    fx.setDesc(3, STATUS_GPA, 1, virtq.F_WRITE, 0);
    fx.pushAvail(0);
    fx.dev.processQueue(&fx.q);

    try expectEqual(S_OK, fx.ram[@intCast(STATUS_GPA)]);
    const sect: usize = @intCast(SECTOR);
    for (disk_mem[sect..][0..@intCast(half)]) |b| try expectEqual(@as(u8, 0xC1), b);
    for (disk_mem[sect + @as(usize, half) ..][0..@intCast(half)]) |b| try expectEqual(@as(u8, 0xC2), b);
}

test "the store survives a driver reset, because a reset is not a wipe (VIRT-037)" {
    fx.init();
    @memset(fx.ram[@intCast(DATA_GPA)..][0..@intCast(SECTOR)], 0x77);
    _ = fx.submit(T_OUT, 0, @intCast(SECTOR), true);

    // The transport's reset path, as a driver writing Status=0 would reach it.
    fx.dev.write(0x70, 4, 0); // Status register
    for (disk_mem[0..@intCast(SECTOR)]) |b| try expectEqual(@as(u8, 0x77), b);
}
