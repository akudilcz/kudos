//! `ip [addr|route]` — the leased address configuration, in iproute2's shape.
//! `net0` is kudos's name for its one interface; the DNS server rides the addr
//! block because this shell has no resolv.conf to hold it.

const std = @import("std");
const console = @import("../console.zig");
const network = @import("../network.zig");

pub fn run(c: console.Console, args: []const u8) void {
    const n = network.any(c) orelse return;
    if (!n.isUp()) {
        c.write("net0: <DOWN>\n");
        return;
    }
    const lease = n.lease();
    const want_addr = args.len == 0 or std.mem.eql(u8, args, "addr") or std.mem.eql(u8, args, "a");
    const want_route = args.len == 0 or std.mem.eql(u8, args, "route") or std.mem.eql(u8, args, "r");
    if (!want_addr and !want_route) {
        c.write("usage: ip [addr|route]\n");
        return;
    }
    if (want_addr) {
        var buf: [64]u8 = undefined;
        c.write("net0: <UP,LOWER_UP>\n");
        c.write(std.fmt.bufPrint(&buf, "    link/ether {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}\n", .{
            lease.mac[0], lease.mac[1], lease.mac[2], lease.mac[3], lease.mac[4], lease.mac[5],
        }) catch return);
        c.write("    inet ");
        network.writeIp(c, lease.ip);
        c.write(std.fmt.bufPrint(&buf, "/{d}\n", .{network.prefixLen(lease.netmask)}) catch return);
        c.write("    dns ");
        network.writeIp(c, lease.dns);
        c.put('\n');
    }
    if (want_route) {
        c.write("default via ");
        network.writeIp(c, lease.gateway);
        c.write(" dev net0\n");
    }
}
