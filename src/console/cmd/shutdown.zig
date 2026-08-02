//! `shutdown` — request an orderly machine power-off.

const power = @import("../../kernel/power/reboot.zig");
const Out = @import("../out.zig").Out;

/// Request an orderly machine shutdown: the GPU session loop (or the system
/// loop) sees the flag, tears the GSP down cleanly (releasing WPR2 so the next
/// boot is clean), then powers the machine off.
pub fn run(out: Out, args: []const u8) void {
    _ = args;
    out.str("shutting down...\n");
    power.shutdown_requested = true;
}
