//! The guest's display adapter as one virtio-mmio device: the 2D command model
//! (virtio/gpu.zig) behind the version-2 transport (virtio/mmio.zig), plus the
//! config space and interrupt latch that join them. Pure and host-tested
//! (test/kernel/virt/virtio/virtio_gpudev_test.zig) — a scripted driver conversation drives the
//! whole path from a register probe to a published scanout.
//!
//! The machine model owns one of these per guest: it routes MMIO exits inside
//! the device's window to `read`/`write` and mirrors `irqLevel` onto a PIC line.
//! Keeping the wiring here rather than in machine.zig means the device is
//! provable on the host, where guest execution is not needed.

const std = @import("std");
pub const mmio = @import("mmio.zig");
pub const gpu = @import("gpu.zig");
pub const ivirt = @import("ivirt");

/// Virtio device type 16, "GPU device" (virtio 1.1 §5).
const DEVICE_ID_GPU: u32 = 16;

/// struct virtio_gpu_config (§5.7.4): events_read, events_clear, num_scanouts,
/// num_capsets — four little-endian u32s.
const CONFIG_SIZE: usize = 16;
const CONFIG_NUM_SCANOUTS_OFF: usize = 8;

/// Scanouts the device offers. One: the guest's display is the VM window.
const NUM_SCANOUTS: u32 = 1;

/// Queue indices (§5.7.2). The cursor queue is accepted and answered so a driver
/// that programs it does not stall; cursor commands are no-ops in the 2D model.
const CONTROLQ: u16 = 0;
const CURSORQ: u16 = 1;

pub const GpuDev = struct {
    gpu: gpu.Gpu = undefined,
    transport: mmio.Mmio = undefined,
    config: [CONFIG_SIZE]u8 = [_]u8{0} ** CONFIG_SIZE,
    /// The transport's interrupt line, latched here for the machine model to
    /// mirror onto its PIC at the next interrupt poll.
    irq_level: bool = false,
    bound: bool = false,

    /// Wire the device up in place. The transport's backend holds interior
    /// pointers (`ctx` to this struct, `config` to its own field), so this must
    /// run on the GpuDev's FINAL address — the machine model calls it from
    /// `Vm.start`, never from `Vm.create`, whose result is returned by value and
    /// copied into the VM table. `stores` are the host pixel stores the model
    /// blits into; `guest_ram` is the RAM slice its virtqueues live in.
    pub fn bind(self: *GpuDev, id: ivirt.Id, stores: [gpu.MAX_RESOURCES][]u32, guest_ram: []u8) void {
        self.config = [_]u8{0} ** CONFIG_SIZE;
        std.mem.writeInt(u32, self.config[CONFIG_NUM_SCANOUTS_OFF..][0..4], NUM_SCANOUTS, .little);
        self.gpu = gpu.Gpu.init(id, stores);
        self.irq_level = false;
        self.transport = mmio.Mmio.init(.{
            .device_id = DEVICE_ID_GPU,
            // No device-specific features: the 2D scanout path needs none, and
            // the transport asserts VIRTIO_F_VERSION_1 itself.
            .device_features = 0,
            .config = &self.config,
            .ctx = self,
            .notify = onNotify,
            .onReset = onReset,
        }, guest_ram, onIrq);
        self.bound = true;
    }

    /// A guest MMIO read of `size` bytes at `off` (address − the device's window
    /// base). Reads before `bind` are all-zero, so a probe of an unwired slot
    /// finds no device rather than a half-built one.
    pub fn read(self: *GpuDev, off: u64, size: u8) u32 {
        if (!self.bound) return 0;
        return self.transport.read(off, size);
    }

    pub fn write(self: *GpuDev, off: u64, size: u8, val: u32) void {
        if (!self.bound) return;
        self.transport.write(off, size, val);
    }

    /// The device's interrupt line level, for the machine model to reflect onto
    /// its PIC line.
    pub fn irqLevel(self: *const GpuDev) bool {
        return self.irq_level;
    }

    fn onNotify(ctx: *anyopaque, queue: u16) void {
        const self: *GpuDev = @ptrCast(@alignCast(ctx));
        const q = switch (queue) {
            CONTROLQ, CURSORQ => &self.transport.queues[queue],
            else => return,
        };
        self.gpu.processControlQueue(q) catch {
            // A malformed descriptor chain: the guest's queue cannot be trusted,
            // so stop consuming it and tell the driver the device needs reset.
            self.transport.status |= mmio.STATUS_DEVICE_NEEDS_RESET;
            return;
        };
        self.transport.raiseUsedIrq();
    }

    fn onReset(ctx: *anyopaque) void {
        const self: *GpuDev = @ptrCast(@alignCast(ctx));
        self.gpu.reset();
    }

    fn onIrq(ctx: *anyopaque, level: bool) void {
        const self: *GpuDev = @ptrCast(@alignCast(ctx));
        self.irq_level = level;
    }
};

/// Host pixel-store bytes one guest needs: one full-ceiling store per resource
/// slot. The machine model allocates this from the frame allocator at VM
/// creation — never on an exit path.
pub const STORE_BYTES: usize = gpu.MAX_RESOURCES * gpu.STORE_PIXELS * @sizeOf(u32);

/// Carve `mem` — at least STORE_BYTES of host memory — into the per-slot pixel
/// stores `bind` expects.
pub fn carveStores(mem: []u32) [gpu.MAX_RESOURCES][]u32 {
    std.debug.assert(mem.len >= gpu.MAX_RESOURCES * gpu.STORE_PIXELS);
    var stores: [gpu.MAX_RESOURCES][]u32 = undefined;
    for (&stores, 0..) |*s, i| {
        s.* = mem[i * gpu.STORE_PIXELS ..][0..gpu.STORE_PIXELS];
    }
    return stores;
}
