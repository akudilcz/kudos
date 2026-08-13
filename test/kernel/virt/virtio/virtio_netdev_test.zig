//! Host tests of src/kernel/virt/virtio/netdev.zig — the network adapter as a
//! whole device. The fixture speaks the register protocol a Linux virtio-mmio
//! driver speaks, over a fake guest RAM: probe, negotiate, program both queues,
//! then push frames across the FrameSink seam in each direction. It is the
//! proof that guest register accesses turn into plain Ethernet frames at the
//! seam — and back — which guest execution would otherwise be needed to show.

const std = @import("std");
const netdev = @import("testroot").kernel.virtio_netdev;
const ivirt = netdev.ivirt;
const mmio = netdev.mmio;
const virtq = netdev.virtq;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const RAM_LEN = 64 * 1024;
const QSIZE: u32 = 8;

// Guest-physical layout of the fake machine: one ring set per queue.
const RX_DESC_GPA: u64 = 0x100;
const RX_AVAIL_GPA: u64 = 0x300;
const RX_USED_GPA: u64 = 0x400;
const TX_DESC_GPA: u64 = 0x500;
const TX_AVAIL_GPA: u64 = 0x700;
const TX_USED_GPA: u64 = 0x800;
const RX_BUF_GPA: u64 = 0x1000;
const TX_BUF_GPA: u64 = 0x2000;

// Register offsets, spelled independently of the transport so a transposed
// offset there cannot self-verify (virtio 1.1 §4.2.2).

// Wire facts spelled independently of the device model, so a model that
// drifted from the virtio spec cannot self-verify: the net device type (§5),
// the VIRTIO_NET_F_MAC feature bit (§5.1.3), and the 12-byte virtio_net_hdr
// that prefixes every frame under VIRTIO_F_VERSION_1 (§5.1.6).
const NET_DEVICE_ID: u32 = 1;
const F_MAC_BIT0_BANK: u32 = 1 << 5;
const NET_HDR = 12;

// §2.1 device status bits, as a driver sets them in order.
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_NEEDS_RESET: u32 = 64;

const TEST_MAC = [6]u8{ 0x52, 0xAA, 0xBB, 0xCC, 0xDD, 0x07 };

/// One rx queue, one tx queue: the per-queue avail cursor the driver side of
/// the fixture keeps.
const RX = 0;
const TX = 1;

const Fx = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    dev: netdev.NetDev = .{},
    avail_idx: [2]u16 = .{ 0, 0 },
    /// Frames the FrameSink received, copied out at the moment of the call.
    sunk: [4][netdev.MAX_FRAME_BYTES]u8 = undefined,
    sunk_len: [4]usize = .{0} ** 4,
    sunk_count: usize = 0,
    /// What `sinkPut` answers — false plays a bridge whose ring is full.
    accept: bool = true,

    /// In place: the device's backend holds interior pointers to itself and to
    /// THIS fixture's ram, so the fixture can never be initialized by copy.
    fn init(self: *Fx) void {
        self.ram = [_]u8{0} ** RAM_LEN;
        self.avail_idx = .{ 0, 0 };
        self.sunk_len = .{0} ** 4;
        self.sunk_count = 0;
        self.accept = true;
        self.dev = .{};
        self.dev.bind(TEST_MAC, &self.ram);
    }

    fn sinkPut(ctx: *anyopaque, frame: []const u8) bool {
        const self: *Fx = @ptrCast(@alignCast(ctx));
        if (!self.accept) return false;
        @memcpy(self.sunk[self.sunk_count][0..frame.len], frame);
        self.sunk_len[self.sunk_count] = frame.len;
        self.sunk_count += 1;
        return true;
    }

    fn connectSink(self: *Fx) void {
        self.dev.connectSink(.{ .ctx = self, .put = sinkPut });
    }

    fn programQueue(self: *Fx, sel: u32, desc: u64, avail: u64, used: u64) void {
        self.dev.write(mmio.REG_QUEUE_SEL, 4, sel);
        self.dev.write(mmio.REG_QUEUE_NUM, 4, QSIZE);
        self.dev.write(mmio.REG_QUEUE_DESC_LOW, 4, @intCast(desc));
        self.dev.write(mmio.REG_QUEUE_DRIVER_LOW, 4, @intCast(avail));
        self.dev.write(mmio.REG_QUEUE_DEVICE_LOW, 4, @intCast(used));
        self.dev.write(mmio.REG_QUEUE_READY, 4, 1);
    }

    /// Everything a Linux virtio-net driver does before it moves frames:
    /// probe, negotiate features, program both queues, DRIVER_OK.
    fn bringUp(self: *Fx) !void {
        try expectEqual(@as(u32, 0x74726976), self.dev.read(mmio.REG_MAGIC_VALUE, 4)); // "virt"
        try expectEqual(@as(u32, 2), self.dev.read(mmio.REG_VERSION, 4));
        try expectEqual(NET_DEVICE_ID, self.dev.read(mmio.REG_DEVICE_ID, 4));

        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
        // Accept everything offered: MAC in bank 0, VERSION_1 in bank 1.
        self.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 0);
        self.dev.write(mmio.REG_DRIVER_FEATURES_SEL, 4, 0);
        self.dev.write(mmio.REG_DRIVER_FEATURES, 4, self.dev.read(mmio.REG_DEVICE_FEATURES, 4));
        self.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 1);
        self.dev.write(mmio.REG_DRIVER_FEATURES_SEL, 4, 1);
        self.dev.write(mmio.REG_DRIVER_FEATURES, 4, self.dev.read(mmio.REG_DEVICE_FEATURES, 4));
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

        self.programQueue(RX, RX_DESC_GPA, RX_AVAIL_GPA, RX_USED_GPA);
        self.programQueue(TX, TX_DESC_GPA, TX_AVAIL_GPA, TX_USED_GPA);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    }

    fn setDesc(self: *Fx, desc_gpa: u64, i: u16, addr: u64, len: u32, flags: u16, next: u16) void {
        const base: usize = @intCast(desc_gpa + @as(u64, i) * 16);
        std.mem.writeInt(u64, self.ram[base..][0..8], addr, .little);
        std.mem.writeInt(u32, self.ram[base + 8 ..][0..4], len, .little);
        std.mem.writeInt(u16, self.ram[base + 12 ..][0..2], flags, .little);
        std.mem.writeInt(u16, self.ram[base + 14 ..][0..2], next, .little);
    }

    fn pushAvail(self: *Fx, q: usize, avail_gpa: u64, head: u16) void {
        const slot: usize = @intCast(avail_gpa + 4 + @as(u64, self.avail_idx[q] % QSIZE) * 2);
        std.mem.writeInt(u16, self.ram[slot..][0..2], head, .little);
        self.avail_idx[q] +%= 1;
        std.mem.writeInt(u16, self.ram[@intCast(avail_gpa + 2)..][0..2], self.avail_idx[q], .little);
    }

    fn usedIdx(self: *const Fx, used_gpa: u64) u16 {
        return std.mem.readInt(u16, self.ram[@intCast(used_gpa + 2)..][0..2], .little);
    }

    fn usedLen(self: *const Fx, used_gpa: u64, slot: u64) u32 {
        return std.mem.readInt(u32, self.ram[@intCast(used_gpa + 4 + slot * 8 + 4)..][0..4], .little);
    }

    /// Write header+frame bytes into guest RAM at TX_BUF_GPA and publish them
    /// as one transmit chain split across `cuts` — descriptor boundaries that
    /// deliberately misalign with the header/frame boundary.
    fn submitTx(self: *Fx, frame: []const u8, cuts: []const u32) void {
        const total: u32 = @intCast(NET_HDR + frame.len);
        @memset(self.ram[@intCast(TX_BUF_GPA)..][0..NET_HDR], 0);
        @memcpy(self.ram[@intCast(TX_BUF_GPA + NET_HDR)..][0..frame.len], frame);
        var start: u32 = 0;
        var i: u16 = 0;
        for (cuts) |cut| {
            self.setDesc(TX_DESC_GPA, i, TX_BUF_GPA + start, cut - start, virtq.F_NEXT, i + 1);
            start = cut;
            i += 1;
        }
        self.setDesc(TX_DESC_GPA, i, TX_BUF_GPA + start, total - start, 0, 0);
        self.pushAvail(TX, TX_AVAIL_GPA, 0);
        self.dev.write(mmio.REG_QUEUE_NOTIFY, 4, TX);
    }
};

test "config space carries the MAC, at every access width" {
    var f: Fx = undefined;
    f.init();
    for (TEST_MAC, 0..) |b, i| {
        try expectEqual(@as(u32, b), f.dev.read(mmio.REG_CONFIG + i, 1));
    }
    try expectEqual(std.mem.readInt(u32, TEST_MAC[0..4], .little), f.dev.read(mmio.REG_CONFIG, 4));
    try expectEqual(std.mem.readInt(u16, TEST_MAC[4..6], .little), f.dev.read(mmio.REG_CONFIG + 4, 2));
    // Past the MAC there is no config: fields of features never offered read 0.
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_CONFIG + 6, 4));
}

test "an unbound device answers as absent hardware" {
    var dev = netdev.NetDev{};
    try expectEqual(@as(u32, 0), dev.read(mmio.REG_MAGIC_VALUE, 4));
    dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE); // must not fault
    try expect(!dev.irqLevel());
    try expect(!dev.pushRx(&[_]u8{ 1, 2, 3 })); // dropped, not faulted
    try expectEqual(@as(u64, 1), dev.rx_dropped);
}

test "feature negotiation fixpoint: MAC and VERSION_1 offered, nothing else, and accepting them sticks" {
    var f: Fx = undefined;
    f.init();
    f.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 0);
    try expectEqual(F_MAC_BIT0_BANK, f.dev.read(mmio.REG_DEVICE_FEATURES, 4));
    // VIRTIO_F_VERSION_1 is feature bank 1, bit 0 — and bank 1 holds nothing else.
    f.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 1);
    try expectEqual(@as(u32, 1), f.dev.read(mmio.REG_DEVICE_FEATURES, 4));
    f.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 2);
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_DEVICE_FEATURES, 4));

    // A driver that writes the offer back verbatim completes negotiation: the
    // device leaves FEATURES_OK standing rather than revoking it.
    try f.bringUp();
    const status = f.dev.read(mmio.REG_STATUS, 4);
    try expect(status & STATUS_FEATURES_OK != 0);
    try expect(status & STATUS_NEEDS_RESET == 0);
}

test "a fragmented transmit chain reaches the sink exactly once, header stripped" {
    var f: Fx = undefined;
    f.init();
    f.connectSink();
    try f.bringUp();

    var frame: [60]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast((i * 3) & 0xFF);
    // Cuts at 8 and 18: the first descriptor ends inside the header, the second
    // straddles the header/frame boundary — the gather cannot shortcut either.
    f.submitTx(&frame, &[_]u32{ 8, 18 });

    try expectEqual(@as(usize, 1), f.sunk_count);
    try expectEqualSlices(u8, &frame, f.sunk[0][0..f.sunk_len[0]]);
    try expectEqual(@as(u64, 0), f.dev.tx_dropped);
    // The chain retired with nothing written back, and the used irq is up.
    try expectEqual(@as(u16, 1), f.usedIdx(TX_USED_GPA));
    try expectEqual(@as(u32, 0), f.usedLen(TX_USED_GPA, 0));
    try expect(f.dev.irqLevel());
    try expectEqual(mmio.INT_USED_RING, f.dev.read(mmio.REG_INTERRUPT_STATUS, 4));
    f.dev.write(mmio.REG_INTERRUPT_ACK, 4, mmio.INT_USED_RING);
    try expect(!f.dev.irqLevel());
}

test "transmit with no sink connected drops, counts, and still retires the chain" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    var frame: [42]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i);
    f.submitTx(&frame, &[_]u32{});
    try expectEqual(@as(u64, 1), f.dev.tx_dropped);
    try expectEqual(@as(u16, 1), f.usedIdx(TX_USED_GPA)); // the queue keeps flowing
}

test "a sink that refuses a frame is a counted drop" {
    var f: Fx = undefined;
    f.init();
    f.connectSink();
    f.accept = false;
    try f.bringUp();
    var frame: [42]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i);
    f.submitTx(&frame, &[_]u32{});
    try expectEqual(@as(u64, 1), f.dev.tx_dropped);
}

test "a malformed transmit chain marks the device needs-reset instead of looping" {
    var f: Fx = undefined;
    f.init();
    f.connectSink();
    try f.bringUp();
    // A descriptor whose buffer runs past guest RAM: the virtq refuses it.
    f.setDesc(TX_DESC_GPA, 0, RAM_LEN - 8, 64, 0, 0);
    f.pushAvail(TX, TX_AVAIL_GPA, 0);
    f.dev.write(mmio.REG_QUEUE_NOTIFY, 4, TX);
    try expect(f.dev.read(mmio.REG_STATUS, 4) & STATUS_NEEDS_RESET != 0);
    try expectEqual(@as(usize, 0), f.sunk_count);
}

test "pushRx lands the frame in guest memory behind an all-zero virtio_net_hdr" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    // A receive buffer split so the first segment ends inside the header, and
    // poisoned so the header zeros must be written, not inherited.
    @memset(f.ram[@intCast(RX_BUF_GPA)..][0 .. NET_HDR + netdev.MAX_FRAME_BYTES], 0xAA);
    f.setDesc(RX_DESC_GPA, 0, RX_BUF_GPA, 7, virtq.F_WRITE | virtq.F_NEXT, 1);
    f.setDesc(RX_DESC_GPA, 1, RX_BUF_GPA + 7, NET_HDR + @as(u32, netdev.MAX_FRAME_BYTES) - 7, virtq.F_WRITE, 0);
    f.pushAvail(RX, RX_AVAIL_GPA, 0);

    var frame: [26]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(0x40 + i);
    try expect(f.dev.pushRx(&frame));

    const delivered = f.ram[@intCast(RX_BUF_GPA)..][0 .. NET_HDR + frame.len];
    try expectEqualSlices(u8, &([_]u8{0} ** NET_HDR), delivered[0..NET_HDR]);
    try expectEqualSlices(u8, &frame, delivered[NET_HDR..]);
    try expectEqual(@as(u16, 1), f.usedIdx(RX_USED_GPA));
    try expectEqual(@as(u32, NET_HDR + frame.len), f.usedLen(RX_USED_GPA, 0));
    try expect(f.dev.irqLevel());
    try expectEqual(@as(u64, 0), f.dev.rx_dropped);
}

test "pushRx with no free buffer counts a drop" {
    var f: Fx = undefined;
    f.init();

    // Before the driver is up the queue is not ready: a drop, not a device
    // failure — the guest simply is not listening yet.
    try expect(!f.dev.pushRx(&[_]u8{ 1, 2, 3 }));
    try expectEqual(@as(u64, 1), f.dev.rx_dropped);
    try expect(f.dev.read(mmio.REG_STATUS, 4) & STATUS_NEEDS_RESET == 0);

    // With the driver up but the avail ring empty, the same: drop and count.
    try f.bringUp();
    try expect(!f.dev.pushRx(&[_]u8{ 1, 2, 3 }));
    try expectEqual(@as(u64, 2), f.dev.rx_dropped);
    try expect(!f.dev.irqLevel()); // nothing landed, nothing to signal
    try expectEqual(@as(u16, 0), f.usedIdx(RX_USED_GPA));
}

test "pushRx into a too-small buffer retires the chain empty and counts the loss" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    f.setDesc(RX_DESC_GPA, 0, RX_BUF_GPA, 8, virtq.F_WRITE, 0); // shorter than the header alone
    f.pushAvail(RX, RX_AVAIL_GPA, 0);
    var frame: [26]u8 = undefined;
    for (&frame, 0..) |*b, i| b.* = @intCast(i);
    try expect(!f.dev.pushRx(&frame));
    try expectEqual(@as(u64, 1), f.dev.rx_dropped);
    // The buffer is consumed with a used length of 0: the driver learns it
    // holds nothing, and the ring cannot wedge on it.
    try expectEqual(@as(u16, 1), f.usedIdx(RX_USED_GPA));
    try expectEqual(@as(u32, 0), f.usedLen(RX_USED_GPA, 0));
}

test "an oversized inbound frame never touches the queue" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    f.setDesc(RX_DESC_GPA, 0, RX_BUF_GPA, NET_HDR + @as(u32, netdev.MAX_FRAME_BYTES), virtq.F_WRITE, 0);
    f.pushAvail(RX, RX_AVAIL_GPA, 0);
    const jumbo = [_]u8{0x55} ** (netdev.MAX_FRAME_BYTES + 1);
    try expect(!f.dev.pushRx(&jumbo));
    try expectEqual(@as(u64, 1), f.dev.rx_dropped);
    try expectEqual(@as(u16, 0), f.usedIdx(RX_USED_GPA)); // the buffer is still posted
}

test "guestMac is locally administered, unicast, and distinct per guest (VIRT-027)" {
    const m0 = netdev.guestMac(0);
    const m1 = netdev.guestMac(1);
    try expect(m0[0] & 0x02 != 0); // locally administered
    try expect(m0[0] & 0x01 == 0); // unicast
    try expect(!std.mem.eql(u8, &m0, &m1));
    try expectEqualSlices(u8, m0[0..5], m1[0..5]); // same prefix, distinct tail
}

test "guestIdFor inverts guestMac exactly, and only for guest addresses (VIRT-029)" {
    // Every address guestMac hands out maps back to its slot…
    var id: usize = 0;
    while (id < ivirt.MAX_VMS) : (id += 1) {
        const mac = netdev.guestMac(id);
        try expectEqual(@as(?ivirt.Id, id), netdev.guestIdFor(&mac));
    }
    // …and nothing else maps at all: a slot past the table, a foreign OUI with
    // the same last byte, broadcast, and one flipped prefix byte.
    const past = [6]u8{ 'R', 'S', 'V', 'D', 'K', ivirt.MAX_VMS };
    try expectEqual(@as(?ivirt.Id, null), netdev.guestIdFor(&past));
    const foreign = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0 };
    try expectEqual(@as(?ivirt.Id, null), netdev.guestIdFor(&foreign));
    const broadcast = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    try expectEqual(@as(?ivirt.Id, null), netdev.guestIdFor(&broadcast));
    var near = netdev.guestMac(0);
    near[0] ^= 0x02;
    try expectEqual(@as(?ivirt.Id, null), netdev.guestIdFor(&near));
}
