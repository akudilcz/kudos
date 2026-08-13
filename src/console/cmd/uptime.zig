//! `uptime` — how long since boot, and how many cores are on.

const std = @import("std");
const buildinfo = @import("buildinfo");
const console = @import("../console.zig");
const percpu = @import("../../kernel/sched/percpu.zig");
const sched = @import("../../kernel/sched/sched.zig");
const timer = @import("../../kernel/timer/timer.zig");

pub fn run(c: console.Console, _: []const u8) void {
    const s = timer.millis() / 1000;
    var cores: u32 = 1;
    if (comptime buildinfo.smp) {
        cores = 0;
        var i: u32 = 0;
        while (i < percpu.MAX_CPUS) : (i += 1) {
            if (sched.coreOnline(i)) cores += 1;
        }
    }
    var buf: [64]u8 = undefined;
    c.write(std.fmt.bufPrint(&buf, "up {d}:{d:0>2}:{d:0>2}, {d} cores\n", .{
        s / 3600, (s / 60) % 60, s % 60, cores,
    }) catch return);
}
