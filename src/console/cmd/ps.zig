//! `ps` — cores, their CPU %, and the tasks on each.

const std = @import("std");
const buildinfo = @import("buildinfo");
const smp = @import("../../kernel/smp/smp.zig");
const sched = @import("../../kernel/sched/sched.zig");
const taskstat = @import("../../kernel/sched/taskstat.zig");
const percpu = @import("../../kernel/sched/percpu.zig");
const console = @import("../console.zig");

/// `ps` — list every core as a "process" with its CPU % and the tasks it runs
/// Core 0 is the "system process"
/// (owns hardware + the system task). Single-core kudos shows just core 0.
pub fn run(c: console.Console, _: []const u8) void {
    if (!buildinfo.smp) {
        // N=1: there is one core and one terminal; no scheduler/stats to walk.
        c.write("CORE  ROLE             CPU%  TASKS\n");
        c.write("#0    system+#0>       --    (single-core: cooperative loop)\n");
        return;
    }

    const ncores = smp.coresOnline();
    c.write("CORE  ROLE             CPU%  TASKS\n");
    var core: u32 = 0;
    while (core < ncores) : (core += 1) {
        const pc = percpu.at(core);
        const pct = taskstat.cpuPercentSince(pc);

        // Role column: core 0 is the system process; others are their terminal.
        var line: [96]u8 = undefined;
        const role: []const u8 = if (core == 0) "system" else "terminal";
        const s = std.fmt.bufPrint(&line, "#{d:<3} {s:<16} {d:>3}%  ", .{ core, role, pct }) catch continue;
        c.write(s);

        // Task names on this core.
        var tasks: [16]taskstat.TaskInfo = undefined;
        const n = taskstat.snapshotTasks(core, &tasks);
        var first = true;
        for (tasks[0..n]) |ti| {
            if (!first) c.write(", ");
            first = false;
            c.write(ti.nameSlice());
            // Show what the task is currently doing, if it has a labeled activity
            // (e.g. a running `prime`): "supervisor[prime]".
            const act = ti.activitySlice();
            if (act.len != 0) {
                c.put('[');
                c.write(act);
                c.put(']');
            }
            // Exact per-task CPU time (KRN-005): the ms this task has been
            // on-CPU since spawn, charged at every reschedule.
            var ms: [24]u8 = undefined;
            c.write(std.fmt.bufPrint(&ms, "={d}ms", .{ti.cpu_ms}) catch "=?ms");
            if (ti.is_current) c.write("*");
        }
        c.put('\n');
    }
    c.write("(* = running; [..] = current command; =Nms = task CPU time; CPU% = recent load since last ps)\n");
}
