//! DHCP wire parsing and the lease-acceptance rule — pure, so they can be
//! host-tested (`zig build test`). The IO (broadcast, retry, deadline) and the
//! commit into `config.zig` stay in dhcp.zig.
//!
//! WHY THIS IS NOT IN dhcp.zig. dhcp.zig imports net.zig, which imports the NIC's
//! MMIO, so it cannot compile on the host and nothing in it can be tested. The
//! acceptance rule below is the single most expensive rule in the network stack to
//! get wrong — it already cost us a machine — and until now nothing could check it
//! except booting real hardware and watching the box fail to answer a ping.

const std = @import("std");

// BOOTP fixed-header layout (RFC 2131 §2) and the option codes we consume
// (RFC 2132). Options start after the magic cookie at offset 236+4.
pub const OFF_YIADDR: usize = 16;
pub const BOOTP_FIXED: usize = 240;

pub const OPT_SUBNET: u8 = 1;
pub const OPT_ROUTER: u8 = 3;
pub const OPT_DNS: u8 = 6;
pub const OPT_MSGTYPE: u8 = 53;
pub const OPT_SERVERID: u8 = 54;
pub const OPT_END: u8 = 255;
pub const OPT_PAD: u8 = 0;

pub const DHCPOFFER: u8 = 2;
pub const DHCPACK: u8 = 5;
pub const DHCPNAK: u8 = 6;

/// Everything an ACK/OFFER can tell us. Absent options are `null` — NOT zero, so
/// "the server said 0.0.0.0" stays distinct from "the server said nothing".
pub const Options = struct {
    msg_type: ?u8 = null,
    mask: ?[4]u8 = null,
    gateway: ?[4]u8 = null,
    dns: ?[4]u8 = null,
    server_id: ?[4]u8 = null,
};

/// Walk the TLV option list. Malformed input is TRUNCATED, never trusted: a length
/// byte that runs off the end of the datagram stops the walk rather than indexing
/// past it — this parser reads a buffer any host on the LAN can send us.
pub fn parseOptions(msg: []const u8) Options {
    var o = Options{};
    if (msg.len < BOOTP_FIXED) return o;
    var i: usize = BOOTP_FIXED;
    while (i + 1 < msg.len) {
        const code = msg[i];
        if (code == OPT_END) break;
        if (code == OPT_PAD) {
            i += 1;
            continue;
        }
        const len = msg[i + 1];
        if (i + 2 + @as(usize, len) > msg.len) break; // truncated option: stop, don't read
        const body = msg[i + 2 .. i + 2 + len];
        switch (code) {
            OPT_MSGTYPE => if (len >= 1) {
                o.msg_type = body[0];
            },
            OPT_SUBNET => if (len >= 4) {
                o.mask = body[0..4].*;
            },
            OPT_ROUTER => if (len >= 4) {
                o.gateway = body[0..4].*;
            },
            OPT_DNS => if (len >= 4) {
                o.dns = body[0..4].*; // first server only
            },
            OPT_SERVERID => if (len >= 4) {
                o.server_id = body[0..4].*;
            },
            else => {},
        }
        i += 2 + @as(usize, len);
    }
    return o;
}

/// The `yiaddr` field — the address the server is offering us.
pub fn yiaddr(msg: []const u8) [4]u8 {
    if (msg.len < OFF_YIADDR + 4) return .{ 0, 0, 0, 0 };
    return msg[OFF_YIADDR..][0..4].*;
}

pub fn isZero(ip: [4]u8) bool {
    return std.mem.eql(u8, &ip, &[_]u8{ 0, 0, 0, 0 });
}

/// A lease we are willing to commit.
pub const Lease = struct {
    ip: [4]u8,
    mask: [4]u8,
    gateway: [4]u8, // zero when the server offered none
    dns: [4]u8, // zero when the server offered none
    /// True when the mask was assumed rather than offered — the caller logs it.
    assumed_mask: bool,
};

/// THE LEASE IS THE ADDRESS. Everything else is optional.
///
/// An address alone makes us REACHABLE — ARP, ICMP, KMR1, all the on-subnet traffic the
/// boot path and remote control need. A gateway buys off-subnet routing and a DNS server
/// buys name lookup; those are SERVICES, and a service that needs one must check for it
/// AT USE and fail there. Demanding them up front instead throws away a usable address,
/// and a kudos with no address answers no ARP: no ping, no KMR1, no remote reboot, and
/// no way to tell it apart from a wedged kernel.
///
/// Returns null only when there is genuinely no address to have.
pub fn acceptAck(ip: [4]u8, o: Options) ?Lease {
    if (isZero(ip)) return null; // no address: there is nothing to accept

    // A missing netmask is legal and recoverable: assume the class-C subnet. Being
    // wrong here costs on/off-subnet routing decisions for hosts outside our /24.
    // Being UNCONFIGURED costs the whole machine.
    const assumed = o.mask == null;
    return Lease{
        .ip = ip,
        .mask = o.mask orelse .{ 255, 255, 255, 0 },
        .gateway = o.gateway orelse .{ 0, 0, 0, 0 },
        .dns = o.dns orelse .{ 0, 0, 0, 0 },
        .assumed_mask = assumed,
    };
}
