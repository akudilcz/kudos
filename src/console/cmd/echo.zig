//! `echo TEXT` — print TEXT.

const console = @import("../console.zig");

/// `echo TEXT` — print the argument string followed by a newline.
pub fn run(c: console.Console, args: []const u8) void {
    c.write(args);
    c.put('\n');
}
