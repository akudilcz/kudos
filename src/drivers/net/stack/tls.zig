//! TLS 1.2/1.3 as a byte-stream SESSION over the single-connection TCP stream
//! (tcp.zig), driving the vendored std.crypto TLS client (tlsclient.zig). This
//! file is ONLY the crypto seam: the ciphertext transport the client reads and
//! writes through — a `std.Io.Reader`/`std.Io.Writer` pair over tcp.send and
//! tcp.received — plus `open`/`Session`: handshake, then plaintext
//! `writeAll`/`read`. It knows nothing about HTTP; the one HTTP client
//! (http.zig) layers request framing on top, identically for the plain and TLS
//! transports.
//!
//! This module offers no unauthenticated mode (spec NET-011): `open` always
//! verifies the server's certificate chain against the embedded trusted-CA set
//! (roots.zig) for the explicit SNI host, at the wall-clock time the kernel RTC
//! established, and the vendored client's no-verification and self-signed arms
//! are deleted so a bypass does not compile. A clock that cannot establish
//! certificate validity refuses the connection (spec NET-015).

const std = @import("std");
const TlsClient = @import("tlsclient.zig");
const tlsstream = @import("tlsstream.zig");
const tcp = @import("tcp.zig");
const roots = @import("roots.zig");
const sched = @import("../../../kernel/sched/sched.zig");
const timer = @import("../../../kernel/timer/timer.zig");
const wallclock = @import("../../../kernel/timer/wallclock.zig");
const entropy = @import("../../../kernel/cpu/entropy.zig");
const heap = @import("../../../kernel/memory/heap.zig");
const klog = @import("../../../kernel/debug/klog.zig");
const inet = @import("inet");

/// Budget for the NEXT byte, not the whole transaction: the transport renews it
/// on progress, so transfer time scales with body size while a peer that goes
/// silent still fails within one window. A whole-transaction cap made any
/// response larger than the link could move in the window impossible — the same
/// bug fixed for plain HTTP (http_wire.GET_STALL_MS). Generous, since TLS adds
/// handshake round trips.
const TLS_STALL_MS: u64 = 15_000;

/// Ceiling on a whole TLS session, however much progress it makes (spec
/// NET-020).
///
/// The stall budget above is deliberately renewed on every byte, so a large
/// download is not punished for being large. On its own that is a hole: a peer
/// sending one byte every fourteen seconds renews it forever, and because a
/// request now HOLDS the network stack for its duration, "forever" is not just
/// this transfer — it is every other network user on the machine, waiting behind
/// a session that will never finish. Two minutes is far beyond any legitimate
/// exchange kudos makes and far short of indefinite.
const TLS_SESSION_MS: u64 = 120_000;

/// The client asserts its input buffer holds a whole ciphertext record, so this
/// is a floor, not a preference (TlsClient.min_buffer_len).
const RECORD_LEN: usize = TlsClient.min_buffer_len;
/// Plaintext headroom above the record floor: what a `read` can take in one
/// call without another trip to the wire.
const PLAINTEXT_LEN: usize = 16 * 1024;
/// The ciphertext side's buffer, and a FLOOR set by the client, not a
/// preference: it encrypts each record by taking `writableSliceGreedy(
/// min_buffer_len)` from this writer and encrypting into it in place. A smaller
/// buffer can never satisfy that request, and the client answers by draining and
/// asking again — forever, with nothing to send, which presents as a wedged core
/// rather than an error.
const SOCKET_WRITE_LEN: usize = RECORD_LEN;

/// Why a transport call failed. `std.Io` reports only ReadFailed/WriteFailed —
/// the cause is recorded here, the way std's own stream adapters do it, so a
/// stall is never confused with a reset or an orderly close.
const TransportError = error{ TlsTcpStall, TlsTcpReset, TlsTcpSend, TlsSessionTooLong, TlsCancelled };

/// The ciphertext transport: kudos' one TCP connection presented as the
/// Reader/Writer pair the TLS client drives. It moves BYTES ON THE WIRE; every
/// bit of crypto sits above it.
///
/// `reader` and `writer` are FIELDS, and the vtable functions recover this
/// struct with `@fieldParentPtr`, so the transport must live at a stable
/// address for the life of the session — it is heap-owned by `State` below.
const Transport = struct {
    reader: std.Io.Reader,
    writer: std.Io.Writer,
    /// How much of tcp's growing receive buffer the client has consumed — the
    /// moral equivalent of a file offset.
    consumed: usize = 0,
    /// Renewed on progress; see TLS_STALL_MS.
    deadline_ms: u64,
    /// NOT renewed, ever: the whole session's ceiling (TLS_SESSION_MS).
    session_deadline_ms: u64 = 0,
    err: ?TransportError = null,
    read_buf: [RECORD_LEN]u8 = undefined,
    write_buf: [SOCKET_WRITE_LEN]u8 = undefined,

    /// Wire the interfaces to THIS object's buffers. Written in place, never
    /// through a temporary: the vtables recover the transport by field offset,
    /// so the address it is initialised at is the one it must keep.
    fn init(self: *Transport, deadline_ms: u64) void {
        self.consumed = 0;
        self.deadline_ms = deadline_ms;
        self.session_deadline_ms = timer.millis() + TLS_SESSION_MS;
        self.err = null;
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

    /// Hand the client the next unread span of received bytes, pumping the
    /// connection until at least one new byte arrives. `error.EndOfStream` is an
    /// orderly FIN. A reset is never EOF: the peer abandoned the stream
    /// mid-record, so reporting an end would present a truncated body as a
    /// complete one.
    fn streamIn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Transport = @alignCast(@fieldParentPtr("reader", r));
        // This call's verdict, not a previous one's. `err` is only ever read
        // after a failure, and leaving a stale value latched made every later
        // failure in the session report the FIRST one's cause — a reset arriving
        // after an earlier stall read as "peer went silent".
        self.err = null;
        while (tcp.received().len <= self.consumed) {
            if (tcp.wasReset()) {
                self.err = error.TlsTcpReset;
                return error.ReadFailed;
            }
            if (tcp.finished()) return error.EndOfStream;
            // ^C: an https agent stream renews its stall budget as long as the
            // peer trickles bytes — the requesting task's cancel ends it early.
            if (sched.cancelled()) {
                self.err = error.TlsCancelled;
                return error.ReadFailed;
            }
            switch (tlsstream.verdict(timer.millis(), self.deadline_ms, self.session_deadline_ms)) {
                .keep_waiting => {},
                .stalled => {
                    self.err = error.TlsTcpStall;
                    return error.ReadFailed;
                },
                .too_long => {
                    self.err = error.TlsSessionTooLong;
                    return error.ReadFailed;
                },
            }
            _ = tcp.pumpUntil(self.consumed, self.deadline_ms);
        }
        const src = limit.sliceConst(tcp.received()[self.consumed..]);
        const dest = try w.writableSliceGreedy(1);
        const n = @min(dest.len, src.len);
        @memcpy(dest[0..n], src[0..n]);
        w.advance(n);
        self.consumed += n;
        self.deadline_ms = timer.millis() + TLS_STALL_MS; // progress renews the budget
        return n;
    }

    /// Send: the buffered bytes first, then each slice, then the last slice
    /// repeated `splat` times. TLS is a byte stream, so segment boundaries do
    /// not matter and each slice can go out as it stands.
    fn drainOut(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Transport = @alignCast(@fieldParentPtr("writer", w));
        self.err = null; // this call's verdict, not a previous one's (see streamIn)
        var total: usize = 0; // everything sent, buffered bytes included
        const buffered = w.buffered();
        if (buffered.len != 0) {
            try self.send(buffered);
            total += buffered.len;
        }
        if (data.len != 0) {
            for (data[0 .. data.len - 1]) |bytes| {
                if (bytes.len == 0) continue;
                try self.send(bytes);
                total += bytes.len;
            }
            const pattern = data[data.len - 1];
            if (pattern.len != 0) for (0..splat) |_| {
                try self.send(pattern);
                total += pattern.len;
            };
        }
        // `consume` turns bytes-sent into the bytes-taken-from-`data` the caller
        // is owed, and clears what it took from the buffer.
        return w.consume(total);
    }

    fn send(self: *Transport, bytes: []const u8) std.Io.Writer.Error!void {
        if (!tcp.send(bytes)) {
            self.err = error.TlsTcpSend;
            return error.WriteFailed;
        }
    }
};

/// Everything one session owns, in one heap allocation: the transport (whose
/// address the client's Reader/Writer capture), the client, and the record
/// buffers the client was handed. Tens of KiB — far more than the kernel task
/// stack should carry, which is why it is never a local.
const State = struct {
    transport: Transport,
    client: TlsClient,
    /// The handshake's record staging (tlsclient.HandshakeScratch): 32 KiB that
    /// upstream keeps in `init`'s frame and a kernel task stack cannot.
    handshake: TlsClient.HandshakeScratch,
    /// Where each outgoing record is assembled before encryption — caller-owned
    /// for the same reason.
    record: [std.crypto.tls.max_ciphertext_len]u8,
    tls_read_buf: [RECORD_LEN + PLAINTEXT_LEN]u8,
    tls_write_buf: [RECORD_LEN]u8,
};

/// A live TLS session over the current TCP connection: a plaintext byte stream
/// (`writeAll`/`read`) with the cipher handled beneath. The HTTP client drives
/// this exactly like the plain-TCP transport, so request framing has one home.
pub const Session = struct {
    /// Heap-owned. Owner: this Session; release path: `close`.
    state: *State,

    /// Release what `open` acquired. The TCP connection is closed by the HTTP
    /// layer (`tcp.close`), which owns that resource.
    pub fn close(self: *Session) void {
        heap.allocator().destroy(self.state);
        self.state = undefined;
    }

    /// Name what went wrong on the trace before collapsing it to the one error
    /// the fetch API carries (spec NET-017). Without this a decrypt failure, a
    /// silent peer and a reset all read as "TlsFailed", which is where debugging
    /// https stops.
    ///
    /// THREE layers have to be asked, because each hides the one below it. The
    /// std client reports every read fault as `ReadFailed` and records the real
    /// cause in `read_err` — so `@errorName(e)` alone turns a `TlsBadRecordMac`
    /// into "ReadFailed", which is a fact about the API and not about the
    /// failure. Below that, the transport records whether the byte stream itself
    /// stalled, reset, or failed to send. A session that spent a day being
    /// diagnosed as a network problem was a decrypt failure the whole time.
    fn fail(self: *Session, what: []const u8, e: anyerror) inet.FetchError {
        // A cancel is the CALLER's act, not a TLS failure — report it as what
        // it is, and skip the diagnosis a real fault deserves.
        if (self.state.transport.err) |t| if (t == error.TlsCancelled) return error.Cancelled;
        var buf: [160]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&buf, "tls: {s} failed: {s}{s}{s}\n", .{
            what,
            tlsstream.describeRead(self.state.client.read_err, e),
            if (self.state.client.read_err != null) " (client)" else "",
            if (self.state.transport.err) |t| switch (t) {
                error.TlsTcpStall => " (transport: peer went silent)",
                error.TlsSessionTooLong => " (transport: session exceeded its total budget)",
                error.TlsTcpReset => " (transport: connection reset)",
                error.TlsTcpSend => " (transport: send failed)",
                error.TlsCancelled => " (cancelled)",
            } else "",
        }) catch "tls: session failed\n");
        return error.TlsFailed;
    }

    /// Encrypt and send `bytes`, then push them onto the wire: the caller's next
    /// act is to wait for a reply, so nothing may sit in the buffer.
    pub fn writeAll(self: *Session, bytes: []const u8) inet.FetchError!void {
        const c = &self.state.client;
        c.writer.writeAll(bytes) catch |e| return self.fail("write", e);
        // TWO buffers, so two flushes. The client's flush turns plaintext into
        // records and leaves them in the TRANSPORT's buffer — it never touches
        // the wire itself (even `end`, sending close_notify, only advances that
        // buffer). Flushing the transport is what hands them to tcp.send, and
        // without it the request sits in RAM while the caller waits for a reply
        // that cannot come.
        c.writer.flush() catch |e| return self.fail("flush", e);
        self.state.transport.writer.flush() catch |e| return self.fail("send", e);
    }

    /// Decrypt up to `buf.len` bytes. Returns 0 at end of stream — either a
    /// proper TLS close_notify OR a plain TCP FIN without one.
    ///
    /// Real HTTPS servers (google, most CDNs) end a response by closing the TCP
    /// connection with a bare FIN and no close_notify. Treating that as a
    /// failure breaks nearly every real site — the whole body has already been
    /// delivered, the peer just skipped the courtesy alert — so the client is
    /// built with `allow_truncation_attacks`, which forwards the end of stream
    /// here as a short read, exactly as curl and browsers do. Genuine truncation
    /// is still caught one layer up by HTTP framing: a short Content-Length body
    /// or an unterminated chunked stream. Other TLS errors (a real decrypt
    /// failure, a transport reset mid-record) still propagate as TlsFailed.
    /// Returns as soon as ANY plaintext is available — it does NOT wait for
    /// `buf` to fill (spec NET-016).
    ///
    /// `readSliceShort` was the wrong primitive here, and expensively so: it
    /// returns short if and only if the stream ENDED, so with the 16 KiB buffer
    /// both callers pass, a 900-byte response made this wait for 15484 bytes
    /// that were never coming. The whole response sat decrypted in memory while
    /// the transport counted out its 15-second silence budget and reported "peer
    /// went silent" — about a peer that had answered in full. It also made
    /// server-sent events over HTTPS (NET-014) impossible, because no event
    /// could be delivered until 16 KiB of them had accumulated.
    ///
    /// `peek(1)` is the primitive that says "wait for SOME plaintext": it fills
    /// until at least one byte is decrypted, then `buffered` hands over
    /// everything the client already has and `toss` consumes it.
    ///
    /// `readVec` is NOT usable here, and the reason is worth stating because it
    /// reads like it should be: the client decrypts ONE record per call into its
    /// OWN buffer and returns 0, so a caller treating 0 as end-of-stream — which
    /// http.zig's body loop does, correctly — sees an empty response body while
    /// the data sits decrypted one layer down.
    pub fn read(self: *Session, buf: []u8) inet.FetchError!usize {
        return tlsstream.readAvailable(&self.state.client.reader, buf) catch |e|
            self.fail("read", e);
    }
};

/// Open a TLS session over the already-connected TCP stream (tcp.connect must
/// have succeeded), running the handshake with full chain verification against
/// the embedded trusted roots. Fails ClockUnset before touching the wire when
/// the wall clock cannot establish certificate validity (NET-015).
pub fn open(host: []const u8) inet.FetchError!Session {
    const now = wallclock.epochSeconds();
    if (!roots.clockEstablishesValidity(now)) return error.ClockUnset;
    const now_sec = now.?;

    // Build the trust bundle on first use (parse-once; later calls are free).
    const stats = roots.ensure(heap.allocator(), @embedFile("cacert_pem"), now_sec) catch {
        klog.puts("tls: trusted-root bundle failed to load — refusing https\n");
        return error.TlsFailed;
    };
    if (stats.skipped != 0) {
        var buf: [64]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&buf, "tls: roots loaded {d}, skipped {d}\n", .{ stats.loaded, stats.skipped }) catch "");
    }

    // The client's whole entropy requirement, from the kernel source. A short
    // fill is a refusal, never a weaker handshake.
    var seed: [TlsClient.Options.entropy_len]u8 = undefined;
    if (!entropy.fill(&seed)) {
        klog.puts("tls: no entropy source — refusing https\n");
        return error.TlsFailed;
    }

    const a = heap.allocator();
    const state = a.create(State) catch return error.OutOfMemory;
    errdefer a.destroy(state);
    state.transport.init(timer.millis() + TLS_STALL_MS);

    state.client = TlsClient.init(&state.transport.reader, &state.transport.writer, .{
        .host = .{ .explicit = host },
        .ca = .{ .bundle = roots.bundlePtr().? }, // ensure() above built it
        .read_buffer = &state.tls_read_buf,
        .write_buffer = &state.tls_write_buf,
        .entropy = &seed,
        .handshake_scratch = &state.handshake,
        .record_scratch = &state.record,
        // The kernel wall clock, in the shape std names time: nanoseconds since
        // the epoch. Certificate NotBefore/NotAfter are checked against it.
        .realtime_now = .{ .nanoseconds = @as(i96, now_sec) * std.time.ns_per_s },
        // HTTP framing detects truncation (see Session.read), and without this a
        // bare-FIN close — what most real servers do — reads as an error.
        .allow_truncation_attacks = true,
    }) catch |e| {
        // Name what failed. A handshake has many ways to end and they call for
        // different fixes — an expired clock, a root the bundle lacks, a peer
        // that hung up — so a single "TlsFailed" on the trace is a dead end for
        // whoever has to work out why https stopped working.
        var buf: [96]u8 = undefined;
        klog.puts(std.fmt.bufPrint(&buf, "tls: handshake with {s} failed: {s}{s}\n", .{
            host,
            @errorName(e),
            if (state.transport.err) |t| switch (t) {
                error.TlsTcpStall => " (transport: peer went silent)",
                error.TlsSessionTooLong => " (transport: session exceeded its total budget)",
                error.TlsTcpReset => " (transport: connection reset)",
                error.TlsTcpSend => " (transport: send failed)",
                error.TlsCancelled => " (cancelled)",
            } else "",
        }) catch "tls: handshake failed\n");
        if (state.transport.err) |t| if (t == error.TlsCancelled) return error.Cancelled;
        return error.TlsFailed;
    };
    return .{ .state = state };
}
