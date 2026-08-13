//! `uname [-a]` — what this machine is running. Bare prints the system name;
//! `-a` adds the build number, commit and build time from buildinfo.

const std = @import("std");
const buildinfo = @import("buildinfo");
const console = @import("../console.zig");

pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("kudos\n");
        return;
    }
    if (!std.mem.eql(u8, args, "-a")) {
        c.write("usage: uname [-a]\n");
        return;
    }
    var buf: [128]u8 = undefined;
    c.write(std.fmt.bufPrint(&buf, "kudos #{d} {s} {s} x86_64\n", .{
        buildinfo.build_number,
        buildinfo.git_hash,
        buildinfo.build_time,
    }) catch "kudos\n");
}
