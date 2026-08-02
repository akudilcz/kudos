//! `calc` — open the graphing calculator window.

const console = @import("../console.zig");

/// `calc` — open the graphing calculator window.
pub fn run(c: console.Console, _: []const u8) void {
    c.spawnApp(.calc) catch {
        c.write("error: could not open calc\n");
        return;
    };
    c.write("opened the calculator\n");
}
