//! The console's handle on the network: the lazy bring-up every network command
//! shares, and the address formatting they all print.
//!
//! Bring-up is HERE rather than in a command because there is no longer one
//! network command to hang it off: `ip`, `ping`, `host` and `curl` each need the
//! NIC claimed and a lease taken, and each must trigger that at most once.
//! Boot never stalls on DHCP — nothing is attempted until someone asks.

const std = @import("std");
const inet = @import("inet");
const console = @import("console.zig");

/// Whether bring-up has been attempted. One attempt only: after it runs `isUp`
/// reflects the result, and a second command must not pay the DHCP timeout again.
var tried = false;

/// The network with its NIC claimed and a lease taken, or a printed complaint and
/// null. Every network command starts here: there may be no stack in this build,
/// and a command that silently does nothing is worse than one that says why.
pub fn up(c: console.Console) ?inet.INet {
    const n = inet.instance orelse {
        c.write("no network stack in this build\n");
        return null;
    };
    if (!tried) {
        tried = true;
        _ = n.bringUp();
    }
    if (!n.isUp()) {
        c.write("network is down\n");
        return null;
    }
    return n;
}

/// The network without requiring it to be up — for `ip` , which must be able to
/// report a DOWN link rather than refuse to run.
pub fn any(c: console.Console) ?inet.INet {
    const n = inet.instance orelse {
        c.write("no network stack in this build\n");
        return null;
    };
    if (!tried) {
        tried = true;
        _ = n.bringUp();
    }
    return n;
}

/// Write an IPv4 address as dotted-decimal.
pub fn writeIp(c: console.Console, ip: [4]u8) void {
    var buf: [16]u8 = undefined;
    c.write(std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] }) catch return);
}

/// A netmask as a CIDR prefix length, the form `ip addr` prints. Counts set bits
/// rather than assuming a contiguous mask, so an odd mask reports what it is.
pub fn prefixLen(mask: [4]u8) u8 {
    var bits: u8 = 0;
    for (mask) |b| bits += @popCount(b);
    return bits;
}
