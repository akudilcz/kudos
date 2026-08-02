//! `exit` — close this terminal's window.

const console = @import("../console.zig");

/// `exit` — close this terminal's window. Teardown is deferred to the next frame
/// because the command runs inside the very window it is closing.
pub fn run(c: console.Console, _: []const u8) void {
    c.close();
}
