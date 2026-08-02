//! `clock` — open the analog clock window.

const console = @import("../console.zig");

/// `clock` — open the analog clock window.
pub fn run(c: console.Console, _: []const u8) void {
    c.spawnApp(.clock) catch {
        c.write("error: could not open clock\n");
        return;
    };
    c.write("opened the clock\n");
}
