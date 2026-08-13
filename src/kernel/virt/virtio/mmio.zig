//! Modern (version 2) virtio-mmio transport (virtio 1.1 §4.2.2). Pure register
//! state machine: the machine model routes MMIO exits inside the device's
//! window to `read`/`write`, a QueueNotify write hands the queue index to the
//! backend device model, and interrupt-level changes leave through the injected
//! `irq` callback. Host-tested (test/kernel/virt/virtio/virtio_mmio_test.zig).
//!
//! The transport owns queue programming only: it fills each virtq.Virtq's size
//! and ring addresses from the Queue* registers and flips it ready; the backend
//! walks the queues when notified. Feature negotiation always offers
//! VIRTIO_F_VERSION_1 — a version-2 virtio-mmio device has no legacy mode
//! (§4.2.2.2), so the bit is the transport's to assert, not the backend's.

pub const virtq = @import("virtq.zig");

// Register offsets (§4.2.2 "MMIO Device Register Layout").
//
// PUBLIC because the conformance suites drive this device model through these
// exact offsets, and a test that re-spells a spec constant is testing its own
// copy: all four virtio suites had restated this map, ~104 lines of numbers
// with nothing checking they still matched. A spec value a test drives against
// is part of this module's contract.
pub const REG_MAGIC_VALUE: u64 = 0x000;
pub const REG_VERSION: u64 = 0x004;
pub const REG_DEVICE_ID: u64 = 0x008;
pub const REG_VENDOR_ID: u64 = 0x00c;
pub const REG_DEVICE_FEATURES: u64 = 0x010;
pub const REG_DEVICE_FEATURES_SEL: u64 = 0x014;
pub const REG_DRIVER_FEATURES: u64 = 0x020;
pub const REG_DRIVER_FEATURES_SEL: u64 = 0x024;
pub const REG_QUEUE_SEL: u64 = 0x030;
pub const REG_QUEUE_NUM_MAX: u64 = 0x034;
pub const REG_QUEUE_NUM: u64 = 0x038;
pub const REG_QUEUE_READY: u64 = 0x044;
pub const REG_QUEUE_NOTIFY: u64 = 0x050;
pub const REG_INTERRUPT_STATUS: u64 = 0x060;
pub const REG_INTERRUPT_ACK: u64 = 0x064;
pub const REG_STATUS: u64 = 0x070;
pub const REG_QUEUE_DESC_LOW: u64 = 0x080;
pub const REG_QUEUE_DESC_HIGH: u64 = 0x084;
pub const REG_QUEUE_DRIVER_LOW: u64 = 0x090;
pub const REG_QUEUE_DRIVER_HIGH: u64 = 0x094;
pub const REG_QUEUE_DEVICE_LOW: u64 = 0x0a0;
pub const REG_QUEUE_DEVICE_HIGH: u64 = 0x0a4;
pub const REG_SHM_SEL: u64 = 0x0ac;
pub const REG_SHM_LEN_LOW: u64 = 0x0b0;
pub const REG_SHM_LEN_HIGH: u64 = 0x0b4;
pub const REG_SHM_BASE_LOW: u64 = 0x0b8;
pub const REG_SHM_BASE_HIGH: u64 = 0x0bc;
pub const REG_CONFIG_GENERATION: u64 = 0x0fc;
pub const REG_CONFIG: u64 = 0x100;

/// "virt" little-endian — the MagicValue a driver probes for (§4.2.2).
const MAGIC_VALUE: u32 = 0x74726976;
/// Register-layout version 2, the modern (non-legacy) interface (§4.2.2).
const VERSION_MODERN: u32 = 2;
/// "SVDK" little-endian — the kudos hypervisor's vendor tag.
const VENDOR_ID: u32 = 0x4b445653;
/// Largest queue size the transport accepts (§4.2.2 QueueNumMax).
const QUEUE_NUM_MAX: u32 = 256;
/// VIRTIO_F_VERSION_1, feature bit 32 (§6): "this device is a virtio 1 device".
const VIRTIO_F_VERSION_1: u64 = 1 << 32;

/// SHMLen for a shared-memory region that does not exist (§4.2.2.2): all ones,
/// in BOTH halves, because the driver assembles the two 32-bit reads into one
/// 64-bit length and tests it against ~0.
///
/// kudos exposes no shared-memory regions: the 2D scanout path copies through
/// virtqueues and never maps host memory into the guest. That makes this the
/// one value the transport must state rather than leave to the unmapped-reads-
/// as-zero rule, because zero does not mean "absent" — it describes a region
/// that EXISTS at address zero with zero length. A driver told that reserves
/// it, fails, and aborts its probe: it is how virtio-gpu refuses to bind while
/// virtio-net and virtio-input, which never ask for a region, bind fine.
const SHM_LEN_ABSENT: u32 = 0xffff_ffff;

// InterruptStatus bits (§4.2.2).
pub const INT_USED_RING: u32 = 1 << 0;
pub const INT_CONFIG: u32 = 1 << 1;

/// VIRTIO_CONFIG_S_NEEDS_RESET (§2.1): a device model ors this into `status`
/// when it gives up on a guest that programmed a malformed queue, so the driver
/// re-initializes rather than waiting forever for a response that will never
/// come.
pub const STATUS_DEVICE_NEEDS_RESET: u32 = 64;

const FEATURE_BANK_BITS: u6 = 32;

/// What a device model plugs into the transport: its identity, feature bits,
/// config space, and the callbacks the transport fires into it.
pub const Backend = struct {
    /// Virtio device type (§5), e.g. 16 for a GPU device.
    device_id: u32,
    /// Device-specific feature bits; VIRTIO_F_VERSION_1 is added by the transport.
    device_features: u64,
    /// Device-specific configuration space, mapped at offset 0x100.
    config: []u8,
    ctx: *anyopaque,
    /// A driver wrote QueueNotify for this queue — process it.
    notify: *const fn (ctx: *anyopaque, queue: u16) void,
    /// The driver wrote Status=0 — drop all device-model state.
    onReset: *const fn (ctx: *anyopaque) void,
    /// The driver wrote config-space bytes starting at `off` — null for devices
    /// whose config is read-only. virtio-input's select/subsel protocol is the
    /// consumer: each written selector re-derives the config payload.
    configWritten: ?*const fn (ctx: *anyopaque, off: u64) void = null,
};

pub const MAX_QUEUES = 2;

pub const Mmio = struct {
    backend: Backend,
    /// Drives the device's interrupt line level into the machine model.
    irq: *const fn (ctx: *anyopaque, level: bool) void,
    queues: [MAX_QUEUES]virtq.Virtq,
    /// QueueNum values parked per queue; applied to the Virtq at QueueReady=1.
    queue_num: [MAX_QUEUES]u32 = [_]u32{0} ** MAX_QUEUES,
    status: u32 = 0,
    device_features_sel: u32 = 0,
    driver_features_sel: u32 = 0,
    driver_features: u64 = 0,
    queue_sel: u32 = 0,
    int_status: u32 = 0,
    config_generation: u32 = 0,

    pub fn init(backend: Backend, mem: []u8, irq: *const fn (ctx: *anyopaque, level: bool) void) Mmio {
        var m = Mmio{ .backend = backend, .irq = irq, .queues = undefined };
        for (&m.queues) |*q| {
            q.* = .{ .mem = mem, .size = 0, .desc_gpa = 0, .avail_gpa = 0, .used_gpa = 0 };
        }
        return m;
    }

    /// Handle a guest MMIO read of `size` bytes (1, 2, or 4) at `off` (address −
    /// device base). Registers honor only 32-bit access (§4.2.2.2 — the driver
    /// MUST use u32 there; anything else reads 0); config space is byte-granular
    /// (§4.2.2.2 allows 8/16/32-bit config access, and Linux reads sub-word
    /// config fields with readb/readw). Unmapped offsets read 0, which is
    /// harmless only where zero and "absent" mean the same thing to a driver —
    /// SHMLen is the register where they do not, and it is answered explicitly
    /// above rather than left to the default.
    pub fn read(self: *Mmio, off: u64, size: u8) u32 {
        if (off >= REG_CONFIG) return self.configRead(off - REG_CONFIG, size);
        if (size != 4) return 0;
        return switch (off) {
            REG_MAGIC_VALUE => MAGIC_VALUE,
            REG_VERSION => VERSION_MODERN,
            REG_DEVICE_ID => self.backend.device_id,
            REG_VENDOR_ID => VENDOR_ID,
            REG_DEVICE_FEATURES => featureBank(self.backend.device_features | VIRTIO_F_VERSION_1, self.device_features_sel),
            REG_QUEUE_NUM_MAX => if (self.queue_sel < MAX_QUEUES) QUEUE_NUM_MAX else 0,
            REG_QUEUE_READY => if (self.selectedQueue()) |q| @intFromBool(q.ready) else 0,
            REG_INTERRUPT_STATUS => self.int_status,
            REG_STATUS => self.status,
            REG_CONFIG_GENERATION => self.config_generation,
            REG_SHM_LEN_LOW, REG_SHM_LEN_HIGH => SHM_LEN_ABSENT,
            // Unreachable in practice: a driver told the length is all-ones
            // stops before reading the base. Answered anyway, so the register
            // block is wholly mapped rather than mapped where it was noticed.
            REG_SHM_BASE_LOW, REG_SHM_BASE_HIGH => 0,
            else => 0,
        };
    }

    /// Handle a guest MMIO write of the low `size` bytes (1, 2, or 4) of `val`
    /// at `off`. Registers honor only 32-bit access (as `read`); config space is
    /// byte-granular — virtio-input's select/subsel registers are written with
    /// writeb, and a widened write would clobber the neighboring selector.
    /// Writes to read-only or absent registers are ignored.
    pub fn write(self: *Mmio, off: u64, size: u8, val: u32) void {
        if (off >= REG_CONFIG) {
            self.configWrite(off - REG_CONFIG, size, val);
            return;
        }
        if (size != 4) return;
        switch (off) {
            // The shared-memory region selector. Ignored deliberately: with no
            // region to select, every SHMLen read answers "absent" whatever was
            // selected, so remembering the selection would change nothing.
            REG_SHM_SEL => {},
            REG_DEVICE_FEATURES_SEL => self.device_features_sel = val,
            REG_DRIVER_FEATURES => setFeatureBank(&self.driver_features, self.driver_features_sel, val),
            REG_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
            REG_QUEUE_SEL => self.queue_sel = val,
            REG_QUEUE_NUM => if (self.queue_sel < MAX_QUEUES) {
                self.queue_num[self.queue_sel] = @min(val, QUEUE_NUM_MAX);
            },
            REG_QUEUE_READY => if (self.selectedQueue()) |q| {
                if (val & 1 != 0) {
                    q.size = @intCast(self.queue_num[self.queue_sel]);
                    q.last_avail = 0;
                    q.used_idx = 0;
                    q.ready = true;
                } else {
                    q.ready = false;
                }
            },
            REG_QUEUE_NOTIFY => if (val < MAX_QUEUES) {
                self.backend.notify(self.backend.ctx, @intCast(val));
            },
            REG_INTERRUPT_ACK => {
                self.int_status &= ~val;
                if (self.int_status == 0) self.irq(self.backend.ctx, false);
            },
            REG_STATUS => if (val == 0) self.reset() else {
                self.status = val;
            },
            REG_QUEUE_DESC_LOW => if (self.selectedQueue()) |q| setLow32(&q.desc_gpa, val),
            REG_QUEUE_DESC_HIGH => if (self.selectedQueue()) |q| setHigh32(&q.desc_gpa, val),
            REG_QUEUE_DRIVER_LOW => if (self.selectedQueue()) |q| setLow32(&q.avail_gpa, val),
            REG_QUEUE_DRIVER_HIGH => if (self.selectedQueue()) |q| setHigh32(&q.avail_gpa, val),
            REG_QUEUE_DEVICE_LOW => if (self.selectedQueue()) |q| setLow32(&q.used_gpa, val),
            REG_QUEUE_DEVICE_HIGH => if (self.selectedQueue()) |q| setHigh32(&q.used_gpa, val),
            else => {},
        }
    }

    /// The backend consumed a buffer: latch the used-ring interrupt and raise
    /// the line (§4.2.2 InterruptStatus bit 0).
    pub fn raiseUsedIrq(self: *Mmio) void {
        self.int_status |= INT_USED_RING;
        self.irq(self.backend.ctx, true);
    }

    /// The device's configuration changed: bump ConfigGeneration so an in-flight
    /// config read is detectably stale, latch the config interrupt, raise the
    /// line (§4.2.2 InterruptStatus bit 1).
    pub fn raiseCfgIrq(self: *Mmio) void {
        self.config_generation +%= 1;
        self.int_status |= INT_CONFIG;
        self.irq(self.backend.ctx, true);
    }

    fn selectedQueue(self: *Mmio) ?*virtq.Virtq {
        if (self.queue_sel >= MAX_QUEUES) return null;
        return &self.queues[self.queue_sel];
    }

    /// Status=0: a full device reset (§4.2.2.2 / §2.1) — queues unready and
    /// unprogrammed, negotiation cleared, interrupt deasserted, backend told.
    fn reset(self: *Mmio) void {
        self.status = 0;
        self.device_features_sel = 0;
        self.driver_features_sel = 0;
        self.driver_features = 0;
        self.queue_sel = 0;
        for (&self.queues, &self.queue_num) |*q, *num| {
            q.size = 0;
            q.desc_gpa = 0;
            q.avail_gpa = 0;
            q.used_gpa = 0;
            q.last_avail = 0;
            q.used_idx = 0;
            q.ready = false;
            num.* = 0;
        }
        self.int_status = 0;
        self.irq(self.backend.ctx, false);
        self.backend.onReset(self.backend.ctx);
    }

    /// Little-endian view of `size` config-space bytes; bytes past the end read 0.
    fn configRead(self: *const Mmio, off: u64, size: u8) u32 {
        var v: u32 = 0;
        var i: u64 = 0;
        while (i < size) : (i += 1) {
            const byte_off = off + i;
            if (byte_off >= self.backend.config.len) break;
            v |= @as(u32, self.backend.config[@intCast(byte_off)]) << @intCast(8 * i);
        }
        return v;
    }

    /// Little-endian write of `size` bytes into config space; bytes past the end
    /// are dropped. Fires the backend's configWritten hook when any byte landed.
    fn configWrite(self: *Mmio, off: u64, size: u8, val: u32) void {
        if (off >= self.backend.config.len) return;
        var i: u64 = 0;
        while (i < size) : (i += 1) {
            const byte_off = off + i;
            if (byte_off >= self.backend.config.len) break;
            self.backend.config[@intCast(byte_off)] = @truncate(val >> @intCast(8 * i));
        }
        if (self.backend.configWritten) |hook| hook(self.backend.ctx, off);
    }
};

/// The 32-bit window of `features` selected by a *FeaturesSel register; banks
/// past the second read 0 (§4.2.2 DeviceFeatures/DriverFeatures).
fn featureBank(features: u64, sel: u32) u32 {
    if (sel > 1) return 0;
    return @truncate(features >> (@as(u6, @intCast(sel)) * FEATURE_BANK_BITS));
}

fn setFeatureBank(features: *u64, sel: u32, val: u32) void {
    if (sel > 1) return;
    const shift: u6 = @as(u6, @intCast(sel)) * FEATURE_BANK_BITS;
    const mask = @as(u64, 0xFFFF_FFFF) << shift;
    features.* = (features.* & ~mask) | (@as(u64, val) << shift);
}

fn setLow32(word: *u64, val: u32) void {
    word.* = (word.* & 0xFFFF_FFFF_0000_0000) | val;
}

fn setHigh32(word: *u64, val: u32) void {
    word.* = (word.* & 0x0000_0000_FFFF_FFFF) | (@as(u64, val) << 32);
}
