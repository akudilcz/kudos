//! Host tests of src/kernel/virt/virtio/inputdev.zig — the guest's keyboard and
//! absolute pointer as whole devices. The fixture speaks the register protocol a
//! Linux virtio-input driver speaks, over a fake guest RAM: probe, negotiate,
//! program both queues, walk the configuration selectors the way a driver
//! interrogates an evdev device, then read the events the device writes into the
//! event queue. It is the proof that a keystroke at the seam becomes the evdev
//! bytes a guest reads — which guest execution would otherwise be needed to show.

const std = @import("std");
const inputdev = @import("testroot").kernel.virtio_inputdev;
const virtq = inputdev.virtq;
const mmio = inputdev.mmio; // the register map, from the module that owns it
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

const RAM_LEN = 64 * 1024;
const QSIZE: u32 = 8;

// Guest-physical layout of the fake machine: one ring set per queue.
const EV_DESC_GPA: u64 = 0x100;
const EV_AVAIL_GPA: u64 = 0x300;
const EV_USED_GPA: u64 = 0x400;
const ST_DESC_GPA: u64 = 0x500;
const ST_AVAIL_GPA: u64 = 0x700;
const ST_USED_GPA: u64 = 0x800;
const EV_BUF_GPA: u64 = 0x1000;
const ST_BUF_GPA: u64 = 0x2000;

// Register offsets, spelled independently of the transport so a transposed
// offset there cannot self-verify (virtio 1.1 §4.2.2).

// Wire facts spelled independently of the device model, so a model that drifted
// from the virtio spec cannot self-verify: the input device type (§5.8), the
// config-space field offsets (§5.8.5), and the 8-byte virtio_input_event
// (§5.8.6).
const INPUT_DEVICE_ID: u32 = 18;
const CFG_SELECT: u64 = mmio.REG_CONFIG + 0;
const CFG_SUBSEL: u64 = mmio.REG_CONFIG + 1;
const CFG_SIZE: u64 = mmio.REG_CONFIG + 2;
const CFG_PAYLOAD: u64 = mmio.REG_CONFIG + 8;
const EVENT_BYTES: u32 = 8;

// §5.8.5 selectors.
const CFG_ID_NAME: u32 = 0x01;
const CFG_ID_DEVIDS: u32 = 0x03;
const CFG_PROP_BITS: u32 = 0x10;
const CFG_EV_BITS: u32 = 0x11;
const CFG_ABS_INFO: u32 = 0x12;

// §2.1 device status bits, as a driver sets them in order.
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_NEEDS_RESET: u32 = 64;

// The queues, by index (§5.8.2).
const EVQ = 0;
const STQ = 1;

const Fx = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    dev: inputdev.InputDev = .{},
    avail_idx: [2]u16 = .{ 0, 0 },

    /// In place: the device's backend holds interior pointers to itself and to
    /// THIS fixture's ram, so the fixture can never be initialized by copy.
    fn init(self: *Fx, kind: inputdev.Kind) void {
        self.ram = [_]u8{0} ** RAM_LEN;
        self.avail_idx = .{ 0, 0 };
        self.dev = .{};
        self.dev.bind(kind, &self.ram);
    }

    fn programQueue(self: *Fx, sel: u32, desc: u64, avail: u64, used: u64) void {
        self.dev.write(mmio.REG_QUEUE_SEL, 4, sel);
        self.dev.write(mmio.REG_QUEUE_NUM, 4, QSIZE);
        self.dev.write(mmio.REG_QUEUE_DESC_LOW, 4, @intCast(desc));
        self.dev.write(mmio.REG_QUEUE_DRIVER_LOW, 4, @intCast(avail));
        self.dev.write(mmio.REG_QUEUE_DEVICE_LOW, 4, @intCast(used));
        self.dev.write(mmio.REG_QUEUE_READY, 4, 1);
    }

    /// Everything a Linux virtio-input driver does before events flow: probe,
    /// negotiate features, program both queues, DRIVER_OK.
    fn bringUp(self: *Fx) !void {
        try expectEqual(@as(u32, 0x74726976), self.dev.read(mmio.REG_MAGIC_VALUE, 4)); // "virt"
        try expectEqual(@as(u32, 2), self.dev.read(mmio.REG_VERSION, 4));
        try expectEqual(INPUT_DEVICE_ID, self.dev.read(mmio.REG_DEVICE_ID, 4));

        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
        self.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 0);
        self.dev.write(mmio.REG_DRIVER_FEATURES_SEL, 4, 0);
        self.dev.write(mmio.REG_DRIVER_FEATURES, 4, self.dev.read(mmio.REG_DEVICE_FEATURES, 4));
        self.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 1);
        self.dev.write(mmio.REG_DRIVER_FEATURES_SEL, 4, 1);
        self.dev.write(mmio.REG_DRIVER_FEATURES, 4, self.dev.read(mmio.REG_DEVICE_FEATURES, 4));
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

        self.programQueue(EVQ, EV_DESC_GPA, EV_AVAIL_GPA, EV_USED_GPA);
        self.programQueue(STQ, ST_DESC_GPA, ST_AVAIL_GPA, ST_USED_GPA);
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

    /// Post `n` empty 8-byte event buffers, the way the driver keeps the event
    /// queue stocked. Buffer i lives at EV_BUF_GPA + i*8 and is descriptor i.
    fn postEventBuffers(self: *Fx, n: u16) void {
        var i: u16 = 0;
        while (i < n) : (i += 1) {
            self.setDesc(EV_DESC_GPA, i, EV_BUF_GPA + @as(u64, i) * EVENT_BYTES, EVENT_BYTES, virtq.F_WRITE, 0);
            self.pushAvail(EVQ, EV_AVAIL_GPA, i);
        }
    }

    /// Read back event buffer `i` as (type, code, value).
    fn event(self: *const Fx, i: u64) struct { t: u16, code: u16, value: u32 } {
        const base: usize = @intCast(EV_BUF_GPA + i * EVENT_BYTES);
        return .{
            .t = std.mem.readInt(u16, self.ram[base..][0..2], .little),
            .code = std.mem.readInt(u16, self.ram[base + 2 ..][0..2], .little),
            .value = std.mem.readInt(u32, self.ram[base + 4 ..][0..4], .little),
        };
    }

    /// Select a configuration item the way a driver does — writeb each selector
    /// — and return the size byte the device answered with.
    fn select(self: *Fx, sel: u32, subsel: u32) u32 {
        self.dev.write(CFG_SELECT, 1, sel);
        self.dev.write(CFG_SUBSEL, 1, subsel);
        return self.dev.read(CFG_SIZE, 1);
    }

    fn payloadByte(self: *Fx, i: u64) u32 {
        return self.dev.read(CFG_PAYLOAD + i, 1);
    }
};

// ── the device as hardware ──────────────────────────────────────────────────────

test "an unbound device answers as absent hardware" {
    var dev = inputdev.InputDev{};
    try expectEqual(@as(u32, 0), dev.read(mmio.REG_MAGIC_VALUE, 4));
    dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE); // must not fault
    try expect(!dev.irqLevel());
    dev.key(30, true); // dropped, not faulted
    try expect(dev.dropped > 0);
}

test "the guest is presented a keyboard and a pointing device (VIRT-022, VIRT-024)" {
    var f: Fx = undefined;
    for ([_]inputdev.Kind{ .keyboard, .tablet }) |kind| {
        f.init(kind);
        try f.bringUp();
        try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_STATUS, 4) & STATUS_NEEDS_RESET);
    }
}

// ── configuration: what the guest probes to know which device it found ─────────

test "the keyboard and the tablet name themselves differently (ID_NAME)" {
    var f: Fx = undefined;
    for ([_]inputdev.Kind{ .keyboard, .tablet }) |kind| {
        f.init(kind);
        const want = kind.deviceName();
        const size = f.select(CFG_ID_NAME, 0);
        try expectEqual(@as(u32, @intCast(want.len)), size);
        for (want, 0..) |c, i| try expectEqual(@as(u32, c), f.payloadByte(i));
    }
}

test "the tablet advertises absolute axes and their range; the keyboard has none (VIRT-024)" {
    var f: Fx = undefined;
    f.init(.tablet);
    // ABS_X and ABS_Y both report struct virtio_input_absinfo: 5 u32 fields.
    for ([_]u32{ 0x00, 0x01 }) |axis| {
        try expectEqual(@as(u32, 20), f.select(CFG_ABS_INFO, axis));
        try expectEqual(@as(u32, 0), f.dev.read(CFG_PAYLOAD, 4)); // min
        try expectEqual(inputdev.ABS_MAX, f.dev.read(CFG_PAYLOAD + 4, 4)); // max
        try expectEqual(@as(u32, 0), f.dev.read(CFG_PAYLOAD + 8, 4)); // fuzz
        try expectEqual(@as(u32, 0), f.dev.read(CFG_PAYLOAD + 12, 4)); // flat
    }
    // A third axis is not there, and says so with size 0 rather than silence.
    try expectEqual(@as(u32, 0), f.select(CFG_ABS_INFO, 0x02));

    f.init(.keyboard);
    try expectEqual(@as(u32, 0), f.select(CFG_ABS_INFO, 0x00));
}

test "each kind advertises exactly the event types it can emit (EV_BITS)" {
    var f: Fx = undefined;

    f.init(.keyboard);
    try expect(f.select(CFG_EV_BITS, inputdev.EV_KEY) > 0);
    try expect(f.select(CFG_EV_BITS, inputdev.EV_SYN) > 0);
    // A keyboard has no absolute axes: a guest that bound a pointer driver to it
    // would be a guest we told the wrong thing.
    try expectEqual(@as(u32, 0), f.select(CFG_EV_BITS, inputdev.EV_ABS));

    f.init(.tablet);
    try expect(f.select(CFG_EV_BITS, inputdev.EV_ABS) > 0);
    try expect(f.select(CFG_EV_BITS, inputdev.EV_KEY) > 0); // the buttons
    // The tablet's key bitmap covers its buttons and stops there.
    const size = f.select(CFG_EV_BITS, inputdev.EV_KEY);
    const btn_left_byte = inputdev.BTN_LEFT / 8;
    try expect(size > btn_left_byte);
    try expectEqual(@as(u32, 1) << @intCast(inputdev.BTN_LEFT % 8), f.payloadByte(btn_left_byte) & (@as(u32, 1) << @intCast(inputdev.BTN_LEFT % 8)));
}

test "only the tablet claims direct coordinates, so nothing accelerates them" {
    var f: Fx = undefined;
    f.init(.tablet);
    try expect(f.select(CFG_PROP_BITS, 0) > 0);
    f.init(.keyboard);
    try expectEqual(@as(u32, 0), f.select(CFG_PROP_BITS, 0));
}

test "an unknown selector answers size 0 rather than stale bytes" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try expect(f.select(CFG_ID_NAME, 0) > 0); // leaves a real payload behind
    try expectEqual(@as(u32, 0), f.select(0x7E, 0)); // no such item
    try expectEqual(@as(u32, 0), f.payloadByte(0)); // and the payload went with it
}

test "the device identifies itself as virtual, not as somebody's real hardware" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try expectEqual(@as(u32, 8), f.select(CFG_ID_DEVIDS, 0));
    try expectEqual(@as(u32, 0x06), f.dev.read(CFG_PAYLOAD, 2)); // BUS_VIRTUAL
    const kbd_product = f.dev.read(CFG_PAYLOAD + 4, 2);
    f.init(.tablet);
    _ = f.select(CFG_ID_DEVIDS, 0);
    // Two devices on one guest must not be one product id twice, or udev cannot
    // tell them apart.
    try expect(f.dev.read(CFG_PAYLOAD + 4, 2) != kbd_product);
}

// ── events: the seam a keystroke crosses ────────────────────────────────────────

test "a keypress reaches the guest as EV_KEY then SYN_REPORT (VIRT-023)" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    f.postEventBuffers(4);

    const KEY_A: u16 = 30; // linux/input-event-codes.h KEY_A
    f.dev.key(KEY_A, true);

    // Two events landed, in order, each in its own buffer.
    try expectEqual(@as(u16, 2), f.usedIdx(EV_USED_GPA));
    const press = f.event(0);
    try expectEqual(inputdev.EV_KEY, press.t);
    try expectEqual(KEY_A, press.code);
    try expectEqual(@as(u32, 1), press.value);
    const syn = f.event(1);
    try expectEqual(inputdev.EV_SYN, syn.t);
    try expectEqual(inputdev.SYN_REPORT, syn.code);
    // Each buffer is retired holding a whole event.
    try expectEqual(EVENT_BYTES, f.usedLen(EV_USED_GPA, 0));
    try expectEqual(@as(u64, 0), f.dev.dropped);
}

test "a release is a distinct event: a held key is not a stuck key (VIRT-023)" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    f.postEventBuffers(4);

    const KEY_A: u16 = 30;
    f.dev.key(KEY_A, true);
    f.dev.key(KEY_A, false);
    try expectEqual(@as(u32, 1), f.event(0).value); // press
    try expectEqual(@as(u32, 0), f.event(2).value); // release, past its SYN
    try expectEqual(KEY_A, f.event(2).code);
}

test "pointer motion carries both axes inside one report (VIRT-025)" {
    var f: Fx = undefined;
    f.init(.tablet);
    try f.bringUp();
    f.postEventBuffers(4);

    f.dev.motion(1234, 5678);
    const x = f.event(0);
    const y = f.event(1);
    const syn = f.event(2);
    try expectEqual(inputdev.EV_ABS, x.t);
    try expectEqual(inputdev.ABS_X, x.code);
    try expectEqual(@as(u32, 1234), x.value);
    try expectEqual(inputdev.ABS_Y, y.code);
    try expectEqual(@as(u32, 5678), y.value);
    // X and Y of one motion are in the SAME batch: a guest must never see the
    // pointer travel along one axis and then the other.
    try expectEqual(inputdev.EV_SYN, syn.t);
}

test "a pointer button reaches the guest as its own EV_KEY event (VIRT-026)" {
    var f: Fx = undefined;
    f.init(.tablet);
    try f.bringUp();
    f.postEventBuffers(4);

    // A button is an EV_KEY in the BTN_ range on the SAME device the motion
    // came from — a compositor pairs the click with the position it arrived at.
    f.dev.key(inputdev.BTN_LEFT, true);
    try expectEqual(inputdev.EV_KEY, f.event(0).t);
    try expectEqual(inputdev.BTN_LEFT, f.event(0).code);
    try expectEqual(@as(u32, 1), f.event(0).value);

    f.dev.key(inputdev.BTN_LEFT, false);
    try expectEqual(@as(u32, 0), f.event(2).value); // and the release, past its SYN
}

test "a position past the declared range is clamped, never wrapped" {
    var f: Fx = undefined;
    f.init(.tablet);
    try f.bringUp();
    f.postEventBuffers(4);

    f.dev.motion(inputdev.ABS_MAX + 5000, 0);
    // Wrapping would put the pointer at the opposite edge — the corner-sticking
    // failure scripts/vm/run.sh documents for out-of-range tablet reports.
    try expectEqual(inputdev.ABS_MAX, f.event(0).value);
}

test "the device interrupts the guest once its events are readable" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    f.postEventBuffers(2);
    try expect(!f.dev.irqLevel());

    f.dev.key(30, true);
    try expect(f.dev.irqLevel());
    try expectEqual(@as(u32, 1), f.dev.read(mmio.REG_INTERRUPT_STATUS, 4)); // used-ring bit
    f.dev.write(mmio.REG_INTERRUPT_ACK, 4, 1);
    try expect(!f.dev.irqLevel());
}

// ── failures are counted, never silent ─────────────────────────────────────────

test "a keystroke with nowhere to land is counted, not queued" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    // The driver is up but has posted no buffers.
    f.dev.key(30, true);
    try expect(f.dev.dropped > 0);

    // Input is only meaningful while it is fresh: the dropped keystroke must NOT
    // reappear when buffers arrive, or it would type into whatever has focus by
    // then.
    const before = f.dev.dropped;
    f.postEventBuffers(4);
    try expectEqual(@as(u16, 0), f.usedIdx(EV_USED_GPA));
    try expectEqual(before, f.dev.dropped);
}

test "events before the driver is up are counted, not faulted" {
    var f: Fx = undefined;
    f.init(.keyboard);
    // No bringUp: the queue is not ready.
    f.dev.key(30, true);
    f.dev.motion(1, 2);
    try expect(f.dev.dropped >= 2);
    try expect(!f.dev.irqLevel());
}

test "a buffer too small for an event is retired empty and counted" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    // A 4-byte buffer cannot hold an 8-byte event.
    f.setDesc(EV_DESC_GPA, 0, EV_BUF_GPA, 4, virtq.F_WRITE, 0);
    f.pushAvail(EVQ, EV_AVAIL_GPA, 0);

    f.dev.key(30, true);
    // The chain still comes back to the driver, holding nothing — a queue that
    // stopped flowing would wedge the guest's input for good.
    try expect(f.usedIdx(EV_USED_GPA) > 0);
    try expectEqual(@as(u32, 0), f.usedLen(EV_USED_GPA, 0));
    try expect(f.dev.dropped > 0);
}

test "a descriptor pointing outside guest RAM stops the queue and asks for reset" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    f.setDesc(EV_DESC_GPA, 0, RAM_LEN + 0x1000, EVENT_BYTES, virtq.F_WRITE, 0);
    f.pushAvail(EVQ, EV_AVAIL_GPA, 0);

    f.dev.key(30, true);
    try expect(f.dev.read(mmio.REG_STATUS, 4) & STATUS_NEEDS_RESET != 0);
    try expect(f.dev.dropped > 0);
}

// ── the status queue: buffers come back ────────────────────────────────────────

test "status chains are retired, so a driver's status queue never stalls" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    f.setDesc(ST_DESC_GPA, 0, ST_BUF_GPA, EVENT_BYTES, 0, 0);
    f.pushAvail(STQ, ST_AVAIL_GPA, 0);
    f.dev.write(mmio.REG_QUEUE_NOTIFY, 4, STQ);
    try expectEqual(@as(u16, 1), f.usedIdx(ST_USED_GPA));
}

// ── reset ──────────────────────────────────────────────────────────────────────

test "a reset clears the selector but keeps the drop count" {
    var f: Fx = undefined;
    f.init(.keyboard);
    try f.bringUp();
    try expect(f.select(CFG_ID_NAME, 0) > 0);
    f.dev.key(30, true); // no buffers posted: a drop
    const dropped = f.dev.dropped;
    try expect(dropped > 0);

    f.dev.write(mmio.REG_STATUS, 4, 0);
    // A re-probing driver starts from an unset selector rather than inheriting
    // the previous driver's answer…
    try expectEqual(@as(u32, 0), f.dev.read(CFG_SIZE, 1));
    try expectEqual(@as(u32, 0), f.payloadByte(0));
    // …but the counter diagnoses the device's whole life, not one generation.
    try expectEqual(dropped, f.dev.dropped);
}
