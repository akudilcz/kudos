//! Host tests of the TLS 1.3 client's OWN moves (src/drivers/net/stack/
//! tlsclient.zig): the ClientHello it opens with, and how it fails when the
//! peer misbehaves. There is no TLS server on the host to complete a handshake
//! against (and the client's patched Options make verification mandatory, so a
//! canned transcript cannot satisfy it either) — what is provable here is that
//! the first flight is well-formed before a single byte is read, and that a
//! hostile or dead peer produces a clean error, never a hang or a crash. The
//! key schedule beneath is vector-proven separately (tlskeys_test, RFC 8448).

const std = @import("std");
const tlsclient = @import("testroot").net.tlsclient;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A fixed date inside the shipped trust bundle's validity, so Options carries
/// a sane wall clock (nothing here reaches certificate checks — the peer dies
/// first).
const NOW_SEC: i64 = 1_754_000_000;

/// The ciphertext transport the client is given, in the same shape the kernel
/// supplies (tls.zig `Transport`): a `std.Io.Reader` serving a canned script and
/// a `std.Io.Writer` capturing every byte sent. Held at a stable address — the
/// vtable functions recover it by field offset.
const Peer = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    script: []const u8 = &.{},
    read_at: usize = 0,
    captured: [8192]u8 = undefined,
    n: usize = 0,
    /// The client asserts its input can hold a whole record.
    read_buf: [tlsclient.min_buffer_len]u8 = undefined,
    write_buf: [1024]u8 = undefined,

    fn init(self: *Peer, script: []const u8) void {
        self.script = script;
        self.read_at = 0;
        self.n = 0;
        self.reader = .{
            .vtable = &.{ .stream = streamIn },
            .buffer = &self.read_buf,
            .seek = 0,
            .end = 0,
        };
        self.writer = .{
            .vtable = &.{ .drain = drainOut },
            .buffer = &self.write_buf,
            .end = 0,
        };
    }

    /// Serve the script; running out is the peer closing the connection.
    fn streamIn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Peer = @alignCast(@fieldParentPtr("reader", r));
        if (self.read_at >= self.script.len) return error.EndOfStream;
        const src = limit.sliceConst(self.script[self.read_at..]);
        const dest = try w.writableSliceGreedy(1);
        const n = @min(dest.len, src.len);
        @memcpy(dest[0..n], src[0..n]);
        w.advance(n);
        self.read_at += n;
        return n;
    }

    /// Capture, in the order the bytes would reach the wire.
    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Peer = @alignCast(@fieldParentPtr("writer", w));
        self.append(w.buffer[0..w.end]);
        w.end = 0;
        if (data.len == 0) return 0;
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.append(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| self.append(pattern);
        consumed += pattern.len * splat;
        return consumed;
    }

    fn append(self: *Peer, bytes: []const u8) void {
        const take = @min(bytes.len, self.captured.len - self.n);
        @memcpy(self.captured[self.n..][0..take], bytes[0..take]);
        self.n += take;
    }

    fn sent(self: *Peer) []const u8 {
        return self.captured[0..self.n];
    }
};

/// Run a handshake against `script` and leave everything the client sent in
/// `peer`. The flush is what a failed handshake would otherwise strand in the
/// transport's buffer — the point of these tests is the bytes, error or not.
fn handshake(peer: *Peer, script: []const u8) !void {
    peer.init(script);
    var read_buf: [tlsclient.min_buffer_len + 4096]u8 = undefined;
    var write_buf: [tlsclient.min_buffer_len]u8 = undefined;
    var entropy: [tlsclient.Options.entropy_len]u8 = @splat(0x2A);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    // The staging the kernel owns for the client (see tlsclient's header): kept
    // off this frame here too, so the test does not carry what the kernel refuses to.
    const scratch = try std.testing.allocator.create(tlsclient.HandshakeScratch);
    defer std.testing.allocator.destroy(scratch);
    const record = try std.testing.allocator.create([std.crypto.tls.max_ciphertext_len]u8);
    defer std.testing.allocator.destroy(record);
    defer peer.writer.flush() catch {};
    _ = try tlsclient.init(&peer.reader, &peer.writer, .{
        .host = .{ .explicit = "lemon.test" },
        .ca = .{ .bundle = &bundle },
        .read_buffer = &read_buf,
        .write_buffer = &write_buf,
        .entropy = &entropy,
        .handshake_scratch = scratch,
        .record_scratch = record,
        .realtime_now = .{ .nanoseconds = @as(i96, NOW_SEC) * std.time.ns_per_s },
    });
}

test "init speaks first: a well-formed TLS 1.3 ClientHello before any read" {
    var peer: Peer = undefined;
    // The peer never answers; init must still have SENT its hello. A stream that
    // ends before the handshake completes is a TRUNCATED connection — the client
    // names it that rather than reporting a transport read failure.
    try std.testing.expectError(error.TlsConnectionTruncated, handshake(&peer, &.{}));
    const b = peer.sent();
    try expect(b.len > 50);
    // TLS record header: handshake(22), legacy record version 3.1.
    try expectEqual(@as(u8, 22), b[0]);
    try expectEqual(@as(u8, 3), b[1]);
    try expectEqual(@as(u8, 1), b[2]);
    // Record length covers exactly the rest of the flight.
    const rec_len = (@as(usize, b[3]) << 8) | b[4];
    try expectEqual(b.len - 5, rec_len);
    // Handshake header: client_hello(1).
    try expectEqual(@as(u8, 1), b[5]);
}

test "the ClientHello carries the server name it was asked to verify (SNI)" {
    var peer: Peer = undefined;
    handshake(&peer, &.{}) catch {};
    try expect(std.mem.indexOf(u8, peer.sent(), "lemon.test") != null);
}

test "the ClientHello offers TLS 1.3 in supported_versions" {
    var peer: Peer = undefined;
    handshake(&peer, &.{}) catch {};
    // supported_versions extension (type 0x002B): find its header, then the
    // 0x0304 (TLS 1.3) pair must sit inside its short version list.
    const b = peer.sent();
    const ext = std.mem.indexOf(u8, b, &.{ 0x00, 0x2B }) orelse return error.NoSupportedVersionsExtension;
    try expect(std.mem.indexOf(u8, b[ext..@min(b.len, ext + 12)], &.{ 0x03, 0x04 }) != null);
}

test "a garbage first record from the peer is a clean error, never a hang or crash" {
    var peer: Peer = undefined;
    const garbage = [_]u8{0x55} ** 64;
    if (handshake(&peer, &garbage)) |_| return error.HandshakeShouldHaveFailed else |_| {}
}

test "an alert record from the peer surfaces as an error" {
    var peer: Peer = undefined;
    // alert(21), version 3.3, length 2: fatal(2) handshake_failure(40).
    const alert = [_]u8{ 21, 3, 3, 0, 2, 2, 40 };
    if (handshake(&peer, &alert)) |_| return error.HandshakeShouldHaveFailed else |_| {}
}
