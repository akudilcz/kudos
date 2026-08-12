//! `caps` — what this kudos publishes to a loaded `.kudos` module (MOD-011).
//!
//! abi.zig is the DECLARED set, which the factory serves to whoever writes a
//! module. This answers what the machine running now hands back, to which kind of
//! module, and whether the capability has anything behind it yet: `window` is
//! declared always and live only once the desktop is up.

const std = @import("std");
const capabilities = @import("../capabilities.zig");
const console = @import("../console.zig");

const USAGE =
    \\usage: caps
    \\  what a loaded .kudos module may bind with api.get_interface(id, version)
    \\
;

/// Three marks, one per run kind. Marks rather than words because the SHAPE is
/// the point — a row of dashes is a capability nothing can reach.
fn grants(e: capabilities.Entry, buf: *[3]u8) []const u8 {
    buf[0] = if (e.app_terminal) 'a' else '-';
    buf[1] = if (e.app_headless) 'h' else '-';
    buf[2] = if (e.feature) 'f' else '-';
    return buf[0..];
}

pub fn run(c: console.Console, args: []const u8) void {
    if (std.mem.trim(u8, args, " \t").len != 0) {
        c.write(USAGE);
        return;
    }

    c.write("published capabilities (a = app with a terminal, h = app with none, f = feature)\n\n");
    var line: [160]u8 = undefined;
    var marks: [3]u8 = undefined;
    var i: usize = 0;
    while (i < capabilities.count()) : (i += 1) {
        const e = capabilities.at(i);
        c.write(std.fmt.bufPrint(&line, "  {s:<9} id {d} v{d}  {s}  {s}\n    {s}\n", .{
            e.name,
            e.id,
            e.version,
            grants(e, &marks),
            if (e.live) "live" else "not on this machine yet",
            e.why,
        }) catch continue);
    }
    // Deny by default is the rule, so the absence of a row is the answer for
    // everything else — said out loud, because a short list reads as a missing
    // feature rather than a decision.
    c.write("\nanything not listed is refused: a module is handed nothing beyond its\n");
    c.write("base Api unless a row above grants it (see src/console/grants.zig).\n");
}
