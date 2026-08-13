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

/// The Ethernet II header: destination address, source address, ethertype.
/// A frame shorter than this carries no addresses, so nothing can be decided
/// about it — every consumer of this contract needs the same floor.
pub const ETHER_HEADER_BYTES: usize = 14;

/// Where the addresses sit inside that header, and how wide they are. The
/// bridge's whole forwarding policy is read from these two fields, on both
/// sides of a seam that may not share a packet-parsing module.
pub const ETHER_ADDR_BYTES: usize = 6;
pub const ETHER_DST_OFF: usize = 0;
pub const ETHER_SRC_OFF: usize = 6;

/// The group bit of an Ethernet address' first byte: set on broadcast and
/// multicast destinations, clear on a unicast one (IEEE 802-2014 §9.2).
pub const ETHER_GROUP_BIT: u8 = 1;

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

// ── the module-fetch mailbox (Interface.net) ─────────────────────────────────
//
// A module runs on its own core and must never touch the stack (core-0-owned,
// single connection), so its fetch is a PARKED REQUEST: it writes url + target
// name, the system core performs the transfer, the module polls the state. The
// body crosses as a ramdisk file, so a download's size is nobody's buffer.
//
// Lock-free like `iwindow`: the request fields are written before `mf_state` is
// released to `.requested` and read after it is acquired, so the state IS the
// barrier. One fetch at a time — the stack has one connection, and a second
// `begin` is refused rather than queued.

const abi = @import("abi");

/// The mailbox's bounds ARE the ABI's — a module is told NET_URL_MAX, and the
/// mailbox refusing a different number would be a contract split in two.
pub const MFETCH_URL_MAX: usize = abi.NET_URL_MAX;
pub const MFETCH_NAME_MAX: usize = 64;

pub const MFetchState = enum(u8) {
    /// No fetch parked; `requestModuleFetch` may start one.
    idle,
    /// Parked, not yet taken by the pump.
    requested,
    /// The pump is transferring.
    in_flight,
    /// The body was written to the ramdisk; `finishModuleFetch` returns to idle.
    done,
    /// The transfer failed; `finishModuleFetch` returns to idle.
    failed,
};

var mf_state: MFetchState = .idle;
var mf_url_buf: [MFETCH_URL_MAX]u8 = undefined;
var mf_url_len: usize = 0;
var mf_name_buf: [MFETCH_NAME_MAX]u8 = undefined;
var mf_name_len: usize = 0;

/// PRODUCER (the module, via its capability adapter): park a fetch of `url`
/// into ramdisk file `name`. False when one is already parked or in flight, or
/// either argument is over its bound.
pub fn requestModuleFetch(url: []const u8, name: []const u8) bool {
    if (@atomicLoad(MFetchState, &mf_state, .acquire) != .idle) return false;
    if (url.len == 0 or url.len > MFETCH_URL_MAX) return false;
    if (name.len == 0 or name.len > MFETCH_NAME_MAX) return false;
    @memcpy(mf_url_buf[0..url.len], url);
    mf_url_len = url.len;
    @memcpy(mf_name_buf[0..name.len], name);
    mf_name_len = name.len;
    @atomicStore(MFetchState, &mf_state, .requested, .release); // barrier: publishes url+name
    return true;
}

pub const MFetchReq = struct { url: []const u8, name: []const u8 };

/// CONSUMER (the system core's pump): take the parked request, moving it to
/// `.in_flight`. The returned slices point into this mailbox and stay valid
/// until the fetch completes (the producer cannot park another until then).
pub fn takeModuleFetchRequest() ?MFetchReq {
    if (@atomicLoad(MFetchState, &mf_state, .acquire) != .requested) return null;
    @atomicStore(MFetchState, &mf_state, .in_flight, .release);
    return .{ .url = mf_url_buf[0..mf_url_len], .name = mf_name_buf[0..mf_name_len] };
}

/// CONSUMER: the transfer ended — the body is on the ramdisk (`ok`) or nothing
/// is (`!ok`).
pub fn completeModuleFetch(ok: bool) void {
    @atomicStore(MFetchState, &mf_state, if (ok) .done else .failed, .release);
}

/// PRODUCER: the parked fetch's current state.
pub fn moduleFetchState() MFetchState {
    return @atomicLoad(MFetchState, &mf_state, .acquire);
}

/// PRODUCER: acknowledge a done/failed result, freeing the slot. A no-op in
/// any other state, so a confused module cannot cancel a live transfer that
/// the pump still owns.
pub fn finishModuleFetch() void {
    const s = @atomicLoad(MFetchState, &mf_state, .acquire);
    if (s == .done or s == .failed) {
        @atomicStore(MFetchState, &mf_state, .idle, .release);
    }
}

// ── the guest-name table ─────────────────────────────────────────────────────
//
// Guest VMs are reachable BY NAME (`host zigserver`, a factory at
// "zigserver:8623") with no configuration: the hypervisor registers each
// guest's catalog id against the MAC it deals that guest, the stack binds the
// address when the guest's DHCP ACK crosses the bridge (guests lease from the
// wire's DHCP server, never from kudos — dhcp_wire.snoopAck), and the
// resolver consults this table after dotted literals, before DNS. The
// hypervisor and the stack may not import each other, so the table lives in
// this leaf, like the frame constants above.
//
// Keyed by MAC, not name: the MAC is derived from the VM slot, so it is known
// at registration, unique per live guest, and still known at teardown — while
// the address does not exist until the guest has run its own DHCP client.
//
// Cross-core like the mailboxes above: register runs on core 0, unregister on
// the guest's own core, bind on whichever task drives the stack, lookup on any
// session. `used` is the publish barrier for the entry's fields; `ip` is a
// separate atomic because it arrives later, from another core.

/// Longest registrable guest name. Catalog ids are single short words.
pub const GUEST_NAME_MAX: usize = 32;

/// Table capacity — one entry per possible live guest. The hypervisor asserts
/// at comptime that its slot count (ivirt.MAX_VMS, which imports this module
/// and so cannot be named here) fits.
pub const GUEST_NAMES: usize = 4;

const GuestName = struct {
    /// Publish barrier: the name and MAC are valid only while this is true.
    used: bool = false,
    mac: [6]u8 = @splat(0),
    /// The bound address as one atomic word (native byte order via @bitCast);
    /// 0 = lease not yet seen. Never a real lease: a server grants no 0.0.0.0.
    ip: u32 = 0,
    name_len: u8 = 0,
    name: [GUEST_NAME_MAX]u8 = undefined,
};

var guest_names: [GUEST_NAMES]GuestName = @splat(.{});

/// HYPERVISOR (core 0, guest start): publish `name` for the guest holding
/// `mac`, with no address yet. Re-registering a MAC replaces its entry (a
/// recycled VM slot deals the same MAC). False when the name does not fit or
/// every entry is taken by another live guest.
pub fn registerGuest(name: []const u8, mac: [6]u8) bool {
    if (name.len == 0 or name.len > GUEST_NAME_MAX) return false;
    var slot: ?usize = null;
    for (&guest_names, 0..) |*e, i| {
        if (@atomicLoad(bool, &e.used, .acquire)) {
            if (std.mem.eql(u8, &e.mac, &mac)) {
                slot = i;
                break;
            }
        } else if (slot == null) slot = i;
    }
    const e = &guest_names[slot orelse return false];
    // Retract while rewriting: a lookup racing this sees the entry absent,
    // never a torn name.
    @atomicStore(bool, &e.used, false, .release);
    e.mac = mac;
    @memcpy(e.name[0..name.len], name);
    e.name_len = @intCast(name.len);
    @atomicStore(u32, &e.ip, 0, .monotonic);
    @atomicStore(bool, &e.used, true, .release);
    return true;
}

/// HYPERVISOR (the core tearing the guest down): the guest holding `mac`
/// stopped — its name resolves no more. A no-op for a MAC never registered,
/// so every teardown path may call it unconditionally.
pub fn unregisterGuest(mac: [6]u8) void {
    for (&guest_names) |*e| {
        if (!@atomicLoad(bool, &e.used, .acquire)) continue;
        if (std.mem.eql(u8, &e.mac, &mac)) @atomicStore(bool, &e.used, false, .release);
    }
}

/// NET STACK: a DHCP ACK for `mac` crossed the bridge — bind its address. A
/// no-op for a MAC not in the table (this host's own lease, or a stranger's).
/// A re-lease simply rebinds.
pub fn bindGuestIp(mac: [6]u8, ip: [4]u8) void {
    const word: u32 = @bitCast(ip);
    if (word == 0) return; // 0 is the "unbound" value, never a lease
    for (&guest_names) |*e| {
        if (!@atomicLoad(bool, &e.used, .acquire)) continue;
        if (std.mem.eql(u8, &e.mac, &mac)) @atomicStore(u32, &e.ip, word, .release);
    }
}

/// RESOLVER: the address bound to guest `name`, or null while the guest has no
/// lease yet (or no such guest runs). An entry whose lease has not landed is
/// skipped, not final — two boots of the same image are two entries.
pub fn lookupGuest(name: []const u8) ?[4]u8 {
    for (&guest_names) |*e| {
        if (!@atomicLoad(bool, &e.used, .acquire)) continue;
        if (!std.mem.eql(u8, e.name[0..e.name_len], name)) continue;
        const word = @atomicLoad(u32, &e.ip, .acquire);
        if (word != 0) return @bitCast(word);
    }
    return null;
}
