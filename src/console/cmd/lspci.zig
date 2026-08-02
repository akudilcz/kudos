//! `lspci` — list enumerated PCI devices.

const std = @import("std");
const ipci = @import("ipci"); // the hardware inventory, as a list of facts
const console = @import("../console.zig");

/// `lspci` — list enumerated PCI devices (bus:slot.func, vendor:device, class).
pub fn run(c: console.Console, _: []const u8) void {
    for (ipci.devices) |d| {
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{x:0>2}:{x:0>2}.{x} {x:0>4}:{x:0>4} class {x:0>2}.{x:0>2}\n", .{ d.bus, d.slot, d.func, d.vendor, d.device, d.class, d.subclass }) catch continue;
        c.write(s);
    }
}
