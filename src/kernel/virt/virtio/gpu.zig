//! virtio-gpu 2D device model (virtio 1.1 §5.7) — the guest's display adapter.
//! Pure: it consumes control-queue commands from a virtq over guest RAM, blits
//! guest pixels into caller-provided host stores, and publishes the scanned-out
//! store through ivirt for the desktop to composite. It never allocates: the
//! pixel stores arrive at init and the scatter lists live in fixed arrays.
//! Host-tested (test/kernel/virt/virtio/virtio_gpu_test.zig).
//!
//! The virtq bounds checks guard descriptor addresses; this module extends the
//! same invariant to the command payloads: every backing-store scatter entry is
//! checked against guest RAM, every rectangle against the resource it targets,
//! and every transfer row against the attached backing — a malformed command is
//! meant to earn a virtio_gpu error response rather than an out-of-range access,
//! host or guest. A malformed descriptor CHAIN (a virtq.Error) aborts processing so
//! the caller can mark the device needs-reset.
//!
//! Wire structs are extern with little-endian fields (§5.7.6); kudos targets
//! x86-64 only, so the in-memory layout is the wire layout.

const std = @import("std");
pub const virtq = @import("virtq.zig");
pub const ivirt = @import("ivirt");

// Control-queue command types (§5.7.6 enum virtio_gpu_ctrl_type).
pub const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
pub const CMD_RESOURCE_CREATE_2D: u32 = 0x0101;
pub const CMD_RESOURCE_UNREF: u32 = 0x0102;
pub const CMD_SET_SCANOUT: u32 = 0x0103;
pub const CMD_RESOURCE_FLUSH: u32 = 0x0104;
pub const CMD_TRANSFER_TO_HOST_2D: u32 = 0x0105;
pub const CMD_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
pub const CMD_RESOURCE_DETACH_BACKING: u32 = 0x0107;
pub const CMD_UPDATE_CURSOR: u32 = 0x0300;
pub const CMD_MOVE_CURSOR: u32 = 0x0301;

// Response types (§5.7.6 enum virtio_gpu_ctrl_type).
pub const RESP_OK_NODATA: u32 = 0x1100;
pub const RESP_OK_DISPLAY_INFO: u32 = 0x1101;
pub const RESP_ERR_UNSPEC: u32 = 0x1200;
pub const RESP_ERR_INVALID_RESOURCE_ID: u32 = 0x1202;
pub const RESP_ERR_INVALID_PARAMETER: u32 = 0x1203;

/// VIRTIO_GPU_FLAG_FENCE (§5.7.6): the response must echo the flag and fence_id.
pub const FLAG_FENCE: u32 = 1;

// The two formats the desktop composites natively (§5.7.6 enum
// virtio_gpu_formats): u32 texels whose byte order is B,G,R,A — Linux's
// default for a virtio-gpu dumb framebuffer.
pub const FORMAT_B8G8R8A8_UNORM: u32 = 1;
pub const FORMAT_B8G8R8X8_UNORM: u32 = 2;

/// VIRTIO_GPU_MAX_SCANOUTS (§5.7.4) — the display-info response always carries
/// this many slots; kudos enables only the first.
pub const MAX_SCANOUTS = 16;

pub const MAX_RESOURCES = 4;
const BYTES_PER_PIXEL: u32 = 4;
/// X-format guests leave alpha undefined; the compositor blends, so every texel
/// lands opaque.
const ALPHA_OPAQUE: u32 = 0xFF00_0000;
/// Granularity of guest backing pages: a Linux guest attaches one scatter
/// entry per 4 KiB page.
const GUEST_PAGE_BYTES: u32 = 4096;
/// Pixels every host store holds (the ivirt.publishFb contract).
pub const STORE_PIXELS: u32 = ivirt.FB_MAX_W * ivirt.FB_MAX_H;
/// Scatter entries for a full-screen resource backed page-by-page.
pub const MAX_BACKING_ENTRIES: u32 = STORE_PIXELS * BYTES_PER_PIXEL / GUEST_PAGE_BYTES;

/// Common request/response header (§5.7.6 struct virtio_gpu_ctrl_hdr).
pub const CtrlHdr = extern struct {
    type: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    padding: u32,
};

/// §5.7.6 struct virtio_gpu_rect.
pub const Rect = extern struct { x: u32, y: u32, width: u32, height: u32 };

// Per-command request bodies (§5.7.6), each carrying the common header.
const ResourceCreate2d = extern struct { hdr: CtrlHdr, resource_id: u32, format: u32, width: u32, height: u32 };
const ResourceUnref = extern struct { hdr: CtrlHdr, resource_id: u32, padding: u32 };
const SetScanout = extern struct { hdr: CtrlHdr, r: Rect, scanout_id: u32, resource_id: u32 };
const ResourceFlush = extern struct { hdr: CtrlHdr, r: Rect, resource_id: u32, padding: u32 };
const TransferToHost2d = extern struct { hdr: CtrlHdr, r: Rect, offset: u64, resource_id: u32, padding: u32 };
const AttachBacking = extern struct { hdr: CtrlHdr, resource_id: u32, nr_entries: u32 };
/// §5.7.6 struct virtio_gpu_mem_entry — one guest-physical backing page range.
pub const MemEntry = extern struct { addr: u64, length: u32, padding: u32 };
const DetachBacking = extern struct { hdr: CtrlHdr, resource_id: u32, padding: u32 };

/// §5.7.6 struct virtio_gpu_display_one / virtio_gpu_resp_display_info.
const DisplayOne = extern struct { r: Rect, enabled: u32, flags: u32 };
const RespDisplayInfo = extern struct { hdr: CtrlHdr, pmodes: [MAX_SCANOUTS]DisplayOne };

/// A guest 2D resource: its mode plus the scatter list of guest pages backing
/// it. Slot i owns host store i; id 0 marks the slot free (the protocol
/// reserves resource id 0 as "none").
const Resource = struct {
    id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    nr_entries: u32 = 0,
    entries: [MAX_BACKING_ENTRIES]MemEntry = undefined,
};

pub const Gpu = struct {
    /// The mailbox slot of the guest this device belongs to — every scanout
    /// publish, retract and flush is addressed to it, so one guest's display can
    /// never appear in another guest's window.
    id: ivirt.Id,
    /// Caller-provided host pixel stores, one per resource slot, each holding
    /// STORE_PIXELS BGRA texels. The scanned-out one is what ivirt publishes.
    stores: [MAX_RESOURCES][]u32,
    resources: [MAX_RESOURCES]Resource = [_]Resource{.{}} ** MAX_RESOURCES,
    /// The resource scanout 0 shows; 0 = blank (nothing published).
    scanout_resource_id: u32 = 0,
    /// Staging for one gathered request / built response / transferred pixel
    /// row — fields, not stack, to keep vCPU-task frames small.
    req_buf: [@sizeOf(AttachBacking) + MAX_BACKING_ENTRIES * @sizeOf(MemEntry)]u8 = undefined,
    resp_buf: [@sizeOf(RespDisplayInfo)]u8 = undefined,
    row_buf: [ivirt.FB_MAX_W * BYTES_PER_PIXEL]u8 = undefined,

    pub fn init(id: ivirt.Id, stores: [MAX_RESOURCES][]u32) Gpu {
        for (stores) |s| std.debug.assert(s.len >= STORE_PIXELS);
        return .{ .id = id, .stores = stores };
    }

    /// Drop all device-model state: every resource freed, the scanout blanked
    /// and its published framebuffer retracted. The transport's onReset calls
    /// this when the driver writes Status=0 (§2.1 device reset) — without it a
    /// re-probing driver would find stale resources and a stale scanout.
    pub fn reset(self: *Gpu) void {
        if (self.scanout_resource_id != 0) ivirt.retractFb(self.id);
        self.scanout_resource_id = 0;
        self.resources = [_]Resource{.{}} ** MAX_RESOURCES;
    }

    /// Drain the control queue: for each available chain, parse and execute the
    /// command, write the response into the chain's device-writable
    /// descriptors, and push the used element. A virtq.Error means the guest
    /// programmed a malformed queue — processing stops and the caller marks
    /// the device needs-reset.
    pub fn processControlQueue(self: *Gpu, q: *virtq.Virtq) virtq.Error!void {
        while (try q.popAvail()) |head| {
            const written = try self.processOne(q, head);
            q.pushUsed(head, written);
        }
    }

    fn processOne(self: *Gpu, q: *virtq.Virtq, head: u16) virtq.Error!u32 {
        // Gather the device-readable segments into req_buf. A request larger
        // than any legal command is truncated here and rejected by `execute`'s
        // per-command length checks.
        var req_len: usize = 0;
        var gather = virtq.chain(q, head);
        while (try gather.next()) |d| {
            if (d.flags & virtq.F_WRITE != 0) continue;
            const seg = try q.segment(d);
            const n = @min(self.req_buf.len - req_len, seg.len);
            @memcpy(self.req_buf[req_len..][0..n], seg[0..n]);
            req_len += n;
        }

        const resp_len = self.execute(q.mem, self.req_buf[0..req_len]);

        // Scatter the response into the device-writable segments, in order.
        var written: usize = 0;
        var scatter = virtq.chain(q, head);
        while (try scatter.next()) |d| {
            if (d.flags & virtq.F_WRITE == 0) continue;
            if (written >= resp_len) break;
            const seg = try q.segment(d);
            const n = @min(seg.len, resp_len - written);
            @memcpy(seg[0..n], self.resp_buf[written..][0..n]);
            written += n;
        }
        return @intCast(written);
    }

    /// Execute one gathered command, build the response in resp_buf, and
    /// return its length.
    fn execute(self: *Gpu, mem: []const u8, req: []const u8) usize {
        const hdr = parse(CtrlHdr, req) orelse
            return self.respond(std.mem.zeroes(CtrlHdr), RESP_ERR_UNSPEC);
        return switch (hdr.type) {
            CMD_GET_DISPLAY_INFO => self.getDisplayInfo(hdr),
            CMD_RESOURCE_CREATE_2D => self.resourceCreate2d(hdr, req),
            CMD_RESOURCE_UNREF => self.resourceUnref(hdr, req),
            CMD_RESOURCE_ATTACH_BACKING => self.attachBacking(hdr, req, mem),
            CMD_RESOURCE_DETACH_BACKING => self.detachBacking(hdr, req),
            CMD_SET_SCANOUT => self.setScanout(hdr, req),
            CMD_TRANSFER_TO_HOST_2D => self.transferToHost2d(hdr, req, mem),
            CMD_RESOURCE_FLUSH => self.resourceFlush(hdr, req),
            CMD_UPDATE_CURSOR, CMD_MOVE_CURSOR => self.respond(hdr, RESP_OK_NODATA),
            else => self.respond(hdr, RESP_ERR_UNSPEC),
        };
    }

    /// A header-only response (§5.7.6: every command yields at least a hdr).
    fn respond(self: *Gpu, req_hdr: CtrlHdr, code: u32) usize {
        const rh = respHdr(req_hdr, code);
        @memcpy(self.resp_buf[0..@sizeOf(CtrlHdr)], std.mem.asBytes(&rh));
        return @sizeOf(CtrlHdr);
    }

    fn getDisplayInfo(self: *Gpu, hdr: CtrlHdr) usize {
        var resp = std.mem.zeroes(RespDisplayInfo);
        resp.hdr = respHdr(hdr, RESP_OK_DISPLAY_INFO);
        resp.pmodes[0] = .{
            .r = .{ .x = 0, .y = 0, .width = ivirt.FB_MAX_W, .height = ivirt.FB_MAX_H },
            .enabled = 1,
            .flags = 0,
        };
        @memcpy(self.resp_buf[0..@sizeOf(RespDisplayInfo)], std.mem.asBytes(&resp));
        return @sizeOf(RespDisplayInfo);
    }

    fn resourceCreate2d(self: *Gpu, hdr: CtrlHdr, req: []const u8) usize {
        const c = parse(ResourceCreate2d, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        if (c.resource_id == 0 or self.findResource(c.resource_id) != null)
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        if (c.format != FORMAT_B8G8R8A8_UNORM and c.format != FORMAT_B8G8R8X8_UNORM)
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        if (c.width == 0 or c.height == 0 or c.width > ivirt.FB_MAX_W or c.height > ivirt.FB_MAX_H)
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        const slot = self.freeSlot() orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        self.resources[slot] = .{ .id = c.resource_id, .width = c.width, .height = c.height };
        // A new resource reads as black, not as whatever its host store last
        // held. Nothing else clears it: SET_SCANOUT publishes the store the
        // moment the guest names it, which is before the first
        // TRANSFER_TO_HOST_2D has put a single pixel there, so an unblanked
        // store IS what the window composites for those frames. Uninitialised
        // memory shown as pixels is the visible half; the half that matters is
        // that a slot reused by a later guest would otherwise show the previous
        // guest's last frame, and one guest may never see another's screen.
        @memset(self.stores[slot], 0);
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn resourceUnref(self: *Gpu, hdr: CtrlHdr, req: []const u8) usize {
        const c = parse(ResourceUnref, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        if (self.scanout_resource_id == c.resource_id) {
            self.scanout_resource_id = 0;
            ivirt.retractFb(self.id);
        }
        self.resources[slot] = .{};
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn attachBacking(self: *Gpu, hdr: CtrlHdr, req: []const u8, mem: []const u8) usize {
        const c = parse(AttachBacking, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        const res = &self.resources[slot];
        res.nr_entries = 0; // no partial list survives a failed attach
        if (c.nr_entries == 0 or c.nr_entries > MAX_BACKING_ENTRIES)
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        const list_bytes = @as(usize, c.nr_entries) * @sizeOf(MemEntry);
        if (req.len < @sizeOf(AttachBacking) + list_bytes)
            return self.respond(hdr, RESP_ERR_UNSPEC);
        for (0..c.nr_entries) |i| {
            const off = @sizeOf(AttachBacking) + i * @sizeOf(MemEntry);
            const e = std.mem.bytesToValue(MemEntry, req[off..][0..@sizeOf(MemEntry)]);
            // The security boundary: a scatter page outside guest RAM never
            // gets recorded, so no later transfer can read through it.
            if (e.length == 0 or e.addr > mem.len or e.length > mem.len - e.addr)
                return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
            res.entries[i] = e;
        }
        res.nr_entries = c.nr_entries;
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn detachBacking(self: *Gpu, hdr: CtrlHdr, req: []const u8) usize {
        const c = parse(DetachBacking, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        self.resources[slot].nr_entries = 0;
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn setScanout(self: *Gpu, hdr: CtrlHdr, req: []const u8) usize {
        const c = parse(SetScanout, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        if (c.scanout_id != 0) return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        if (c.resource_id == 0) { // blank the display
            self.scanout_resource_id = 0;
            ivirt.retractFb(self.id);
            return self.respond(hdr, RESP_OK_NODATA);
        }
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        const res = &self.resources[slot];
        self.scanout_resource_id = c.resource_id;
        ivirt.publishFb(self.id, self.stores[slot].ptr, res.width, res.height);
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn transferToHost2d(self: *Gpu, hdr: CtrlHdr, req: []const u8, mem: []const u8) usize {
        const c = parse(TransferToHost2d, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        const res = &self.resources[slot];
        if (!rectFits(c.r, res.width, res.height))
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        if (c.r.width == 0 or c.r.height == 0) return self.respond(hdr, RESP_OK_NODATA);

        // Guest source: row i of the rect lives at offset + i*stride in the
        // backing (stride = full resource width — the rect addresses a window
        // of the guest's framebuffer image).
        const stride = @as(u64, res.width) * BYTES_PER_PIXEL;
        const row_bytes = @as(u64, c.r.width) * BYTES_PER_PIXEL;
        // Saturating: a guest offset near u64 max must fail the check, not wrap.
        const last_row_end = c.offset +| @as(u64, c.r.height - 1) * stride +| row_bytes;
        if (last_row_end > backingBytes(res))
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);

        const store = self.stores[slot];
        for (0..c.r.height) |i| {
            const row = self.row_buf[0..@intCast(row_bytes)];
            if (!readBacking(res, mem, c.offset + i * stride, row))
                return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
            const dst_base = (@as(usize, c.r.y) + i) * res.width + c.r.x;
            for (0..c.r.width) |px| {
                const texel = std.mem.readInt(u32, row[px * BYTES_PER_PIXEL ..][0..4], .little);
                store[dst_base + px] = texel | ALPHA_OPAQUE;
            }
        }
        return self.respond(hdr, RESP_OK_NODATA);
    }

    fn resourceFlush(self: *Gpu, hdr: CtrlHdr, req: []const u8) usize {
        const c = parse(ResourceFlush, req) orelse return self.respond(hdr, RESP_ERR_UNSPEC);
        const slot = self.findResource(c.resource_id) orelse
            return self.respond(hdr, RESP_ERR_INVALID_RESOURCE_ID);
        const res = &self.resources[slot];
        if (!rectFits(c.r, res.width, res.height))
            return self.respond(hdr, RESP_ERR_INVALID_PARAMETER);
        if (c.resource_id == self.scanout_resource_id) ivirt.markFbDirty(self.id);
        return self.respond(hdr, RESP_OK_NODATA);
    }

    /// Slot index of the live resource with this id, or null (id 0 never matches).
    fn findResource(self: *const Gpu, id: u32) ?usize {
        if (id == 0) return null;
        for (&self.resources, 0..) |*r, i| {
            if (r.id == id) return i;
        }
        return null;
    }

    fn freeSlot(self: *const Gpu) ?usize {
        for (&self.resources, 0..) |*r, i| {
            if (r.id == 0) return i;
        }
        return null;
    }
};

fn parse(comptime T: type, req: []const u8) ?T {
    if (req.len < @sizeOf(T)) return null;
    return std.mem.bytesToValue(T, req[0..@sizeOf(T)]);
}

/// Response header (§5.7.6): a fenced request's response echoes the flag and
/// fence_id so the driver can retire the fence.
fn respHdr(req: CtrlHdr, code: u32) CtrlHdr {
    const fenced = req.flags & FLAG_FENCE != 0;
    return .{
        .type = code,
        .flags = if (fenced) FLAG_FENCE else 0,
        .fence_id = if (fenced) req.fence_id else 0,
        .ctx_id = 0,
        .padding = 0,
    };
}

/// Whether the rect lies inside a w x h surface, overflow-safe in u64.
fn rectFits(r: Rect, w: u32, h: u32) bool {
    return @as(u64, r.x) + r.width <= w and @as(u64, r.y) + r.height <= h;
}

fn backingBytes(res: *const Resource) u64 {
    var total: u64 = 0;
    for (res.entries[0..res.nr_entries]) |e| total += e.length;
    return total;
}

/// Copy `out.len` bytes from linear backing offset `off`, walking the scatter
/// list. Entries were bounds-checked at attach; the guest-RAM check is repeated
/// here anyway — reads through the scatter list are exactly where a stale or
/// corrupted entry would escape guest memory. False when the range is not
/// fully covered or an entry fails the re-check; the caller then errors the
/// command without a partial blit being observable as success.
fn readBacking(res: *const Resource, mem: []const u8, off: u64, out: []u8) bool {
    var remaining = out;
    var cursor: u64 = 0; // linear offset where the current entry begins
    var want = off;
    for (res.entries[0..res.nr_entries]) |e| {
        if (remaining.len == 0) break;
        const e_len: u64 = e.length;
        if (want >= cursor and want < cursor + e_len) {
            if (e.addr > mem.len or e_len > mem.len - e.addr) return false;
            const in_off = want - cursor;
            const n: usize = @intCast(@min(e_len - in_off, remaining.len));
            @memcpy(remaining[0..n], mem[@intCast(e.addr + in_off)..][0..n]);
            remaining = remaining[n..];
            want += n;
        }
        cursor += e_len;
    }
    return remaining.len == 0;
}
