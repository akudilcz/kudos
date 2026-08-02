//! netdebug transport glue: stateless UDP
//! request/response on port 9515 — ramdisk mirror, remote input injection,
//! and screenshot triggers. The entire protocol logic is fileproto.buildReply
//! (pure, host-tested over the iramdisk + Inject seams); this file adds only
//! the RX slot, the real injection sink, and unicast TX.
//!
//! RX/TX split: `handleUdp` (called inside net.pump()'s demux) only COPIES
//! the request into a small ring (the host's pipelined pull keeps a window
//! of requests in flight — PERF-013); a full ring drops and the host
//! retransmits. `service()` (called from the same
//! steady loops as netdebug.drain()) sends the reply via unicast sendIp —
//! never from inside the RX path, because sendIp's ARP wait re-enters
//! net.pump() and the shared txpkt staging must not be clobbered (net.zig
//! ctrlpkt precedent).

const std = @import("std");
const net = @import("../stack/net.zig");
const fileproto = @import("fileproto");
const iramdisk = @import("iramdisk");
const keyboard = @import("../../input/keyboard.zig");
const imouse = @import("imouse");

/// KMR1 requests that reached this server (counted before the busy/parse
/// filters). Together with net.rx.frames this forks a "KMR1 went deaf"
/// report: rx.frames frozen = the NIC ring; rx climbing + this frozen = the
/// UDP demux; both climbing = the reply/TX side.
var cnt_reqs = counter.Counter{ .mod = .net, .name = "kmr1.reqs" };
/// Requests dropped because the intake ring was full — the signature of
/// service() starving while a pipelined pull keeps the window full.
var cnt_busy_drops = counter.Counter{ .mod = .net, .name = "kmr1.busy_drops" };
/// service() entries — the other half of the starvation fork: reqs climbing
/// with this frozen names the loop that pumps the net but never services.
var cnt_service = counter.Counter{ .mod = .net, .name = "kmr1.service" };
/// Reply outcomes, one counter per exit: sent onto the wire, request produced
/// no reply (buildReply == 0), or the unicast send itself failed. With these,
/// "the host hears nothing" is attributable to exactly one stage — or proven
/// to be a HOST-side problem.
var cnt_reply_sent = counter.Counter{ .mod = .net, .name = "kmr1.reply_sent" };
var cnt_reply_none = counter.Counter{ .mod = .net, .name = "kmr1.reply_none" };
var cnt_reply_senderr = counter.Counter{ .mod = .net, .name = "kmr1.reply_senderr" };
const tsc = @import("../../../kernel/cpu/tsc.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const power = @import("../../../kernel/power/reboot.zig");
const xhci = @import("../../usb/xhci.zig");
const dbg = @import("../../../kernel/debug/debug.zig");
const klog = @import("../../../kernel/debug/klog.zig");
const counter = @import("../../../kernel/debug/counter.zig");
const netdebug = @import("netdebug.zig");
const buildinfo = @import("buildinfo");

/// The largest request is a WRITE: header + name (u16 len, ≤ 64 used) +
/// MAX_CHUNK of data. Anything bigger is a protocol violation and dropped.
const REQ_CAP: usize = fileproto.HDR_LEN + 2 + 64 + fileproto.MAX_CHUNK;

var fs: ?iramdisk.IRamdisk = null;
/// One parked request. The intake is a RING, not a 1-deep slot: the host's
/// pipelined file pull keeps up to 16 requests in flight (kmir READ_WINDOW,
/// spec PERF-013), and a single slot busy-dropped 15 of every 16 — sustained
/// pressure could exhaust all 8 host retries for one chunk. service() drains
/// far faster than requests arrive; the ring only has to absorb the burst.
const Req = struct {
    buf: [REQ_CAP]u8 = undefined,
    len: usize = 0,
    src: [4]u8 = undefined,
    sport: u16 = 0,
};
/// Ring depth: the host window (16) doubled, so a full window plus its
/// retransmitted twins still parks without a drop.
const REQ_QUEUE_DEPTH: usize = 32;
var req_ring: [REQ_QUEUE_DEPTH]Req = .{Req{}} ** REQ_QUEUE_DEPTH;
var req_head: usize = 0; // consume (service)
var req_tail: usize = 0; // produce (handleUdp); empty when head == tail
fn ringCount() usize {
    return (req_tail + REQ_QUEUE_DEPTH - req_head) % REQ_QUEUE_DEPTH;
}

/// Wire the file-system seam (main_root.zig, once, after ramdisk.init).
pub fn init(the_fs: iramdisk.IRamdisk) void {
    // Claim our port. The stack does not know we exist until we say so.
    net.listenUdp(fileproto.PORT, handleUdp);
    counter.register(&cnt_reqs);
    counter.register(&cnt_busy_drops);
    counter.register(&cnt_service);
    counter.register(&cnt_reply_sent);
    counter.register(&cnt_reply_none);
    counter.register(&cnt_reply_senderr);
    fs = the_fs;
}

/// RX hook (net.zig UDP demux, dport == fileproto.PORT). `p` starts at the
/// UDP header.
pub fn handleUdp(src: [4]u8, p: []const u8) void {
    cnt_reqs.inc();
    if (ringCount() == REQ_QUEUE_DEPTH - 1 or fs == null) {
        if (fs != null) cnt_busy_drops.inc(); // ring full: drop; host retries
        return;
    }
    if (p.len < net.UDP_HLEN + fileproto.HDR_LEN) return;
    const body = p[net.UDP_HLEN..];
    if (body.len > REQ_CAP) return;
    if (fileproto.parseHeader(body) == null) return;
    const r = &req_ring[req_tail];
    @memcpy(r.buf[0..body.len], body);
    r.len = body.len;
    r.src = src;
    r.sport = net.rbe16(p[0..2]);
    // Whoever is driving us IS the trace collector — tell netdebug to unicast to them.
    // Broadcast trace is lossy over wifi (no 802.11 ack/retry): 8% of datagrams vanished
    // during a native test run, taking mirrored terminal lines with them.
    netdebug.collector = src;
    req_tail = (req_tail + 1) % REQ_QUEUE_DEPTH;
}

/// Screenshot trigger (netdebug SHOT + the boot auto-shot): the GPU session
/// loop polls this and runs screenshot.dump with its head context. Sticky
/// until consumed.
var shot_requested: bool = false;

/// Consume a pending SHOT request (GPU session loop).
pub fn takeShotRequest() bool {
    const r = shot_requested;
    shot_requested = false;
    return r;
}

/// Arm a screenshot capture from in-kernel callers (the agent's screen-capture
/// tool, spec AGT-006) — the same sticky flag the KMR1 SHOT sink raises, so the
/// GPU session loop services them identically.
pub fn requestShot() void {
    shot_requested = true;
}

/// A one-slot app-spawn request: the agent's application tool (AGT-006) cannot
/// call the desktop directly — the desktop sits ABOVE the console/agent in the
/// layering — so it parks a request here (this module is the remote-request
/// inbox the desktop's input loop already services, alongside injected keys and
/// the shot flag) and the desktop consumes it on its own core. One deep is
/// enough: a human-paced agent never queues two spawns a frame apart.
var spawn_request: [24]u8 = undefined;
var spawn_request_len: usize = 0;

/// Ask the desktop to open an application window by name (term, system, diag,
/// clock, calc, web, ai). Names the desktop does not know are ignored
/// there, loudly. Overwrites any unconsumed prior request.
pub fn requestSpawn(name: []const u8) void {
    const n = @min(name.len, spawn_request.len);
    @memcpy(spawn_request[0..n], name[0..n]);
    spawn_request_len = n;
}

/// Consume a pending app-spawn request (desktop input loop), or null.
pub fn takeSpawnRequest() ?[]const u8 {
    if (spawn_request_len == 0) return null;
    const n = spawn_request_len;
    spawn_request_len = 0;
    return spawn_request[0..n];
}

/// Injection dedup state (fileproto.Dedup; recorded on successful dispatch).
var dedup = fileproto.Dedup{};

/// The real injection sink: keystrokes into the keyboard driver, motion into
/// the mouse aggregator (TSC-stamped like a live HID report), SHOT into the
/// sticky flag above.
fn sinkKey(_: *anyopaque, ascii: u8, named: u8) void {
    keyboard.inject(.{
        .ascii = ascii,
        .key = switch (named) {
            fileproto.KEY_F1 => .f1,
            fileproto.KEY_F10 => .f10,
            fileproto.KEY_F12 => .f12,
            else => .none,
        },
    });
}
fn sinkMouse(_: *anyopaque, dx: i16, dy: i16, buttons: u8) void {
    imouse.aggregate(.{ .dx = dx, .dy = dy, .buttons = buttons, .t_tsc = tsc.rdtsc() });
}
/// Absolute placement — the same call the USB TABLET path makes (xhci's tablet handler),
/// so an injected pointer and a real absolute device land in exactly the same place. This
/// is what lets the integration suite's drags be pixel-exact on real hardware.
fn sinkMouseAbs(_: *anyopaque, x: i16, y: i16, buttons: u8) void {
    imouse.inject(.{ .dx = 0, .dy = 0, .buttons = buttons, .abs = .{ .x = x, .y = y }, .t_tsc = tsc.rdtsc() });
}
fn sinkShot(_: *anyopaque) void {
    shot_requested = true;
}

/// The agent registers this to serve MCP over netdebug (AGT-011/AGT-013): it
/// runs one JSON-RPC request against the tool registry and writes the response
/// into fileproto.MCP_RESPONSE_FILE on the ramdisk. A hook, not an import — the
/// agent's registry lives ABOVE this transport in the layering, so the console
/// wires it in at init (same shape as the heap fail-log / power flush hooks).
pub var mcp_handler: ?*const fn (body: []const u8) void = null;

/// Wire the MCP request handler (console/agent, once at init).
pub fn setMcpHandler(h: *const fn (body: []const u8) void) void {
    mcp_handler = h;
}

fn sinkMcp(_: *anyopaque, body: []const u8) void {
    if (mcp_handler) |h| h(body);
}

/// Deferred power actions. buildReply must NOT act inline — the ACK it returns has
/// not been transmitted yet at that point, so acting there means the host never
/// learns the command took and retransmits into a machine that is already gone.
/// service() sends the reply, then acts once the grace period below has elapsed.
///
/// The grace period exists because the ACK is a single UDP datagram: if it is lost,
/// the host's retransmit needs a machine that is still alive to answer it. Five
/// seconds is several retries' worth, and it also gives the netdebug FIFO time to
/// drain the last records onto the wire — the ones that say what we did and why.
const ACTION_GRACE_MS: u64 = 5_000;

const Action = enum { none, reboot, shutdown };
var action: Action = .none;
var action_deadline_tsc: u64 = 0;

fn armAction(a: Action) void {
    // First request wins: a retransmitted REBOOT must not keep pushing the deadline
    // out (dedup already suppresses re-dispatch, but a host that changes request_id
    // on retry would otherwise defer the reset forever).
    if (action != .none) return;
    action = a;
    action_deadline_tsc = tsc.rdtsc() +% tsc.msTicks(ACTION_GRACE_MS);
}

fn sinkReboot(_: *anyopaque) void {
    armAction(.reboot);
}

fn sinkShutdown(_: *anyopaque) void {
    armAction(.shutdown);
}

/// The PING status line: everything a host needs to judge "is this kudos healthy"
/// in one datagram, at 1 Hz.
///
/// `ticks` is the IRQ0 counter, and it is the field that earns this datagram. Compared
/// against the host's own wall clock, a frozen tick beside a still-arriving reply says
/// something no other signal can: INTERRUPTS ARE DEAD, BUT THE CPU IS ALIVE. Without it
/// that state is indistinguishable from a wedged machine, and the two need opposite
/// responses.
var pings: u64 = 0;

/// How many PINGs this kudos has answered (the heartbeat run reports it, so the
/// two sides of the request/response pair can be reconciled).
pub fn pingCount() u64 {
    return pings;
}

fn sinkStatus(_: *anyopaque, out: []u8) []const u8 {
    pings += 1;
    const u = xhci.deviceStatus();
    // kbd/mouse/usbdisk are PRESENCE (enumerated + a driver bound); kbd_rep/mouse_rep
    // are the live report counters. Both matter: a keyboard that enumerates and then
    // never reports is a different bug from one that never enumerates, and only the
    // counters moving proves the interrupt path is actually delivering.
    return std.fmt.bufPrint(out, "build={d} up_ms={d} ticks={d} usbdev={d} kbd={d} mouse={d} usbdisk={d} kbd_rep={d} mouse_rep={d}{s}{s}", .{
        buildinfo.build_number,
        timer.millis(),
        timer.now(),
        u.devices,
        @intFromBool(u.keyboard),
        @intFromBool(u.mouse),
        @intFromBool(u.usbdisk),
        u.kbd_reports,
        u.mouse_reports,
        if (timer.tickStalled()) " TICK-STALLED" else "",
        if (timer.sleptIrqsOff()) " SLEPT-IRQS-OFF" else "",
    }) catch "status: format failed";
}

/// WHICH kudos is running. The kernel is fetched over the network at boot now, so
/// "is the machine even running the image I just built" is a question with a real
/// wrong answer (a stale file served out of build/netboot/), and guessing at it
/// wastes whole boots. The running kernel reports its own identity; nothing else
/// is authoritative.
fn sinkVersion(_: *anyopaque, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "build={d} git={s} built={s}", .{
        buildinfo.build_number,
        buildinfo.git_hash,
        buildinfo.build_time,
    }) catch "version: format failed";
}

/// Diagnostics dumps: both only ENQUEUE onto the trace stream (counter lines /
/// diag-ring replay); the metered drain ships them. The ACK goes back on 9515 as
/// usual — the data itself arrives on the 9514 trace, where the collector is
/// already listening.
fn sinkStats(_: *anyopaque) void {
    counter.emitAll(true);
}
fn sinkRingtail(_: *anyopaque, kib: u16) void {
    netdebug.replayRing(@as(usize, kib) * 1024);
}

const sink_vtable = fileproto.Inject.VTable{
    .key = sinkKey,
    .mouse = sinkMouse,
    .mouseAbs = sinkMouseAbs,
    .shot = sinkShot,
    .reboot = sinkReboot,
    .shutdown = sinkShutdown,
    .status = sinkStatus,
    .version = sinkVersion,
    .stats = sinkStats,
    .ringtail = sinkRingtail,
    .mcp = sinkMcp,
};
var sink_ctx: u8 = 0; // the sink is stateless; the vtable needs an address
const sink = fileproto.Inject{ .ctx = &sink_ctx, .vtable = &sink_vtable };

/// Reply staging: UDP header + protocol header + READ_R framing + max chunk.
var reply: [net.UDP_HLEN + fileproto.HDR_LEN + 10 + fileproto.MAX_CHUNK + 64]u8 = undefined;

/// Build + send the pending reply, if any. Called from the steady loops
/// (boot/pump.zig's systemLoop, gpu.zig session loop) right after net.pump().
pub fn service() void {
    cnt_service.inc();
    // The armed power action is checked on EVERY call, not just when a request is
    // pending — the request that armed it is long since answered, and nothing else
    // will come in to drive the timer. The deadline rides the TSC, never the IRQ0
    // tick: the tick is the clock that dies, and "reset in 5 s" measured on a dead
    // clock is a reset that never happens.
    if (action != .none and tsc.rdtsc() >= action_deadline_tsc) {
        const act = action;
        action = .none; // no second attempt if the reset somehow returns
        switch (act) {
            .reboot => {
                klog.puts("kmr1: REBOOT requested — resetting now\n");
                netdebug.flushNow(); // last words onto the wire before we go
                power.reboot();
            },
            .shutdown => {
                // RAISE THE FLAG; DO NOT POWER OFF HERE. Cutting power with GSP-RM still
                // resident leaves the 4090 in a state the host driver cannot re-initialise
                // (Xid 62 / RmInitAdapter 0x62), clearable only by a full power-off. The
                // flag is the orderly path: the GPU session loop leaves its loop, tears GSP
                // down (destroying WPR2), and powers off itself. Where there is no GPU,
                // main_root.zig honours the same flag by powering off directly.
                klog.puts("kmr1: SHUTDOWN requested — orderly teardown, then power off\n");
                netdebug.flushNow();
                power.shutdown_requested = true;
            },
            .none => unreachable,
        }
    }

    if (req_head == req_tail) return; // ring empty
    const r = &req_ring[req_head];
    defer req_head = (req_head + 1) % REQ_QUEUE_DEPTH;
    const the_fs = fs orelse return;

    const n = fileproto.buildReply(the_fs, &dedup, sink, r.buf[0..r.len], reply[net.UDP_HLEN..]);
    if (n == 0) {
        cnt_reply_none.inc();
        return;
    }

    // UDP header + unicast send back to the requester (needs the DHCP lease;
    // ARP resolve may spin net.pump() — we are OUTSIDE the RX path here).
    if (!net.isUp()) {
        cnt_reply_senderr.inc();
        return;
    }
    net.wbe16(reply[0..2], fileproto.PORT);
    net.wbe16(reply[2..4], r.sport);
    net.wbe16(reply[4..6], @intCast(net.UDP_HLEN + n));
    net.wbe16(reply[6..8], 0); // checksum optional for IPv4
    const u = net.txPayload();
    @memcpy(u[0 .. net.UDP_HLEN + n], reply[0 .. net.UDP_HLEN + n]);
    if (net.sendIp(r.src, net.PROTO_UDP, net.UDP_HLEN + n)) cnt_reply_sent.inc() else cnt_reply_senderr.inc();
    // A power action armed by THIS request is not acted on here: the grace period
    // above owns that, so a lost ACK still has a live machine to retransmit to.
}
