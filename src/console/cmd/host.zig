//! `host NAME` — resolve a hostname, in host(1)'s shape.

const console = @import("../console.zig");
const network = @import("../network.zig");
const opt = @import("../opt.zig");

const USAGE = "usage: host NAME\n";

pub fn run(c: console.Console, args: []const u8) void {
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| return opt.refuse(c, "host", o, USAGE);
    var ops = opt.Operands.init("", args);
    const name = ops.next() orelse {
        c.write(USAGE);
        return;
    };
    const n = network.up(c) orelse return;
    if (n.resolve(name)) |ip| {
        c.write(name);
        c.write(" has address ");
        network.writeIp(c, ip);
        c.put('\n');
    } else {
        c.write("Host ");
        c.write(name);
        c.write(" not found\n");
    }
}
