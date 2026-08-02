//! `run <name>` — load and execute a compiled `.kudos` app.
//!
//! Runs inline on THIS session's own task, inside the session's address space
//! (MOD-006): the image and the app's arena are carved from the session's
//! private region, so a stray pointer cannot reach another session (MEM-004)
//! and a fault kills only this session — the task dies, the window closes, the
//! core and every other session keep running (MEM-006, AGT-009, KRN-006).
//! Refused on the single-core build, which has no session spaces.
//!
//! The app reaches the system only through the `Api` built here (spec AGT-008):
//! output goes to this terminal, `cancelled` reflects the window closing, and
//! files resolve against /ramdisk.

const std = @import("std");
const Out = @import("../out.zig").Out;
const vfs = @import("vfs");
const iramdisk = @import("iramdisk");
const buildinfo = @import("buildinfo");
const sched = @import("../../kernel/sched/sched.zig");
const timer = @import("../../kernel/timer/timer.zig");
const runner = @import("../../kernel/loader/runner.zig");
const sessionspace = @import("../../kernel/memory/sessionspace.zig");
const interfaces = @import("../../kernel/loader/interfaces.zig");
const iwindow = @import("../../iface/iwindow.zig");
const abi = runner.abi;

/// How long `DrawApi.open` waits for the desktop to create the window before it
/// gives up and reports failure (handle 0) — a window request while one is
/// already live is refused, and the app must not spin forever on it.
const DRAW_OPEN_TIMEOUT_MS: u64 = 1000;

/// Reached through `Api.ctx` for the duration of one app run.
const RunState = struct {
    out: Out,
    arena: []u8,
    used: usize = 0,
    rng: u64,
};

fn st(p: *anyopaque) *RunState {
    return @ptrCast(@alignCast(p));
}

fn apiPrint(p: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void {
    st(p).out.str(s[0..len]);
}
fn apiPollKey(_: *anyopaque) callconv(.c) i32 {
    return -1; // input delivery to a running app is wired with the session key ring later
}
fn apiMillis(_: *anyopaque) callconv(.c) u64 {
    return timer.millis();
}
fn apiSleepMs(p: *anyopaque, ms: u64) callconv(.c) void {
    const deadline = timer.millis() + ms;
    while (timer.millis() < deadline) {
        if (sched.cancelled() or !st(p).out.alive()) return;
        sched.yieldPeriodic();
    }
}
fn apiYield(_: *anyopaque) callconv(.c) void {
    sched.yieldPeriodic();
}
fn apiCancelled(p: *anyopaque) callconv(.c) bool {
    return sched.cancelled() or !st(p).out.alive();
}
fn apiRand(p: *anyopaque) callconv(.c) u64 {
    const s = st(p);
    s.rng ^= s.rng << 13;
    s.rng ^= s.rng >> 7;
    s.rng ^= s.rng << 17;
    return s.rng;
}
fn apiAlloc(p: *anyopaque, n: usize, log2_align: u8) callconv(.c) ?[*]u8 {
    const s = st(p);
    const al = @as(usize, 1) << @intCast(log2_align);
    const base = std.mem.alignForward(usize, s.used, al);
    if (base + n > s.arena.len) return null;
    s.used = base + n;
    return s.arena.ptr + base;
}
fn ramName(path: []const u8) []const u8 {
    // Apps name files bare or as /ramdisk/<name>; store uses the bare name.
    const pfx = "/ramdisk/";
    return if (std.mem.startsWith(u8, path, pfx)) path[pfx.len..] else path;
}
fn apiFileRead(_: *anyopaque, path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) callconv(.c) isize {
    const rd = iramdisk.instance orelse return -1;
    const data = rd.get(ramName(path[0..path_len])) orelse return -1;
    const n = @min(data.len, cap);
    @memcpy(out[0..n], data[0..n]);
    return @intCast(n);
}
fn apiFileWrite(_: *anyopaque, path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) callconv(.c) bool {
    const rd = iramdisk.instance orelse return false;
    rd.put(ramName(path[0..path_len]), data[0..len]) catch return false;
    return true;
}
// The `draw` capability (Interface.draw): an app that binds it gets ONE bounded
// window and nothing else — vfs/net stay denied by interfaces.get below. open()
// parks the request on the cross-core mailbox and waits (yielding) for the desktop
// on core 0 to create the window and publish its handle; blit() hands the app's
// BGRA pixels across. Serving it to any app makes windowing opt-in by binding.
fn apiDrawOpen(p: *anyopaque, w: u32, h: u32) callconv(.c) u32 {
    iwindow.requestOpen(w, h);
    // Bounded wait: the desktop fulfils within a frame or two, but a second
    // window while one is live is refused (handle stays 0) — give up rather than
    // spin forever, so the app sees the failure and can exit.
    const deadline = timer.millis() + DRAW_OPEN_TIMEOUT_MS;
    while (iwindow.handle() == 0) {
        if (apiCancelled(p) or timer.millis() >= deadline) return 0;
        sched.yieldPeriodic();
    }
    return iwindow.handle();
}
fn apiDrawBlit(_: *anyopaque, handle: u32, pixels: [*]const u32, w: u32, h: u32) callconv(.c) void {
    iwindow.blit(handle, pixels, w, h);
}
const draw_vtable = abi.DrawApi{
    .version = 1,
    .open = apiDrawOpen,
    .blit = apiDrawBlit,
};
fn apiGetInterface(_: *anyopaque, id: u32, version: u32) callconv(.c) ?*const anyopaque {
    if (id == @intFromEnum(abi.Interface.draw) and version == 1) return &draw_vtable;
    return interfaces.get(id, version); // vfs/net/everything else: deny
}

fn report(out: Out, e: anyerror) void {
    out.str("run: ");
    out.str(switch (e) {
        error.TooSmall => "not a .kudos file (too small)",
        error.BadMagic => "not a .kudos file (bad magic)",
        error.BadVersion => "built for a different ABI version",
        error.BadKind => "not an app image",
        error.BadLengths => "corrupt header",
        error.BadCrc => "corrupt image (bad checksum)",
        error.WrongKind => "not an app (it is a feature)",
        error.ImageTooSmall => "internal: image buffer too small",
        else => "load failed",
    });
    out.str("\n");
}

pub fn run(out: Out, args: []const u8) void {
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0) {
        out.str("usage: run <name>\n");
        return;
    }

    // Fault containment needs a session address space (see file header).
    if (!buildinfo.smp) {
        out.str("run: needs the SMP build so a crash is contained to this session\n");
        return;
    }
    const sid = sessionspace.currentSessionId() orelse {
        out.str("run: not on a session task (no address space to contain a crash)\n");
        return;
    };

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        out.str("run: name too long\n");
        return;
    };
    const blob = vfs.read(path) orelse {
        out.str("run: no such app: ");
        out.str(name);
        out.str("\n");
        return;
    };

    const mem_len = runner.imageSize(blob) catch |e| return report(out, e);

    // Image and arena both come from the SESSION's private region (MOD-006) —
    // one run at a time per session (the shell is synchronous), so the region
    // is simply carved front-to-back: image first (16-aligned, SSE-safe for the
    // app's own aligned data), the app arena after it.
    const region = sessionspace.moduleRegion(sid);
    const image_base = std.mem.alignForward(usize, @intFromPtr(region.ptr), 16);
    const image_off = image_base - @intFromPtr(region.ptr);
    if (image_off + mem_len + abi.APP_ARENA_MAX_BYTES > region.len) {
        out.str("run: app image too large for the session's private region\n");
        return;
    }
    const image = @as([*]u8, @ptrFromInt(image_base))[0..mem_len];
    const arena = region[image_off + mem_len ..][0..abi.APP_ARENA_MAX_BYTES];

    const entry = runner.loadApp(blob, image) catch |e| return report(out, e);

    var state = RunState{ .out = out, .arena = arena, .rng = timer.now() | 1 };
    const api = abi.Api{
        .version = abi.ABI_VERSION,
        .ctx = &state,
        .print = apiPrint,
        .poll_key = apiPollKey,
        .millis = apiMillis,
        .sleep_ms = apiSleepMs,
        .yield = apiYield,
        .cancelled = apiCancelled,
        .rand = apiRand,
        .alloc = apiAlloc,
        .file_read = apiFileRead,
        .file_write = apiFileWrite,
        .get_interface = apiGetInterface,
    };

    const rc = entry(&api);
    // If the app opened a window, tell the desktop to close it now that the app
    // has returned — its arena (and any buffer the desktop owns for it) is gone.
    iwindow.requestClose();
    var buf: [32]u8 = undefined;
    out.str(std.fmt.bufPrint(&buf, "\n[exit {d}]\n", .{rc}) catch "\n");
}
