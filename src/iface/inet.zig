//! INet — the network as an application sees it.
//!
//! An app wants to know whether it is online, turn a hostname into an address, ping
//! something, and fetch a URL. It does not want to know that there is an Intel I226
//! behind a DHCP client behind an ARP cache. This vtable is that whole surface, and it
//! is deliberately small: everything below it — Ethernet, IP, UDP, TCP, DHCP, DNS —
//! is an implementation detail of the network group.
//!
//! Real implementation: `src/drivers/net/stack/net.zig` publishes one at boot, wiring these
//! calls to the live stack. Fake: a test can publish its own and exercise an app's
//! network commands with no hardware and no LAN.
//!
//! LEAF module: pure types only, so the kernel and the host tests both compile it.

const std = @import("std");

/// Largest Ethernet frame the network carries: 1500-byte MTU payload plus the
/// 14-byte header, no FCS (no consumer of this contract sees one) and no jumbo
/// frames. Owned here because both the stack below this contract and the
/// hypervisor's guest bridge above it size buffers from it, and they may not
/// import each other.
pub const ETHER_FRAME_MAX: usize = 1514;

/// Everything a fetch can fail with. Spelled out rather than inferred because a vtable
/// needs a concrete error set — and because an app that prints these to a user should
/// be able to see the whole list it must account for.
pub const FetchError = error{
    /// The stack is not up: no NIC, or no address lease.
    NoNetwork,
    /// The URL did not parse (only `http://host[:port]/path` is understood).
    BadUrl,
    /// The URL is too long to fit in the request we would have to send.
    UrlTooLong,
    /// The hostname has no address.
    DnsFailed,
    /// The peer refused the connection, or never answered the handshake.
    ConnectFailed,
    /// The peer hung up mid-transfer.
    ConnectionReset,
    /// A send did not go out.
    SendFailed,
    /// The peer went quiet for too long.
    Timeout,
    /// The TLS handshake or decrypt failed (https) — including a server
    /// certificate chain that did not verify against the trusted CA set, or a
    /// host name the certificate was not issued for (NET-011).
    TlsFailed,
    /// HTTPS refused because the wall clock is absent or impossibly early, so
    /// certificate validity cannot be established (NET-015). Verification is
    /// never bypassed; fix the RTC and retry.
    ClockUnset,
    /// A GET's response status was not 2xx — the body is an error page, not the
    /// resource. `fetch` fails rather than hand back (or save) a 404/500 page as
    /// if it were the file. `post` does NOT raise this: its callers (the agent's
    /// compile loop) need the 4xx body's error text.
    BadStatus,
    /// A backgrounded fetch is already in flight (there is one TCP connection).
    Busy,
    OutOfMemory,
};

/// Completion of a `fetchBackground`: `body` is the response (a slice valid only
/// for the duration of this call — copy it), or null on any failure. Runs on the
/// session loop's core when the job retires.
pub const FetchDone = *const fn (ctx: *anyopaque, body: ?[]const u8) void;

/// A background transfer's standing: response-body bytes received so far, and
/// the body's full size once the server has stated it (null before the response
/// header arrives, and throughout a close-delimited body).
pub const FetchProgress = struct { received: u64, total: ?u64 };

/// One HTTP request header a caller supplies with `post`. Owned by this
/// contract (not the wire layer) because it is part of what an app states
/// about its request; the stack emits each verbatim after its own
/// Host/Connection/Content-Length lines.
pub const Header = struct { name: []const u8, value: []const u8 };

/// Incremental body consumer for `postStream`: `write` receives decoded body
/// bytes the moment they arrive (a server-sent-event consumer sees each event
/// as it crosses the wire). Return false to end the transfer early — e.g.
/// after the SSE `[DONE]` sentinel.
pub const BodySink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, chunk: []const u8) bool,
};

/// The address the network is currently using. All-zero fields mean "no lease" — this
/// is what the stack was GIVEN, not what it wishes it had.
pub const Lease = struct {
    mac: [6]u8 = .{0} ** 6,
    ip: [4]u8 = .{0} ** 4,
    netmask: [4]u8 = .{0} ** 4,
    gateway: [4]u8 = .{0} ** 4,
    dns: [4]u8 = .{0} ** 4,
};

pub const VTable = struct {
    /// Bring the stack up: claim a NIC and acquire an address. Returns false if either
    /// step fails. Idempotent — calling it while already up changes nothing, so a
    /// command may call it freely without first checking `isUp`.
    ///
    /// There is no static-address fallback on purpose: a stack that quietly invents an
    /// address looks up while every packet vanishes, and the failure then surfaces
    /// somewhere far away from the cause.
    bringUp: *const fn (ctx: *anyopaque) bool,

    /// True once a NIC is claimed and an address is held.
    isUp: *const fn (ctx: *anyopaque) bool,

    /// The current address configuration (all-zero when down).
    lease: *const fn (ctx: *anyopaque) Lease,

    /// Look a hostname up. Null when it has no address, or when the lookup timed out —
    /// the caller cannot tell those apart and does not need to.
    resolve: *const fn (ctx: *anyopaque, host: []const u8) ?[4]u8,

    /// Send one echo request and wait up to `timeout_ms` for the reply. Returns the
    /// round-trip time in milliseconds, or null if nothing came back.
    ping: *const fn (ctx: *anyopaque, dst: [4]u8, timeout_ms: u64) ?u64,

    /// Fetch a URL over HTTP and return the response body. The caller owns the returned
    /// memory and frees it with the same allocator.
    fetch: *const fn (ctx: *anyopaque, a: std.mem.Allocator, url: []const u8) FetchError![]u8,

    /// POST `body` to a URL with the caller's `headers` (Content-Type,
    /// Authorization, ...) and return the response body. The caller owns the
    /// returned memory. Used by the agent to reach the LLM.
    post: *const fn (ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) FetchError![]u8,

    /// POST `body` and STREAM the response to `sink` as it arrives (NET-014) —
    /// how a server-sent-event response is consumed. Returns once the stream
    /// ends, the framing completes, or the sink stops it.
    postStream: *const fn (ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8, sink: BodySink) FetchError!void,

    /// Start a GET that runs in the BACKGROUND: it returns at once, the transfer
    /// advances one bounded step per session-loop frame (so a big download does
    /// not stall the 60 Hz render), and `on_done(cb_ctx, body)` fires when it
    /// finishes — body on success, null on failure. `Busy` if one is already in
    /// flight (single connection). Plain HTTP only for now.
    fetchBackground: *const fn (ctx: *anyopaque, a: std.mem.Allocator, url: []const u8, cb_ctx: *anyopaque, on_done: FetchDone) FetchError!void,

    /// The in-flight background GET's standing, or null when none is running.
    /// A read-only probe for progress display; it never affects the transfer.
    fetchProgress: *const fn (ctx: *anyopaque) ?FetchProgress,
};

pub const INet = struct {
    ctx: *anyopaque,
    vt: *const VTable,

    pub fn bringUp(self: INet) bool {
        return self.vt.bringUp(self.ctx);
    }
    pub fn isUp(self: INet) bool {
        return self.vt.isUp(self.ctx);
    }
    pub fn lease(self: INet) Lease {
        return self.vt.lease(self.ctx);
    }
    pub fn resolve(self: INet, host: []const u8) ?[4]u8 {
        return self.vt.resolve(self.ctx, host);
    }
    pub fn ping(self: INet, dst: [4]u8, timeout_ms: u64) ?u64 {
        return self.vt.ping(self.ctx, dst, timeout_ms);
    }
    pub fn fetch(self: INet, a: std.mem.Allocator, url: []const u8) FetchError![]u8 {
        return self.vt.fetch(self.ctx, a, url);
    }
    pub fn post(self: INet, a: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8) FetchError![]u8 {
        return self.vt.post(self.ctx, a, url, headers, body);
    }
    pub fn postStream(self: INet, a: std.mem.Allocator, url: []const u8, headers: []const Header, body: []const u8, sink: BodySink) FetchError!void {
        return self.vt.postStream(self.ctx, a, url, headers, body, sink);
    }
    pub fn fetchBackground(self: INet, a: std.mem.Allocator, url: []const u8, cb_ctx: *anyopaque, on_done: FetchDone) FetchError!void {
        return self.vt.fetchBackground(self.ctx, a, url, cb_ctx, on_done);
    }
    pub fn fetchProgress(self: INet) ?FetchProgress {
        return self.vt.fetchProgress(self.ctx);
    }
};

/// The live network, published by the stack at boot. Null when no network stack was
/// brought up at all — an app must handle that and say so rather than pretending.
pub var instance: ?INet = null;
