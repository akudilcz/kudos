//! `ping HOST` — four ICMP echo requests, reported in ping(8)'s shape. The
//! sizes printed are the REAL ones this stack sends (net.zig: an 8-byte data
//! payload in a 16-byte ICMP message), not ping(8)'s customary 56/64.

const std = @import("std");
const console = @import("../console.zig");
const network = @import("../network.zig");
const timer = @import("../../kernel/timer/timer.zig");
const sched = @import("../../kernel/sched/sched.zig");

const COUNT: u8 = 4;
const TIMEOUT_MS: u64 = 1000;
const SPACING_MS: u64 = 1000;

pub fn run(c: console.Console, host: []const u8) void {
    if (host.len == 0) {
        c.write("usage: ping HOST\n");
        return;
    }
    const n = network.up(c) orelse return;
    // `resolve` takes a literal address as well as a name, so `ping 10.0.2.2`
    // works with no DNS server in sight.
    const ip = n.resolve(host) orelse {
        c.write("ping: ");
        c.write(host);
        c.write(": name or address not known\n");
        return;
    };

    var buf: [64]u8 = undefined;
    c.write("PING ");
    c.write(host);
    c.write(" (");
    network.writeIp(c, ip);
    c.write(") 8 data bytes\n");
    var recv: u8 = 0;
    var sent: u8 = 0;
    var seq: u8 = 0;
    while (seq < COUNT) : (seq += 1) {
        // ^C between echoes: report what was measured so far and stop.
        if (sched.cancelled()) break;
        sent += 1;
        if (n.ping(ip, TIMEOUT_MS)) |rtt| {
            recv += 1;
            c.write("16 bytes from ");
            network.writeIp(c, ip);
            c.write(std.fmt.bufPrint(&buf, ": icmp_seq={d} time={d} ms\n", .{ seq + 1, rtt }) catch return);
        }
        if (seq < COUNT - 1 and !sched.cancelled()) timer.sleep(SPACING_MS);
    }
    c.write("--- ");
    c.write(host);
    c.write(" ping statistics ---\n");
    c.write(std.fmt.bufPrint(&buf, "{d} packets transmitted, {d} received, {d}% packet loss\n", .{
        sent, recv, if (sent == 0) 0 else @as(u32, sent - recv) * 100 / sent,
    }) catch return);
}
