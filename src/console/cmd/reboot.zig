//! `reboot` — restart the machine.

const power = @import("../../kernel/power/reboot.zig");
const console = @import("../console.zig");

/// `reboot` — restart the machine (does not return).
pub fn run(_: console.Console, _: []const u8) void {
    power.reboot();
}
