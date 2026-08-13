//! The inet API facade: the network as applications reach it (iface/inet.zig).
//! Apps ask the network four questions — am I up, what is my address, where
//! does this name point, and fetch me this. Answering them means reaching
//! across net/tcp/http, which is why this seam sits at the group's top, over
//! the stack's PUBLIC surface — it owns no wire state of its own. Every entry
//! that pumps the NIC claims the stack first (NET-018); the steady loops skip
//! a claimed stack and keep rendering, which is why a request never stops the
//! desktop.

const std = @import("std");
const inet = @import("inet");
const job = @import("job"); // the shared named module (jobs.zig + fetchjob.zig too)
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const http = @import("http.zig");
const http_wire = @import("http_wire.zig");
const fetchjob = @import("fetchjob.zig");
const cfg = @import("config.zig");
const jobs = @import("../../../kernel/sched/jobs.zig");
const timer = @import("../../../kernel/timer/timer.zig");

fn vtBringUp(_: *anyopaque) bool {
    // init() blocks in DHCP and pumps the NIC — unclaimed, that is two drivers
    // on one stack the moment anything else is mid-request (NET-018). Busy
    // reads as "not up"; the caller retries.
    if (!net.claimStack()) return false;
    defer net.releaseStack();
    // The contract answers "is the network usable"; WHICH failure it was is
    // the stack's own trace to make, and it has already made it.
    net.init() catch return false;
    return true;
}
fn vtIsUp(_: *anyopaque) bool {
    return net.isUp();
}
fn vtLease(_: *anyopaque) inet.Lease {
    return .{
        .mac = cfg.our_mac,
        .ip = cfg.our_ip,
        .netmask = cfg.netmask,
        .gateway = cfg.gateway,
        .dns = cfg.dns_server,
    };
}
fn vtResolve(_: *anyopaque, host: []const u8) ?[4]u8 {
    // dnsResolve pumps RX for its answer; the claim keeps that off a stack
    // another task is driving (NET-018). Busy reads as unresolved — retry.
    if (!net.claimStack()) return null;
    defer net.releaseStack();
    return net.resolveHost(host);
}
fn vtPing(_: *anyopaque, dst: [4]u8, timeout_ms: u64) ?u64 {
    // ping() pumps RX for its reply — same rule as vtResolve.
    if (!net.claimStack()) return null;
    defer net.releaseStack();
    return net.ping(dst, timeout_ms);
}
fn vtFetch(_: *anyopaque, a: std.mem.Allocator, url: []const u8) inet.FetchError![]u8 {
    // One HTTP client (http.zig) serves both schemes; the URL's scheme selects
    // plain TCP vs TLS beneath it.
    if (!net.claimStack()) return error.Busy;
    defer net.releaseStack();
    return http.request(a, .GET, url, &.{}, "");
}

// ── backgrounded GET (a job.zig cooperative task) ─────────────────────────────
// One at a time: there is one TCP connection system-wide, and the command that
// starts a fetch returns immediately, so the state must outlive it — static, not
// on the caller's stack. The job runs on the session loop (jobs.pump), stepping
// the FetchJob over tcp.zig while net.pump grows the receive buffer, so the
// download advances a chunk per frame and the render never stalls.
// Background-GET request-head capacity. Smaller than the foreground client's
// http_wire.MAX_REQUEST_HEAD on purpose: this head is GET + Host only (no
// caller headers ride the background path), and the buffer is a static that
// lives for the whole session.
const BG_REQUEST_HEAD = 1024;
var bg_busy: bool = false;
var bg_fj: fetchjob.FetchJob = undefined;
var bg_req: [BG_REQUEST_HEAD]u8 = undefined;
var bg_ip: [4]u8 = undefined;
var bg_port: u16 = 0;
var bg_a: std.mem.Allocator = undefined;
var bg_cb: ?inet.FetchDone = null;
var bg_cb_ctx: *anyopaque = undefined;
var bg_seam: u8 = 0; // a non-null ctx for the seam fns (they use the statics)

fn bgStart(_: *anyopaque) bool {
    tcp.beginRecv(bg_a);
    return tcp.connectStart(bg_ip, bg_port);
}
fn bgPoll(_: *anyopaque) fetchjob.ConnState {
    return switch (tcp.connectState()) {
        .established => .established,
        .refused => .failed,
        .connecting => .connecting,
    };
}
fn bgSend(_: *anyopaque, bytes: []const u8) bool {
    return tcp.send(bytes);
}
fn bgReceived(_: *anyopaque) []const u8 {
    return tcp.received();
}
fn bgReserve(_: *anyopaque, bytes: usize) bool {
    return tcp.reserveRecv(bytes);
}
fn bgClosed(_: *anyopaque) bool {
    return tcp.finished() or tcp.wasReset();
}
fn bgMillis(_: *anyopaque) u64 {
    return timer.millis();
}

fn bgFinish(_: *anyopaque, outcome: job.Step) void {
    const body: ?[]const u8 = if (outcome == .done) bg_fj.body else null;
    if (bg_cb) |cb| cb(bg_cb_ctx, body); // copies before we free the buffer
    tcp.close();
    bg_busy = false;
}

fn vtFetchBackground(_: *anyopaque, a: std.mem.Allocator, url: []const u8, cb_ctx: *anyopaque, on_done: inet.FetchDone) inet.FetchError!void {
    if (bg_busy) return error.Busy;
    if (!net.isUp()) return error.NoNetwork;
    const u = http_wire.parseUrl(url) catch return error.BadUrl;
    if (u.scheme == .https) return error.TlsFailed; // background HTTPS is a follow-on
    const ip = blk: {
        // resolveHost may put a DNS query on the wire and pump for the answer —
        // claimed, like every other pumping entry (NET-018). The job itself
        // needs no claim: it steps on the session loop, the steady driver.
        if (!net.claimStack()) return error.Busy;
        defer net.releaseStack();
        break :blk net.resolveHost(u.host) orelse return error.DnsFailed;
    };
    const head = http_wire.buildRequestHead(&bg_req, "GET", u.host, u.path, &.{}, 0) catch return error.UrlTooLong;
    bg_ip = ip;
    bg_port = u.port;
    bg_a = a;
    bg_cb = on_done;
    bg_cb_ctx = cb_ctx;
    bg_fj = .{
        .t = .{ .ctx = &bg_seam, .start = bgStart, .poll = bgPoll, .send = bgSend, .received = bgReceived, .reserve = bgReserve, .closed = bgClosed },
        .clock = .{ .ctx = &bg_seam, .millis = bgMillis },
        .request = head,
    };
    if (!jobs.submit(.{ .ctx = &bg_fj, .step = fetchjob.FetchJob.step, .finish = bgFinish })) return error.Busy;
    bg_busy = true;
}

fn vtFetchProgress(_: *anyopaque) ?inet.FetchProgress {
    if (!bg_busy) return null;
    const p = bg_fj.progress();
    return .{ .received = p.received, .total = p.total };
}

fn vtPost(_: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const inet.Header, body: []const u8) inet.FetchError![]u8 {
    // Same single client, POST verb: the caller's headers pass through verbatim
    // (NET-013); https URLs go over TLS transparently.
    if (!net.claimStack()) return error.Busy;
    defer net.releaseStack();
    return http.request(a, .POST, url, headers, body);
}

fn vtPostStream(_: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const inet.Header, body: []const u8, sink: inet.BodySink) inet.FetchError!void {
    // Same single client, streaming delivery: decoded body bytes reach the
    // sink as they arrive (NET-014 — server-sent events).
    //
    // The claim covers the WHOLE request, handshake to last byte, because every
    // global the request touches — the connection, the receive buffer, the TX
    // staging — is shared and none of it is locked. Holding it for the duration
    // is what lets the render loop skip the stack instead of racing it, so the
    // desktop keeps drawing while the agent waits on the network (NET-018).
    if (!net.claimStack()) return error.Busy;
    defer net.releaseStack();
    return http.requestStream(a, .POST, url, headers, body, sink);
}

const net_vtable = inet.VTable{
    .bringUp = vtBringUp,
    .isUp = vtIsUp,
    .lease = vtLease,
    .resolve = vtResolve,
    .ping = vtPing,
    .fetch = vtFetch,
    .post = vtPost,
    .postStream = vtPostStream,
    .fetchBackground = vtFetchBackground,
    .fetchProgress = vtFetchProgress,
};
// A stable non-null context: the stack's state is module-global, so the vtable ignores
// this — but `undefined` would be UB to pass around even unused.
var net_ctx: u8 = 0;

/// Publish the stack through `iface/inet.zig` so apps can use the network without
/// naming a driver. Called once at boot, before any app runs.
pub fn publish() void {
    net.registerCounters();
    inet.instance = .{ .ctx = @ptrCast(&net_ctx), .vt = &net_vtable };
}
