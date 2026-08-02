//! `clear` — blank the terminal grid.

const console = @import("../console.zig");

/// `clear` — blank the terminal grid.
pub fn run(c: console.Console, _: []const u8) void {
    c.clear();
}
