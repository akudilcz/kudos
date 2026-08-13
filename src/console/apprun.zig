//! Running a `.kudos` app: the `Api` an app image is called through, and the
//! two ways kudos runs one.
//!
//! ONE implementation of the base `Api` (spec AGT-008), because there are two
//! callers and they must not drift: `run <name>` typed in a terminal, which
//! executes the image on that session's own task, and the agent's run_app tool,
//! which has no terminal behind it — it starts a session of its own and captures
//! what the image printed as the tool result.
//!
//! Everything beyond the base `Api` — the capabilities a module binds with
//! `get_interface` — belongs to `capabilities.zig`; this file only chooses a
//! grant. What untrusted code may reach must not be editable from the code that
//! starts it.
//!
//! Both run the image in a SESSION ADDRESS SPACE (MOD-006): the image and the
//! app's arena are carved from that session's private region, so a stray pointer
//! cannot reach another session (MEM-004) and a fault kills only that session's
//! task (MEM-006, AGT-009, KRN-006). The single-core build has no session spaces,
//! so it runs no app image at all.

const std = @import("std");
const Out = @import("out.zig").Out;
const capabilities = @import("capabilities.zig");
const counter = @import("../kernel/debug/counter.zig");
const iramdisk = @import("iramdisk");
const vfs = @import("vfs");
const iwindow = @import("iwindow");
const runner = @import("../kernel/loader/runner.zig");
const sched = @import("../kernel/sched/sched.zig");
const sessionspace = @import("../kernel/memory/sessionspace.zig");
const timer = @import("../kernel/timer/timer.zig");

pub const abi = runner.abi;

/// Why an image could not be run. `runner.LoadError` covers the image itself;
/// the extra case is about the room it was offered.
pub const Error = runner.LoadError || error{
    /// The private region cannot hold this image plus the app's arena.
    RegionTooSmall,
};

/// One sentence for each way a run can be refused — the one home for the
/// wording, so the terminal and the agent report a bad image identically.
pub fn reason(e: anyerror) []const u8 {
    return switch (e) {
        error.TooSmall => "not a .kudos file (too small)",
        error.BadMagic => "not a .kudos file (bad magic)",
        error.BadVersion => "built for a different ABI version",
        error.BadKind => "not an app image",
        error.BadLengths => "corrupt header",
        error.BadCrc => "corrupt image (bad checksum)",
        error.WrongKind => "not an app (it is a feature)",
        error.ImageTooSmall => "internal: image buffer too small",
        error.RegionTooSmall => "app image too large for the session's private region",
        else => "load failed",
    };
}

// ── the Api an app image runs against ────────────────────────────────────────

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
    // Keys come from whichever of the module's windows has focus (MOD-013) —
    // never the terminal's own stream, which belongs to the shell behind it. A
    // module with no window has nothing addressed to it.
    var i: u32 = 0;
    const n = iwindow.count();
    while (i < n) : (i += 1) {
        const h = iwindow.at(i);
        if (!iwindow.focused(h)) continue;
        if (iwindow.popKey(h)) |k| return @as(i32, k);
    }
    return -1;
}
fn apiMillis(_: *anyopaque) callconv(.c) u64 {
    return timer.millis();
}
fn apiSleepMs(p: *anyopaque, ms: u64) callconv(.c) void {
    const deadline = timer.millis() + ms;
    while (timer.millis() < deadline) {
        if (apiCancelled(p)) return;
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
    // Apps name files bare or as /ramdisk/<name>; the store uses the bare name.
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

/// Which grant a run is started under. What each grant may bind is decided in
/// `console/capabilities.zig`, not here.
pub const Options = struct {
    /// Whether a terminal is watching this run. The agent's contained run has
    /// none; a detached run has none either but is reaped by the pump, so both
    /// may own windows — the difference is who is there to see the output.
    windowed: bool,
};

/// Load `blob` into `region` and run it, returning the app's exit code.
///
/// `region` is the calling session's private memory and is carved front to
/// back: the image first (16-aligned, so the app's own aligned data is SSE-safe),
/// the app's arena after it. One run at a time per region — both callers are
/// synchronous, so the carve needs no allocator.
pub fn execute(out: Out, blob: []const u8, region: []u8, opts: Options) Error!i32 {
    const mem_len = try runner.imageSize(blob);
    const image_base = std.mem.alignForward(usize, @intFromPtr(region.ptr), 16);
    const image_off = image_base - @intFromPtr(region.ptr);
    if (image_off + mem_len + abi.APP_ARENA_MAX_BYTES > region.len) return Error.RegionTooSmall;
    const image = @as([*]u8, @ptrFromInt(image_base))[0..mem_len];
    const arena = region[image_off + mem_len ..][0..abi.APP_ARENA_MAX_BYTES];

    const entry = try runner.loadApp(blob, image);

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
        .get_interface = if (opts.windowed) capabilities.appTerminal else capabilities.appHeadless,
    };

    const rc = entry(&api);
    // Every window the module still owns goes now: its arena is gone, so nothing
    // can fill them again.
    var i = iwindow.count();
    while (i > 0) {
        i -= 1;
        iwindow.requestClose(iwindow.at(i));
    }
    return rc;
}

// ── a contained run: an image in a session of its own ────────────────────────

/// How a contained run gets an address space to run in. The session layer
/// (console/session.zig) owns the slot table and publishes this at boot;
/// this module is BELOW it — the loader side of a run — so it is handed the
/// capability rather than reaching up for it.
pub const Sandbox = struct {
    ctx: *anyopaque,
    /// Claim a private space and start `entry` on a task inside it. Returns the
    /// space's id, or null when no slot is free or the space could not be built.
    start: *const fn (ctx: *anyopaque, name: []const u8, entry: *const fn () void) ?u32,
    /// Stop the task if it is still running, wait for it to be reaped, and give
    /// the space back. False when the task never retired (see `stuck` below).
    finish: *const fn (ctx: *anyopaque, id: u32) bool,
};

/// Published once at boot on the SMP build; null on the single-core build,
/// which has no session spaces to contain a run in.
pub var sandbox: ?Sandbox = null;

/// Cap on what one contained run's output contributes to the caller's result:
/// a chatty app must not burn the agent's whole token budget. Overflow is
/// truncated LOUDLY (`Result.truncated`), never silently dropped.
pub const MAX_OUTPUT_BYTES: usize = 8 * 1024;

/// How long a contained run may take before the app is told to stop. Long
/// enough for real compute, short enough that a wedged image does not hold the
/// caller (the agent, mid-conversation) for a noticeable pause.
pub const RUN_BUDGET_MS: u64 = 10_000;

pub const RunError = Error || error{
    /// This build has no session spaces (single-core), so nothing can contain a run.
    NoSandbox,
    /// Every session slot is taken, or the space could not be built.
    NoSession,
    /// A contained run is already in flight, or a previous one is stuck (below).
    Busy,
};

pub const Result = struct {
    /// The app's return value.
    rc: i32,
    /// What the app printed (into this module's buffer; valid until the next run).
    output: []const u8,
    /// Whether output was cut at MAX_OUTPUT_BYTES.
    truncated: bool,
    /// Whether the budget ran out before the app returned.
    timed_out: bool,
};

// The one in-flight contained run. Static because the task that runs the image
// is started by the scheduler and reaches its parameters through no argument of
// its own; single-slot because `busy` refuses a second one — the callers are
// synchronous, and two runs would need two capture buffers anyway.
const Run = struct {
    blob: []const u8 = &.{},
    buf: [MAX_OUTPUT_BYTES]u8 = undefined,
    len: usize = 0,
    truncated: bool = false,
    /// Set by the caller when the budget expires: the app sees it through
    /// `Api.cancelled` (via `Out.alive`) and stops.
    expired: bool = false,
    /// Set by the run task when it is done; the caller reads nothing until then.
    done: bool = false,
    rc: i32 = 0,
    err: ?RunError = null,
};
var run: Run = .{};

/// Whether a contained run is in flight (or stuck).
var busy: bool = false;

/// A run whose task never retired — its image may still be executing and still
/// writing into the capture buffer, so this module cannot lend that buffer out
/// again. One runaway app costs the machine its ability to run another until
/// reboot, and says so, rather than corrupting the next run's output.
var stuck: bool = false;

fn captureAlive(_: *anyopaque) bool {
    return !@atomicLoad(bool, &run.expired, .acquire);
}

fn capturePut(_: *anyopaque, ch: u8) void {
    const n = @atomicLoad(usize, &run.len, .acquire);
    if (n == run.buf.len) {
        @atomicStore(bool, &run.truncated, true, .release);
        return;
    }
    run.buf[n] = ch;
    // Release AFTER the byte: a reader that sees this length sees the bytes.
    @atomicStore(usize, &run.len, n + 1, .release);
}

var capture_ctx: u8 = 0;

fn captureOut() Out {
    return .{ .ctx = &capture_ctx, .putFn = capturePut, .aliveFn = captureAlive };
}

/// The contained run's task: it is the session's own task, so the space it runs
/// in IS its identity (the same way `run` finds its region — MOD-006).
fn runTask() void {
    const id = sessionspace.currentSessionId() orelse {
        run.err = RunError.NoSession;
        @atomicStore(bool, &run.done, true, .release);
        return;
    };
    if (execute(captureOut(), run.blob, sessionspace.moduleRegion(id), .{ .windowed = false })) |rc| {
        run.rc = rc;
    } else |e| {
        run.err = e;
    }
    @atomicStore(bool, &run.done, true, .release);
}

/// Run `blob` in a session of its own and return what it printed and returned.
/// The caller is not on that session's task, so a fault in the image kills the
/// run, not the caller (MEM-006) — which is the whole reason the agent may
/// execute code it just had compiled.
pub fn runContained(blob: []const u8, budget_ms: u64) RunError!Result {
    const sb = sandbox orelse return RunError.NoSandbox;
    if (busy or stuck) return RunError.Busy;
    busy = true;
    defer busy = false;

    run.blob = blob;
    run.len = 0;
    run.truncated = false;
    run.expired = false;
    run.done = false;
    run.rc = 0;
    run.err = null;

    const id = sb.start(sb.ctx, "kudosapp", runTask) orelse return RunError.NoSession;

    const deadline = timer.millis() + budget_ms;
    while (!@atomicLoad(bool, &run.done, .acquire)) {
        if (timer.millis() >= deadline) {
            // Tell the image to stop; a cooperative one returns and is reaped,
            // and `finish` below waits for that. One that never looks is what
            // `stuck` is for.
            @atomicStore(bool, &run.expired, true, .release);
            break;
        }
        sched.yield();
    }
    const timed_out = !@atomicLoad(bool, &run.done, .acquire);
    if (!sb.finish(sb.ctx, id)) stuck = true;

    if (run.err) |e| return e;
    return .{
        .rc = run.rc,
        .output = run.buf[0..@atomicLoad(usize, &run.len, .acquire)],
        .truncated = @atomicLoad(bool, &run.truncated, .acquire),
        .timed_out = timed_out,
    };
}

// ── a detached windowed run: an image that outlives its caller ───────────────
//
// The agent's contained run is synchronous and budgeted (RUN_BUDGET_MS), which
// is right for a program whose OUTPUT is the answer — and wrong for one whose
// WINDOW is the answer: a visualisation is not "done" in ten seconds, it runs
// until the person watching closes it. A detached run starts the image on a
// session task of its own and returns; its windows are then the app's lifeline —
// closing them cancels the run (`Api.cancelled` and `WindowApi.closed` both go
// true), and the pump reaps the session once the image returns. ONE detached run
// at a time (SPAWN_ID), however many windows it holds.

/// Bytes the detached run's image may occupy. Its own copy — the caller's blob
/// is a ramdisk file a later `compile` may replace under a still-running app.
const DETACHED_BLOB_MAX: usize = 512 * 1024;

const Detached = struct {
    buf: [DETACHED_BLOB_MAX]u8 = undefined,
    len: usize = 0,
    session: u32 = 0,
    /// Set by the run task as its last act; the pump reaps on seeing it.
    done: bool = false,
    /// Bytes the image printed with nobody to read them — counted, not silent.
    dropped: u64 = 0,
    /// The run once had a window; a zero handle after this means it was closed.
    had_window: bool = false,
};
var detached: Detached = .{};
var detached_active: bool = false;

var cnt_detached_dropped = counter.Counter{ .mod = .ui, .name = "blobwin.out_dropped" };

fn detachedAlive(_: *anyopaque) bool {
    // Windows ARE the liveness signal: once the module has opened one, its
    // windows all closing is the person saying stop. Before the first one the
    // run is simply alive (it may be computing its first frame).
    if (iwindow.count() != 0) {
        detached.had_window = true;
        return true;
    }
    return !detached.had_window;
}

fn detachedPut(_: *anyopaque, ch: u8) void {
    _ = ch;
    // Nothing reads a detached run's prints — there is no terminal behind it and
    // no tool result waiting. Dropped LOUDLY: the counter is the evidence.
    detached.dropped += 1;
    cnt_detached_dropped.inc();
}

var detached_out_ctx: u8 = 0;

fn detachedTask() void {
    const id = sessionspace.currentSessionId() orelse {
        @atomicStore(bool, &detached.done, true, .release);
        return;
    };
    const out = Out{ .ctx = &detached_out_ctx, .putFn = detachedPut, .aliveFn = detachedAlive };
    _ = execute(out, detached.buf[0..detached.len], sessionspace.moduleRegion(id), .{ .windowed = true }) catch {};
    @atomicStore(bool, &detached.done, true, .release);
}

/// Start `blob` detached, with the window grant. Returns once the task is
/// started — the window arrives when the image asks for one.
pub fn startWindowed(blob: []const u8) RunError!void {
    const sb = sandbox orelse return RunError.NoSandbox;
    if (detached_active) return RunError.Busy;
    if (blob.len > DETACHED_BLOB_MAX) return RunError.RegionTooSmall;
    // Verify EAGERLY, so the caller hears "bad image" now rather than a window
    // that never appears.
    _ = try runner.imageSize(blob);
    counter.register(&cnt_detached_dropped); // idempotent
    @memcpy(detached.buf[0..blob.len], blob);
    detached.len = blob.len;
    detached.done = false;
    detached.dropped = 0;
    detached.had_window = false;
    detached.session = sb.start(sb.ctx, "kudoswin", detachedTask) orelse return RunError.NoSession;
    detached_active = true;
}

/// Reap a finished detached run (the pump calls this on the steady loop): give
/// the session back once the image has returned. Nothing to reap is a no-op.
pub fn reapWindowed() void {
    if (!detached_active) return;
    if (!@atomicLoad(bool, &detached.done, .acquire)) return;
    const sb = sandbox orelse return;
    _ = sb.finish(sb.ctx, detached.session);
    detached_active = false;
}

/// The spawn id `TaskApi` hands out. There is one detached slot, so there is one
/// id; it is non-zero because 0 means "refused".
pub const SPAWN_ID: u32 = 1;

/// Run compiled module `name` (a `/ramdisk/<name>.kudos`) detached — what
/// `TaskApi.spawn` calls. Returns SPAWN_ID, or 0 on any refusal.
pub fn spawnModule(name: []const u8) u32 {
    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch return 0;
    const blob = vfs.read(path) orelse return 0;
    startWindowed(blob) catch return 0;
    return SPAWN_ID;
}

/// Ask the spawned module to stop — what `TaskApi.stop` calls. The run observes
/// it through `Api.cancelled`; the pump reaps the session when it returns.
pub fn stopSpawned(id: u32) bool {
    if (id != SPAWN_ID or !detached_active) return false;
    detached.had_window = true; // makes detachedAlive false once no window is live
    iwindow.reset();
    return true;
}
