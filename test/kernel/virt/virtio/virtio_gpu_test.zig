//! Host tests of src/kernel/virt/virtio/gpu.zig — the virtio-gpu 2D command
//! path over a fake guest RAM, and above all its security boundary: no
//! command, rect, or scatter entry may ever reach outside guest RAM or the
//! host store. Requests are encoded byte-by-byte at the §5.7.6 wire offsets,
//! independently of the module's extern structs, so a layout mistake cannot
//! self-verify.

const std = @import("std");
const gpu = @import("virtio_gpu");
const virtq = gpu.virtq;
const ivirt = gpu.ivirt;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expect = std.testing.expect;

const RAM_LEN = 64 * 1024;
const QSIZE: u16 = 8;

// Guest-physical layout of the fake machine.
const DESC_GPA: u64 = 0x100;
const AVAIL_GPA: u64 = 0x800;
const USED_GPA: u64 = 0xA00;
const REQ_GPA: u64 = 0x1000;
const RESP_GPA: u64 = 0x2000;
const RESP_CAP: u32 = 512;
const IMG_GPA: u64 = 0x3000; // guest framebuffer, lower half
const IMG2_GPA: u64 = 0x3800; // upper half, deliberately non-contiguous

// A test image small enough to check every texel: 8x4 B8G8R8X8.
const IMG_W: u32 = 8;
const IMG_H: u32 = 4;
const IMG_STRIDE: u32 = IMG_W * 4;
const RES_ID: u32 = 1;
const IMG_HALF: u32 = IMG_H / 2 * IMG_STRIDE; // bytes per backing entry

/// Guest address of linear image offset `lin` through the split scatter map.
fn imgAddr(lin: u32) u64 {
    return if (lin < IMG_HALF) IMG_GPA + lin else IMG2_GPA + (lin - IMG_HALF);
}

const STORE_SENTINEL: u32 = 0x1111_1111;

// Host pixel stores, one per resource slot (globals: 4 x 3 MiB).
var stores_mem: [gpu.MAX_RESOURCES][gpu.STORE_PIXELS]u32 = undefined;

/// The mailbox slot every device under test publishes its scanout to. The model
/// is per-guest, so the tests fix one id and assert against that slot alone.
const VM: ivirt.Id = 0;

fn makeGpu() gpu.Gpu {
    var stores: [gpu.MAX_RESOURCES][]u32 = undefined;
    for (&stores, &stores_mem) |*s, *m| {
        s.* = m;
        @memset(m, STORE_SENTINEL);
    }
    return gpu.Gpu.init(VM, stores);
}

/// Little-endian request encoder writing raw §5.7.6 wire bytes.
const Req = struct {
    buf: [256]u8 = undefined,
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

    /// virtio_gpu_ctrl_hdr: type, flags, fence_id, ctx_id, padding.
    fn hdr(self: *Req, cmd: u32, flags: u32, fence_id: u64) *Req {
        return self.u32le(cmd).u32le(flags).u64le(fence_id).u32le(0).u32le(0);
    }

    fn rect(self: *Req, x: u32, y: u32, w: u32, h: u32) *Req {
        return self.u32le(x).u32le(y).u32le(w).u32le(h);
    }

    fn bytes(self: *const Req) []const u8 {
        return self.buf[0..self.len];
    }
};

const Fx = struct {
    ram: [RAM_LEN]u8 align(16) = [_]u8{0} ** RAM_LEN,
    q: virtq.Virtq = undefined,
    avail_idx: u16 = 0,
    submitted: u16 = 0,

    /// In place: `q.mem` must point at THIS fixture's ram, so the fixture can
    /// never be initialized by copy.
    fn init(self: *Fx) void {
        ivirt.reset(VM);
        self.* = .{};
        self.q = .{
            .mem = &self.ram,
            .size = QSIZE,
            .desc_gpa = DESC_GPA,
            .avail_gpa = AVAIL_GPA,
            .used_gpa = USED_GPA,
            .ready = true,
        };
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

    const Outcome = struct { resp: u32, flags: u32, fence_id: u64, written: u32 };

    /// Run one command through the control queue: request in a readable
    /// descriptor, response in a writable one.
    fn submit(self: *Fx, g: *gpu.Gpu, req: []const u8) !Outcome {
        @memcpy(self.ram[@intCast(REQ_GPA)..][0..req.len], req);
        @memset(self.ram[@intCast(RESP_GPA)..][0..RESP_CAP], 0);
        self.setDesc(0, REQ_GPA, @intCast(req.len), virtq.F_NEXT, 1);
        self.setDesc(1, RESP_GPA, RESP_CAP, virtq.F_WRITE, 0);
        self.pushAvail(0);
        try g.processControlQueue(&self.q);
        self.submitted += 1;
        // The command must be retired through the used ring.
        try expectEqual(self.submitted, std.mem.readInt(u16, self.ram[@intCast(USED_GPA + 2)..][0..2], .little));
        const elem: usize = @intCast(USED_GPA + 4 + @as(u64, (self.submitted - 1) % QSIZE) * 8);
        try expectEqual(@as(u32, 0), std.mem.readInt(u32, self.ram[elem..][0..4], .little)); // head id
        return .{
            .resp = std.mem.readInt(u32, self.ram[@intCast(RESP_GPA)..][0..4], .little),
            .flags = std.mem.readInt(u32, self.ram[@intCast(RESP_GPA + 4)..][0..4], .little),
            .fence_id = std.mem.readInt(u64, self.ram[@intCast(RESP_GPA + 8)..][0..8], .little),
            .written = std.mem.readInt(u32, self.ram[elem + 4 ..][0..4], .little),
        };
    }

    fn expectOk(self: *Fx, g: *gpu.Gpu, req: []const u8) !void {
        try expectEqual(gpu.RESP_OK_NODATA, (try self.submit(g, req)).resp);
    }

    /// Fill the guest image through the split scatter map: texel (col,row) =
    /// row*0x100 + col, alpha byte 0 — so a forced-opaque copy is
    /// distinguishable from a straight one.
    fn paintGuestImage(self: *Fx) void {
        for (0..IMG_H) |row| {
            for (0..IMG_W) |col| {
                const lin: u32 = @intCast(row * IMG_STRIDE + col * 4);
                const off: usize = @intCast(imgAddr(lin));
                std.mem.writeInt(u32, self.ram[off..][0..4], @intCast(row * 0x100 + col), .little);
            }
        }
    }
};

fn create2d(r: *Req, id: u32, format: u32, w: u32, h: u32) []const u8 {
    return r.hdr(gpu.CMD_RESOURCE_CREATE_2D, 0, 0).u32le(id).u32le(format).u32le(w).u32le(h).bytes();
}

/// Re-lay the sentinel over a slot's store AFTER its resource exists. Creating
/// a resource blanks its store on purpose, so a test that means to watch which
/// pixels a TRANSFER writes has to establish its marker afterwards — otherwise
/// it is watching the blanking, and would pass over a transfer that wrote
/// nothing at all.
fn seedStore(slot: usize) void {
    @memset(&stores_mem[slot], STORE_SENTINEL);
}

/// Attach the 8x4 test image as its two non-contiguous scatter entries, so a
/// transfer's linear offsets must cross an entry boundary.
fn attachSplitImage(r: *Req) []const u8 {
    return r.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING, 0, 0).u32le(RES_ID).u32le(2)
        .u64le(IMG_GPA).u32le(IMG_HALF).u32le(0) // rows 0-1
        .u64le(IMG2_GPA).u32le(IMG_HALF).u32le(0) // rows 2-3
        .bytes();
}

test "GET_DISPLAY_INFO: one enabled scanout at the ADVERTISED mode, full response written" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r = Req{};
    const out = try f.submit(&g, r.hdr(gpu.CMD_GET_DISPLAY_INFO, 0, 0).bytes());
    try expectEqual(gpu.RESP_OK_DISPLAY_INFO, out.resp);
    try expectEqual(@as(u32, 24 + 16 * 24), out.written); // hdr + 16 pmodes
    const pmode: usize = @intCast(RESP_GPA + 24);
    try expectEqual(@as(u32, 0), std.mem.readInt(u32, f.ram[pmode..][0..4], .little)); // x
    // The advertised mode, NOT the ceiling: a guest takes this as its display
    // size, and a window shows it pixel-for-pixel, so a device that advertised
    // more than a window can hold would have every guest render a picture that
    // then has to be cropped or resampled.
    try expectEqual(@as(u32, ivirt.FB_MODE_W), std.mem.readInt(u32, f.ram[pmode + 8 ..][0..4], .little));
    try expectEqual(@as(u32, ivirt.FB_MODE_H), std.mem.readInt(u32, f.ram[pmode + 12 ..][0..4], .little));
    // And it must be something a window can actually show whole.
    try std.testing.expect(ivirt.FB_MODE_W <= ivirt.FB_MAX_W and ivirt.FB_MODE_H <= ivirt.FB_MAX_H);
    try expectEqual(@as(u32, 1), std.mem.readInt(u32, f.ram[pmode + 16 ..][0..4], .little)); // enabled
    try expectEqual(@as(u32, 0), std.mem.readInt(u32, f.ram[pmode + 24 ..][0..4], .little)); // pmode[1] disabled
}

// VIRT-013: the guest gets a graphics device it can scan out from.
test "full sequence: create, attach split backing, scanout, sub-rect transfer, flush" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    f.paintGuestImage();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    seedStore(0);
    var r2 = Req{};
    try f.expectOk(&g, attachSplitImage(&r2));

    var r3 = Req{};
    try f.expectOk(&g, r3.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    const fb = ivirt.fb(VM) orelse return error.TestUnexpectedResult;
    try expectEqual(@as([*]const u32, @ptrCast(&stores_mem[0])), fb.ptr);
    try expectEqual(IMG_W, fb.w);
    try expectEqual(IMG_H, fb.h);
    try expect(!ivirt.takeFbDirty(VM)); // nothing flushed yet

    // Transfer rect (x=2, y=1, w=4, h=2): rows 1 and 2 — the second row lives
    // in the second scatter entry.
    var r4 = Req{};
    const rect_off: u64 = 1 * IMG_STRIDE + 2 * 4;
    try f.expectOk(&g, r4.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(2, 1, 4, 2).u64le(rect_off).u32le(RES_ID).u32le(0).bytes());
    const store = &stores_mem[0];
    for (0..IMG_H) |row| {
        for (0..IMG_W) |col| {
            const inside = row >= 1 and row < 3 and col >= 2 and col < 6;
            const want: u32 = if (inside)
                @as(u32, @intCast(row * 0x100 + col)) | 0xFF00_0000 // guest texel, alpha forced
            else
                STORE_SENTINEL; // outside the rect: untouched
            try expectEqual(want, store[row * IMG_W + col]);
        }
    }

    var r5 = Req{};
    try f.expectOk(&g, r5.hdr(gpu.CMD_RESOURCE_FLUSH, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(RES_ID).u32le(0).bytes());
    try expect(ivirt.takeFbDirty(VM));
    try expect(!ivirt.takeFbDirty(VM)); // one-shot
}

test "SET_SCANOUT resource 0 blanks; unref of the scanout also retracts" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8A8_UNORM, IMG_W, IMG_H));
    var r2 = Req{};
    try f.expectOk(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    try expect(ivirt.fb(VM) != null);
    var r3 = Req{};
    try f.expectOk(&g, r3.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, 0, 0).u32le(0).u32le(0).bytes());
    try expect(ivirt.fb(VM) == null);
    // Re-scanout, then unref the resource out from under it.
    var r4 = Req{};
    try f.expectOk(&g, r4.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    var r5 = Req{};
    try f.expectOk(&g, r5.hdr(gpu.CMD_RESOURCE_UNREF, 0, 0).u32le(RES_ID).u32le(0).bytes());
    try expect(ivirt.fb(VM) == null);
}

test "device reset drops every resource, retracts the scanout, frees the ids" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8A8_UNORM, IMG_W, IMG_H));
    var r2 = Req{};
    try f.expectOk(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    try expect(ivirt.fb(VM) != null);

    g.reset();
    try expect(ivirt.fb(VM) == null);
    // The old id is free again: a re-probing driver re-creates it without a
    // duplicate-id rejection.
    var r3 = Req{};
    try f.expectOk(&g, create2d(&r3, RES_ID, gpu.FORMAT_B8G8R8A8_UNORM, IMG_W, IMG_H));
}

test "create: bad format, oversize mode, duplicate id, resource ceiling" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, create2d(&r1, 1, 99, 8, 8))).resp);
    var r2 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, create2d(&r2, 1, gpu.FORMAT_B8G8R8A8_UNORM, ivirt.FB_MAX_W + 1, 8))).resp);
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, create2d(&r3, 1, gpu.FORMAT_B8G8R8A8_UNORM, 8, ivirt.FB_MAX_H + 1))).resp);
    var r4 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, create2d(&r4, 0, gpu.FORMAT_B8G8R8A8_UNORM, 8, 8))).resp);
    var i: u32 = 1;
    while (i <= gpu.MAX_RESOURCES) : (i += 1) {
        var rc = Req{};
        try f.expectOk(&g, create2d(&rc, i, gpu.FORMAT_B8G8R8A8_UNORM, 8, 8));
    }
    var r5 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, create2d(&r5, 2, gpu.FORMAT_B8G8R8A8_UNORM, 8, 8))).resp); // duplicate
    var r6 = Req{};
    try expectEqual(gpu.RESP_ERR_UNSPEC, (try f.submit(&g, create2d(&r6, 99, gpu.FORMAT_B8G8R8A8_UNORM, 8, 8))).resp); // all slots taken
}

test "invalid resource id: transfer, scanout, flush, unref, attach" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, r1.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 0, 1, 1).u64le(0).u32le(99).u32le(0).bytes())).resp);
    var r2 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, 1, 1).u32le(0).u32le(99).bytes())).resp);
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, r3.hdr(gpu.CMD_RESOURCE_FLUSH, 0, 0).rect(0, 0, 1, 1).u32le(99).u32le(0).bytes())).resp);
    var r4 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, r4.hdr(gpu.CMD_RESOURCE_UNREF, 0, 0).u32le(99).u32le(0).bytes())).resp);
    var r5 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_RESOURCE_ID, (try f.submit(&g, r5.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING, 0, 0).u32le(99).u32le(1).u64le(IMG_GPA).u32le(64).u32le(0).bytes())).resp);
}

test "attach: an out-of-RAM scatter entry is rejected and nothing is recorded" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    // Second entry pokes past the end of guest RAM.
    var r2 = Req{};
    const bad = r2.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING, 0, 0).u32le(RES_ID).u32le(2)
        .u64le(IMG_GPA).u32le(64).u32le(0)
        .u64le(RAM_LEN - 16).u32le(64).u32le(0).bytes();
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, bad)).resp);
    // No partial scatter list survives: a transfer finds no backing.
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 0, 1, 1).u64le(0).u32le(RES_ID).u32le(0).bytes())).resp);
}

test "attach: entry addr past RAM and entry count over the ceiling are rejected" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    var r2 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r2.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING, 0, 0).u32le(RES_ID).u32le(1).u64le(RAM_LEN).u32le(4).u32le(0).bytes())).resp);
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_RESOURCE_ATTACH_BACKING, 0, 0).u32le(RES_ID).u32le(gpu.MAX_BACKING_ENTRIES + 1).bytes())).resp);
}

test "a new resource blanks its store: a scanout shows black, never stale pixels" {
    var f: Fx = undefined;
    f.init();
    // The store arrives holding another image entirely — which is the real
    // case: these stores are per-VM and outlive the guest that last drew into
    // them, so a slot handed to a new guest starts full of the old guest's
    // final frame.
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));

    // SET_SCANOUT publishes the store immediately — before any
    // TRANSFER_TO_HOST_2D has put a pixel in it — so what it holds at creation
    // is what the window composites for those first frames.
    var r2 = Req{};
    try f.expectOk(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    try expect(ivirt.fb(VM) != null);
    for (stores_mem[0][0 .. IMG_W * IMG_H]) |px| try expectEqual(@as(u32, 0), px);
}

test "transfer: rect outside the resource leaves the store untouched" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    f.paintGuestImage();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    seedStore(0);
    var r2 = Req{};
    try f.expectOk(&g, attachSplitImage(&r2));
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(5, 0, 4, 1).u64le(0).u32le(RES_ID).u32le(0).bytes())).resp); // x+w > 8
    var r4 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r4.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 3, 1, 2).u64le(0).u32le(RES_ID).u32le(0).bytes())).resp); // y+h > 4
    for (stores_mem[0][0 .. IMG_W * IMG_H]) |px| try expectEqual(STORE_SENTINEL, px);
}

test "transfer: an offset past the backing, or near u64 max, is rejected" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    seedStore(0);
    var r2 = Req{};
    try f.expectOk(&g, attachSplitImage(&r2));
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 0, IMG_W, IMG_H).u64le(4).u32le(RES_ID).u32le(0).bytes())).resp); // slides past the end
    var r4 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r4.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 0, 1, 1).u64le(std.math.maxInt(u64) - 2).u32le(RES_ID).u32le(0).bytes())).resp);
    for (stores_mem[0][0 .. IMG_W * IMG_H]) |px| try expectEqual(STORE_SENTINEL, px);
}

test "transfer: a scatter entry corrupted after attach is re-checked, not trusted" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    seedStore(0);
    var r2 = Req{};
    try f.expectOk(&g, attachSplitImage(&r2));
    g.resources[0].entries[0].addr = RAM_LEN; // the corruption the re-check defends against
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_TRANSFER_TO_HOST_2D, 0, 0).rect(0, 0, 1, 1).u64le(0).u32le(RES_ID).u32le(0).bytes())).resp);
}

test "flush: rect outside the resource is invalid and marks nothing dirty" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    var r2 = Req{};
    try f.expectOk(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(0).u32le(RES_ID).bytes());
    _ = ivirt.takeFbDirty(VM);
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r3.hdr(gpu.CMD_RESOURCE_FLUSH, 0, 0).rect(0, 0, IMG_W + 1, IMG_H).u32le(RES_ID).u32le(0).bytes())).resp);
    try expect(!ivirt.takeFbDirty(VM));
}

test "scanout id other than 0 is invalid" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, create2d(&r1, RES_ID, gpu.FORMAT_B8G8R8X8_UNORM, IMG_W, IMG_H));
    var r2 = Req{};
    try expectEqual(gpu.RESP_ERR_INVALID_PARAMETER, (try f.submit(&g, r2.hdr(gpu.CMD_SET_SCANOUT, 0, 0).rect(0, 0, IMG_W, IMG_H).u32le(1).u32le(RES_ID).bytes())).resp);
}

test "cursor commands are OK no-ops; unknown commands are ERR_UNSPEC" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    try f.expectOk(&g, r1.hdr(gpu.CMD_UPDATE_CURSOR, 0, 0).bytes());
    var r2 = Req{};
    try f.expectOk(&g, r2.hdr(gpu.CMD_MOVE_CURSOR, 0, 0).bytes());
    var r3 = Req{};
    try expectEqual(gpu.RESP_ERR_UNSPEC, (try f.submit(&g, r3.hdr(0xDEAD, 0, 0).bytes())).resp);
}

test "a truncated request earns ERR_UNSPEC, never a crash" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    const out = try f.submit(&g, r1.hdr(gpu.CMD_RESOURCE_CREATE_2D, 0, 0).bytes()); // hdr only, body missing
    try expectEqual(gpu.RESP_ERR_UNSPEC, out.resp);
    var r2 = Req{};
    try expectEqual(gpu.RESP_ERR_UNSPEC, (try f.submit(&g, r2.u32le(gpu.CMD_GET_DISPLAY_INFO).bytes())).resp); // shorter than a hdr
}

test "a fenced request's response echoes FLAG_FENCE and the fence id" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    var r1 = Req{};
    const out = try f.submit(&g, r1.hdr(gpu.CMD_GET_DISPLAY_INFO, gpu.FLAG_FENCE, 0x1234_5678_9ABC).bytes());
    try expectEqual(gpu.FLAG_FENCE, out.flags);
    try expectEqual(@as(u64, 0x1234_5678_9ABC), out.fence_id);
    var r2 = Req{};
    const plain = try f.submit(&g, r2.hdr(gpu.CMD_GET_DISPLAY_INFO, 0, 0xFFFF).bytes());
    try expectEqual(@as(u32, 0), plain.flags);
    try expectEqual(@as(u64, 0), plain.fence_id);
}

test "a poisoned descriptor chain aborts processing with a virtq error" {
    var f: Fx = undefined;
    f.init();
    var g = makeGpu();
    // Request descriptor points past the end of guest RAM.
    f.setDesc(0, RAM_LEN, 24, 0, 0);
    f.pushAvail(0);
    try expectError(virtq.Error.AddrOutOfBounds, g.processControlQueue(&f.q));
    // Self-looping chain.
    var f2: Fx = undefined;
    f2.init();
    f2.setDesc(0, REQ_GPA, 24, virtq.F_NEXT, 0);
    f2.pushAvail(0);
    try expectError(virtq.Error.ChainTooLong, g.processControlQueue(&f2.q));
}
