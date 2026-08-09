//! netdebug wire codec + server logic — PURE module, host-tested. Single
//! framing source of truth (tools/netdebug-mcp/kmir.py is
//! the host implementation). All integers little-endian.

const std = @import("std");

pub const MAGIC: u32 = 0x31524d4b; // 'KMR1'
pub const PORT: u16 = 9515;
pub const MAX_CHUNK: u16 = 1200; // one reply always fits one MTU

pub const OP_LIST: u8 = 0x01;
pub const OP_LIST_R: u8 = 0x81;
pub const OP_READ: u8 = 0x02;
pub const OP_READ_R: u8 = 0x82;
pub const OP_WRITE: u8 = 0x03; // whole small file (≤ MAX_CHUNK) create/overwrite
pub const OP_WRITE_R: u8 = 0x83; // u32 new generation
pub const OP_KEY: u8 = 0x04; // u8 ascii (injected keystroke)
pub const OP_KEY_R: u8 = 0x84;
pub const OP_MOUSE: u8 = 0x05; // i16 dx, i16 dy, u8 buttons
pub const OP_MOUSE_R: u8 = 0x85;
pub const OP_SHOT: u8 = 0x06; // trigger a screenshot into the ramdisk (async)
pub const OP_SHOT_R: u8 = 0x86;
pub const OP_REBOOT: u8 = 0x07; // reset the machine (ACKed BEFORE the reset — see below)
pub const OP_REBOOT_R: u8 = 0x87;
pub const OP_PING: u8 = 0x09; // liveness probe; the reply carries a status line
pub const OP_PING_R: u8 = 0x89;
pub const OP_VERSION: u8 = 0x0a; // identity: build number + git hash + build time
pub const OP_VERSION_R: u8 = 0x8a;
pub const OP_SHUTDOWN: u8 = 0x0b; // end the run: ACK now, reset after a grace period
pub const OP_SHUTDOWN_R: u8 = 0x8b;
/// i16 x, i16 y, u8 buttons — the pointer goes EXACTLY there.
///
/// OP_MOUSE is relative, and kudos runs relative motion through a pointer-ACCELERATION
/// curve (imouse.zig); absolute events bypass it. That is invisible under QEMU, whose
/// usb-tablet is an absolute device — so the integration suite's drags, written as
/// relative deltas, land pixel-exact there and were AMPLIFIED into the screen edge on
/// lemon's real (relative) mouse. A test harness must not have its input reinterpreted
/// by an acceleration curve: this op puts the cursor where the test says.
pub const OP_MOUSE_ABS: u8 = 0x0c;
pub const OP_MOUSE_ABS_R: u8 = 0x8c;
pub const OP_STATS: u8 = 0x0d; // dump every diagnostics counter onto the netdebug stream
pub const OP_STATS_R: u8 = 0x8d;
pub const OP_RINGTAIL: u8 = 0x0e; // u16 KiB: replay the newest N KiB of the diag ring (flight recorder)
pub const OP_RINGTAIL_R: u8 = 0x8e;
/// One MCP (Model Context Protocol) JSON-RPC request, body = the request bytes.
/// kudos runs it against the agent's tool registry (spec AGT-011/AGT-013) and
/// writes the JSON-RPC response into MCP_RESPONSE_FILE on the ramdisk; the
/// reply carries that file's new generation, and the client pulls the response
/// with the ordinary windowed READ — so an arbitrarily large tools/list is not
/// bound by the single-datagram cap.
pub const OP_MCP: u8 = 0x0f;
pub const OP_MCP_R: u8 = 0x8f;
/// A whole string of keystrokes in one datagram; the reply is the u16 count of
/// LEADING bytes the machine took.
///
/// OP_KEY carries one byte per round trip, so a 144-character command line is
/// 144 datagrams — 144 chances to lose one, and 144 windows in which a full
/// input ring can swallow a byte and leave a corrupt command behind. This op
/// makes the same line one or two round trips, and makes the loss impossible to
/// miss rather than impossible to see: a short count is not an error, it is the
/// machine saying how much it had room for, and the caller resends from there.
pub const OP_TEXT: u8 = 0x10;
pub const OP_TEXT_R: u8 = 0x90;
/// Focus the front-most visible window whose title contains the body's needle,
/// and reply with the title of the window focused AFTER the request is parked.
/// An EMPTY needle changes nothing and only reports — the query form.
///
/// Injected input goes wherever focus happens to be, so every remote typing
/// session begins with a guess about which window that is. Clicking a title bar
/// to fix it needs coordinates that change whenever a window moves; naming the
/// window does not.
pub const OP_FOCUS: u8 = 0x11;
pub const OP_FOCUS_R: u8 = 0x91;
/// The ramdisk file the OP_MCP handler writes its JSON-RPC response into. One
/// well-known name, shared by the kernel handler and the remote client.
pub const MCP_RESPONSE_FILE = "mcp-response.json";
pub const OP_ERR: u8 = 0xff;

/// Named (non-character) keys an OP_KEY may carry in its optional second byte.
/// Kept numeric and stable on the wire — the guest maps them to its own Key enum.
pub const KEY_NONE: u8 = 0;
// Value 1 was F11 (the removed on-screen diagnostics console); left unassigned so
// F12/F10 keep their stable on-wire numbers.
pub const KEY_F12: u8 = 2;
pub const KEY_F10: u8 = 3;
pub const KEY_F1: u8 = 4;

/// Max bytes of the ASCII line a PING or VERSION reply carries.
pub const STATUS_CAP: usize = 160;

pub const ERR_UNKNOWN_NAME: u8 = 1;
pub const ERR_GENERATION: u8 = 2;
pub const ERR_BAD_REQUEST: u8 = 3;
/// The request was well-formed and the machine had no room for it — retry it.
/// Distinct from every other error because it is the only one where sending the
/// SAME bytes again is the correct response; the request is not recorded as
/// dispatched, so the retransmit is a fresh attempt rather than a re-ACK.
pub const ERR_BUSY: u8 = 4;

pub const HDR_LEN: usize = 8;

pub const Header = struct { op: u8, request_id: u16 };

/// Parse + validate the common header; null for foreign/garbled datagrams.
pub fn parseHeader(p: []const u8) ?Header {
    if (p.len < HDR_LEN) return null;
    if (std.mem.readInt(u32, p[0..4], .little) != MAGIC) return null;
    return .{ .op = p[4], .request_id = std.mem.readInt(u16, p[6..8], .little) };
}

pub fn writeHeader(buf: []u8, op: u8, request_id: u16) usize {
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    buf[4] = op;
    buf[5] = 0; // flags
    std.mem.writeInt(u16, buf[6..8], request_id, .little);
    return HDR_LEN;
}

pub const ReadReq = struct {
    name: []const u8,
    generation: u32,
    offset: u32,
    len: u16,
};

/// Body of a READ request (after the header). Null on malformed input.
pub fn parseReadReq(body: []const u8) ?ReadReq {
    if (body.len < 2) return null;
    const nlen = std.mem.readInt(u16, body[0..2], .little);
    if (body.len < 2 + @as(usize, nlen) + 10) return null;
    const name = body[2 .. 2 + nlen];
    const rest = body[2 + nlen ..];
    return .{
        .name = name,
        .generation = std.mem.readInt(u32, rest[0..4], .little),
        .offset = std.mem.readInt(u32, rest[4..8], .little),
        .len = std.mem.readInt(u16, rest[8..10], .little),
    };
}

pub fn writeReadReq(buf: []u8, request_id: u16, req: ReadReq) usize {
    var n = writeHeader(buf, OP_READ, request_id);
    std.mem.writeInt(u16, buf[n..][0..2], @intCast(req.name.len), .little);
    n += 2;
    @memcpy(buf[n .. n + req.name.len], req.name);
    n += req.name.len;
    std.mem.writeInt(u32, buf[n..][0..4], req.generation, .little);
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], req.offset, .little);
    std.mem.writeInt(u16, buf[n + 8 ..][0..2], req.len, .little);
    return n + 10;
}

/// READ_R reply: header + {generation, offset, len} + data.
pub fn writeReadResp(buf: []u8, request_id: u16, generation: u32, offset: u32, data: []const u8) usize {
    var n = writeHeader(buf, OP_READ_R, request_id);
    std.mem.writeInt(u32, buf[n..][0..4], generation, .little);
    std.mem.writeInt(u32, buf[n + 4 ..][0..4], offset, .little);
    std.mem.writeInt(u16, buf[n + 8 ..][0..2], @intCast(data.len), .little);
    n += 10;
    @memcpy(buf[n .. n + data.len], data);
    return n + data.len;
}

pub const ListEntry = struct {
    name: []const u8,
    generation: u32,
    size: u32,
    crc: u32,
};

/// LIST_R reply from `entries`. Returns bytes written, or null if it will
/// not fit `buf` (protocol reserves a truncated flag; the caller errors
/// loudly for now — the ramdisk holds a handful of files).
pub fn writeListResp(buf: []u8, request_id: u16, entries: []const ListEntry) ?usize {
    var n = writeHeader(buf, OP_LIST_R, request_id);
    if (buf.len < n + 2) return null;
    std.mem.writeInt(u16, buf[n..][0..2], @intCast(entries.len), .little);
    n += 2;
    for (entries) |e| {
        const need = 2 + e.name.len + 12;
        if (buf.len < n + need) return null;
        std.mem.writeInt(u16, buf[n..][0..2], @intCast(e.name.len), .little);
        n += 2;
        @memcpy(buf[n .. n + e.name.len], e.name);
        n += e.name.len;
        std.mem.writeInt(u32, buf[n..][0..4], e.generation, .little);
        std.mem.writeInt(u32, buf[n + 4 ..][0..4], e.size, .little);
        std.mem.writeInt(u32, buf[n + 8 ..][0..4], e.crc, .little);
        n += 12;
    }
    return n;
}

pub fn writeErr(buf: []u8, request_id: u16, code: u8) usize {
    const n = writeHeader(buf, OP_ERR, request_id);
    buf[n] = code;
    return n + 1;
}

/// Injection request encoders (host-test parity with kmir.py; the kernel
/// never sends these).
pub fn writeKeyReq(buf: []u8, request_id: u16, ascii: u8, named: u8) usize {
    const n = writeHeader(buf, OP_KEY, request_id);
    buf[n] = ascii;
    buf[n + 1] = named;
    return n + 2;
}

/// A TEXT request carries the string raw, so one datagram holds MAX_CHUNK of it;
/// the caller sends what fits and resumes from the reply's count.
pub fn writeTextReq(buf: []u8, request_id: u16, s: []const u8) usize {
    const n = writeHeader(buf, OP_TEXT, request_id);
    const take = @min(s.len, @min(@as(usize, MAX_CHUNK), buf.len - n));
    @memcpy(buf[n .. n + take], s[0..take]);
    return n + take;
}

pub fn writeFocusReq(buf: []u8, request_id: u16, needle: []const u8) usize {
    const n = writeHeader(buf, OP_FOCUS, request_id);
    const take = @min(needle.len, buf.len - n);
    @memcpy(buf[n .. n + take], needle[0..take]);
    return n + take;
}

pub fn writeMouseReq(buf: []u8, request_id: u16, dx: i16, dy: i16, buttons: u8) usize {
    const n = writeHeader(buf, OP_MOUSE, request_id);
    std.mem.writeInt(i16, buf[n..][0..2], dx, .little);
    std.mem.writeInt(i16, buf[n + 2 ..][0..2], dy, .little);
    buf[n + 4] = buttons;
    return n + 5;
}

pub fn writeMouseAbsReq(buf: []u8, request_id: u16, x: i16, y: i16, buttons: u8) usize {
    const n = writeHeader(buf, OP_MOUSE_ABS, request_id);
    std.mem.writeInt(i16, buf[n..][0..2], x, .little);
    std.mem.writeInt(i16, buf[n + 2 ..][0..2], y, .little);
    buf[n + 4] = buttons;
    return n + 5;
}

pub fn writeShotReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_SHOT, request_id);
}

pub fn writeRebootReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_REBOOT, request_id);
}

pub fn writePingReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_PING, request_id);
}

pub fn writeVersionReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_VERSION, request_id);
}

pub fn writeShutdownReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_SHUTDOWN, request_id);
}

pub fn writeStatsReq(buf: []u8, request_id: u16) usize {
    return writeHeader(buf, OP_STATS, request_id);
}

pub fn writeRingtailReq(buf: []u8, request_id: u16, kib: u16) usize {
    const n = writeHeader(buf, OP_RINGTAIL, request_id);
    std.mem.writeInt(u16, buf[n..][0..2], kib, .little);
    return n + 2;
}

/// Duplicate suppression for injection ops: the last 64 request_ids. A
/// retransmitted KEY/MOUSE/SHOT is acked again but never re-injected. Ids
/// are recorded via `record` only after a successful dispatch, so a
/// malformed datagram does not poison the id for a well-formed retransmit.
/// 64, not 8: the window is shared across op classes, and closed-loop mouse
/// traffic can push more than 8 dispatches between a key's first arrival and
/// its retransmit — at 8, the retransmitted key fell out of the window and
/// was injected a second time.
pub const Dedup = struct {
    /// Window capacity — the one home for the size (tests import it).
    pub const CAP = 64;
    rids: [CAP]u16 = undefined,
    /// What each recorded request answered. Only OP_TEXT has an answer worth
    /// remembering (its accepted count); every other deduped op records 0. A
    /// retransmit must replay the SAME count — recomputing it would inject the
    /// accepted prefix a second time, and answering 0 would make the caller
    /// resend a line the machine already took.
    results: [CAP]u16 = undefined,
    n: usize = 0,

    /// The recorded answer for `rid` if this request has already been
    /// dispatched, else null.
    pub fn seen(self: *const Dedup, rid: u16) ?u16 {
        const live = @min(self.n, self.rids.len);
        for (self.rids[0..live], self.results[0..live]) |r, res| if (r == rid) return res;
        return null;
    }

    pub fn record(self: *Dedup, rid: u16, result: u16) void {
        self.rids[self.n % self.rids.len] = rid;
        self.results[self.n % self.results.len] = result;
        self.n += 1;
    }
};

/// Injection sink — the seam between the pure server logic and the input/GPU
/// side effects. Scoped to the net group (CLAUDE.md: single-group contracts
/// stay in the group, not src/iface/). Real sink: fileserv.zig; fake:
/// test/drivers/net/debug/fileserv_test.zig.
pub const Inject = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `ascii` is the character (0 when the press has none); `named` is a
        /// KEY_* code for keys that have no character at all (F11/F12).
        /// FALSE when the input queue had no room — the caller must not ACK a
        /// keystroke the machine did not take.
        key: *const fn (ctx: *anyopaque, ascii: u8, named: u8) bool,
        /// Inject `s` as consecutive keystrokes and return how many LEADING
        /// bytes were taken. A short count is the queue filling up, not an
        /// error; the caller resends the remainder. Never reorders or skips: the
        /// accepted bytes are always a prefix, or a command line would arrive
        /// scrambled rather than truncated.
        text: *const fn (ctx: *anyopaque, s: []const u8) u16,
        /// Ask the desktop to focus the front-most visible window whose title
        /// contains `needle` (empty = report only), and fill `out` with the title
        /// of the currently-focused window, returning the used slice.
        ///
        /// The focus change is a REQUEST: the desktop owns the window list and
        /// runs on its own core, so it applies the change on its next input
        /// pass. The title reported here is therefore the one in effect as the
        /// reply is built — a caller confirms by asking again.
        focus: *const fn (ctx: *anyopaque, needle: []const u8, out: []u8) []const u8,
        mouse: *const fn (ctx: *anyopaque, dx: i16, dy: i16, buttons: u8) void,
        /// Absolute pointer placement — bypasses the acceleration curve (see OP_MOUSE_ABS).
        mouseAbs: *const fn (ctx: *anyopaque, x: i16, y: i16, buttons: u8) void,
        shot: *const fn (ctx: *anyopaque) void,
        /// REQUEST a reset — must NOT reset inline. buildReply's caller has to
        /// transmit the ACK first (see the OP_REBOOT branch), so the real sink
        /// only raises a flag that the steady loop acts on.
        reboot: *const fn (ctx: *anyopaque) void,
        /// REQUEST an orderly end of run: ACK, then reset after a grace period.
        /// Same no-reset-inline rule as `reboot`, and for the same reason.
        shutdown: *const fn (ctx: *anyopaque) void,
        /// Fill `out` with the ASCII status line a PING reply carries and return
        /// the used slice. Read-only: a liveness probe must have no side effects.
        status: *const fn (ctx: *anyopaque, out: []u8) []const u8,
        /// Fill `out` with the ASCII identity line a VERSION reply carries (build
        /// number, git hash, build time) and return the used slice.
        ///
        /// This answers "WHICH kudos is actually running", and it is not a nicety. The
        /// machine fetches its kernel over the network at boot, so there is a real
        /// failure mode where a stale image is served from a directory that was never
        /// rebuilt — and every symptom of it looks like a code bug. Asking the running
        /// kernel to report its own build settles the question in one datagram.
        version: *const fn (ctx: *anyopaque, out: []u8) []const u8,
        /// Dump every registered diagnostics counter onto the trace stream
        /// (counter.emitAll, forced past the module gate — an explicitly requested
        /// dump must never come back empty because a gate was off).
        stats: *const fn (ctx: *anyopaque) void,
        /// Replay the newest `kib` KiB of the in-memory diag ring onto the trace
        /// stream — the flight-recorder dump (dbg records land in the ring even
        /// when their module's gate is off; this recovers that history).
        ringtail: *const fn (ctx: *anyopaque, kib: u16) void,
        /// Run one MCP JSON-RPC request against the agent's tool registry and
        /// write the response into MCP_RESPONSE_FILE on the ramdisk (spec
        /// AGT-011/AGT-013). Side-effectful (a tools/call runs the tool), so it
        /// rides the deduped group. No reply bytes here — buildReply answers
        /// with the response file's generation and the client READs it.
        mcp: *const fn (ctx: *anyopaque, body: []const u8) void,
    };

    pub fn key(self: Inject, ascii: u8, named: u8) bool {
        return self.vtable.key(self.ctx, ascii, named);
    }
    pub fn text(self: Inject, s: []const u8) u16 {
        return self.vtable.text(self.ctx, s);
    }
    pub fn focus(self: Inject, needle: []const u8, out: []u8) []const u8 {
        return self.vtable.focus(self.ctx, needle, out);
    }
    pub fn mouse(self: Inject, dx: i16, dy: i16, buttons: u8) void {
        self.vtable.mouse(self.ctx, dx, dy, buttons);
    }
    pub fn mouseAbs(self: Inject, x: i16, y: i16, buttons: u8) void {
        self.vtable.mouseAbs(self.ctx, x, y, buttons);
    }
    pub fn shot(self: Inject) void {
        self.vtable.shot(self.ctx);
    }
    pub fn reboot(self: Inject) void {
        self.vtable.reboot(self.ctx);
    }
    pub fn shutdown(self: Inject) void {
        self.vtable.shutdown(self.ctx);
    }
    pub fn status(self: Inject, out: []u8) []const u8 {
        return self.vtable.status(self.ctx, out);
    }
    pub fn version(self: Inject, out: []u8) []const u8 {
        return self.vtable.version(self.ctx, out);
    }
    pub fn stats(self: Inject) void {
        self.vtable.stats(self.ctx);
    }
    pub fn ringtail(self: Inject, kib: u16) void {
        self.vtable.ringtail(self.ctx, kib);
    }
    pub fn mcp(self: Inject, body: []const u8) void {
        self.vtable.mcp(self.ctx, body);
    }
};

const iramdisk = @import("iramdisk");

/// The whole server: one request datagram in, one reply out (written into
/// `out`, returns its length; 0 = ignore the datagram). Pure over the
/// iramdisk + Inject seams — host-tested with RamdiskSim and a recording
/// sink (test/drivers/net/debug/fileserv_test.zig); the kernel glue (fileserv.zig) adds only
/// transport.
pub fn buildReply(fs: iramdisk.IRamdisk, dedup: *Dedup, sink: Inject, req: []const u8, out: []u8) usize {
    const hdr = parseHeader(req) orelse return 0;
    const body = req[HDR_LEN..];
    switch (hdr.op) {
        // OP_TEXT rides this group for its dedup, but answers with a COUNT rather
        // than a bare ACK — see the reply assembly at the end of the branch.
        OP_KEY, OP_TEXT, OP_MOUSE, OP_MOUSE_ABS, OP_SHOT, OP_REBOOT, OP_SHUTDOWN, OP_STATS, OP_RINGTAIL => {
            const result: u16 = dedup.seen(hdr.request_id) orelse blk: {
                var taken: u16 = 0;
                switch (hdr.op) {
                    OP_KEY => {
                        if (body.len < 1) return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
                        // Byte 1 (optional) is a NAMED key — F11/F12 and friends have no
                        // ASCII, and the integration suite drives the window manager with
                        // them, so an ASCII-only injector cannot run the WM tests natively.
                        // Absent = KEY_NONE, which keeps every existing 1-byte client working.
                        const named: u8 = if (body.len >= 2) body[1] else KEY_NONE;
                        // A refused keystroke is NOT recorded as dispatched and NOT
                        // ACKed: the ACK has to mean the machine took the key, or a
                        // caller counting ACKs believes it typed a line the machine
                        // only heard part of. ERR_BUSY sends the caller round again
                        // with the same request_id, which the dedup window will not
                        // suppress because nothing was recorded.
                        if (!sink.key(body[0], named)) return writeErr(out, hdr.request_id, ERR_BUSY);
                    },
                    OP_TEXT => taken = sink.text(body),
                    OP_MOUSE => {
                        if (body.len < 5) return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
                        sink.mouse(
                            std.mem.readInt(i16, body[0..2], .little),
                            std.mem.readInt(i16, body[2..4], .little),
                            body[4],
                        );
                    },
                    OP_MOUSE_ABS => {
                        if (body.len < 5) return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
                        sink.mouseAbs(
                            std.mem.readInt(i16, body[0..2], .little),
                            std.mem.readInt(i16, body[2..4], .little),
                            body[4],
                        );
                    },
                    OP_SHOT => sink.shot(),
                    // These only REQUEST the power action. The machine must still be
                    // alive to put the ACK below on the wire — the sink arms a timer
                    // and fileserv.service() acts once the reply has been sent AND a
                    // grace period has passed. Act inline and the caller never learns
                    // it worked, so it retries forever into a machine already gone.
                    OP_REBOOT => sink.reboot(),
                    OP_SHUTDOWN => sink.shutdown(),
                    // Diagnostics dumps: side-effectful (they enqueue onto the trace
                    // stream), so they ride the deduped group — a retransmitted STATS
                    // is acked again but the counters are not dumped twice.
                    OP_STATS => sink.stats(),
                    OP_RINGTAIL => {
                        const kib: u16 = if (body.len >= 2) std.mem.readInt(u16, body[0..2], .little) else 64;
                        sink.ringtail(kib);
                    },
                    else => unreachable,
                }
                dedup.record(hdr.request_id, taken);
                break :blk taken;
            };
            const n = writeHeader(out, hdr.op | 0x80, hdr.request_id);
            if (hdr.op != OP_TEXT) return n;
            // TEXT answers with the count — replayed verbatim on a retransmit, so
            // the caller resumes from the same byte whether or not the first reply
            // survived the wire.
            std.mem.writeInt(u16, out[n..][0..2], result, .little);
            return n + 2;
        },
        // NOT deduped: focusing a named window is idempotent — the second request
        // finds the same window already focused and changes nothing — so a
        // retransmit may safely re-run, and re-running is what makes the reply's
        // title CURRENT rather than a cached snapshot of where focus used to be.
        OP_FOCUS => {
            const n = writeHeader(out, OP_FOCUS_R, hdr.request_id);
            var buf: [STATUS_CAP]u8 = undefined;
            const title = sink.focus(body, &buf);
            const take = @min(title.len, @min(STATUS_CAP, out.len - n));
            @memcpy(out[n..][0..take], title[0..take]);
            return n + take;
        },
        // NOT deduped: PING and VERSION are read-only, so answering a retransmit is
        // correct and answering it AGAIN is the point — every probe must get a
        // reply, or the host cannot tell a lost packet from a dead machine.
        OP_PING, OP_VERSION => {
            const n = writeHeader(out, hdr.op | 0x80, hdr.request_id);
            var buf: [STATUS_CAP]u8 = undefined;
            const line = if (hdr.op == OP_PING) sink.status(&buf) else sink.version(&buf);
            const take = @min(line.len, @min(STATUS_CAP, out.len - n));
            @memcpy(out[n..][0..take], line[0..take]);
            return n + take;
        },
        OP_LIST => {
            var entries: [32]ListEntry = undefined;
            const count = @min(fs.count(), entries.len);
            for (0..count) |i| {
                const e = fs.at(i);
                entries[i] = .{ .name = e.name, .generation = e.generation, .size = @intCast(e.data.len), .crc = e.crc32 };
            }
            return writeListResp(out, hdr.request_id, entries[0..count]) orelse
                writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
        },
        OP_MCP => {
            // Run the JSON-RPC request against the agent's registry (dedup-guarded
            // so a retransmit does not re-run a tools/call's side effects), then
            // reply with the response file's generation — the client READs it.
            if (dedup.seen(hdr.request_id) == null) {
                sink.mcp(body);
                dedup.record(hdr.request_id, 0);
            }
            var gen: u32 = 0;
            for (0..fs.count()) |i| {
                const e = fs.at(i);
                if (std.mem.eql(u8, e.name, MCP_RESPONSE_FILE)) gen = e.generation;
            }
            var n = writeHeader(out, OP_MCP_R, hdr.request_id);
            std.mem.writeInt(u32, out[n..][0..4], gen, .little);
            n += 4;
            return n;
        },
        OP_WRITE => {
            // Body: u16 name_len, name, data (whole file, one datagram).
            if (body.len < 2) return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
            const nlen = std.mem.readInt(u16, body[0..2], .little);
            if (body.len < 2 + @as(usize, nlen) or nlen == 0)
                return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
            const name = body[2 .. 2 + nlen];
            const data = body[2 + nlen ..];
            fs.put(name, data) catch return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
            // Reply with the new generation (LIST semantics for the entry).
            var gen: u32 = 0;
            for (0..fs.count()) |i| {
                const e = fs.at(i);
                if (std.mem.eql(u8, e.name, name)) gen = e.generation;
            }
            var n = writeHeader(out, OP_WRITE_R, hdr.request_id);
            std.mem.writeInt(u32, out[n..][0..4], gen, .little);
            n += 4;
            return n;
        },
        OP_READ => {
            const rr = parseReadReq(body) orelse
                return writeErr(out, hdr.request_id, ERR_BAD_REQUEST);
            for (0..fs.count()) |i| {
                const e = fs.at(i);
                if (!std.mem.eql(u8, e.name, rr.name)) continue;
                if (e.generation != rr.generation)
                    return writeErr(out, hdr.request_id, ERR_GENERATION);
                if (rr.offset >= e.data.len)
                    return writeReadResp(out, hdr.request_id, e.generation, rr.offset, &.{});
                const avail: usize = e.data.len - rr.offset;
                const len = @min(@min(@as(usize, rr.len), MAX_CHUNK), avail);
                return writeReadResp(out, hdr.request_id, e.generation, rr.offset, e.data[rr.offset .. rr.offset + len]);
            }
            return writeErr(out, hdr.request_id, ERR_UNKNOWN_NAME);
        },
        else => return writeErr(out, hdr.request_id, ERR_BAD_REQUEST),
    }
}
