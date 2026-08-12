//! The capability vtables a loaded `.kudos` module binds, and the one door it
//! binds them through. WHO may bind WHAT is `grants.zig`; this file is the
//! machine side — the adapters that front a kudos contract in C-ABI terms.
//!
//! In console/, not with the loader: an adapter names the desktop mailboxes, the
//! counter registry, the scheduler, the file system. `src/kernel/` may not reach
//! up into those, so a registry under `kernel/loader/` could only publish what
//! needs no system around it. The loader verifies, places and jumps;
//! `apprun.zig` builds the `Api`; this answers what that `Api` asks outward, and
//! `hotload.zig` is handed the same answer for a feature.
//!
//! Every adapter: a module runs in a session address space on its own core
//! (MOD-006) while the desktop and the GL context live on core 0, so no module
//! pointer is ever handed across — the module's core copies into kernel-global
//! staging and core 0 reads only that.
//!
//! Vtables are `const` and STATIC: their addresses outlive any call, and nothing
//! in one may depend on which run is asking (that is the grant's job).

const std = @import("std");
const abi = @import("abi");
const apprun = @import("apprun.zig");
const counter = @import("../kernel/debug/counter.zig");
const grants = @import("grants.zig");
const percpu = @import("../kernel/sched/percpu.zig");
const taskstat = @import("../kernel/sched/taskstat.zig");
const heap = @import("../kernel/memory/heap.zig");
const iaccel = @import("iaccel");
const idesk = @import("idesk");
const ifilesys = @import("ifilesys");
const inet = @import("inet");
const iramdisk = @import("iramdisk");
const ivirt = @import("ivirt");
const iscene = @import("iscene");
const iwindow = @import("iwindow");
const sched = @import("../kernel/sched/sched.zig");
const timer = @import("../kernel/timer/timer.zig");
const vfs = @import("vfs");

pub const Grant = grants.Grant;

/// Resolve a capability request (MOD-008, MOD-009): the vtable for `{id, version}`
/// when the grant table allows it AND this ABI defines it, else null.
pub fn get(grant: Grant, id: u32, version: u32) ?*const anyopaque {
    if (!grants.allows(grant, id, version)) return null;
    return vtableFor(id, version);
}

/// The vtable a published `{id, version}` hands back. Granted-but-undelivered is
/// refused at build time by the comptime block below, not at runtime with null.
fn vtableFor(id: u32, version: u32) ?*const anyopaque {
    if (id == @intFromEnum(abi.Interface.window) and version == 1) return &window_vtable;
    if (id == @intFromEnum(abi.Interface.vfs) and version == 1) return &vfs_vtable;
    if (id == @intFromEnum(abi.Interface.net) and version == 1) return &net_vtable;
    if (id == @intFromEnum(abi.Interface.gl) and version == 1) return &gl_vtable;
    if (id == @intFromEnum(abi.Interface.input) and version == 1) return &input_vtable;
    if (id == @intFromEnum(abi.Interface.metrics) and version == 1) return &metrics_vtable;
    if (id == @intFromEnum(abi.Interface.desk) and version == 1) return &desk_vtable;
    if (id == @intFromEnum(abi.Interface.guests) and version == 1) return &guests_vtable;
    if (id == @intFromEnum(abi.Interface.task) and version == 1) return &task_vtable;
    if (id == @intFromEnum(abi.Interface.taskctl) and version == 1) return &taskctl_vtable;
    return null;
}

// ── the C-ABI entry points a module's `get_interface` points at ───────────────
//
// One per grant: the ABI fixes the signature at `(ctx, id, version)` and `ctx`
// belongs to the run, so the grant cannot travel through the call. Each caller
// installs the thunk for the run it starts.

pub fn appTerminal(_: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque {
    return get(.app_terminal, id, version);
}

pub fn appHeadless(_: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque {
    return get(.app_headless, id, version);
}

pub fn feature(_: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque {
    return get(.feature, id, version);
}

// ── what `caps` reports ──────────────────────────────────────────────────────

/// One published capability, for `cmd/caps.zig`. `live` is the runtime answer,
/// which is why this view exists at all.
pub const Entry = struct {
    name: []const u8,
    id: u32,
    version: u32,
    app_terminal: bool,
    app_headless: bool,
    feature: bool,
    why: []const u8,
    live: bool,
};

/// How many capabilities this kudos publishes.
pub fn count() usize {
    return grants.TABLE.len;
}

/// The i-th published capability (i < count()).
pub fn at(i: usize) Entry {
    const row = grants.TABLE[i];
    return .{
        .name = @tagName(row.id),
        .id = @intFromEnum(row.id),
        .version = row.version,
        .app_terminal = row.app_terminal,
        .app_headless = row.app_headless,
        .feature = row.feature,
        .why = row.why,
        .live = isLive(row.id),
    };
}

/// Whether a published capability can do anything on this machine as it stands —
/// declared and available are different claims.
fn isLive(id: abi.Interface) bool {
    return switch (id) {
        // A window needs a compositor to take the open request, and the compositor
        // publishes its hooks only once the desktop is up. Before that — or on a
        // build with no desktop — nothing will ever take it. The pointer arrives
        // through that same desktop.
        .window, .gl, .input, .desk => iaccel.compositor.pump != null,
        // A parked fetch needs a live stack to be performed against.
        .net => inet.instance != null,
        // Reads and writes of state that always exists (guest slots exist even
        // when every one is absent — absent IS an answer). taskctl needs a
        // session space to run a module in, which the single-core build lacks.
        .vfs, .metrics, .guests, .task => true,
        .taskctl => apprun.sandbox != null,
        else => false,
    };
}

// ── Interface.window — the module's own windows ───────────────────────────────

/// How long a create waits for the desktop to publish the window. The bound IS
/// the safety story: the compositor may never come up, and a module spinning on
/// that would burn a core with nothing to show.
const WINDOW_CREATE_TIMEOUT_MS: u64 = 1000;

fn winCreate(_: *anyopaque, title: [*]const u8, title_len: usize, w: u32, h: u32, m: u32) callconv(.c) u32 {
    const wm: iwindow.Mode = if (m == abi.WINDOW_SCENE) .scene else .pixels;
    const h_win = iwindow.requestCreate(w, h, wm, title[0..title_len]);
    if (h_win == 0) return 0;
    const deadline = timer.millis() + WINDOW_CREATE_TIMEOUT_MS;
    while (!iwindow.live(h_win)) {
        if (sched.cancelled() or timer.millis() >= deadline) return 0;
        sched.yieldPeriodic();
    }
    return h_win;
}

fn winClose(_: *anyopaque, h: u32) callconv(.c) void {
    iwindow.requestClose(h);
}

fn winClosed(_: *anyopaque, h: u32) callconv(.c) bool {
    return iwindow.closed(h);
}

fn winSize(_: *anyopaque, h: u32, out_w: *u32, out_h: *u32) callconv(.c) bool {
    return iwindow.size(h, out_w, out_h);
}

fn winFocused(_: *anyopaque, h: u32) callconv(.c) bool {
    return iwindow.focused(h);
}

fn winRetitle(_: *anyopaque, h: u32, title: [*]const u8, title_len: usize) callconv(.c) bool {
    return iwindow.retitle(h, title[0..title_len]);
}

fn winBlit(_: *anyopaque, h: u32, pixels: [*]const u32, w: u32, hgt: u32) callconv(.c) void {
    // The copy happens on the module's own core; core 0 never dereferences a
    // module pointer.
    iwindow.blit(h, pixels, w, hgt);
}

fn winCount(_: *anyopaque) callconv(.c) u32 {
    return iwindow.count();
}

fn winAt(_: *anyopaque, i: u32) callconv(.c) u32 {
    return iwindow.at(i);
}

const window_vtable = abi.WindowApi{
    .version = 1,
    .create = winCreate,
    .close = winClose,
    .closed = winClosed,
    .size = winSize,
    .focused = winFocused,
    .retitle = winRetitle,
    .blit = winBlit,
    .count = winCount,
    .at = winAt,
};

// ── Interface.vfs — the ramdisk as a namespace ────────────────────────────────
//
// Everything below normalizes against /ramdisk and REFUSES a path that lands
// anywhere else: the other mounts ride hardware transports the system core
// owns, and this adapter runs on the module's core. The base Api's flat
// file_read/file_write already reach the same store from the same context, so
// nothing here widens where a module's bytes can go — only how they are named.

/// Resolve a module path to an absolute /ramdisk path, or null (too long, or
/// escaping the ramdisk).
fn vfsPath(buf: *[vfs.MAX_PATH]u8, path: []const u8) ?[]const u8 {
    const abs = vfs.normalize("/ramdisk", path, buf) orelse return null;
    if (!std.mem.startsWith(u8, abs, "/ramdisk")) return null;
    return abs;
}

fn vfsSize(_: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) i64 {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return -1;
    const data = vfs.read(abs) orelse return -1;
    return @intCast(data.len);
}

fn vfsRead(_: *anyopaque, path: [*]const u8, path_len: usize, offset: u32, out: [*]u8, cap: usize) callconv(.c) isize {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return -1;
    const data = vfs.read(abs) orelse return -1;
    if (offset >= data.len) return 0; // at/past the end: a clean EOF, not an error
    const n = @min(cap, data.len - offset);
    @memcpy(out[0..n], data[offset..][0..n]);
    return @intCast(n);
}

fn vfsWrite(_: *anyopaque, path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) callconv(.c) bool {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return false;
    vfs.write(abs, data[0..len]) catch return false;
    return true;
}

fn vfsRemove(_: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return false;
    vfs.remove(abs) catch return false;
    return true;
}

fn vfsMkdir(_: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return false;
    vfs.mkdir(abs) catch return false;
    return true;
}

fn vfsRmdir(_: *anyopaque, path: [*]const u8, path_len: usize) callconv(.c) bool {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return false;
    vfs.rmdir(abs) catch return false;
    return true;
}

/// The list callback's accumulation state — entries land as "name\n" or
/// "name/\n", truncated between lines, never mid-name.
const VfsList = struct {
    out: [*]u8,
    cap: usize,
    used: usize = 0,

    fn cb(ctx: ?*anyopaque, entry: ifilesys.Entry) void {
        const self: *VfsList = @ptrCast(@alignCast(ctx.?));
        const extra: usize = if (entry.kind == .dir) 2 else 1; // "/\n" or "\n"
        if (self.used + entry.name.len + extra > self.cap) return;
        @memcpy(self.out[self.used..][0..entry.name.len], entry.name);
        self.used += entry.name.len;
        if (entry.kind == .dir) {
            self.out[self.used] = '/';
            self.used += 1;
        }
        self.out[self.used] = '\n';
        self.used += 1;
    }
};

fn vfsListFn(_: *anyopaque, path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) callconv(.c) isize {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = vfsPath(&buf, path[0..path_len]) orelse return -1;
    var acc = VfsList{ .out = out, .cap = cap };
    vfs.list(abs, VfsList.cb, &acc) catch return -1;
    return @intCast(acc.used);
}

const vfs_vtable = abi.VfsApi{
    .version = 1,
    .size = vfsSize,
    .read = vfsRead,
    .write = vfsWrite,
    .remove = vfsRemove,
    .mkdir = vfsMkdir,
    .rmdir = vfsRmdir,
    .list = vfsListFn,
};

// ── work modules park for the system core ─────────────────────────────────────

/// Perform whatever a module has parked, on the core that owns the thing it
/// needs. Called from the steady loop (boot/pump.zig), never from a module's
/// core: `NetApi.fetch_begin` parks a URL, and the network stack belongs to core
/// 0. One bounded step per call — the transfer itself advances on the stack's own
/// background path, so a download never stalls a frame.
pub fn service() void {
    if (inet.takeModuleFetchRequest()) |req| startModuleFetch(req);
}

/// The name a fetch lands under, copied out of the mailbox at start: the
/// completion fires frames later, and the mailbox's slices are only valid until
/// its state moves on.
var fetch_name_buf: [inet.MFETCH_NAME_MAX]u8 = undefined;
var fetch_name_len: usize = 0;
/// The completion seam wants a stable non-null context; it carries no state.
var fetch_ctx: u8 = 0;

fn fetchDone(_: *anyopaque, body: ?[]const u8) void {
    // Success is "the file is there": a transfer failure or a store with no room
    // both report failed, so the module never reads a file that never appeared.
    const ok = blk: {
        const b = body orelse break :blk false;
        const rd = iramdisk.instance orelse break :blk false;
        rd.put(fetch_name_buf[0..fetch_name_len], b) catch break :blk false;
        break :blk true;
    };
    inet.completeModuleFetch(ok);
}

fn startModuleFetch(req: inet.MFetchReq) void {
    const n = inet.instance orelse return inet.completeModuleFetch(false);
    fetch_name_len = @min(req.name.len, fetch_name_buf.len);
    @memcpy(fetch_name_buf[0..fetch_name_len], req.name[0..fetch_name_len]);
    n.fetchBackground(heap.allocator(), req.url, @ptrCast(&fetch_ctx), fetchDone) catch {
        inet.completeModuleFetch(false);
    };
}

// ── Interface.net — parked fetches, performed by the system core ──────────────

fn netOnline(_: *anyopaque) callconv(.c) bool {
    const n = inet.instance orelse return false;
    return n.isUp();
}

fn netFetchBegin(_: *anyopaque, url: [*]const u8, url_len: usize, name: [*]const u8, name_len: usize) callconv(.c) bool {
    // The name becomes a ramdisk file; a separator in it would name a path this
    // interface never promised. The mailbox bounds the lengths.
    const nm = name[0..name_len];
    if (std.mem.indexOfAny(u8, nm, "/\\") != null) return false;
    if (inet.instance == null) return false;
    return inet.requestModuleFetch(url[0..url_len], nm);
}

fn netFetchPoll(_: *anyopaque) callconv(.c) u32 {
    return switch (inet.moduleFetchState()) {
        .idle => abi.NET_IDLE,
        .requested, .in_flight => abi.NET_IN_FLIGHT,
        .done => abi.NET_DONE,
        .failed => abi.NET_FAILED,
    };
}

fn netFetchEnd(_: *anyopaque) callconv(.c) void {
    inet.finishModuleFetch();
}

const net_vtable = abi.NetApi{
    .version = 1,
    .online = netOnline,
    .fetch_begin = netFetchBegin,
    .fetch_poll = netFetchPoll,
    .fetch_end = netFetchEnd,
};

// ── Interface.input — the pointer, for one of the module's windows ────────────

fn inputPointer(_: *anyopaque, handle: u32, out_x: *i32, out_y: *i32, out_buttons: *u8) callconv(.c) bool {
    const p = iwindow.pointer(handle) orelse return false;
    out_x.* = p.x;
    out_y.* = p.y;
    out_buttons.* = p.buttons;
    return true;
}

const input_vtable = abi.InputApi{
    .version = 1,
    .pointer = inputPointer,
};

// ── Interface.gl — recorded 3D for a scene window ──────────────────────────────
//
// Every call copies into that window's scene mailbox on the module's own core;
// the desktop validates and replays at frame time. `frame(handle)` selects the
// window and ops go there until `end_frame`. One recording open at a time on the
// machine, which is also how many windowed runs there are (apprun's one detached
// slot).

/// How long `end_frame` waits for the compositor to take the previous frame
/// before dropping this one. A stalled desktop must not wedge the module.
const GL_FRAME_TIMEOUT_MS: u64 = 1000;

/// Window index ops record into, or null between frames.
var gl_target: ?usize = null;

fn glSlot() ?*iscene.Slot {
    const win = gl_target orelse return null;
    return iscene.recording(win);
}

fn glFrame(_: *anyopaque, handle: u32) callconv(.c) bool {
    if (iwindow.mode(handle) != iwindow.Mode.scene) return false;
    gl_target = iwindow.indexOf(handle) orelse return false;
    return true;
}

fn glEnable(_: *anyopaque, cap: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .enable, .a = cap });
}
fn glDisable(_: *anyopaque, cap: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .disable, .a = cap });
}
fn glMatrixMode(_: *anyopaque, mode: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .matrix_mode, .a = mode });
}
fn glLoadIdentity(_: *anyopaque) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .load_identity });
}
fn glLoadMatrix(_: *anyopaque, m: *const [16]f32) callconv(.c) void {
    const s = glSlot() orelse return;
    const off = iscene.pushFloats(s, m);
    iscene.record(s, .{ .op = .load_matrix, .off = off, .n = 16 });
}
fn glMultMatrix(_: *anyopaque, m: *const [16]f32) callconv(.c) void {
    const s = glSlot() orelse return;
    const off = iscene.pushFloats(s, m);
    iscene.record(s, .{ .op = .mult_matrix, .off = off, .n = 16 });
}
fn glRotate(_: *anyopaque, angle_deg: f32, x: f32, y: f32, z: f32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{
        .op = .rotate,
        .a = @bitCast(angle_deg),
        .b = @bitCast(x),
        .c = @bitCast(y),
        .d = @bitCast(z),
    });
}
fn glTranslate(_: *anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .translate, .a = @bitCast(x), .b = @bitCast(y), .c = @bitCast(z) });
}
fn glScale(_: *anyopaque, x: f32, y: f32, z: f32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .scale, .a = @bitCast(x), .b = @bitCast(y), .c = @bitCast(z) });
}
fn glColor(_: *anyopaque, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{
        .op = .color,
        .a = @bitCast(r),
        .b = @bitCast(g),
        .c = @bitCast(b),
        .d = @bitCast(a),
    });
}
fn glVertices(_: *anyopaque, xyz: [*]const f32, n: u32) callconv(.c) void {
    const s = glSlot() orelse return;
    // Bound before the copy: n is module-supplied.
    const take = @min(n, iscene.MAX_FLOATS / 3);
    const off = iscene.pushFloats(s, xyz[0 .. @as(usize, take) * 3]);
    iscene.record(s, .{ .op = .vertices, .off = off, .n = take });
    if (take != n) s.overflowed = true;
}
fn glNormals(_: *anyopaque, xyz: [*]const f32, n: u32) callconv(.c) void {
    const s = glSlot() orelse return;
    const take = @min(n, iscene.MAX_FLOATS / 3);
    const off = iscene.pushFloats(s, xyz[0 .. @as(usize, take) * 3]);
    iscene.record(s, .{ .op = .normals, .off = off, .n = take });
    if (take != n) s.overflowed = true;
}
fn glDrawArrays(_: *anyopaque, mode: u32, first: u32, nverts: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .draw_arrays, .a = mode, .b = first, .c = nverts });
}
fn glDrawElements(_: *anyopaque, mode: u32, idx: [*]const u16, n: u32) callconv(.c) void {
    const s = glSlot() orelse return;
    const take = @min(n, iscene.MAX_INDICES);
    const off = iscene.pushIndices(s, idx[0..take]);
    iscene.record(s, .{ .op = .draw_elements, .a = mode, .off = off, .n = take });
    if (take != n) s.overflowed = true;
}
fn glClearColor(_: *anyopaque, r: f32, g: f32, b: f32, a: f32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{
        .op = .clear_color,
        .a = @bitCast(r),
        .b = @bitCast(g),
        .c = @bitCast(b),
        .d = @bitCast(a),
    });
}
fn glDepthFunc(_: *anyopaque, func: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .depth_func, .a = func });
}
fn glFrontFace(_: *anyopaque, mode: u32) callconv(.c) void {
    iscene.record(glSlot() orelse return, .{ .op = .front_face, .a = mode });
}
fn glEndFrame(_: *anyopaque) callconv(.c) void {
    const win = gl_target orelse return;
    gl_target = null;
    // This wait IS the frame pacing: the compositor takes one frame per present.
    // Bounded — a dead desktop drops the frame instead of wedging the core.
    const deadline = timer.millis() + GL_FRAME_TIMEOUT_MS;
    while (!iscene.canPublish(win)) {
        if (sched.cancelled() or timer.millis() >= deadline) {
            iscene.resetSlot(iscene.recording(win));
            return;
        }
        sched.yieldPeriodic();
    }
    iscene.publish(win);
}

const gl_vtable = abi.GlApi{
    .version = 1,
    .frame = glFrame,
    .enable = glEnable,
    .disable = glDisable,
    .matrix_mode = glMatrixMode,
    .load_identity = glLoadIdentity,
    .load_matrix = glLoadMatrix,
    .mult_matrix = glMultMatrix,
    .rotate = glRotate,
    .translate = glTranslate,
    .scale = glScale,
    .color = glColor,
    .vertices = glVertices,
    .normals = glNormals,
    .draw_arrays = glDrawArrays,
    .draw_elements = glDrawElements,
    .clear_color = glClearColor,
    .depth_func = glDepthFunc,
    .front_face = glFrontFace,
    .end_frame = glEndFrame,
};

// ── Interface.task — what runs; features may spawn and stop ────────────────────

fn taskCount(_: *anyopaque) callconv(.c) u32 {
    return @intCast(taskstat.snapshotAll());
}

fn taskAt(_: *anyopaque, i: u32, out: *abi.TaskInfo) callconv(.c) bool {
    const t = taskstat.rowAt(i) orelse return false;
    out.* = .{
        .state = switch (t.state) {
            .running => abi.TASK_RUNNING,
            .runnable => abi.TASK_READY,
            .blocked => abi.TASK_BLOCKED,
            .dead => abi.TASK_DONE,
        },
        .core = t.core,
        .cpu_ms = t.cpu_ms,
        .current = @intFromBool(t.is_current),
    };
    return true;
}

fn taskLabel(_: *anyopaque, i: u32, out: [*]u8, cap: usize) callconv(.c) isize {
    const t = taskstat.rowAt(i) orelse return -1;
    const name = t.nameSlice();
    const n = @min(name.len, cap);
    @memcpy(out[0..n], name[0..n]);
    return @intCast(n);
}

fn taskSelfCore(_: *anyopaque) callconv(.c) u32 {
    return @intCast(percpu.indexOrZero());
}

const task_vtable = abi.TaskApi{
    .version = 1,
    .count = taskCount,
    .at = taskAt,
    .label = taskLabel,
    .self_core = taskSelfCore,
};

// ── Interface.taskctl — placing work on the machine (features) ─────────────────

fn taskSpawn(_: *anyopaque, name: [*]const u8, name_len: usize) callconv(.c) u32 {
    return apprun.spawnModule(name[0..name_len]);
}

fn taskStop(_: *anyopaque, id: u32) callconv(.c) bool {
    return apprun.stopSpawned(id);
}

const taskctl_vtable = abi.TaskCtlApi{
    .version = 1,
    .spawn = taskSpawn,
    .stop = taskStop,
};

// ── Interface.desk — the desktop, for feature modules ─────────────────────────

fn deskWindow(_: *anyopaque, action: u32, needle: [*]const u8, needle_len: usize) callconv(.c) bool {
    const act: idesk.Action = switch (action) {
        abi.DESK_FOCUS => .focus,
        abi.DESK_MAXIMISE => .maximise,
        abi.DESK_MINIMISE => .minimise,
        abi.DESK_RESTORE => .restore,
        abi.DESK_CLOSE => .close,
        else => return false,
    };
    return idesk.postAction(act, needle[0..needle_len]);
}

fn deskWindows(_: *anyopaque, out: [*]u8, cap: usize) callconv(.c) usize {
    const text = idesk.windows();
    const n = @min(text.len, cap);
    @memcpy(out[0..n], text[0..n]);
    return n;
}

const desk_vtable = abi.DeskApi{
    .version = 1,
    .window = deskWindow,
    .windows = deskWindows,
};

// ── Interface.guests — the machine's virtual machines, for feature modules ────

fn guestsCount(_: *anyopaque) callconv(.c) u32 {
    return ivirt.MAX_VMS;
}

fn guestsState(_: *anyopaque, id: u32) callconv(.c) u32 {
    if (id >= ivirt.MAX_VMS) return abi.GUEST_ABSENT;
    return switch (ivirt.state(id)) {
        .absent => abi.GUEST_ABSENT,
        .fetching => abi.GUEST_FETCHING,
        .booting => abi.GUEST_BOOTING,
        .running => abi.GUEST_RUNNING,
        .halted => abi.GUEST_HALTED,
        .failed => abi.GUEST_FAILED,
    };
}

fn guestsRequestStop(_: *anyopaque, id: u32) callconv(.c) void {
    if (id >= ivirt.MAX_VMS) return;
    ivirt.requestStop(id);
}

const guests_vtable = abi.GuestsApi{
    .version = 1,
    .count = guestsCount,
    .state = guestsState,
    .request_stop = guestsRequestStop,
};

// ── Interface.metrics — read-only machine figures ─────────────────────────────

fn metricsFrameStats(_: *anyopaque, out: *abi.FrameStats) callconv(.c) bool {
    const s = iaccel.frame_stats;
    out.* = .{
        .seq = s.seq,
        .fps = s.fps,
        .pump_avg_us = s.pump_avg_us,
        .pump_max_us = s.pump_max_us,
        .inputs_per_s = s.inputs_per_s,
    };
    // seq 0 means the present loop has never written a sample: report absence
    // rather than a machine holding zero frames a second.
    return s.seq != 0;
}

fn metricsCounterCount(_: *anyopaque) callconv(.c) u32 {
    return @intCast(counter.all().len);
}

/// A counter's full key, spelled the one way the machine spells it —
/// `<subsystem>.<name>`, as `stats` prints it and the trace emits it.
fn counterKey(c: *const counter.Counter, buf: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ @tagName(c.mod), c.name }) catch null;
}

fn metricsCounterName(_: *anyopaque, i: u32, out: [*]u8, cap: usize) callconv(.c) isize {
    const all = counter.all();
    if (i >= all.len) return -1;
    var buf: [abi.METRICS_NAME_MAX]u8 = undefined;
    const key = counterKey(all[i], &buf) orelse return -1;
    const n = @min(key.len, cap);
    @memcpy(out[0..n], key[0..n]);
    return @intCast(n);
}

fn metricsCounter(_: *anyopaque, name: [*]const u8, name_len: usize, out: *u64) callconv(.c) bool {
    const want = name[0..name_len];
    var buf: [abi.METRICS_NAME_MAX]u8 = undefined;
    for (counter.all()) |c| {
        const key = counterKey(c, &buf) orelse continue;
        if (std.mem.eql(u8, key, want)) {
            out.* = c.v;
            return true;
        }
    }
    // A subsystem that published no counter and a counter reading zero are
    // different answers (iface/idevices.zig's rule), so a miss is false, not 0.
    return false;
}

const metrics_vtable = abi.MetricsApi{
    .version = 1,
    .frame_stats = metricsFrameStats,
    .counter_count = metricsCounterCount,
    .counter_name = metricsCounterName,
    .counter = metricsCounter,
};

comptime {
    for (grants.TABLE) |row| {
        // Granted but not defined: the agent's documentation is generated from
        // abi.CAPABILITIES, so this would be a capability a module is allowed to
        // bind and can never read about.
        var defined = false;
        for (abi.CAPABILITIES) |cap| {
            if (cap.id == row.id and cap.version == row.version) defined = true;
        }
        if (!defined) @compileError(
            "grants.zig publishes " ++ @tagName(row.id) ++
                " at a version abi.CAPABILITIES does not define",
        );
        // Granted but not delivered: `get` would refuse a request the table says
        // is allowed, and the refusal would look like a policy decision.
        if (vtableFor(@intFromEnum(row.id), row.version) == null) @compileError(
            "grants.zig publishes " ++ @tagName(row.id) ++
                " but vtableFor has no arm for it",
        );
    }
}
