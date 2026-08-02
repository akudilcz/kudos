//! `term` — open a new terminal window.

const console = @import("../console.zig");

/// `term` — open a new terminal window hosting a fresh session (APP-001). The
/// session's task runs on whichever core is free (KRN-009); the only hard limit
/// is the session table itself.
pub fn run(c: console.Console, _: []const u8) void {
    c.spawnApp(.term) catch |e| {
        // A full session table is the one expected failure: say so plainly
        // rather than a generic failure.
        if (e == error.NoFreeSessions) {
            c.write("error: no free sessions\n");
        } else {
            c.write("error: could not open term\n");
        }
    };
}
