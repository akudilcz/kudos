//! Pure HTTP/1.1 wire helpers: URL parsing, request-head building, status/header
//! parsing, and an incremental chunked-transfer decoder. No sockets, no
//! allocation on the hot path — so the framing the in-kernel HTTP client relies
//! on is host-tested directly, including the split cases (a chunk header or
//! terminator straddling two reads) that only show up under a real socket.
//! The TLS/TCP transport and the streaming SSE sink
//! are layered on top; this module knows nothing about them.

const std = @import("std");
const inet = @import("inet");

/// Capacity for a full request head (request line + Host/Connection/
/// Content-Length + caller headers). The one buffer size every foreground
/// request stages its head into.
pub const MAX_REQUEST_HEAD: usize = 2048;

/// The two header names that frame a response body (RFC 9112 §6).
const TRANSFER_ENCODING = "Transfer-Encoding";
const CONTENT_LENGTH = "Content-Length";

pub const Scheme = enum { http, https };

pub const Url = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    path: []const u8,
};

pub const UrlError = error{ BadScheme, EmptyHost };

/// Parse `scheme://host[:port]/path`. Slices point into `url`. Default port is
/// 80 for http and 443 for https; a missing path becomes "/".
pub fn parseUrl(url: []const u8) UrlError!Url {
    var scheme: Scheme = undefined;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, "https://")) {
        scheme = .https;
        rest = url["https://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        scheme = .http;
        rest = url["http://".len..];
    } else return error.BadScheme;

    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const authority = if (slash) |i| rest[0..i] else rest;
    const path = if (slash) |i| rest[i..] else "/";

    var host = authority;
    var port: u16 = if (scheme == .https) 443 else 80;
    if (std.mem.indexOfScalar(u8, authority, ':')) |c| {
        host = authority[0..c];
        port = std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch port;
    }
    if (host.len == 0) return error.EmptyHost;
    return .{ .scheme = scheme, .host = host, .port = port, .path = path };
}

/// Build the request head (request line + headers + terminating blank line) into
/// `buf`. `Host` is always added; `Content-Length` is added when `body_len > 0`
/// or `method` is POST; caller `extra` headers (inet.Header — the app-seam
/// contract type) follow verbatim. Returns the used slice or error.NoSpace.
pub fn buildRequestHead(
    buf: []u8,
    method: []const u8,
    host: []const u8,
    path: []const u8,
    extra: []const inet.Header,
    body_len: usize,
) error{NoSpace}![]u8 {
    var fw = std.Io.Writer.fixed(buf);
    const w = &fw;
    write(w, method) catch return error.NoSpace;
    write(w, " ") catch return error.NoSpace;
    write(w, path) catch return error.NoSpace;
    write(w, " HTTP/1.1\r\nHost: ") catch return error.NoSpace;
    write(w, host) catch return error.NoSpace;
    write(w, "\r\nConnection: close\r\n") catch return error.NoSpace;
    if (body_len > 0 or std.mem.eql(u8, method, "POST")) {
        w.print("Content-Length: {d}\r\n", .{body_len}) catch return error.NoSpace;
    }
    for (extra) |h| {
        w.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.NoSpace;
    }
    write(w, "\r\n") catch return error.NoSpace;
    return fw.buffered();
}

fn write(w: anytype, s: []const u8) !void {
    try w.writeAll(s);
}

/// Parse the numeric status from a status line ("HTTP/1.1 200 OK").
pub fn parseStatus(status_line: []const u8) ?u16 {
    var it = std.mem.tokenizeScalar(u8, status_line, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code = it.next() orelse return null;
    return std.fmt.parseInt(u16, code, 10) catch null;
}

/// Case-insensitive header lookup within a raw header block (CRLF-separated
/// lines, no trailing blank line required). Returns the trimmed value.
pub fn headerValue(header_block: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header_block, "\r\n");
    while (lines.next()) |line| {
        const c = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..c], " \t"), name)) {
            return std.mem.trim(u8, line[c + 1 ..], " \t");
        }
    }
    return null;
}

/// How a response body is framed, read from the raw header block. Chunked wins
/// over Content-Length (RFC 9112 §6.3): a chunked response reports
/// `content_length = null` even if it also carries the header. Both null means
/// close-delimited — the body ends at end of stream. The ONE interpretation of
/// Transfer-Encoding/Content-Length; the buffered and streaming clients both
/// frame through it.
pub const Framing = struct { chunked: bool, content_length: ?usize };

pub fn framing(head: []const u8) Framing {
    if (headerValue(head, TRANSFER_ENCODING)) |te| {
        if (std.ascii.indexOfIgnoreCase(te, "chunked") != null)
            return .{ .chunked = true, .content_length = null };
    }
    if (headerValue(head, CONTENT_LENGTH)) |v| {
        return .{
            .chunked = false,
            .content_length = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null,
        };
    }
    return .{ .chunked = false, .content_length = null };
}

/// Split a response buffer at the header/body boundary (the first blank line).
/// Returns .{ headers, body } or null if the terminator has not arrived yet.
pub fn splitHead(buf: []const u8) ?struct { head: []const u8, body: []const u8 } {
    const term = std.mem.indexOf(u8, buf, "\r\n\r\n") orelse return null;
    return .{ .head = buf[0..term], .body = buf[term + 4 ..] };
}

/// Incremental decoder for `Transfer-Encoding: chunked`. Feed body bytes with
/// `push`; decoded payload is appended to `out`. `done` becomes true at the
/// terminating zero-length chunk. Handles chunk headers and data split across
/// arbitrary feed boundaries.
pub const ChunkedDecoder = struct {
    const State = enum { size, data, cr_after_data, lf_after_data, trailer };
    state: State = .size,
    remaining: usize = 0,
    size_seen: bool = false,
    done: bool = false,
    /// The chunk-size line as received so far. 32 bytes holds any hex size
    /// prefix that can fit in usize; a line that fills it is already oversize
    /// and fails parseHexPrefix's range check at the newline.
    line_buf: [32]u8 = undefined,
    line_len: usize = 0,

    pub fn push(self: *ChunkedDecoder, chunk: []const u8, out: *std.array_list.Managed(u8)) !void {
        var i: usize = 0;
        while (i < chunk.len and !self.done) {
            switch (self.state) {
                .size => {
                    const b = chunk[i];
                    i += 1;
                    if (b == '\n') {
                        self.remaining = try parseHexPrefix(self.line_buf[0..self.line_len]);
                        self.line_len = 0;
                        if (self.remaining == 0) {
                            self.done = true;
                        } else {
                            self.state = .data;
                        }
                    } else if (b != '\r') {
                        // Overflow only truncates ";ext" tail bytes: a hex prefix
                        // long enough to fill the line is already over usize and
                        // fails parseHexPrefix's range check at the newline.
                        if (self.line_len < self.line_buf.len) {
                            self.line_buf[self.line_len] = b;
                            self.line_len += 1;
                        }
                    }
                },
                .data => {
                    const take = @min(self.remaining, chunk.len - i);
                    try out.appendSlice(chunk[i .. i + take]);
                    i += take;
                    self.remaining -= take;
                    if (self.remaining == 0) self.state = .cr_after_data;
                },
                .cr_after_data => {
                    if (chunk[i] == '\r') i += 1;
                    self.state = .lf_after_data;
                },
                .lf_after_data => {
                    if (chunk[i] == '\n') i += 1;
                    self.state = .size;
                },
                .trailer => i += 1,
            }
        }
    }
};

fn parseHexPrefix(s: []const u8) error{InvalidChunkSize}!usize {
    // Chunk size may be followed by ";ext"; take leading hex digits only.
    var v: usize = 0;
    for (s) |c| {
        const d: usize = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => break,
        };
        // A size that cannot fit usize is not a size — reject the hostile
        // line instead of wrapping into a bogus one.
        if (v > (std.math.maxInt(usize) - d) / 16) return error.InvalidChunkSize;
        v = v * 16 + d;
    }
    return v;
}

/// Incremental response extractor for a STREAMED transfer (spec NET-014):
/// buffers raw wire bytes until the header/body split, reads the body framing
/// from the head (chunked, Content-Length, or close-delimited), then emits
/// decoded body bytes to `out` on every subsequent `push` — the caller sees a
/// server-sent-event stream event by event, never "when the connection
/// closes". Pure over bytes, host-tested across hostile split boundaries.
pub const StreamingBody = struct {
    headbuf: std.array_list.Managed(u8),
    state: enum { head, body } = .head,
    chunked: bool = false,
    content_length: ?usize = null,
    body_seen: usize = 0,
    dec: ChunkedDecoder = .{},

    pub fn init(a: std.mem.Allocator) StreamingBody {
        return .{ .headbuf = std.array_list.Managed(u8).init(a) };
    }

    pub fn deinit(self: *StreamingBody) void {
        self.headbuf.deinit();
    }

    /// Feed raw wire bytes; decoded body bytes are appended to `out`. Returns
    /// true when the response is COMPLETE (chunked terminator seen, or
    /// Content-Length reached); a close-delimited body completes only when the
    /// caller sees end of stream.
    pub fn push(self: *StreamingBody, bytes: []const u8, out: *std.array_list.Managed(u8)) !bool {
        var rest = bytes;
        if (self.state == .head) {
            try self.headbuf.appendSlice(rest);
            const split = splitHead(self.headbuf.items) orelse return false;
            const fr = framing(split.head);
            self.chunked = fr.chunked;
            self.content_length = fr.content_length;
            self.state = .body;
            // The body bytes that arrived glued to the head continue below.
            rest = split.body;
        }
        if (self.chunked) {
            try self.dec.push(rest, out);
            return self.dec.done;
        }
        if (self.content_length) |cl| {
            const take = @min(rest.len, cl - self.body_seen);
            try out.appendSlice(rest[0..take]);
            self.body_seen += take;
            return self.body_seen >= cl;
        }
        try out.appendSlice(rest);
        self.body_seen += rest.len;
        return false; // close-delimited: complete only at end of stream
    }
};
