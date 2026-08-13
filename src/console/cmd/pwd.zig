//! `pwd` — this terminal's working directory.

const console = @import("../console.zig");

pub fn run(c: console.Console, _: []const u8) void {
    c.write(c.cwd());
    c.put('\n');
}
