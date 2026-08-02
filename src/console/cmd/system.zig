//! `system` — open the system-monitor window.

const console = @import("../console.zig");

/// `system` — open the system-monitor window.
pub fn run(c: console.Console, _: []const u8) void {
    c.spawnApp(.system) catch {
        c.write("error: could not open system\n");
        return;
    };
    c.write("opened the system monitor\n");
}
