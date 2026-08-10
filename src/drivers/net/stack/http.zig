//! The kernel's single HTTP/1.1 client. One `request` turns a method + URL +
//! headers + body into a response body — for BOTH transports (plain TCP and
//! TLS) and BOTH verbs (GET, POST). Scheme selects the transport; nothing else
//! differs, so there is exactly one place that speaks HTTP. All wire framing
//! (URL parse, request head, header/body split, chunked decode) is the pure,
//! host-tested vocabulary of http_wire.zig; this file only moves bytes and
//! drives the transport.
//!
//! Both verbs send `Connection: close`, so a complete response is bounded by the
//! peer closing the stream (plain FIN or TLS close_notify): the read loop runs
//! to end-of-stream, then the body is framed by Transfer-Encoding/Content-Length.

const std = @import("std");
const tcp = @import("tcp.zig");
const tls = @import("tls.zig");
const net = @import("net.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const http_wire = @import("http_wire.zig");
const inet = @import("inet");

/// Bytes of request pushed per TCP segment: the one-connection stream builds a
/// single segment per `send`, so long bodies are handed over in MTU-sized runs.
const SEND_CHUNK: usize = 1400;
/// Response staging buffer. One TLS record is at most 16 KiB; a matching size
/// keeps the plain path's copies coarse too.
const READ_CHUNK: usize = 16 * 1024;

pub const Method = enum {
    GET,
    POST,

    fn name(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
        };
    }
};

/// The response byte stream, abstracted over transport. `writeAll` sends request
/// bytes; `read` fills `buf` and returns 0 at end of stream. The plain arm talks
/// straight to tcp.zig; the tls arm drives a TLS session (tls.zig).
const Stream = union(enum) {
    plain: Plain,
    tls: *tls.Session,

    fn writeAll(self: *Stream, bytes: []const u8) inet.FetchError!void {
        switch (self.*) {
            .plain => |*p| return p.writeAll(bytes),
            .tls => |s| return s.writeAll(bytes),
        }
    }

    fn read(self: *Stream, buf: []u8) inet.FetchError!usize {
        switch (self.*) {
            .plain => |*p| return p.read(buf),
            .tls => |s| return s.read(buf),
        }
    }
};

/// Plain-TCP transport: send over tcp.send; read the growing receive buffer via
/// a consumed offset — the same shape the TLS stream uses beneath the cipher.
const Plain = struct {
    consumed: usize = 0,
    deadline_ms: u64,
    /// How long this request waits for the NEXT byte — the method's budget,
    /// carried on the stream so the renewal below uses the same number the open
    /// did rather than a constant that only matches for a GET.
    stall_ms: u64,

    fn writeAll(self: *Plain, bytes: []const u8) inet.FetchError!void {
        _ = self;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = @min(SEND_CHUNK, bytes.len - off);
            if (!tcp.send(bytes[off .. off + n])) return error.SendFailed;
            off += n;
        }
    }

    fn read(self: *Plain, buf: []u8) inet.FetchError!usize {
        while (tcp.received().len <= self.consumed) {
            if (tcp.finished()) return 0; // orderly FIN — end of a close-delimited body
            if (tcp.wasReset()) return error.ConnectionReset; // peer aborted
            if (timer.millis() >= self.deadline_ms) return error.Timeout;
            _ = tcp.pumpUntil(self.consumed, self.deadline_ms);
        }
        const src = tcp.received()[self.consumed..];
        const n = @min(buf.len, src.len);
        @memcpy(buf[0..n], src[0..n]);
        self.consumed += n;
        // Progress renews the stall budget (http_wire.stallMs).
        self.deadline_ms = timer.millis() + self.stall_ms;
        return n;
    }
};

/// Everything both request paths share before their read loops: check the
/// stack is up, parse the URL, resolve the host, open the receive buffer and
/// the connection, build and send the request head (+ body), and select the
/// transport by scheme. On failure the connection is closed here; on success
/// the CALLER owns the close (`defer tcp.close()`). `session` is caller-owned
/// storage because the tls arm of the returned Stream points into it.
fn openAndSend(
    a: std.mem.Allocator,
    method: Method,
    url: []const u8,
    headers: []const inet.Header,
    body: []const u8,
    session: *tls.Session,
) inet.FetchError!Stream {
    if (!net.isUp()) return error.NoNetwork;
    const u = http_wire.parseUrl(url) catch return error.BadUrl;
    const ip = net.resolveHost(u.host) orelse return error.DnsFailed;

    tcp.beginRecv(a);
    errdefer tcp.close();
    if (!tcp.connect(ip, u.port)) return error.ConnectFailed;

    var headbuf: [http_wire.MAX_REQUEST_HEAD]u8 = undefined;
    const head = http_wire.buildRequestHead(&headbuf, method.name(), u.host, u.path, headers, body.len) catch
        return error.UrlTooLong;

    // Open the transport, then run one identical send sequence over it.
    var stream: Stream = undefined;
    if (u.scheme == .https) {
        session.* = try tls.open(u.host);
        stream = .{ .tls = session };
    } else {
        const stall_ms = http_wire.stallMs(method == .POST);
        stream = .{ .plain = .{ .deadline_ms = timer.millis() + stall_ms, .stall_ms = stall_ms } };
    }
    errdefer if (stream == .tls) session.close();

    try stream.writeAll(head);
    if (body.len != 0) try stream.writeAll(body);
    return stream;
}

/// Issue one request and return the decoded response body (caller owns it).
/// `headers` are sent verbatim after the always-present Host/Connection/
/// Content-Length; `body` is used only when non-empty (POST). Scheme in `url`
/// picks the transport.
pub fn request(
    a: std.mem.Allocator,
    method: Method,
    url: []const u8,
    headers: []const inet.Header,
    body: []const u8,
) inet.FetchError![]u8 {
    var session: tls.Session = undefined;
    var stream = try openAndSend(a, method, url, headers, body, &session);
    defer tcp.close();
    defer if (stream == .tls) session.close(); // releases the heap-owned TLS client

    var resp = std.array_list.Managed(u8).init(a);
    defer resp.deinit();
    // Heap, not a frame: READ_CHUNK on the stack put this frame over the
    // 16 KiB budget; one request-lifetime allocation is free by comparison.
    const chunk = a.alloc(u8, READ_CHUNK) catch return error.OutOfMemory;
    defer a.free(chunk);
    while (true) {
        const n = stream.read(chunk) catch |e| {
            // A transport error with nothing received is the failure; once a full
            // response has been framed, an abrupt close after it is not.
            if (frameComplete(resp.items)) break;
            return e;
        };
        if (n == 0) break; // end of stream (FIN / close_notify)
        resp.appendSlice(chunk[0..n]) catch return error.OutOfMemory;
        if (frameComplete(resp.items)) break; // whole body in hand — stop early
    }

    // A GET that did not succeed returned an error page, not the resource — fail
    // rather than hand it back (net fetch would save a 404 as the model file).
    // POST is exempt: the agent's compile loop reads the 422 body's error text.
    if (method == .GET) {
        if (http_wire.splitHead(resp.items)) |split| {
            const line_end = std.mem.indexOfScalar(u8, split.head, '\r') orelse split.head.len;
            const status = http_wire.parseStatus(split.head[0..line_end]) orelse return error.BadStatus;
            if (status < 200 or status >= 300) return error.BadStatus;
        }
    }

    return decodeBody(a, resp.items);
}

/// True once `raw` holds a complete Content-Length response — a cheap early-stop
/// so the read loop need not wait for the peer's close. Chunked and
/// close-delimited responses have no cheap completeness test, so this stays
/// false for them; they end on end-of-stream (`n == 0`), which is guaranteed
/// because every request carries `Connection: close`.
fn frameComplete(raw: []const u8) bool {
    const split = http_wire.splitHead(raw) orelse return false;
    if (http_wire.framing(split.head).content_length) |cl| return split.body.len >= cl;
    return false;
}

/// Decode the response body: chunked -> reassembled payload; Content-Length ->
/// exactly that many bytes; otherwise (close-delimited) -> everything after the
/// header terminator.
fn decodeBody(a: std.mem.Allocator, raw: []const u8) inet.FetchError![]u8 {
    const split = http_wire.splitHead(raw) orelse return a.dupe(u8, raw);
    const fr = http_wire.framing(split.head);
    if (fr.chunked) {
        var out = std.array_list.Managed(u8).init(a);
        errdefer out.deinit();
        var dec = http_wire.ChunkedDecoder{};
        // A peer that frames its body illegally ends the transfer as surely as
        // a hangup.
        dec.push(split.body, &out) catch |e| return switch (e) {
            error.InvalidChunkSize => error.ConnectionReset,
            error.OutOfMemory => error.OutOfMemory,
        };
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
    if (fr.content_length) |cl| {
        return a.dupe(u8, split.body[0..@min(cl, split.body.len)]);
    }
    return a.dupe(u8, split.body);
}

/// Issue one request and stream the DECODED response body to `sink` as bytes
/// arrive (spec NET-014) — an SSE consumer sees each event when it crosses the
/// wire, not when the connection closes. The sink returning false stops the
/// transfer early (e.g. after the `[DONE]` sentinel). Same transports, same
/// framing vocabulary as `request`; only delivery differs.
pub fn requestStream(
    a: std.mem.Allocator,
    method: Method,
    url: []const u8,
    headers: []const inet.Header,
    body: []const u8,
    sink: inet.BodySink,
) inet.FetchError!void {
    var session: tls.Session = undefined;
    var stream = try openAndSend(a, method, url, headers, body, &session);
    defer tcp.close();
    defer if (stream == .tls) session.close(); // releases the heap-owned TLS client

    var framing = http_wire.StreamingBody.init(a);
    defer framing.deinit();
    var decoded = std.array_list.Managed(u8).init(a);
    defer decoded.deinit();

    // Heap, not a frame — same budget rationale as `request`.
    const chunk = a.alloc(u8, READ_CHUNK) catch return error.OutOfMemory;
    defer a.free(chunk);
    var delivered: usize = 0;
    while (true) {
        const n = stream.read(chunk) catch |e| {
            // Once at least one body byte was delivered, an abrupt close ends
            // the stream like a FIN; before that it is the failure it is.
            if (delivered != 0) return;
            return e;
        };
        if (n == 0) return; // end of stream — close-delimited bodies end here
        const complete = framing.push(chunk[0..n], &decoded) catch |e| return switch (e) {
            error.InvalidChunkSize => error.ConnectionReset,
            error.OutOfMemory => error.OutOfMemory,
        };
        if (decoded.items.len != 0) {
            const keep_going = sink.write(sink.ctx, decoded.items);
            delivered += decoded.items.len;
            decoded.clearRetainingCapacity();
            if (!keep_going) return; // consumer saw its sentinel
        }
        if (complete) return; // framing says the body is whole
    }
}
