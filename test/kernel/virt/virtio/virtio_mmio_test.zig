//! Host tests of src/kernel/virt/virtio/mmio.zig — the version-2 virtio-mmio
//! register machine: probe constants, feature banks, queue programming into the
//! virtq, notify/interrupt plumbing, and the Status=0 full reset.

const std = @import("std");
const mmio = @import("virtio_mmio");
const virtq = mmio.virtq;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;

// Register offsets a driver uses, spelled here independently of the module so a
// transposed offset in the implementation cannot self-verify.
const MAGIC: u64 = 0x000;
const VERSION: u64 = 0x004;
const DEVICE_ID: u64 = 0x008;
const VENDOR_ID: u64 = 0x00c;
const DEVICE_FEATURES: u64 = 0x010;
const DEVICE_FEATURES_SEL: u64 = 0x014;
const DRIVER_FEATURES: u64 = 0x020;
const DRIVER_FEATURES_SEL: u64 = 0x024;
const QUEUE_SEL: u64 = 0x030;
const QUEUE_NUM_MAX: u64 = 0x034;
const QUEUE_NUM: u64 = 0x038;
const QUEUE_READY: u64 = 0x044;
const QUEUE_NOTIFY: u64 = 0x050;
const INT_STATUS: u64 = 0x060;
const INT_ACK: u64 = 0x064;
const STATUS: u64 = 0x070;
const QUEUE_DESC_LOW: u64 = 0x080;
const QUEUE_DESC_HIGH: u64 = 0x084;
const QUEUE_DRIVER_LOW: u64 = 0x090;
const QUEUE_DRIVER_HIGH: u64 = 0x094;
const QUEUE_DEVICE_LOW: u64 = 0x0a0;
const QUEUE_DEVICE_HIGH: u64 = 0x0a4;
const SHM_SEL: u64 = 0x0ac;
const SHM_LEN_LOW: u64 = 0x0b0;
const SHM_LEN_HIGH: u64 = 0x0b4;
const CONFIG_GENERATION: u64 = 0x0fc;
const CONFIG: u64 = 0x100;

/// Records every callback the transport fires, standing in for the device model
/// and the machine model's interrupt line.
const Probe = struct {
    notified: [8]u16 = undefined,
    notify_count: usize = 0,
    resets: usize = 0,
    irq_levels: [8]bool = undefined,
    irq_count: usize = 0,
    config_write_offs: [8]u64 = undefined,
    config_write_count: usize = 0,

    fn notify(ctx: *anyopaque, queue: u16) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.notified[self.notify_count] = queue;
        self.notify_count += 1;
    }

    fn onReset(ctx: *anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.resets += 1;
    }

    fn irq(ctx: *anyopaque, level: bool) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.irq_levels[self.irq_count] = level;
        self.irq_count += 1;
    }

    fn configWritten(ctx: *anyopaque, off: u64) void {
        const self: *Probe = @ptrCast(@alignCast(ctx));
        self.config_write_offs[self.config_write_count] = off;
        self.config_write_count += 1;
    }
};

const GPU_DEVICE_ID: u32 = 16;
const TEST_FEATURES: u64 = 0x5; // arbitrary device bits in bank 0

const Fixture = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    config: [8]u8 = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 },
    probe: Probe = .{},

    fn device(self: *Fixture) mmio.Mmio {
        return mmio.Mmio.init(.{
            .device_id = GPU_DEVICE_ID,
            .device_features = TEST_FEATURES,
            .config = &self.config,
            .ctx = &self.probe,
            .notify = Probe.notify,
            .onReset = Probe.onReset,
        }, &self.ram, Probe.irq);
    }

    /// Same device, but with the config-write hook attached (the virtio-input
    /// select/subsel pattern).
    fn deviceWithHook(self: *Fixture) mmio.Mmio {
        var m = self.device();
        m.backend.configWritten = Probe.configWritten;
        return m;
    }
};

test "probe constants: magic, version 2, device id, vendor id" {
    var f = Fixture{};
    var m = f.device();
    try expectEqual(@as(u32, 0x74726976), m.read(MAGIC, 4)); // "virt"
    try expectEqual(@as(u32, 2), m.read(VERSION, 4));
    try expectEqual(GPU_DEVICE_ID, m.read(DEVICE_ID, 4));
    try expectEqual(@as(u32, 0x4b445653), m.read(VENDOR_ID, 4)); // "SVDK"
}

test "feature banks: bank 0 shows device bits, bank 1 shows VERSION_1 (bit 32)" {
    var f = Fixture{};
    var m = f.device();
    m.write(DEVICE_FEATURES_SEL, 4, 0);
    try expectEqual(@as(u32, 0x5), m.read(DEVICE_FEATURES, 4));
    m.write(DEVICE_FEATURES_SEL, 4, 1);
    try expectEqual(@as(u32, 1), m.read(DEVICE_FEATURES, 4)); // VIRTIO_F_VERSION_1
    m.write(DEVICE_FEATURES_SEL, 4, 2);
    try expectEqual(@as(u32, 0), m.read(DEVICE_FEATURES, 4));
}

test "driver features: both banks assemble into one u64" {
    var f = Fixture{};
    var m = f.device();
    m.write(DRIVER_FEATURES_SEL, 4, 0);
    m.write(DRIVER_FEATURES, 4, 0x5);
    m.write(DRIVER_FEATURES_SEL, 4, 1);
    m.write(DRIVER_FEATURES, 4, 0x1);
    try expectEqual(@as(u64, 0x1_0000_0005), m.driver_features);
}

test "queue programming lands in the selected Virtq" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_SEL, 4, 1);
    try expectEqual(@as(u32, 256), m.read(QUEUE_NUM_MAX, 4));
    m.write(QUEUE_NUM, 4, 128);
    m.write(QUEUE_DESC_LOW, 4, 0x0000_1000);
    m.write(QUEUE_DESC_HIGH, 4, 0x1);
    m.write(QUEUE_DRIVER_LOW, 4, 0x0000_2000);
    m.write(QUEUE_DRIVER_HIGH, 4, 0x0);
    m.write(QUEUE_DEVICE_LOW, 4, 0x0000_3000);
    m.write(QUEUE_DEVICE_HIGH, 4, 0x0);
    try expectEqual(@as(u32, 0), m.read(QUEUE_READY, 4));
    m.write(QUEUE_READY, 4, 1);
    const q = &m.queues[1];
    try expectEqual(@as(u16, 128), q.size);
    try expectEqual(@as(u64, 0x1_0000_1000), q.desc_gpa);
    try expectEqual(@as(u64, 0x2000), q.avail_gpa);
    try expectEqual(@as(u64, 0x3000), q.used_gpa);
    try expect(q.ready);
    try expectEqual(@as(u32, 1), m.read(QUEUE_READY, 4));
    // Queue 0 was never touched.
    try expect(!m.queues[0].ready);
    try expectEqual(@as(u64, 0), m.queues[0].desc_gpa);
}

test "a programmed queue accepts a virtq round-trip through guest RAM" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_SEL, 4, 0);
    m.write(QUEUE_NUM, 4, 8);
    m.write(QUEUE_DESC_LOW, 4, 0x1000);
    m.write(QUEUE_DRIVER_LOW, 4, 0x2000);
    m.write(QUEUE_DEVICE_LOW, 4, 0x3000);
    m.write(QUEUE_READY, 4, 1);
    // Driver publishes avail entry 0 -> head 2.
    std.mem.writeInt(u16, f.ram[0x2004..][0..2], 2, .little);
    std.mem.writeInt(u16, f.ram[0x2002..][0..2], 1, .little);
    try expectEqual(@as(?u16, 2), try m.queues[0].popAvail());
}

test "QueueNumMax reads 0 for a queue the device does not have" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_SEL, 4, mmio.MAX_QUEUES);
    try expectEqual(@as(u32, 0), m.read(QUEUE_NUM_MAX, 4));
}

test "QueueNum is clamped to QueueNumMax" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_SEL, 4, 0);
    m.write(QUEUE_NUM, 4, 1024);
    m.write(QUEUE_READY, 4, 1);
    try expectEqual(@as(u16, 256), m.queues[0].size);
}

test "QueueNotify hands the queue index to the backend" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_NOTIFY, 4, 1);
    m.write(QUEUE_NOTIFY, 4, 0);
    try expectEqual(@as(usize, 2), f.probe.notify_count);
    try expectEqual(@as(u16, 1), f.probe.notified[0]);
    try expectEqual(@as(u16, 0), f.probe.notified[1]);
}

test "QueueNotify for an absent queue is dropped" {
    var f = Fixture{};
    var m = f.device();
    m.write(QUEUE_NOTIFY, 4, mmio.MAX_QUEUES);
    try expectEqual(@as(usize, 0), f.probe.notify_count);
}

test "used-ring interrupt: raise latches bit 0, ACK clears and drops the line" {
    var f = Fixture{};
    var m = f.device();
    m.raiseUsedIrq();
    try expectEqual(@as(u32, 1), m.read(INT_STATUS, 4));
    try expectEqual(@as(usize, 1), f.probe.irq_count);
    try expect(f.probe.irq_levels[0]);
    m.write(INT_ACK, 4, 1);
    try expectEqual(@as(u32, 0), m.read(INT_STATUS, 4));
    try expectEqual(@as(usize, 2), f.probe.irq_count);
    try expect(!f.probe.irq_levels[1]);
}

test "config interrupt: bit 1, and ACKing only it keeps the line up" {
    var f = Fixture{};
    var m = f.device();
    m.raiseUsedIrq();
    m.raiseCfgIrq();
    try expectEqual(@as(u32, 3), m.read(INT_STATUS, 4));
    const irqs_before = f.probe.irq_count;
    m.write(INT_ACK, 4, 2); // config acked, used-ring still pending
    try expectEqual(@as(u32, 1), m.read(INT_STATUS, 4));
    try expectEqual(irqs_before, f.probe.irq_count); // no irq(false) yet
    m.write(INT_ACK, 4, 1);
    try expect(!f.probe.irq_levels[f.probe.irq_count - 1]);
}

test "raiseCfgIrq bumps ConfigGeneration" {
    var f = Fixture{};
    var m = f.device();
    const gen = m.read(CONFIG_GENERATION, 4);
    m.raiseCfgIrq();
    try expectEqual(gen + 1, m.read(CONFIG_GENERATION, 4));
}

test "Status round-trips; writing 0 resets everything and tells the backend" {
    var f = Fixture{};
    var m = f.device();
    m.write(STATUS, 4, 0xF);
    try expectEqual(@as(u32, 0xF), m.read(STATUS, 4));
    m.write(DRIVER_FEATURES_SEL, 4, 1);
    m.write(DRIVER_FEATURES, 4, 1);
    m.write(QUEUE_SEL, 4, 0);
    m.write(QUEUE_NUM, 4, 8);
    m.write(QUEUE_DESC_LOW, 4, 0x1000);
    m.write(QUEUE_READY, 4, 1);
    m.raiseUsedIrq();

    m.write(STATUS, 4, 0);
    try expectEqual(@as(u32, 0), m.read(STATUS, 4));
    try expectEqual(@as(usize, 1), f.probe.resets);
    try expect(!m.queues[0].ready);
    try expectEqual(@as(u16, 0), m.queues[0].size);
    try expectEqual(@as(u64, 0), m.queues[0].desc_gpa);
    try expectEqual(@as(u64, 0), m.driver_features);
    try expectEqual(@as(u32, 0), m.read(INT_STATUS, 4));
    try expect(!f.probe.irq_levels[f.probe.irq_count - 1]); // line dropped
}

test "config space reads little-endian u32s at 0x100+, 0 past the end" {
    var f = Fixture{};
    var m = f.device();
    try expectEqual(@as(u32, 0x44332211), m.read(CONFIG, 4));
    try expectEqual(@as(u32, 0x88776655), m.read(CONFIG + 4, 4));
    try expectEqual(@as(u32, 0x0000_8877), m.read(CONFIG + 6, 4)); // straddles the end
    try expectEqual(@as(u32, 0), m.read(CONFIG + 8, 4));
}

test "config space writes land in the backend's bytes, clipped at the end" {
    var f = Fixture{};
    var m = f.device();
    m.write(CONFIG + 4, 4, 0xAABBCCDD);
    try expectEqual(@as(u8, 0xDD), f.config[4]);
    try expectEqual(@as(u8, 0xAA), f.config[7]);
    m.write(CONFIG + 6, 4, 0x1122_3344); // top half would spill past the end
    try expectEqual(@as(u8, 0x44), f.config[6]);
    try expectEqual(@as(u8, 0x33), f.config[7]);
}

test "unmapped registers read 0 and ignore writes" {
    var f = Fixture{};
    var m = f.device();
    try expectEqual(@as(u32, 0), m.read(0x0c8, 4));
    m.write(0x0c8, 4, 0xDEAD_BEEF); // must not disturb anything
    try expectEqual(@as(u32, 0x74726976), m.read(MAGIC, 4));
}

// A transport that answers 0 here tells the driver a shared-memory region
// EXISTS, at address zero with zero length. Linux's virtio-gpu is the driver
// that asks: it reserves what it was told about, the reservation fails, and the
// probe aborts — so the guest gets no DRM device and no scanout, while every
// device whose driver never asks binds normally and hides the fault.
test "a shared-memory region that does not exist reads back as all ones" {
    var f = Fixture{};
    var m = f.device();
    for ([_]u32{ 0, 1, 7 }) |region| {
        m.write(SHM_SEL, 4, region);
        try expectEqual(@as(u32, 0xffff_ffff), m.read(SHM_LEN_LOW, 4));
        try expectEqual(@as(u32, 0xffff_ffff), m.read(SHM_LEN_HIGH, 4));
    }
}

test "config space honors byte and word access widths" {
    var f = Fixture{};
    var m = f.device();
    try expectEqual(@as(u32, 0x11), m.read(CONFIG, 1));
    try expectEqual(@as(u32, 0x3322), m.read(CONFIG + 1, 2));
    try expectEqual(@as(u32, 0x88), m.read(CONFIG + 7, 1));
}

test "a byte config write leaves its neighbors untouched" {
    var f = Fixture{};
    var m = f.device();
    m.write(CONFIG + 2, 1, 0xFF);
    try expectEqual(@as(u8, 0x22), f.config[1]);
    try expectEqual(@as(u8, 0xFF), f.config[2]);
    try expectEqual(@as(u8, 0x44), f.config[3]);
}

test "registers refuse sub-word access: reads 0, writes dropped" {
    var f = Fixture{};
    var m = f.device();
    try expectEqual(@as(u32, 0), m.read(MAGIC, 1));
    try expectEqual(@as(u32, 0), m.read(MAGIC, 2));
    m.write(STATUS, 2, 0xF); // must not negotiate
    try expectEqual(@as(u32, 0), m.read(STATUS, 4));
}

test "configWritten hook fires per landed write with the config offset" {
    var f = Fixture{};
    var m = f.deviceWithHook();
    m.write(CONFIG, 1, 0x01); // select
    m.write(CONFIG + 1, 1, 0x02); // subsel
    try expectEqual(@as(usize, 2), f.probe.config_write_count);
    try expectEqual(@as(u64, 0), f.probe.config_write_offs[0]);
    try expectEqual(@as(u64, 1), f.probe.config_write_offs[1]);
    m.write(CONFIG + 32, 1, 0x03); // past the end: dropped, no hook
    try expectEqual(@as(usize, 2), f.probe.config_write_count);
}
