//! Host tests of the TLS session's plaintext byte-stream policy.
//!
//! The fake reader here matters as much as the assertions: it mimics the
//! vendored TLS client exactly — it decrypts into the READER'S OWN buffer and
//! returns 0, which its vtable is documented to allow. Every wrong primitive
//! tried against this bug looked correct until it met that behaviour, so a fake
//! that returned a byte count would have passed all of them.

const std = @import("std");
const tlsstream = @import("tlsstream");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// A reader that behaves like the TLS client: each trip to the "wire" moves one
/// scripted record into `Reader.buffer` and returns 0.
const FakeClient = struct {
    reader: std.Io.Reader,
    script: []const u8,
    sent: usize = 0,
    /// Trips to the transport. The point of the whole fix is that this stays
    /// small — bytes already decrypted must not cost another one.
    trips: usize = 0,
    /// Bytes moved per trip, standing in for one TLS record.
    record: usize,
    buf: [4096]u8 = undefined,

    fn init(self: *FakeClient, script: []const u8, record: usize) void {
        self.script = script;
        self.sent = 0;
        self.trips = 0;
        self.record = record;
        self.reader = .{
            .vtable = &.{ .stream = stream },
            .buffer = &self.buf,
            .seek = 0,
            .end = 0,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        const self: *FakeClient = @alignCast(@fieldParentPtr("reader", r));
        self.trips += 1;
        if (self.sent >= self.script.len) return error.EndOfStream;
        const take = @min(self.record, self.script.len - self.sent);
        // Straight into the reader's buffer, exactly as the client does.
        @memcpy(r.buffer[r.end..][0..take], self.script[self.sent..][0..take]);
        r.end += take;
        self.sent += take;
        return 0; // decrypted into `buffer`, nothing written to `w`
    }
};

test "a short response is delivered whole on the first read (NET-016)" {
    var fake: FakeClient = undefined;
    const body = "x" ** 900;
    fake.init(body, body.len);

    // The caller's buffer is far larger than the response — the exact shape
    // that stalled for fifteen seconds, because the old primitive waited for
    // 16 KiB of a 900-byte answer that had already arrived in full.
    var buf: [16 * 1024]u8 = undefined;
    const n = try tlsstream.readAvailable(&fake.reader, &buf);

    try expectEqual(@as(usize, 900), n);
    try expectEqualStrings(body, buf[0..n]);
    try expectEqual(@as(usize, 1), fake.trips);
}

test "buffered bytes are served without another trip to the wire (NET-016)" {
    var fake: FakeClient = undefined;
    const body = "y" ** 3000;
    fake.init(body, body.len); // one record holds it all

    // Three small reads over one decrypted record. A server-sent-event consumer
    // reads exactly like this, and every trip it does not have to make is an
    // event delivered when it crossed the wire rather than when the buffer
    // happened to fill.
    var small: [1000]u8 = undefined;
    var total: usize = 0;
    for (0..3) |_| total += try tlsstream.readAvailable(&fake.reader, &small);

    try expectEqual(@as(usize, 3000), total);
    try expectEqual(@as(usize, 1), fake.trips);
}

test "a reader that buffers and returns zero still yields its bytes (NET-016)" {
    var fake: FakeClient = undefined;
    const body = "abcdefghij";
    fake.init(body, 4); // three records: 4 + 4 + 2

    // This is the case that makes `readVec` wrong: the client returns 0 while
    // making progress, so a caller counting that return reads a complete
    // response as an empty one — silent data loss rather than a visible hang.
    var buf: [64]u8 = undefined;
    var got: [16]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const k = try tlsstream.readAvailable(&fake.reader, &buf);
        if (k == 0) break;
        @memcpy(got[n..][0..k], buf[0..k]);
        n += k;
    }
    try expectEqualStrings(body, got[0..n]);
}

test "end of stream is a zero-length read, not a failure (NET-016)" {
    var fake: FakeClient = undefined;
    fake.init("", 16);

    // Real servers end a response with a bare FIN and no close_notify; treating
    // that as an error breaks nearly every site.
    var buf: [64]u8 = undefined;
    try expectEqual(@as(usize, 0), try tlsstream.readAvailable(&fake.reader, &buf));
}

test "a peer that drips one byte per window is eventually cut off (NET-020)" {
    const stall: u64 = 15_000;
    const total: u64 = 120_000;

    // Progress renews the per-byte budget, deliberately — a big download must
    // not be punished for being big. Walk a peer that answers just inside every
    // stall window and confirm the SESSION budget is what finally ends it,
    // because the renewable one never will.
    var now: u64 = 0;
    var stall_deadline: u64 = stall;
    var ended_at: ?u64 = null;
    while (now < 10 * total) : (now += stall - 1) {
        switch (tlsstream.verdict(now, stall_deadline, total)) {
            .keep_waiting => stall_deadline = now + stall, // a byte arrived
            .stalled => return error.StalledDespiteProgress,
            .too_long => {
                ended_at = now;
                break;
            },
        }
    }
    try expect(ended_at != null);
    try expect(ended_at.? >= total);
}

test "a quiet peer is stalled, not merely slow (NET-020)" {
    // Inside both budgets: wait.
    try expect(tlsstream.verdict(10, 100, 1000) == .keep_waiting);
    // Past the per-byte budget only: the peer went quiet.
    try expect(tlsstream.verdict(150, 100, 1000) == .stalled);
    // Past the total: that verdict wins, because it is the one that cannot be
    // renewed and so the one that guarantees the session ends.
    try expect(tlsstream.verdict(1500, 9999, 1000) == .too_long);
}

test "a decrypt failure is named as one, never as the API's wrapper (NET-017)" {
    // The client reports every read fault as ReadFailed and puts the real cause
    // in read_err. Naming only the wrapper is what made a corrupted record and
    // a silent peer arrive at the trace as the same word.
    try expectEqualStrings("TlsBadRecordMac", tlsstream.describeRead(error.TlsBadRecordMac, error.ReadFailed));
    try expectEqualStrings("TlsAlert", tlsstream.describeRead(error.TlsAlert, error.ReadFailed));
    try expectEqualStrings("TlsConnectionTruncated", tlsstream.describeRead(error.TlsConnectionTruncated, error.ReadFailed));

    // With nothing recorded below, the caller's own error is the best available.
    try expectEqualStrings("ReadFailed", tlsstream.describeRead(null, error.ReadFailed));
}
