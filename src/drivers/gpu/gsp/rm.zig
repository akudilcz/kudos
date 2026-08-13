//! Resource-manager client. Once the GSP is booted and the RPC ring is up, this
//! allocates GPU memory through the RM, submits commands, and reads fences. The
//! M9 success criterion lives here: submit one trivial command and read back a
//! fence the GPU wrote to DMA memory.

const std = @import("std");
const log = @import("../rm/log.zig").gpu;
const shim = @import("../rm/shim.zig");
const gsp = @import("gsp.zig");
const gspfw = @import("../rm/gspfw.zig");
const nvrm = @import("../rm/nvrm.zig");

/// Offset of the RPC payload (RM alloc/control header + params) within a queue
/// element: 48-byte element header + 32-byte RpcMessageHeader. The GSP writes the
/// reply in place here; this mapping is not plain-coherent for GSP DMA, so the
/// reply bytes must be clflushed before reading (same rule as msgq.drainUntil).
const RPC_PAYLOAD_OFF: u64 = gspfw.GSP_MSG_HDR_SIZE + @sizeOf(gspfw.RpcMessageHeader);

pub const Error = error{
    RmAllocFailed,
    RmControlFailed,
    RmFreeFailed,
} || gsp.Error;

/// Invalidate `len` bytes of cache lines at `base` so a subsequent read sees the
/// GSP's DMA write (this mapping is not plain-coherent for GSP DMA).
fn flushReply(base: u64, len: usize) void {
    var o: u64 = 0;
    while (o < len) : (o += 64) shim.invalidateLine(base + o);
}

/// Read one u32 from a reply's RM header at `field_off`, flushing the payload's
/// cache lines first.
fn readReplyU32(elem_phys: u64, payload_len: usize, field_off: usize) u32 {
    flushReply(elem_phys + RPC_PAYLOAD_OFF, payload_len);
    const p: [*]const volatile u8 = @ptrFromInt(elem_phys + RPC_PAYLOAD_OFF + field_off);
    return @as(u32, p[0]) | (@as(u32, p[1]) << 8) | (@as(u32, p[2]) << 16) | (@as(u32, p[3]) << 24);
}

/// Build a GSP_RM_ALLOC RPC (nvrm.RpcRmAlloc header + `params`), send it, await the
/// reply, and require both the transport result (checked in msgq.drainUntil) and
/// the RM-level `status` to be 0. nouveau r535_gsp_rpc_rm_alloc_get/push.
///
///   hParent/hObject/hClass are the RM object-tree handles; `params` is the
///   class-specific alloc-params block (empty for objects with none).
pub fn allocObject(g: gsp.Gsp, hClient: u32, hParent: u32, hObject: u32, hClass: u32, params: []const u8) Error!void {
    var buf: [4096]u8 align(8) = undefined;
    const total = @sizeOf(nvrm.RpcRmAlloc) + params.len;
    if (total > buf.len) return error.RmAllocFailed;
    @memset(buf[0..total], 0);
    const hdr: *nvrm.RpcRmAlloc = @ptrCast(@alignCast(&buf[0]));
    hdr.* = .{
        .hClient = hClient,
        .hParent = hParent,
        .hObject = hObject,
        .hClass = hClass,
        .status = 0,
        .paramsSize = @intCast(params.len),
        .flags = 0,
        .reserved = .{ 0, 0, 0, 0 },
    };
    @memcpy(buf[@sizeOf(nvrm.RpcRmAlloc) .. @sizeOf(nvrm.RpcRmAlloc) + params.len], params);

    const reply = try gsp.rpc(g, nvrm.FUNCTION_GSP_RM_ALLOC, buf[0..total]);
    const status = readReplyU32(reply.elem_phys, total, @offsetOf(nvrm.RpcRmAlloc, "status"));
    if (status != 0) {
        log("gpu.rm: RM_ALLOC cls=0x{x} obj=0x{x} status=0x{x}\n", .{ hClass, hObject, status });
        return error.RmAllocFailed;
    }
}

/// Build a GSP_RM_CONTROL RPC (nvrm.RpcRmControl header + `params`), send it, await
/// the reply, require status==0, and copy the reply params back into `params` (the
/// GSP overwrites them in place — output ctrls read their result from there).
/// nouveau r535_gsp_rpc_rm_ctrl_get/push.
pub fn control(g: gsp.Gsp, hObject: u32, cmd: u32, params: []u8) Error!void {
    var buf: [4096]u8 align(8) = undefined;
    const total = @sizeOf(nvrm.RpcRmControl) + params.len;
    if (total > buf.len) return error.RmControlFailed;
    @memset(buf[0..total], 0);
    const hdr: *nvrm.RpcRmControl = @ptrCast(@alignCast(&buf[0]));
    hdr.* = .{
        .hClient = nvrm.RM_CLIENT0,
        .hObject = hObject,
        .cmd = cmd,
        .status = 0,
        .paramsSize = @intCast(params.len),
        .flags = 0,
    };
    @memcpy(buf[@sizeOf(nvrm.RpcRmControl) .. @sizeOf(nvrm.RpcRmControl) + params.len], params);

    const reply = try gsp.rpc(g, nvrm.FUNCTION_GSP_RM_CONTROL, buf[0..total]);
    const status = readReplyU32(reply.elem_phys, total, @offsetOf(nvrm.RpcRmControl, "status"));
    if (status != 0) {
        log("gpu.rm: RM_CONTROL cmd=0x{x} obj=0x{x} status=0x{x}\n", .{ cmd, hObject, status });
        return error.RmControlFailed;
    }
    // Copy the reply params (just past the control header) back into the caller's
    // buffer — output ctrls (GET_*) read their result from there. VOLATILE source:
    // the GSP DMA-wrote this reply, so a plain [*]const u8 read lets the optimizer
    // fold the copy against the pre-transfer buffer state (the xhci.zig bug).
    // flushReply's clflush does NOT stop compiler folding. Mirrors the sibling
    // reader readReplyU32, which is already volatile.
    // @memcpy rejects a volatile source, so copy byte-wise.
    flushReply(reply.elem_phys + RPC_PAYLOAD_OFF, total);
    const src: [*]const volatile u8 = @ptrFromInt(reply.elem_phys + RPC_PAYLOAD_OFF + @sizeOf(nvrm.RpcRmControl));
    var k: usize = 0;
    while (k < params.len) : (k += 1) params[k] = src[k];
}

/// Free an RM object (FUNCTION_FREE, rpc_free_v03_00 — r535/alloc.c
/// r535_gsp_rpc_rm_free): hRoot = client, hObjectParent = 0, hObjectOld =
/// the object. Used by the GR golden-context staging, which allocates a
/// throwaway channel + 3D object and frees them.
pub fn freeObject(g: gsp.Gsp, hClient: u32, hObject: u32) Error!void {
    var params = nvrm.RpcFreeParams{
        .hRoot = hClient,
        .hObjectParent = 0,
        .hObjectOld = hObject,
        .status = 0,
    };
    const p: [*]const u8 = @ptrCast(&params);
    const reply = try gsp.rpc(g, nvrm.FUNCTION_FREE, @constCast(p[0..@sizeOf(nvrm.RpcFreeParams)]));
    const status = readReplyU32(reply.elem_phys, @sizeOf(nvrm.RpcFreeParams), @offsetOf(nvrm.RpcFreeParams, "status"));
    if (status != 0) {
        log("gpu.rm: FREE obj=0x{x} status=0x{x}\n", .{ hObject, status });
        return error.RmFreeFailed;
    }
}

/// The three fixed RM handles the display path hangs off (client → device →
/// subdevice), returned by clientDeviceCtor.
pub const RmObjects = struct { client: u32, device: u32, subdevice: u32 };

/// Allocate the root RM object tree the display path hangs off:
/// client (NV01_ROOT) → device (NV01_DEVICE_0) → subdevice (NV20_SUBDEVICE_0),
/// using the fixed kudos handles. nouveau nvkm_gsp_client_device_ctor. Single
/// client (id 0). Returns the three handles.
pub fn clientDeviceCtor(g: gsp.Gsp) Error!RmObjects {
    const hClient = nvrm.RM_CLIENT0;

    // 1. Root client (parent == object == client handle).
    var croot = nvrm.Nv0000AllocParams{
        .hClient = hClient,
        .processID = 0xffff_ffff,
        .processName = [_]u8{0} ** nvrm.NV_PROC_NAME_MAX_LENGTH,
        .pad = .{ 0, 0, 0, 0 },
        .pOsPidInfo = 0,
    };
    try allocObject(g, hClient, hClient, hClient, nvrm.NV01_ROOT, std.mem.asBytes(&croot));

    // 2. Device (parent = client, handle = RM_DEVICE). Only hClientShare set.
    var dev = std.mem.zeroes(nvrm.Nv0080AllocParams);
    dev.hClientShare = hClient;
    try allocObject(g, hClient, hClient, nvrm.RM_DEVICE, nvrm.NV01_DEVICE_0, std.mem.asBytes(&dev));

    // 3. Subdevice (parent = device, handle = RM_SUBDEVICE). subDeviceId = 0.
    var sub = std.mem.zeroes(nvrm.Nv2080AllocParams);
    try allocObject(g, hClient, nvrm.RM_DEVICE, nvrm.RM_SUBDEVICE, nvrm.NV20_SUBDEVICE_0, std.mem.asBytes(&sub));

    log("gpu.rm: client/device/subdevice allocated (client=0x{x})\n", .{hClient});
    return .{ .client = hClient, .device = nvrm.RM_DEVICE, .subdevice = nvrm.RM_SUBDEVICE };
}

/// A fence the GPU writes to a known DMA location on command completion.
pub const Fence = struct {
    /// Physical/identity-mapped address the GPU writes the fence value to.
    addr: u64,
    /// The value we expect once the submitted command retires.
    expected: u32,

    /// Read the current fence value (volatile — the GPU writes it via DMA).
    pub fn read(self: Fence) u32 {
        const p: *volatile u32 = @ptrFromInt(self.addr);
        return p.*;
    }

    /// True once the GPU has signaled completion.
    pub fn signaled(self: Fence) bool {
        return self.read() == self.expected;
    }
};

/// Liveness check: the GSP booted and a real RPC round-trip (GET_GSP_STATIC_INFO)
/// already completed inside gsp.boot. `.ok` means the 4090's GSP-RM is alive and
/// responding to us under kudos.
pub fn checkAlive(g: gsp.Gsp) shim.Status {
    if (!g.running) {
        log("gpu.rm: GSP not running after boot\n", .{});
        return .err_invalid_state;
    }
    return .ok;
}
