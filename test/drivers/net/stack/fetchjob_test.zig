//! Host tests of src/drivers/net/stack/fetchjob.zig — the resumable HTTP GET
//! state machine, driven step by step against a fake transport that delivers a
//! response in chunks and a scripted clock.

const std = @import("std");
const fetchjob = @import("fetchjob");
const job = @import("job");

/// A fake connection: scripted handshake, a send sink, and a receive buffer the
/// test feeds one chunk at a time (as the real RX pump would grow it).
const FakeConn = struct {
    conn: fetchjob.ConnState = .connecting,
    start_ok: bool = true,
    started: bool = false,
    sent: std.array_list.Managed(u8),
    recv: std.array_list.Managed(u8),
    peer_closed: bool = false,
    /// The whole-response reservation: how many bytes were asked for, and how
    /// many times. A second ask would mean the buffer grows after all.
    reserved: usize = 0,
    reserve_calls: usize = 0,
    reserve_ok: bool = true,

    fn start(ctx: *anyopaque) bool {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        self.started = true;
        return self.start_ok;
    }
    fn poll(ctx: *anyopaque) fetchjob.ConnState {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        return self.conn;
    }
    fn send(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        self.sent.appendSlice(bytes) catch return false;
        return true;
    }
    fn received(ctx: *anyopaque) []const u8 {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        return self.recv.items;
    }
    fn reserve(ctx: *anyopaque, bytes: usize) bool {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        self.reserve_calls += 1;
        self.reserved = bytes;
        return self.reserve_ok;
    }
    fn closed(ctx: *anyopaque) bool {
        const self: *FakeConn = @ptrCast(@alignCast(ctx));
        return self.peer_closed;
    }
    fn transport(self: *FakeConn) fetchjob.Transport {
        return .{ .ctx = self, .start = start, .poll = poll, .send = send, .received = received, .reserve = reserve, .closed = closed };
    }
};

const FakeClock = struct {
    now: u64 = 0,
    fn millis(ctx: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn clock(self: *FakeClock) fetchjob.Clock {
        return .{ .ctx = self, .millis = millis };
    }
};

test "resumable GET: connect, send, absorb chunks, complete on Content-Length (NET-009)" {
    var conn = FakeConn{ .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    // connecting: start called, still handshaking.
    try std.testing.expectEqual(job.Step.working, fetchjob.FetchJob.step(&fj));
    try std.testing.expect(conn.started);
    try std.testing.expectEqual(fetchjob.Phase.connecting, fj.phase);

    // handshake completes -> the job moves to sending.
    conn.conn = .established;
    try std.testing.expectEqual(job.Step.working, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(fetchjob.Phase.sending, fj.phase);

    // sending: the request goes out, then receiving.
    try std.testing.expectEqual(job.Step.working, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqualStrings("GET /x HTTP/1.1\r\n\r\n", conn.sent.items);
    try std.testing.expectEqual(fetchjob.Phase.receiving, fj.phase);

    // Body arrives in pieces; the job stays `working` until the whole 5 bytes land.
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel");
    try std.testing.expectEqual(job.Step.working, fetchjob.FetchJob.step(&fj));
    try conn.recv.appendSlice("lo");
    try std.testing.expectEqual(job.Step.done, fetchjob.FetchJob.step(&fj));

    try std.testing.expectEqual(@as(u16, 200), fj.status);
    try std.testing.expectEqualStrings("hello", fj.body);
}

test "progress: nothing before the header, then body bytes against Content-Length" {
    var conn = FakeConn{ .conn = .established, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // connecting -> sending
    _ = fetchjob.FetchJob.step(&fj); // sending -> receiving

    // Header not in yet: nothing to report.
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\nContent-Le");
    _ = fetchjob.FetchJob.step(&fj);
    try std.testing.expectEqual(fetchjob.Progress{ .received = 0, .total = null }, fj.progress());

    // Header + part of the body: the count and the stated size.
    try conn.recv.appendSlice("ngth: 5\r\n\r\nhel");
    _ = fetchjob.FetchJob.step(&fj);
    try std.testing.expectEqual(fetchjob.Progress{ .received = 3, .total = 5 }, fj.progress());

    // Complete: the count reaches the size.
    try conn.recv.appendSlice("lo");
    try std.testing.expectEqual(job.Step.done, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(fetchjob.Progress{ .received = 5, .total = 5 }, fj.progress());
}

test "a non-2xx status fails the job (never a body)" {
    var conn = FakeConn{ .conn = .established, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // connecting -> sending (established)
    _ = fetchjob.FetchJob.step(&fj); // sending -> receiving
    try conn.recv.appendSlice("HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nno!");
    try std.testing.expectEqual(job.Step.failed, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(fetchjob.Phase.failed, fj.phase);
}

test "a silent peer past the stall budget fails; progress renews it" {
    var conn = FakeConn{ .conn = .established, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // -> sending
    _ = fetchjob.FetchJob.step(&fj); // -> receiving (deadline = now + STALL_MS)
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhalf"); // progress
    _ = fetchjob.FetchJob.step(&fj); // renews deadline

    // Just before the budget: still working.
    clk.now += fetchjob.STALL_MS - 1;
    try std.testing.expectEqual(job.Step.working, fetchjob.FetchJob.step(&fj));
    // Past it with no new bytes: fail.
    clk.now += 2;
    try std.testing.expectEqual(job.Step.failed, fetchjob.FetchJob.step(&fj));
}

test "the whole response is reserved once, from Content-Length, before the body lands (NET-009)" {
    var conn = FakeConn{ .conn = .established, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // -> sending
    _ = fetchjob.FetchJob.step(&fj); // -> receiving

    // The head alone, without its size yet: nothing to reserve against.
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\nContent-Len");
    _ = fetchjob.FetchJob.step(&fj);
    try std.testing.expectEqual(@as(usize, 0), conn.reserve_calls);

    // The size arrives with the first body byte: head + body is asked for at
    // once, while only the head is buffered — the room for the WHOLE response.
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n";
    try conn.recv.appendSlice("gth: 5\r\n\r\nh");
    _ = fetchjob.FetchJob.step(&fj);
    try std.testing.expectEqual(@as(usize, 1), conn.reserve_calls);
    try std.testing.expectEqual(head.len + 5, conn.reserved);

    // Every later step reuses that room: a second ask would mean the buffer
    // grows across the transfer after all, which is the bug being prevented.
    try conn.recv.appendSlice("ello");
    try std.testing.expectEqual(job.Step.done, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(@as(usize, 1), conn.reserve_calls);
    try std.testing.expectEqualStrings("hello", fj.body);
}

test "a response too large to buffer fails at the header, not part-way through (NET-009)" {
    var conn = FakeConn{ .conn = .established, .reserve_ok = false, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // -> sending
    _ = fetchjob.FetchJob.step(&fj); // -> receiving

    // The header states a size the transport cannot make room for. The job ends
    // HERE, on the first step that knows the size — not after the body has been
    // dribbling in for minutes against a buffer that can never hold it.
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n\r\nx");
    try std.testing.expectEqual(job.Step.failed, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(fetchjob.Phase.failed, fj.phase);
    try std.testing.expectEqual(@as(usize, 1), conn.reserve_calls);
}

test "a close-delimited body states no size, so nothing is reserved (NET-009)" {
    var conn = FakeConn{ .conn = .established, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET /x HTTP/1.1\r\n\r\n" };

    _ = fetchjob.FetchJob.step(&fj); // -> sending
    _ = fetchjob.FetchJob.step(&fj); // -> receiving

    // No Content-Length: the size is the peer's close, which is not known until
    // it happens. Asking for a number nobody stated is not available, so this
    // body grows as it always did.
    try conn.recv.appendSlice("HTTP/1.1 200 OK\r\n\r\nbody");
    _ = fetchjob.FetchJob.step(&fj);
    conn.peer_closed = true;
    try std.testing.expectEqual(job.Step.done, fetchjob.FetchJob.step(&fj));
    try std.testing.expectEqual(@as(usize, 0), conn.reserve_calls);
    try std.testing.expectEqualStrings("body", fj.body);
}

test "no route: start fails the job immediately" {
    var conn = FakeConn{ .start_ok = false, .sent = std.array_list.Managed(u8).init(std.testing.allocator), .recv = std.array_list.Managed(u8).init(std.testing.allocator) };
    defer conn.sent.deinit();
    defer conn.recv.deinit();
    var clk = FakeClock{};
    var fj = fetchjob.FetchJob{ .t = conn.transport(), .clock = clk.clock(), .request = "GET / HTTP/1.1\r\n\r\n" };
    try std.testing.expectEqual(job.Step.failed, fetchjob.FetchJob.step(&fj));
}
