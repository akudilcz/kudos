//! Host tests of src/kernel/virt/virtio/gpudev.zig — the display adapter as a
//! whole device. The fixture speaks the register protocol a Linux virtio-mmio
//! driver speaks, over a fake guest RAM: probe, negotiate, program the queue,
//! submit a command chain, take the interrupt. It is the end-to-end proof that
//! guest register accesses turn into a published scanout, which guest execution
//! (blocked on nested VT-x hardware) would otherwise be needed to show.

const std = @import("std");
const gpudev = @import("testroot").kernel.virtio_gpudev;
const gpu = gpudev.gpu;
const mmio = gpudev.mmio;
const virtq = gpu.virtq;
const ivirt = gpudev.ivirt;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;
const QSIZE: u32 = 8;

// Guest-physical layout of the fake machine.
const DESC_GPA: u64 = 0x100;
const AVAIL_GPA: u64 = 0x800;
const USED_GPA: u64 = 0xA00;
const REQ_GPA: u64 = 0x1000;
const RESP_GPA: u64 = 0x2000;
const RESP_CAP: u32 = 512;
const IMG_GPA: u64 = 0x3000;

// A 4x2 B8G8R8X8 test image — small enough to check every texel.
const IMG_W: u32 = 4;
const IMG_H: u32 = 2;
const RES_ID: u32 = 1;

// Register offsets, spelled independently of the transport so a transposed
// offset there cannot self-verify (virtio 1.1 §4.2.2).

// §2.1 device status bits, as a driver sets them in order.
const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;
const STATUS_NEEDS_RESET: u32 = 64;

const VM: ivirt.Id = 0;

// Host pixel stores: the full per-guest allocation the machine model makes.
var store_mem: [gpudev.STORE_BYTES / @sizeOf(u32)]u32 = undefined;

const Fx = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    dev: gpudev.GpuDev = .{},
    avail_idx: u16 = 0,
    submitted: u16 = 0,

    /// In place: the device's backend holds interior pointers to itself and to
    /// THIS fixture's ram, so the fixture can never be initialized by copy.
    fn init(self: *Fx) void {
        ivirt.reset(VM);
        self.ram = [_]u8{0} ** RAM_LEN;
        self.avail_idx = 0;
        self.submitted = 0;
        self.dev = .{};
        @memset(&store_mem, 0);
        self.dev.bind(VM, gpudev.carveStores(&store_mem), &self.ram);
    }

    /// Everything a Linux virtio driver does before it submits work: probe,
    /// negotiate features, program the control queue, DRIVER_OK.
    fn bringUp(self: *Fx) !void {
        try expectEqual(@as(u32, 0x74726976), self.dev.read(mmio.REG_MAGIC_VALUE, 4)); // "virt"
        try expectEqual(@as(u32, 2), self.dev.read(mmio.REG_VERSION, 4));
        try expectEqual(@as(u32, 16), self.dev.read(mmio.REG_DEVICE_ID, 4)); // GPU device

        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER);
        // VIRTIO_F_VERSION_1 lives in feature bank 1, bit 0.
        self.dev.write(mmio.REG_DEVICE_FEATURES_SEL, 4, 1);
        try expectEqual(@as(u32, 1), self.dev.read(mmio.REG_DEVICE_FEATURES, 4));
        self.dev.write(mmio.REG_DRIVER_FEATURES_SEL, 4, 1);
        self.dev.write(mmio.REG_DRIVER_FEATURES, 4, 1);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);

        self.dev.write(mmio.REG_QUEUE_SEL, 4, 0);
        self.dev.write(mmio.REG_QUEUE_NUM, 4, QSIZE);
        self.dev.write(mmio.REG_QUEUE_DESC_LOW, 4, @intCast(DESC_GPA));
        self.dev.write(mmio.REG_QUEUE_DRIVER_LOW, 4, @intCast(AVAIL_GPA));
        self.dev.write(mmio.REG_QUEUE_DEVICE_LOW, 4, @intCast(USED_GPA));
        self.dev.write(mmio.REG_QUEUE_READY, 4, 1);
        self.dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
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

    /// Post one command the way a driver does — request and response
    /// descriptors, then a QueueNotify register write — and read back the
    /// response type the device wrote into guest memory.
    fn submit(self: *Fx, req: []const u8) !u32 {
        @memcpy(self.ram[@intCast(REQ_GPA)..][0..req.len], req);
        @memset(self.ram[@intCast(RESP_GPA)..][0..RESP_CAP], 0);
        self.setDesc(0, REQ_GPA, @intCast(req.len), virtq.F_NEXT, 1);
        self.setDesc(1, RESP_GPA, RESP_CAP, virtq.F_WRITE, 0);
        self.pushAvail(0);
        self.dev.write(mmio.REG_QUEUE_NOTIFY, 4, 0);
        self.submitted += 1;
        try expectEqual(self.submitted, std.mem.readInt(u16, self.ram[@intCast(USED_GPA + 2)..][0..2], .little));
        return std.mem.readInt(u32, self.ram[@intCast(RESP_GPA)..][0..4], .little);
    }

    fn expectOk(self: *Fx, req: []const u8) !void {
        try expectEqual(gpu.RESP_OK_NODATA, try self.submit(req));
    }
};

/// Little-endian §5.7.6 wire-byte request encoder.
const Req = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn u32le(self: *Req, v: u32) *Req {
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
        return self;
    }

    fn u64le(self: *Req, v: u64) *Req {
        std.mem.writeInt(u64, self.buf[self.len..][0..8], v, .little);
        self.len += 8;
        return self;
    }

    fn hdr(self: *Req, cmd: u32) *Req {
        return self.u32le(cmd).u32le(0).u64le(0).u32le(0).u32le(0);
    }

    fn rect(self: *Req, x: u32, y: u32, w: u32, h: u32) *Req {
        return self.u32le(x).u32le(y).u32le(w).u32le(h);
    }

    fn bytes(self: *const Req) []const u8 {
        return self.buf[0..self.len];
    }
};

test "config space reports one scanout, at every access width" {
    var f: Fx = undefined;
    f.init();
    // num_scanouts is the third u32 of struct virtio_gpu_config.
    try expectEqual(@as(u32, 1), f.dev.read(mmio.REG_CONFIG + 8, 4));
    try expectEqual(@as(u32, 1), f.dev.read(mmio.REG_CONFIG + 8, 1));
    try expectEqual(@as(u32, 1), f.dev.read(mmio.REG_CONFIG + 8, 2));
    // events_read / events_clear / num_capsets are all zero.
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_CONFIG, 4));
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_CONFIG + 12, 4));
}

test "an unbound device answers as absent hardware" {
    var dev = gpudev.GpuDev{};
    try expectEqual(@as(u32, 0), dev.read(mmio.REG_MAGIC_VALUE, 4));
    dev.write(mmio.REG_STATUS, 4, STATUS_ACKNOWLEDGE); // must not fault
    try expect(!dev.irqLevel());
}

test "driver bring-up through a scanout: registers in, published framebuffer out" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();

    // Paint the guest's framebuffer: texel (col,row) = row*0x100 + col, alpha 0.
    for (0..IMG_H) |row| {
        for (0..IMG_W) |col| {
            const off: usize = @intCast(IMG_GPA + (row * IMG_W + col) * 4);
            std.mem.writeInt(u32, f.ram[off..][0..4], @intCast(row * 0x100 + col), .little);
        }
    }

    var r1 = Req{};
    try f.expectOk(r1.hdr(gpu.CMD_RESOURCE_CREATE_2D).u32le(RES_ID)
        .u32le(gpu.FORMAT_B8G8R8X8_UNORM).u32le(IMG_W).u32le(IMG_H).bytes());
    var r2 = Req{};
    try f.expectOk(r2.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING).u32le(RES_ID).u32le(1)
        .u64le(IMG_GPA).u32le(IMG_W * IMG_H * 4).u32le(0).bytes());
    var r3 = Req{};
    try f.expectOk(r3.hdr(gpu.CMD_SET_SCANOUT).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());

    // The scanout is published to this guest's mailbox slot, pointing at the
    // first pixel store.
    const fb = ivirt.fb(VM) orelse return error.TestUnexpectedResult;
    try expectEqual(@as([*]const u32, @ptrCast(&store_mem)), fb.ptr);
    try expectEqual(IMG_W, fb.w);
    try expectEqual(IMG_H, fb.h);

    var r4 = Req{};
    try f.expectOk(r4.hdr(gpu.CMD_TRANSFER_TO_HOST_2D).rect(0, 0, IMG_W, IMG_H)
        .u64le(0).u32le(RES_ID).u32le(0).bytes());
    for (0..IMG_H) |row| {
        for (0..IMG_W) |col| {
            const want: u32 = @as(u32, @intCast(row * 0x100 + col)) | 0xFF00_0000;
            try expectEqual(want, store_mem[row * IMG_W + col]);
        }
    }

    // Only a flush makes the frame visible to the compositor.
    try expect(!ivirt.takeFbDirty(VM));
    var r5 = Req{};
    try f.expectOk(r5.hdr(gpu.CMD_RESOURCE_FLUSH).rect(0, 0, IMG_W, IMG_H).u32le(RES_ID).u32le(0).bytes());
    try expect(ivirt.takeFbDirty(VM));
}

test "used-ring interrupt is raised per notify and cleared by the ACK register" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    try expect(!f.dev.irqLevel());

    var r = Req{};
    try f.expectOk(r.hdr(gpu.CMD_RESOURCE_CREATE_2D).u32le(RES_ID)
        .u32le(gpu.FORMAT_B8G8R8A8_UNORM).u32le(IMG_W).u32le(IMG_H).bytes());
    try expect(f.dev.irqLevel());
    try expectEqual(mmio.INT_USED_RING, f.dev.read(mmio.REG_INTERRUPT_STATUS, 4));

    f.dev.write(mmio.REG_INTERRUPT_ACK, 4, mmio.INT_USED_RING);
    try expect(!f.dev.irqLevel());
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_INTERRUPT_STATUS, 4));
}

test "the cursor queue is answered, not ignored" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    // Program queue 1 the same way, then notify it.
    f.dev.write(mmio.REG_QUEUE_SEL, 4, 1);
    f.dev.write(mmio.REG_QUEUE_NUM, 4, QSIZE);
    f.dev.write(mmio.REG_QUEUE_DESC_LOW, 4, @intCast(DESC_GPA));
    f.dev.write(mmio.REG_QUEUE_DRIVER_LOW, 4, @intCast(AVAIL_GPA));
    f.dev.write(mmio.REG_QUEUE_DEVICE_LOW, 4, @intCast(USED_GPA));
    f.dev.write(mmio.REG_QUEUE_READY, 4, 1);

    var r = Req{};
    const req = r.hdr(gpu.CMD_UPDATE_CURSOR).bytes();
    @memcpy(f.ram[@intCast(REQ_GPA)..][0..req.len], req);
    f.setDesc(0, REQ_GPA, @intCast(req.len), virtq.F_NEXT, 1);
    f.setDesc(1, RESP_GPA, RESP_CAP, virtq.F_WRITE, 0);
    f.pushAvail(0);
    f.dev.write(mmio.REG_QUEUE_NOTIFY, 4, 1);
    try expectEqual(@as(u16, 1), std.mem.readInt(u16, f.ram[@intCast(USED_GPA + 2)..][0..2], .little));
    try expectEqual(gpu.RESP_OK_NODATA, std.mem.readInt(u32, f.ram[@intCast(RESP_GPA)..][0..4], .little));
}

test "a malformed descriptor chain marks the device needs-reset instead of looping" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    // A descriptor whose buffer runs past guest RAM: the virtq refuses it.
    f.setDesc(0, RAM_LEN - 8, 64, 0, 0);
    f.pushAvail(0);
    f.dev.write(mmio.REG_QUEUE_NOTIFY, 4, 0);
    try expect(f.dev.read(mmio.REG_STATUS, 4) & STATUS_NEEDS_RESET != 0);
    try expect(!f.dev.irqLevel()); // nothing was consumed, so nothing is signalled
}

test "a driver reset drops the scanout and the device comes back clean" {
    var f: Fx = undefined;
    f.init();
    try f.bringUp();
    var r1 = Req{};
    try f.expectOk(r1.hdr(gpu.CMD_RESOURCE_CREATE_2D).u32le(RES_ID)
        .u32le(gpu.FORMAT_B8G8R8A8_UNORM).u32le(IMG_W).u32le(IMG_H).bytes());
    var r2 = Req{};
    try f.expectOk(r2.hdr(gpu.CMD_SET_SCANOUT).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    try expect(ivirt.fb(VM) != null);

    f.dev.write(mmio.REG_STATUS, 4, 0);
    try expect(ivirt.fb(VM) == null);
    try expectEqual(@as(u32, 0), f.dev.read(mmio.REG_STATUS, 4));
    try expect(!f.dev.irqLevel());

    // A re-probing driver finds a working device and its resource ids free.
    f.avail_idx = 0;
    f.submitted = 0;
    @memset(f.ram[@intCast(USED_GPA)..][0..16], 0);
    @memset(f.ram[@intCast(AVAIL_GPA)..][0..16], 0);
    try f.bringUp();
    var r3 = Req{};
    try f.expectOk(r3.hdr(gpu.CMD_RESOURCE_CREATE_2D).u32le(RES_ID)
        .u32le(gpu.FORMAT_B8G8R8A8_UNORM).u32le(IMG_W).u32le(IMG_H).bytes());
}
