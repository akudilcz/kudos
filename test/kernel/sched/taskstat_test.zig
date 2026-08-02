//! Host tests of the `ps` listing's read-side view (src/kernel/sched/
//! taskstat.zig, KRN-005). Born from a live boot-3 failure: `ps` on real
//! hardware streamed raw heap for hundreds of kilobytes after one task's
//! activity label. The snapshot had copied a TORN activity_len from a task
//! mid-birth on another core, and the slice ran off the fixed array into
//! memory. The invariant: however torn the copy, a label slice NEVER exceeds
//! its array — the worst a race may cost is one garbled label, never a
//! memory stream.

const std = @import("std");
const taskstat = @import("testroot").kernel.taskstat;

test "a torn activity length can never slice past the label array (the ps heap-stream bug)" {
    var info: taskstat.TaskInfo = undefined;
    @memset(&info.activity, 'x');
    info.activity_len = std.math.maxInt(usize); // the torn read ps saw
    try std.testing.expect(info.activitySlice().len <= info.activity.len);
    info.activity_len = info.activity.len + 1; // near-miss garbage too
    try std.testing.expect(info.activitySlice().len <= info.activity.len);
}

test "an honest activity length is returned verbatim" {
    var info: taskstat.TaskInfo = undefined;
    @memset(&info.activity, 0);
    info.activity[0] = 'n';
    info.activity[1] = 'e';
    info.activity[2] = 't';
    info.activity_len = 3;
    try std.testing.expectEqualStrings("net", info.activitySlice());
}
