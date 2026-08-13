//! The guest's keyboard and pointer as virtio-input devices (virtio 1.1 §5.8),
//! one device model behind the version-2 transport (virtio/mmio.zig). Pure and
//! host-tested (test/kernel/virt/virtio/virtio_inputdev_test.zig) — a scripted
//! driver conversation drives the whole path from a register probe to evdev
//! events landing in the guest's event queue.
//!
//! One model, two kinds. A keyboard and an absolute pointer differ only in what
//! their configuration space advertises — the event codes they can emit, and
//! (for the pointer) the axis ranges. The queues, the transport, and the event
//! wire format are identical, so splitting them into two files would be two
//! copies of one device with a different constant table.
//!
//! The pointer is ABSOLUTE (ABS_X/ABS_Y), never relative. A VM window shows the
//! guest's scanout at a known size, so the host pointer's position inside that
//! window IS the guest's pointer position: no grab, no acceleration, no drift
//! between two cursors. This is the same reasoning scripts/vm/run.sh gives for
//! driving kudos itself with a usb-tablet rather than a usb-mouse.
//!
//! Events flow one way through the event queue: the driver posts empty buffers,
//! the device fills one per event. A guest that has posted no buffers cannot be
//! told anything, and the keystroke is counted rather than queued — input is
//! only meaningful while it is fresh, and a burst replayed later would type
//! into whatever has focus by then.

const std = @import("std");
pub const mmio = @import("mmio.zig");
pub const virtq = @import("virtq.zig");
const ivirt = @import("ivirt");

/// Virtio device type 18, "input device" (virtio 1.1 §5.8).
const DEVICE_ID_INPUT: u32 = 18;

/// Queue indices (§5.8.2): eventq carries device→driver events, statusq carries
/// driver→device status (LEDs and the like). No feature bit is offered.
const EVENTQ: u16 = 0;
const STATUSQ: u16 = 1;

/// struct virtio_input_event (§5.8.6): the Linux evdev event, little-endian.
pub const EVENT_BYTES: usize = 8;

// ── evdev wire constants (linux/input-event-codes.h) ────────────────────────────
//
// Spelled here because they are an external interface: the guest kernel matches
// on these numbers, so they are named constants at the boundary that uses them.

/// EV_SYN — the event-batch terminator.
pub const EV_SYN: u16 = 0x00;
/// EV_KEY — a key or button changed state.
pub const EV_KEY: u16 = 0x01;
/// EV_ABS — an absolute axis moved.
pub const EV_ABS: u16 = 0x03;
/// SYN_REPORT — end of one batch of events that happened together.
pub const SYN_REPORT: u16 = 0x00;
/// ABS_X, ABS_Y — the absolute pointer axes.
pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
/// BTN_LEFT / BTN_RIGHT / BTN_MIDDLE — the pointer buttons (§ button range).
pub const BTN_LEFT: u16 = 0x110;
pub const BTN_RIGHT: u16 = 0x111;
pub const BTN_MIDDLE: u16 = 0x112;
/// The largest key code a keyboard advertises. 0x2FF covers the whole KEY_*
/// range a PC keyboard produces, which is what the EV_KEY bitmap must span.
const KEY_CODE_MAX: u16 = 0x2FF;

// ── configuration space (§5.8.5) ────────────────────────────────────────────────

/// virtio_input_config selectors (§5.8.5).
const CFG_UNSET: u8 = 0x00;
const CFG_ID_NAME: u8 = 0x01;
const CFG_ID_DEVIDS: u8 = 0x03;
const CFG_PROP_BITS: u8 = 0x10;
const CFG_EV_BITS: u8 = 0x11;
const CFG_ABS_INFO: u8 = 0x12;

/// The union at the tail of virtio_input_config is 128 bytes (§5.8.5): the
/// longest member is the 128-byte string/bitmap.
const CFG_PAYLOAD_BYTES: usize = 128;
/// Offsets within virtio_input_config: select, subsel, size, 5 reserved bytes,
/// then the union.
const CFG_OFF_SELECT: usize = 0;
const CFG_OFF_SUBSEL: usize = 1;
const CFG_OFF_SIZE: usize = 2;
const CFG_OFF_PAYLOAD: usize = 8;
const CONFIG_SIZE: usize = CFG_OFF_PAYLOAD + CFG_PAYLOAD_BYTES;

/// INPUT_PROP_DIRECT — the pointer's coordinates are on the screen it draws to,
/// not a relative pad. A Wayland compositor reads this to decide whether the
/// device needs pointer acceleration; a direct device must not get any.
const INPUT_PROP_DIRECT: u16 = 0x01;

/// The virtual devices' USB-style identity (§5.8.5 devids). BUS_VIRTUAL says
/// plainly that nothing behind this is physical.
const BUS_VIRTUAL: u16 = 0x06;
const VENDOR_ID: u16 = 0x1AF4; // Red Hat / virtio, as the transport reports
const PRODUCT_KEYBOARD: u16 = 1;
const PRODUCT_TABLET: u16 = 2;
const VERSION_ID: u16 = 1;

/// Which device this instance is. The only thing that differs between the two.
pub const Kind = enum {
    keyboard,
    tablet,

    /// The name the guest shows for this device (§5.8.5 ID_NAME).
    pub fn deviceName(self: Kind) []const u8 {
        return switch (self) {
            .keyboard => "kudos virtio keyboard",
            .tablet => "kudos virtio tablet",
        };
    }

    fn product(self: Kind) u16 {
        return switch (self) {
            .keyboard => PRODUCT_KEYBOARD,
            .tablet => PRODUCT_TABLET,
        };
    }
};

/// The absolute axis range a tablet reports. Owned by the mailbox the positions
/// arrive through (iface/ivirt.zig), because the window scaling into it and the
/// device declaring it must be the same number — a guest's idea of "the pointer
/// is here" is then independent of the window's pixel size.
pub const ABS_MAX: u32 = ivirt.ABS_RANGE;

pub const InputDev = struct {
    kind: Kind = .keyboard,
    transport: mmio.Mmio = undefined,
    config: [CONFIG_SIZE]u8 = [_]u8{0} ** CONFIG_SIZE,
    /// The transport's interrupt line, latched here for the machine model to
    /// mirror onto its PIC at the next interrupt poll.
    irq_level: bool = false,
    bound: bool = false,
    /// Events that reached no guest buffer: the driver not up, no free
    /// descriptor, an unusable ring, or a buffer too small for one event.
    dropped: u64 = 0,

    /// Wire the device up in place. The transport's backend holds interior
    /// pointers (`ctx` to this struct, `config` to its own field), so this must
    /// run on the InputDev's FINAL address — the machine model calls it from
    /// `Vm.start`, never from `Vm.create`, whose result is returned by value and
    /// copied into the VM table. `guest_ram` is the RAM slice the virtqueues
    /// live in.
    pub fn bind(self: *InputDev, kind: Kind, guest_ram: []u8) void {
        self.kind = kind;
        self.irq_level = false;
        self.dropped = 0;
        self.config = [_]u8{0} ** CONFIG_SIZE;
        self.transport = mmio.Mmio.init(.{
            .device_id = DEVICE_ID_INPUT,
            .device_features = 0,
            .config = &self.config,
            .ctx = self,
            .notify = onNotify,
            .onReset = onReset,
            .configWritten = onConfigWritten,
        }, guest_ram, onIrq);
        self.bound = true;
    }

    /// A guest MMIO read of `size` bytes at `off` (address − the device's window
    /// base). Reads before `bind` are all-zero, so a probe of an unwired slot
    /// finds no device rather than a half-built one.
    pub fn read(self: *InputDev, off: u64, size: u8) u32 {
        if (!self.bound) return 0;
        return self.transport.read(off, size);
    }

    pub fn write(self: *InputDev, off: u64, size: u8, val: u32) void {
        if (!self.bound) return;
        self.transport.write(off, size, val);
    }

    /// The device's interrupt line level, for the machine model to reflect onto
    /// its PIC line.
    pub fn irqLevel(self: *const InputDev) bool {
        return self.irq_level;
    }

    /// Post one key or button transition, terminated by SYN_REPORT so the guest
    /// acts on it immediately rather than waiting for the next event.
    pub fn key(self: *InputDev, code: u16, down: bool) void {
        self.post(EV_KEY, code, if (down) 1 else 0);
        self.sync();
    }

    /// Post an absolute pointer position, both axes in one batch: X and Y of one
    /// motion belong to the same SYN_REPORT, or the guest sees the pointer move
    /// along one axis and then the other.
    pub fn motion(self: *InputDev, x: u32, y: u32) void {
        self.post(EV_ABS, ABS_X, @min(x, ABS_MAX));
        self.post(EV_ABS, ABS_Y, @min(y, ABS_MAX));
        self.sync();
    }

    /// Terminate a batch (§5.8.6): everything since the last SYN_REPORT happened
    /// at one instant.
    pub fn sync(self: *InputDev) void {
        self.post(EV_SYN, SYN_REPORT, 0);
    }

    /// Deliver one event into the guest's next free event buffer. Every failure
    /// is a counted drop — to the caller, a driver that is down, an empty ring
    /// and a too-small buffer all read the same way: the guest did not take it.
    fn post(self: *InputDev, ev_type: u16, code: u16, value: u32) void {
        if (!self.bound) {
            self.dropped += 1;
            return;
        }
        const q = &self.transport.queues[EVENTQ];
        const popped = q.popAvail() catch |e| {
            // NotReady is the normal state before the driver brings the queue
            // up; any other error means the ring itself cannot be trusted.
            if (e != virtq.Error.NotReady)
                self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
            self.dropped += 1;
            return;
        };
        const head = popped orelse {
            self.dropped += 1;
            return;
        };
        var buf: [EVENT_BYTES]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], ev_type, .little);
        std.mem.writeInt(u16, buf[2..4], code, .little);
        std.mem.writeInt(u32, buf[4..8], value, .little);
        const written = deliver(q, head, &buf) catch {
            self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
            self.dropped += 1;
            return;
        };
        // Even a too-small chain is retired (written == 0): the driver gets its
        // buffer back holding nothing, and the queue keeps flowing.
        q.pushUsed(head, written);
        self.transport.raiseUsedIrq();
        if (written == 0) self.dropped += 1;
    }

    fn onNotify(ctx: *anyopaque, queue: u16) void {
        const self: *InputDev = @ptrCast(@alignCast(ctx));
        switch (queue) {
            // An event notify only publishes fresh buffers; events are posted by
            // the window that owns this device, so there is nothing to do here.
            EVENTQ => {},
            // Status events (LED state, and nothing else this device has) are
            // consumed and retired: a driver whose status chains were never
            // returned stops sending them and eventually stalls its own queue.
            STATUSQ => {
                const consumed = self.drainStatusQueue() catch {
                    self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
                    return;
                };
                if (consumed) self.transport.raiseUsedIrq();
            },
            else => {},
        }
    }

    /// Retire every available status chain unread. The device has no LEDs to
    /// light: what matters is that the driver gets its buffers back.
    fn drainStatusQueue(self: *InputDev) virtq.Error!bool {
        const q = &self.transport.queues[STATUSQ];
        var consumed = false;
        while (try q.popAvail()) |head| {
            q.pushUsed(head, 0); // device-readable chain: nothing written back
            consumed = true;
        }
        return consumed;
    }

    /// The driver wrote a selector: re-derive the configuration payload it is
    /// asking about (§5.8.5). Writes to the payload itself are ignored — only
    /// the two selectors choose what the device answers.
    fn onConfigWritten(ctx: *anyopaque, off: u64) void {
        const self: *InputDev = @ptrCast(@alignCast(ctx));
        if (off != CFG_OFF_SELECT and off != CFG_OFF_SUBSEL) return;
        fillConfig(self.kind, self.config[CFG_OFF_SELECT], self.config[CFG_OFF_SUBSEL], &self.config);
    }

    fn onReset(ctx: *anyopaque) void {
        const self: *InputDev = @ptrCast(@alignCast(ctx));
        // The selectors are driver state: a re-probing driver starts from an
        // unset selector rather than inheriting the last one's answer. The drop
        // counter survives on purpose — it diagnoses the device's whole life,
        // not one driver generation.
        self.config = [_]u8{0} ** CONFIG_SIZE;
    }

    fn onIrq(ctx: *anyopaque, level: bool) void {
        const self: *InputDev = @ptrCast(@alignCast(ctx));
        self.irq_level = level;
    }
};

/// Answer one (select, subsel) pair into `out` (§5.8.5): the size byte plus the
/// payload the driver asked for, with the selectors left as written. An
/// unsupported pair answers size 0, which is how a driver learns a capability is
/// absent — so every combination has an answer and none is silence.
///
/// Pure, and the whole of what distinguishes a keyboard from a tablet: it is
/// what the guest probes to decide which evdev device it has found.
pub fn fillConfig(kind: Kind, select: u8, subsel: u8, out: *[CONFIG_SIZE]u8) void {
    @memset(out[CFG_OFF_SIZE..], 0);
    out[CFG_OFF_SELECT] = select;
    out[CFG_OFF_SUBSEL] = subsel;
    const payload = out[CFG_OFF_PAYLOAD..];
    var size: usize = 0;
    switch (select) {
        CFG_ID_NAME => {
            const name = kind.deviceName();
            @memcpy(payload[0..name.len], name);
            size = name.len;
        },
        CFG_ID_DEVIDS => {
            std.mem.writeInt(u16, payload[0..2], BUS_VIRTUAL, .little);
            std.mem.writeInt(u16, payload[2..4], VENDOR_ID, .little);
            std.mem.writeInt(u16, payload[4..6], kind.product(), .little);
            std.mem.writeInt(u16, payload[6..8], VERSION_ID, .little);
            size = 8;
        },
        CFG_PROP_BITS => {
            // Only the tablet claims a property: its coordinates are the
            // screen's (INPUT_PROP_DIRECT), so nothing accelerates them.
            if (kind == .tablet) size = setBit(payload, INPUT_PROP_DIRECT);
        },
        CFG_EV_BITS => size = evBits(kind, subsel, payload),
        CFG_ABS_INFO => size = absInfo(kind, subsel, payload),
        // CFG_UNSET and every unknown selector: size 0, payload zero.
        else => {},
    }
    out[CFG_OFF_SIZE] = @intCast(size);
}

/// The codes this kind can emit for event type `subsel`, as a bitmap (§5.8.5
/// EV_BITS). A zero size for a type the device never emits is the answer that
/// keeps a guest from binding, say, a pointer driver to the keyboard.
fn evBits(kind: Kind, subsel: u8, payload: []u8) usize {
    return switch (kind) {
        .keyboard => switch (subsel) {
            // Every key a PC keyboard can produce. The bitmap is dense rather
            // than a list of the codes kudos happens to map today: what the
            // device CAN carry does not change when the host keymap grows.
            EV_KEY => setRange(payload, KEY_CODE_MAX),
            EV_SYN => setBit(payload, SYN_REPORT),
            else => 0,
        },
        .tablet => switch (subsel) {
            EV_KEY => @max(@max(setBit(payload, BTN_LEFT), setBit(payload, BTN_RIGHT)), setBit(payload, BTN_MIDDLE)),
            EV_ABS => @max(setBit(payload, ABS_X), setBit(payload, ABS_Y)),
            EV_SYN => setBit(payload, SYN_REPORT),
            else => 0,
        },
    };
}

/// struct virtio_input_absinfo (§5.8.5) for absolute axis `subsel`: the range
/// the axis reports over. Fuzz and flat are zero — a synthetic pointer has no
/// noise to filter and no dead zone.
fn absInfo(kind: Kind, subsel: u8, payload: []u8) usize {
    if (kind != .tablet or (subsel != ABS_X and subsel != ABS_Y)) return 0;
    std.mem.writeInt(u32, payload[0..4], 0, .little); // min
    std.mem.writeInt(u32, payload[4..8], ABS_MAX, .little); // max
    std.mem.writeInt(u32, payload[8..12], 0, .little); // fuzz
    std.mem.writeInt(u32, payload[12..16], 0, .little); // flat
    std.mem.writeInt(u32, payload[16..20], 0, .little); // res
    return 20;
}

/// Set one bit in a little-endian bitmap and return the bytes it spans, which
/// is the `size` the driver reads to know how much of the payload is meaningful.
fn setBit(payload: []u8, bit: u16) usize {
    const byte = bit / 8;
    if (byte >= payload.len) return 0;
    payload[byte] |= @as(u8, 1) << @intCast(bit % 8);
    return byte + 1;
}

/// Set every bit from 0 through `last` inclusive, returning the bytes spanned.
fn setRange(payload: []u8, last: u16) usize {
    const bytes = @min(@as(usize, last) / 8 + 1, payload.len);
    @memset(payload[0..bytes], 0xFF);
    return bytes;
}

/// Deliver one input event to the guest.
fn deliver(q: *const virtq.Virtq, head: u16, event: []const u8) virtq.Error!u32 {
    return virtq.scatter(q, head, &.{event});
}
