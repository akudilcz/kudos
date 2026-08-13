//! `host NAME` — resolve a hostname, in host(1)'s shape.

const console = @import("../console.zig");
const network = @import("../network.zig");

pub fn run(c: console.Console, name: []const u8) void {
    if (name.len == 0) {
        c.write("usage: host NAME\n");
        return;
    }
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
