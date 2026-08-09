//! Host tests for the netdebug server logic (fileproto.buildReply) through
//! the iramdisk + Inject seams with RamdiskSim and a recording sink — the
//! full request→reply behavior with no hardware: LIST contents, chunked
//! READs, clamping, generation mismatch, unknown names, WRITE, injection
//! dispatch + request_id dedup, garbage in.

const std = @import("std");
const fileproto = @import("fileproto");
const sim = @import("ramdisk_sim");

fn newSim() sim.RamdiskSim {
    var s = sim.RamdiskSim{};
    s.add("hello.txt", "hello, kudos!", 3);
    s.add("big.bin", "0123456789" ** 200, 1); // 2000 B: forces 2 chunks
    return s;
}

/// Recording injection sink: counts + last values per op.
const SinkSim = struct {
    keys_buf: [256]u8 = undefined,
    keys_len: usize = 0,
    mouse_calls: usize = 0,
    last_dx: i16 = 0,
    last_dy: i16 = 0,
    last_buttons: u8 = 0,
    shots: usize = 0,
    abs_calls: usize = 0,
    last_named: u8 = 0,
    reboots: usize = 0,
    shutdowns: usize = 0,
    status_calls: usize = 0,
    version_calls: usize = 0,
    stats_calls: usize = 0,
    ringtail_calls: usize = 0,
    last_ringtail_kib: u16 = 0,
    mcp_calls: usize = 0,
    mcp_body_buf: [256]u8 = undefined,
    mcp_body_len: usize = 0,
    // The mcp handler writes its response into this ramdisk, exactly as the
    // real fileserv handler writes MCP_RESPONSE_FILE; wired by the harness.
    mcp_fs: ?*sim.RamdiskSim = null,
    mcp_response: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",

    /// How many more keystrokes this sink will take before refusing, standing in
    /// for a full input ring. Effectively unlimited unless a test lowers it.
    room: usize = std.math.maxInt(usize),
    /// The needle of the last focus request, and the title the sink reports back.
    focus_buf: [32]u8 = undefined,
    focus_len: usize = 0,
    focus_calls: usize = 0,
    title: []const u8 = "terminal",

    fn key(ctx: *anyopaque, ascii: u8, named: u8) bool {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        if (self.room == 0) return false;
        self.room -= 1;
        if (self.keys_len < self.keys_buf.len) {
            self.keys_buf[self.keys_len] = ascii;
            self.keys_len += 1;
        }
        self.last_named = named;
        return true;
    }
    fn text(ctx: *anyopaque, s: []const u8) u16 {
        for (s, 0..) |ch, i| {
            if (!key(ctx, ch, fileproto.KEY_NONE)) return @intCast(i);
        }
        return @intCast(s.len);
    }
    fn focus(ctx: *anyopaque, needle: []const u8, out: []u8) []const u8 {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.focus_calls += 1;
        if (needle.len > 0) {
            self.focus_len = @min(needle.len, self.focus_buf.len);
            @memcpy(self.focus_buf[0..self.focus_len], needle[0..self.focus_len]);
            // The real desktop applies the change on its next input pass; this
            // sink stands in for one that already has.
            self.title = "linux #0";
        }
        const n = @min(self.title.len, out.len);
        @memcpy(out[0..n], self.title[0..n]);
        return out[0..n];
    }
    fn mouse(ctx: *anyopaque, dx: i16, dy: i16, buttons: u8) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.mouse_calls += 1;
        self.last_dx = dx;
        self.last_dy = dy;
        self.last_buttons = buttons;
    }
    fn mouseAbs(ctx: *anyopaque, x: i16, y: i16, buttons: u8) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.abs_calls += 1;
        self.last_dx = x;
        self.last_dy = y;
        self.last_buttons = buttons;
    }
    fn shot(ctx: *anyopaque) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.shots += 1;
    }
    fn reboot(ctx: *anyopaque) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.reboots += 1;
    }
    fn shutdown(ctx: *anyopaque) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.shutdowns += 1;
    }
    fn status(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.status_calls += 1;
        const line = "build=1 up_ms=1234 ticks=123";
        @memcpy(out[0..line.len], line);
        return out[0..line.len];
    }

    fn version(ctx: *anyopaque, out: []u8) []const u8 {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.version_calls += 1;
        const line = "build=2 git=abc1234 built=now";
        @memcpy(out[0..line.len], line);
        return out[0..line.len];
    }

    fn stats(ctx: *anyopaque) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.stats_calls += 1;
    }

    fn ringtail(ctx: *anyopaque, kib: u16) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.ringtail_calls += 1;
        self.last_ringtail_kib = kib;
    }

    fn mcp(ctx: *anyopaque, body: []const u8) void {
        const self: *SinkSim = @ptrCast(@alignCast(ctx));
        self.mcp_calls += 1;
        self.mcp_body_len = @min(body.len, self.mcp_body_buf.len);
        @memcpy(self.mcp_body_buf[0..self.mcp_body_len], body[0..self.mcp_body_len]);
        if (self.mcp_fs) |f| f.fs().put(fileproto.MCP_RESPONSE_FILE, self.mcp_response) catch {};
    }

    const vtable = fileproto.Inject.VTable{
        .key = key,
        .text = text,
        .focus = focus,
        .mouse = mouse,
        .mouseAbs = mouseAbs,
        .shot = shot,
        .reboot = reboot,
        .shutdown = shutdown,
        .status = status,
        .version = version,
        .stats = stats,
        .ringtail = ringtail,
        .mcp = mcp,
    };

    fn inject(self: *SinkSim) fileproto.Inject {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// One test harness: sim ramdisk + fresh dedup + recording sink.
const Server = struct {
    s: sim.RamdiskSim,
    dedup: fileproto.Dedup = .{},
    sink: SinkSim = .{},

    fn reply(self: *Server, req: []const u8, out: []u8) usize {
        return fileproto.buildReply(self.s.fs(), &self.dedup, self.sink.inject(), req, out);
    }
};

// DIAG-010: remote list/read/write of ramdisk files — the fileserv contract,
// driven through the real reply builder against a sim ramdisk.
test "LIST lists both files with sizes and generations" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    const rn = fileproto.writeHeader(&req, fileproto.OP_LIST, 42);
    var out: [1500]u8 = undefined;
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expect(n > 0);
    const h = fileproto.parseHeader(out[0..n]).?;
    try std.testing.expectEqual(fileproto.OP_LIST_R, h.op);
    try std.testing.expectEqual(@as(u16, 42), h.request_id);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[8..10], .little));
    // First entry: "hello.txt", gen 3, size 13.
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, out[10..12], .little));
    try std.testing.expectEqualStrings("hello.txt", out[12..21]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[21..25], .little));
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, out[25..29], .little));
}

test "READ round-trips a whole file in chunks with clamping" {
    var srv = Server{ .s = newSim() };
    var assembled: [2000]u8 = undefined;
    var got: usize = 0;
    var rid: u16 = 1;
    while (got < 2000) {
        var req: [64]u8 = undefined;
        const rn = fileproto.writeReadReq(&req, rid, .{ .name = "big.bin", .generation = 1, .offset = @intCast(got), .len = 60000 & 0xffff });
        var out: [1500]u8 = undefined;
        const n = srv.reply(req[0..rn], &out);
        const h = fileproto.parseHeader(out[0..n]).?;
        try std.testing.expectEqual(fileproto.OP_READ_R, h.op);
        try std.testing.expectEqual(rid, h.request_id);
        const len: usize = std.mem.readInt(u16, out[16..18], .little);
        try std.testing.expect(len <= fileproto.MAX_CHUNK); // clamped
        try std.testing.expectEqual(@as(u32, @intCast(got)), std.mem.readInt(u32, out[12..16], .little));
        @memcpy(assembled[got .. got + len], out[18 .. 18 + len]);
        got += len;
        rid += 1;
    }
    try std.testing.expectEqualStrings("0123456789" ** 200, &assembled);
}

test "generation mismatch and unknown names yield ERR" {
    var srv = Server{ .s = newSim() };
    var req: [64]u8 = undefined;
    var out: [1500]u8 = undefined;
    var rn = fileproto.writeReadReq(&req, 5, .{ .name = "hello.txt", .generation = 2, .offset = 0, .len = 100 });
    var n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(fileproto.ERR_GENERATION, out[8]);

    rn = fileproto.writeReadReq(&req, 6, .{ .name = "nope", .generation = 1, .offset = 0, .len = 100 });
    n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.ERR_UNKNOWN_NAME, out[8]);
}

test "garbage and reads past EOF are handled" {
    var srv = Server{ .s = newSim() };
    var out: [1500]u8 = undefined;
    // Not our magic: ignored entirely.
    try std.testing.expectEqual(@as(usize, 0), srv.reply("GET / HTTP/1.0", &out));
    // Offset at EOF: empty READ_R, not an error.
    var req: [64]u8 = undefined;
    const rn = fileproto.writeReadReq(&req, 7, .{ .name = "hello.txt", .generation = 3, .offset = 13, .len = 100 });
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_READ_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, out[16..18], .little));
}

fn writeWriteReq(buf: []u8, rid: u16, name: []const u8, data: []const u8) usize {
    var n = fileproto.writeHeader(buf, fileproto.OP_WRITE, rid);
    std.mem.writeInt(u16, buf[n..][0..2], @intCast(name.len), .little);
    n += 2;
    @memcpy(buf[n .. n + name.len], name);
    n += name.len;
    @memcpy(buf[n .. n + data.len], data);
    return n + data.len;
}

test "WRITE creates a file and overwrite bumps the generation" {
    var srv = Server{ .s = newSim() };
    var req: [1400]u8 = undefined;
    var out: [1500]u8 = undefined;
    // Create.
    var rn = writeWriteReq(&req, 20, "new.txt", "v1");
    var n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_WRITE_R, fileproto.parseHeader(out[0..n]).?.op);
    const gen1 = std.mem.readInt(u32, out[8..12], .little);
    // Overwrite: generation must move.
    rn = writeWriteReq(&req, 21, "new.txt", "v2 longer");
    n = srv.reply(req[0..rn], &out);
    const gen2 = std.mem.readInt(u32, out[8..12], .little);
    try std.testing.expect(gen2 != gen1);
    // Content is really replaced: LIST size reflects it.
    const wrote = srv.s.fs().get("new.txt").?;
    try std.testing.expectEqualStrings("v2 longer", wrote);
    // Empty name is rejected.
    rn = writeWriteReq(&req, 22, "", "data");
    n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..n]).?.op);
}

// DIAG-008/DIAG-009 (injected keys and mice reach the input path) and
// DIAG-015 (screenshot on command): the opcode plumbing, dispatched to the
// sink exactly once and acked; the live halves are the suite drivers' typed
// commands, closed-loop pointer probes, and client.screenshot() round-trips,
// all with hard timeouts.
test "KEY/MOUSE/SHOT dispatch to the sink and ack" {
    var srv = Server{ .s = newSim() };
    var req: [32]u8 = undefined;
    var out: [64]u8 = undefined;

    var rn = fileproto.writeKeyReq(&req, 30, 'k', fileproto.KEY_NONE);
    var n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_KEY_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqualStrings("k", srv.sink.keys_buf[0..srv.sink.keys_len]);

    rn = fileproto.writeMouseReq(&req, 31, -40, 7, 0b001);
    n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_MOUSE_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.mouse_calls);
    try std.testing.expectEqual(@as(i16, -40), srv.sink.last_dx);
    try std.testing.expectEqual(@as(i16, 7), srv.sink.last_dy);
    try std.testing.expectEqual(@as(u8, 0b001), srv.sink.last_buttons);

    rn = fileproto.writeShotReq(&req, 32);
    n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_SHOT_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.shots);
}

test "MOUSE_ABS dispatches absolute coordinates to the sink and acks" {
    var srv = Server{ .s = newSim() };
    var req: [32]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeMouseAbsReq(&req, 33, 640, 400, 0b010);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_MOUSE_ABS_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.abs_calls);
    try std.testing.expectEqual(@as(i16, 640), srv.sink.last_dx);
    try std.testing.expectEqual(@as(i16, 400), srv.sink.last_dy);
    try std.testing.expectEqual(@as(u8, 0b010), srv.sink.last_buttons);
    // A truncated body (fresh request_id) ERRs and reaches no sink.
    const rn2 = fileproto.writeMouseAbsReq(&req, 34, 1, 2, 0);
    const short = srv.reply(req[0 .. rn2 - 2], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..short]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.abs_calls);
}

test "SHUTDOWN is ACKed and deduped like REBOOT" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeShutdownReq(&req, 72);
    var n = srv.reply(req[0..rn], &out);
    const h = fileproto.parseHeader(out[0..n]).?;
    try std.testing.expectEqual(fileproto.OP_SHUTDOWN_R, h.op);
    try std.testing.expectEqual(@as(u16, 72), h.request_id);
    // The sink was only ASKED to power off — buildReply itself must never act.
    try std.testing.expectEqual(@as(usize, 1), srv.sink.shutdowns);
    // A retransmit is re-ACKed but powers off only once.
    n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_SHUTDOWN_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.shutdowns);
}

test "retransmitted injection acks but injects exactly once" {
    var srv = Server{ .s = newSim() };
    var req: [32]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeKeyReq(&req, 40, 'z', fileproto.KEY_NONE);
    for (0..3) |_| {
        const n = srv.reply(req[0..rn], &out);
        try std.testing.expectEqual(fileproto.OP_KEY_R, fileproto.parseHeader(out[0..n]).?.op);
    }
    try std.testing.expectEqualStrings("z", srv.sink.keys_buf[0..srv.sink.keys_len]); // once, not thrice
    // A NEW request_id with the same payload injects again.
    const rn2 = fileproto.writeKeyReq(&req, 41, 'z', fileproto.KEY_NONE);
    _ = srv.reply(req[0..rn2], &out);
    try std.testing.expectEqualStrings("zz", srv.sink.keys_buf[0..srv.sink.keys_len]);
}

test "malformed injection bodies ERR and do not consume the request_id" {
    var srv = Server{ .s = newSim() };
    var out: [64]u8 = undefined;
    // A truncated MOUSE (3-byte body) errors...
    var req: [32]u8 = undefined;
    const full = fileproto.writeMouseReq(&req, 50, 10, 10, 1);
    const n = srv.reply(req[0 .. full - 2], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(fileproto.ERR_BAD_REQUEST, out[8]);
    try std.testing.expectEqual(@as(usize, 0), srv.sink.mouse_calls);
    // ...and the complete retransmit with the SAME id still injects.
    _ = srv.reply(req[0..full], &out);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.mouse_calls);
}

test "unknown op yields ERR_BAD_REQUEST" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeHeader(&req, 0x77, 60);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(fileproto.ERR_BAD_REQUEST, out[8]);
}

// DIAG-018: remote reboot/shutdown are accepted, ACKed before the reset,
// and deduped — the contract every unattended rig recovery leans on.
test "REBOOT is ACKed (the reply must reach the caller BEFORE the machine resets)" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeRebootReq(&req, 71);
    const n = srv.reply(req[0..rn], &out);

    // The ACK exists and names the request. Without it the host cannot tell a
    // reboot that worked from a machine that was already dead, and retries into
    // a box that is mid-reset.
    try std.testing.expectEqual(fileproto.HDR_LEN, n);
    const h = fileproto.parseHeader(out[0..n]).?;
    try std.testing.expectEqual(fileproto.OP_REBOOT_R, h.op);
    try std.testing.expectEqual(@as(u16, 71), h.request_id);
    // The sink was only ASKED to reset — buildReply itself must never reset.
    try std.testing.expectEqual(@as(usize, 1), srv.sink.reboots);
}

test "REBOOT is deduped: a retransmit is re-ACKed but resets only once" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeRebootReq(&req, 71);
    _ = srv.reply(req[0..rn], &out);
    const n = srv.reply(req[0..rn], &out); // same request_id — a retransmit
    try std.testing.expectEqual(fileproto.OP_REBOOT_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.reboots);
}

test "PING replies with the status line appended to the header" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writePingReq(&req, 5);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_PING_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.status_calls);
    try std.testing.expectEqualStrings("build=1 up_ms=1234 ticks=123", out[fileproto.HDR_LEN..n]);
}

test "PING is NOT deduped — every heartbeat gets a fresh status" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    // The SAME request_id twice. Injection ops suppress a duplicate (a replayed
    // keystroke must not type twice); a liveness probe must NOT be suppressed —
    // a deduped PING would answer from cache and report a dead machine as alive.
    const rn = fileproto.writePingReq(&req, 6);
    _ = srv.reply(req[0..rn], &out);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_PING_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 2), srv.sink.status_calls);
}

test "STATS acks, dumps once, and dedups the retransmit" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writeStatsReq(&req, 90);
    var n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_STATS_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.stats_calls);
    n = srv.reply(req[0..rn], &out); // retransmit: re-ACKed, not re-dumped
    try std.testing.expectEqual(fileproto.OP_STATS_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.stats_calls);
}

test "RINGTAIL carries its KiB argument and defaults to 64 without one" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writeRingtailReq(&req, 91, 32);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_RINGTAIL_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(u16, 32), srv.sink.last_ringtail_kib);

    // A bare header (older client): the server picks a useful default.
    var bare: [16]u8 = undefined;
    const bn = fileproto.writeHeader(&bare, fileproto.OP_RINGTAIL, 92);
    _ = srv.reply(bare[0..bn], &out);
    try std.testing.expectEqual(@as(u16, 64), srv.sink.last_ringtail_kib);
}

test "VERSION reports the running kernel's identity, and is not deduped either" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writeVersionReq(&req, 8);
    var n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_VERSION_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqualStrings("build=2 git=abc1234 built=now", out[fileproto.HDR_LEN..n]);

    n = srv.reply(req[0..rn], &out); // same request_id
    try std.testing.expectEqual(@as(usize, 2), srv.sink.version_calls);
    try std.testing.expectEqual(fileproto.OP_VERSION_R, fileproto.parseHeader(out[0..n]).?.op);
}

test "a status line longer than the reply buffer is truncated, not overflowed" {
    var srv = Server{ .s = newSim() };
    var req: [16]u8 = undefined;
    var out: [fileproto.HDR_LEN + 8]u8 = undefined; // room for only 8 status bytes

    const rn = fileproto.writePingReq(&req, 7);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(out.len, n);
    try std.testing.expectEqualStrings("build=1 ", out[fileproto.HDR_LEN..n]);
}

test "MCP request runs against the registry, writes the response, replies with its generation" {
    var srv = Server{ .s = newSim() };
    srv.sink.mcp_fs = &srv.s; // the mcp handler writes MCP_RESPONSE_FILE here
    var req: [256]u8 = undefined;
    var out: [1500]u8 = undefined;

    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
    var rn = fileproto.writeHeader(&req, fileproto.OP_MCP, 21);
    @memcpy(req[rn..][0..body.len], body);
    rn += body.len;

    const n = srv.reply(req[0..rn], &out);
    // The handler ran with the request body verbatim...
    try std.testing.expectEqual(@as(usize, 1), srv.sink.mcp_calls);
    try std.testing.expectEqualStrings(body, srv.sink.mcp_body_buf[0..srv.sink.mcp_body_len]);
    // ...the response landed on the ramdisk for the client to READ...
    try std.testing.expect(srv.s.fs().get(fileproto.MCP_RESPONSE_FILE) != null);
    // ...and the reply is OP_MCP_R carrying that file's generation (non-zero).
    try std.testing.expectEqual(fileproto.OP_MCP_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expect(std.mem.readInt(u32, out[fileproto.HDR_LEN..][0..4], .little) != 0);

    // A retransmit (same request_id) must NOT re-run the tool (side effects),
    // but must still answer with the generation.
    const n2 = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.mcp_calls); // not re-run
    try std.testing.expectEqual(fileproto.OP_MCP_R, fileproto.parseHeader(out[0..n2]).?.op);
}

// DIAG-019/020/021/022: the flow-controlled injection path. The old protocol
// ACKed every keystroke unconditionally, so a caller counting ACKs believed it
// had typed a line the machine had only partly heard — and a truncated command
// is indistinguishable from a mistyped one at the far end.

test "a keystroke the machine has no room for is refused, not ACKed (DIAG-019)" {
    var srv = Server{ .s = newSim() };
    srv.sink.room = 0; // a full input ring
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writeKeyReq(&req, 7, 'x', fileproto.KEY_NONE);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_ERR, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(fileproto.ERR_BUSY, out[fileproto.HDR_LEN]);
    try std.testing.expectEqual(@as(usize, 0), srv.sink.keys_len);
}

test "a refused keystroke is not recorded, so the same request retries (DIAG-019)" {
    var srv = Server{ .s = newSim() };
    srv.sink.room = 0;
    var req: [16]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeKeyReq(&req, 7, 'x', fileproto.KEY_NONE);

    _ = srv.reply(req[0..rn], &out); // refused while full

    // Room appears, and the caller sends the SAME datagram again. Dedup must not
    // suppress it: nothing was dispatched the first time, so suppressing here
    // would ACK a keystroke that was never delivered — the exact failure this
    // whole path exists to remove.
    srv.sink.room = 4;
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_KEY_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, 1), srv.sink.keys_len);
    try std.testing.expectEqual(@as(u8, 'x'), srv.sink.keys_buf[0]);
}

test "TEXT types the whole string in one request and reports the count (DIAG-020)" {
    var srv = Server{ .s = newSim() };
    var req: [128]u8 = undefined;
    var out: [64]u8 = undefined;

    const line = "firefox --profile /tmp/p https://en.wikipedia.org\n";
    const rn = fileproto.writeTextReq(&req, 11, line);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_TEXT_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqual(@as(usize, fileproto.HDR_LEN + 2), n);
    try std.testing.expectEqual(
        @as(u16, line.len),
        std.mem.readInt(u16, out[fileproto.HDR_LEN..][0..2], .little),
    );
    try std.testing.expectEqualStrings(line, srv.sink.keys_buf[0..srv.sink.keys_len]);
}

test "TEXT accepted bytes are a PREFIX, and the count says where to resume (DIAG-020)" {
    var srv = Server{ .s = newSim() };
    srv.sink.room = 3; // room for "abc" and no more
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;

    const rn = fileproto.writeTextReq(&req, 12, "abcdefg");
    _ = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[fileproto.HDR_LEN..][0..2], .little));
    // A PREFIX, never a subset: the caller resumes from index 3, so skipping a
    // byte in the middle and taking a later one would deliver a scrambled line
    // while reporting the same count.
    try std.testing.expectEqualStrings("abc", srv.sink.keys_buf[0..srv.sink.keys_len]);

    srv.sink.room = 16;
    const rn2 = fileproto.writeTextReq(&req, 13, "defg");
    _ = srv.reply(req[0..rn2], &out);
    try std.testing.expectEqualStrings("abcdefg", srv.sink.keys_buf[0..srv.sink.keys_len]);
}

test "a retransmitted TEXT replays its count without typing again (DIAG-020)" {
    var srv = Server{ .s = newSim() };
    srv.sink.room = 3;
    var req: [64]u8 = undefined;
    var out: [64]u8 = undefined;
    const rn = fileproto.writeTextReq(&req, 14, "abcdefg");

    const n1 = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[fileproto.HDR_LEN..][0..2], .little));

    // The reply was lost, so the caller sends the same datagram again. It must
    // get the SAME count back: recomputing it would type the accepted prefix a
    // second time, and answering 0 would make the caller resend a line the
    // machine already has.
    srv.sink.room = 16;
    const n2 = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(n1, n2);
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[fileproto.HDR_LEN..][0..2], .little));
    try std.testing.expectEqualStrings("abc", srv.sink.keys_buf[0..srv.sink.keys_len]);
}

test "FOCUS names a window by a substring of its title (DIAG-021)" {
    var srv = Server{ .s = newSim() };
    var req: [64]u8 = undefined;
    var out: [256]u8 = undefined;

    const rn = fileproto.writeFocusReq(&req, 15, "linux");
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqual(fileproto.OP_FOCUS_R, fileproto.parseHeader(out[0..n]).?.op);
    try std.testing.expectEqualStrings("linux", srv.sink.focus_buf[0..srv.sink.focus_len]);
}

test "FOCUS reports the focused window's title, and an empty needle only asks (DIAG-022)" {
    var srv = Server{ .s = newSim() };
    var req: [64]u8 = undefined;
    var out: [256]u8 = undefined;

    // The query form: no needle, so nothing is requested and the answer is
    // whatever holds focus now. This is how a caller confirms the change it
    // asked for actually landed — the desktop applies it on its own core.
    const rn = fileproto.writeFocusReq(&req, 16, "");
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqualStrings("terminal", out[fileproto.HDR_LEN..n]);
    try std.testing.expectEqual(@as(usize, 0), srv.sink.focus_len);
}

test "FOCUS is NOT deduped — asking again reports the CURRENT window (DIAG-022)" {
    var srv = Server{ .s = newSim() };
    var req: [64]u8 = undefined;
    var out: [256]u8 = undefined;

    // Focusing a named window is idempotent, so a retransmit may safely re-run —
    // and it must, or a caller polling for confirmation would be answered from a
    // cache that still names the window focus has since left.
    const rn = fileproto.writeFocusReq(&req, 17, "linux");
    _ = srv.reply(req[0..rn], &out);
    const n = srv.reply(req[0..rn], &out);
    try std.testing.expectEqualStrings("linux #0", out[fileproto.HDR_LEN..n]);
    try std.testing.expectEqual(@as(usize, 2), srv.sink.focus_calls);
}
