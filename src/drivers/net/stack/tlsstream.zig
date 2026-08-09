//! The plaintext byte-stream policy of a TLS session: how much of what the
//! client has decrypted a read hands back, and what a failure is called.
//!
//! Pure — `std` and the vendored client's error set, nothing else — so both
//! decisions are host-testable. They were not, and both were wrong in ways that
//! only a live capture could show:
//!
//! - a read that waited for the CALLER's buffer to fill stalled for fifteen
//!   seconds on a response that had already arrived in full (spec NET-016);
//! - every failure was reported as `ReadFailed`, the API's wrapper, so a
//!   decrypt failure and a silent peer were indistinguishable (spec NET-017).
//!
//! `tls.zig` owns the transport and the session; this owns what the bytes and
//! the errors MEAN, which is the part a test can pin down.

const std = @import("std");
const TlsClient = @import("tlsclient.zig");

/// Hand back everything the client has already decrypted, waiting only if it has
/// nothing at all. Returns 0 at end of stream (spec NET-016).
///
/// `peekGreedy(1)` is the primitive that expresses "wait for SOME plaintext":
/// it fills until at least one byte is buffered, then yields the whole buffered
/// run. What is left after `toss` stays buffered and is served on the next call
/// without touching the wire — which is what server-sent events need (NET-014).
///
/// TWO neighbouring primitives are wrong here, and both look right:
///
/// `readSliceShort` returns short IF AND ONLY IF the stream ended, so with the
/// 16 KiB buffer the HTTP layer passes it waited for 16 KiB of a 900-byte
/// response — the whole answer sat decrypted in memory while the transport
/// counted out its silence budget and then blamed the peer.
///
/// `readVec` looks like the fix and is worse. The client decrypts into its OWN
/// buffer and returns 0 (its vtable is documented to: "implementations may
/// ignore `data`, writing directly to `Reader.buffer` … and returning 0"), so a
/// caller that treats 0 as end-of-stream — which the HTTP body loop does,
/// correctly — reads a complete response as an empty one. That trades a
/// diagnosable hang for silent data loss.
pub fn readAvailable(r: *std.Io.Reader, buf: []u8) std.Io.Reader.Error!usize {
    const avail = r.peekGreedy(1) catch |e| switch (e) {
        // A bare FIN with no close_notify is how most real servers end a
        // response; the HTTP framing above catches genuine truncation.
        error.EndOfStream => return 0,
        error.ReadFailed => return error.ReadFailed,
    };
    const n = @min(buf.len, avail.len);
    @memcpy(buf[0..n], avail[0..n]);
    r.toss(n);
    return n;
}

/// What a transport waiting for the next byte should do now.
pub const Wait = enum {
    /// Nothing has arrived yet and both budgets still allow waiting.
    keep_waiting,
    /// No byte within the per-byte budget: the peer has gone quiet.
    stalled,
    /// The session has outlived its total budget however much progress it made.
    too_long,
};

/// Decide between waiting, giving up on a quiet peer, and giving up on a session
/// that will not end (spec NET-020).
///
/// TWO budgets, and the second exists because the first cannot express it. The
/// stall budget is renewed on every byte, deliberately, so a large download is
/// not punished for being large — but that makes it renewable forever by a peer
/// sending one byte just inside each window. Since a request holds the whole
/// network stack for its duration, "forever" would not be one slow transfer; it
/// would be every other network user on the machine queued behind a session that
/// never ends. The total budget is never renewed, so it is the one that
/// terminates.
pub fn verdict(now_ms: u64, stall_deadline_ms: u64, session_deadline_ms: u64) Wait {
    if (now_ms >= session_deadline_ms) return .too_long;
    if (now_ms >= stall_deadline_ms) return .stalled;
    return .keep_waiting;
}

/// Name what actually went wrong (spec NET-017).
///
/// The client reports every read fault as `ReadFailed` and records the real
/// cause in `read_err`, so naming `fallback` alone reports a fact about the API
/// rather than about the failure — a `TlsBadRecordMac` and a peer that hung up
/// arrive at the trace as the same word, which is where debugging https stops.
pub fn describeRead(read_err: ?TlsClient.ReadError, fallback: anyerror) []const u8 {
    const cause: anyerror = read_err orelse fallback;
    return @errorName(cause);
}
