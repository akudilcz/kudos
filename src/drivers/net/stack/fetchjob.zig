//! A resumable HTTP GET as a cooperative job (kernel/sched/job.zig) — the
//! exemplar of the bite-a-chunk pattern on the network path.
//!
//! A blocking fetch of a multi-megabyte body holds core 0 for the whole
//! transfer and starves the 60 Hz compositor (measured: a 3.7 MB fetch left the
//! render quiet 6-9 s and tripped the deadman). This job does not block: each
//! `step` sends the request or absorbs whatever the connection has received so
//! far and checks for a complete response, then returns. The session loop pumps
//! the TCP receive buffer (it grows) and this job once per frame, so
//! downloading and rendering interleave — a chunk of each, every frame.
//!
//! IO is a seam (`Transport`) and time is a seam (`Clock`), so the state machine
//! is pure and host-tested against fakes; the kernel wires the seams to tcp.zig
//! and the timer. Framing is the pure http_wire vocabulary, shared with the
//! blocking http.zig client so there is one definition of "a complete response".

const std = @import("std");
const job = @import("job");
const http_wire = @import("http_wire.zig");

/// Connection progress the transport reports.
pub const ConnState = enum { connecting, established, failed };

/// The non-blocking IO the job drives. The kernel implements it over tcp.zig
/// (one connection, its growing receive buffer); a test implements it in RAM.
pub const Transport = struct {
    ctx: *anyopaque,
    /// Begin connecting (send SYN); false = no route, the job fails at once.
    start: *const fn (ctx: *anyopaque) bool,
    /// Where the handshake stands right now (driven by the loop's RX pump).
    poll: *const fn (ctx: *anyopaque) ConnState,
    /// Send request bytes on the established connection; false = send failed.
    send: *const fn (ctx: *anyopaque, bytes: []const u8) bool,
    /// Every response byte received so far (grows across steps).
    received: *const fn (ctx: *anyopaque) []const u8,
    /// True once the peer closed (FIN/RST) — the end of a close-delimited body.
    closed: *const fn (ctx: *anyopaque) bool,
};

pub const Clock = struct {
    ctx: *anyopaque,
    millis: *const fn (ctx: *anyopaque) u64,
};

/// Budget for the NEXT byte, not the whole transfer: renewed whenever the
/// received buffer grows, so transfer time scales with the body while a peer
/// that goes silent still fails within one window (same rule as http.zig).
pub const STALL_MS: u64 = 8_000;

pub const Phase = enum { connecting, sending, receiving, done, failed };

/// A transfer's standing, as `FetchJob.progress` reports it.
pub const Progress = struct { received: usize, total: ?usize };

pub const FetchJob = struct {
    t: Transport,
    clock: Clock,
    /// The prebuilt request (head, plus body for a POST — GET is head only).
    request: []const u8,

    phase: Phase = .connecting,
    started: bool = false,
    seen: usize = 0, // received().len at the last step, to detect progress
    deadline: u64 = 0,

    // Result, valid once phase == .done:
    status: u16 = 0,
    /// The response body — a slice into the transport's received buffer, so the
    /// finish callback must copy it before the connection is reused.
    body: []const u8 = &.{},

    // Transfer progress, maintained by `frame` while receiving — what a
    // progress display reads through `progress()`.
    got_body: usize = 0,
    total_body: ?usize = null,

    fn renew(self: *FetchJob) void {
        self.deadline = self.clock.millis(self.clock.ctx) + STALL_MS;
    }

    fn expired(self: *FetchJob) bool {
        return self.clock.millis(self.clock.ctx) >= self.deadline;
    }

    /// One bounded step. Never blocks: it inspects current connection state and
    /// the bytes received so far, does O(header) framing work, and returns.
    pub fn step(ctx: *anyopaque) job.Step {
        const self: *FetchJob = @ptrCast(@alignCast(ctx));
        switch (self.phase) {
            .connecting => {
                if (!self.started) {
                    if (!self.t.start(self.t.ctx)) return self.fail();
                    self.started = true;
                    self.renew();
                }
                return switch (self.t.poll(self.t.ctx)) {
                    .established => self.beginSend(),
                    .failed => self.fail(),
                    .connecting => if (self.expired()) self.fail() else .working,
                };
            },
            .sending => {
                if (!self.t.send(self.t.ctx, self.request)) return self.fail();
                self.phase = .receiving;
                self.renew();
                return .working;
            },
            .receiving => {
                const r = self.t.received(self.t.ctx);
                if (r.len > self.seen) { // progress renews the stall budget
                    self.seen = r.len;
                    self.renew();
                }
                if (self.frame(r)) |complete| {
                    return if (complete) self.finishBody(r) else if (self.expired()) self.fail() else .working;
                }
                // No header yet: complete only when the peer closes (unlikely
                // this early), else keep waiting within the stall budget.
                if (self.t.closed(self.t.ctx)) return self.finishBody(r);
                return if (self.expired()) self.fail() else .working;
            },
            .done, .failed => return if (self.phase == .done) .done else .failed,
        }
    }

    fn beginSend(self: *FetchJob) job.Step {
        self.phase = .sending;
        self.renew();
        return .working;
    }

    fn fail(self: *FetchJob) job.Step {
        self.phase = .failed;
        return .failed;
    }

    /// Whether `r` frames a complete response yet: null = header not in yet;
    /// true/false = header present, body complete/incomplete. Content-Length and
    /// close-delimited only (chunked decode is a follow-on). Also keeps the
    /// progress fields current — this is the one place the body is measured.
    fn frame(self: *FetchJob, r: []const u8) ?bool {
        const split = http_wire.splitHead(r) orelse return null;
        self.got_body = split.body.len;
        if (contentLength(split.head)) |cl| {
            self.total_body = cl;
            return split.body.len >= cl;
        }
        // No Content-Length: close-delimited; completeness is the peer's close,
        // handled by the caller. Report "header present, not yet complete".
        return false;
    }

    /// How far the transfer has come: response-body bytes received so far, and
    /// the body's full size once the Content-Length header is in (null before
    /// that, and for a close-delimited body throughout).
    pub fn progress(self: *const FetchJob) Progress {
        return .{ .received = self.got_body, .total = self.total_body };
    }

    fn finishBody(self: *FetchJob, r: []const u8) job.Step {
        const split = http_wire.splitHead(r) orelse return self.fail();
        const line_end = std.mem.indexOfScalar(u8, split.head, '\r') orelse split.head.len;
        self.status = http_wire.parseStatus(split.head[0..line_end]) orelse return self.fail();
        if (self.status < 200 or self.status >= 300) return self.fail();
        self.body = if (contentLength(split.head)) |cl| split.body[0..@min(cl, split.body.len)] else split.body;
        self.phase = .done;
        return .done;
    }
};

fn contentLength(head: []const u8) ?usize {
    const v = http_wire.headerValue(head, "Content-Length") orelse return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, v, " "), 10) catch null;
}
