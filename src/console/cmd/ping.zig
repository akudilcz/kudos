//! `ping [-c COUNT] [-i SECS] HOST` — ICMP echo requests, reported in ping(8)'s
//! shape. The sizes printed are the REAL ones this stack sends (net.zig: an
//! 8-byte data payload in a 16-byte ICMP message), not ping(8)'s customary
//! 56/64. Default four echoes a second apart, as ping's own defaults are.

const std = @import("std");
const console = @import("../console.zig");
const network = @import("../network.zig");
const opt = @import("../opt.zig");
const timer = @import("../../kernel/timer/timer.zig");
const sched = @import("../../kernel/sched/sched.zig");

const DEFAULT_COUNT: u32 = 4;
const TIMEOUT_MS: u64 = 1000;
const DEFAULT_SPACING_S: u64 = 1;

const USAGE = "usage: ping [-c COUNT] [-i SECS] HOST\n";

pub fn run(c: console.Console, args: []const u8) void {
    var count: u32 = DEFAULT_COUNT;
    var spacing_ms: u64 = DEFAULT_SPACING_S * 1000;
    var sc = opt.Scan.init("c:i:", args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'c' => count = std.fmt.parseInt(u32, v.arg, 10) catch 0,
            'i' => spacing_ms = 1000 * (std.fmt.parseInt(u64, v.arg, 10) catch return usageErr(c)),
            else => return opt.refuse(c, "ping", o, USAGE),
        },
        else => return opt.refuse(c, "ping", o, USAGE),
    };
    if (count == 0) return usageErr(c);

    var ops = opt.Operands.init("c:i:", args);
    const host = ops.next() orelse return usageErr(c);
    if (ops.next() != null) return usageErr(c); // one host, as ping takes

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
    var recv: u32 = 0;
    var sent: u32 = 0;
    var seq: u32 = 0;
    while (seq < count) : (seq += 1) {
        // ^C between echoes: report what was measured so far and stop.
        if (sched.cancelled()) break;
        sent += 1;
        if (n.ping(ip, TIMEOUT_MS)) |rtt| {
            recv += 1;
            c.write("16 bytes from ");
            network.writeIp(c, ip);
            c.write(std.fmt.bufPrint(&buf, ": icmp_seq={d} time={d} ms\n", .{ seq + 1, rtt }) catch return);
        }
        if (seq < count - 1 and !sched.cancelled()) timer.sleep(spacing_ms);
    }
    c.write("--- ");
    c.write(host);
    c.write(" ping statistics ---\n");
    c.write(std.fmt.bufPrint(&buf, "{d} packets transmitted, {d} received, {d}% packet loss\n", .{
        sent, recv, if (sent == 0) 0 else @as(u64, sent - recv) * 100 / sent,
    }) catch return);
}

fn usageErr(c: console.Console) void {
    c.write(USAGE);
}
