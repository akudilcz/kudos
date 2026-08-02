//! Host tests of the HUD model (src/widgets/hudsnapshot.zig): the values the
//! sampler fills and the view paints, and the display policies that live with
//! them — which counter names read as faults, how task labels truncate, and the
//! capacities the rings and label fields promise. The view's side of the story
//! (that these values reach the pixels) is test/ui/hud_shot.zig.

const std = @import("std");
const snap = @import("hudsnapshot");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "the counter wall's columns are the four groups in fixed reading order" {
    try expectEqual(4, snap.Group.ALL.len);
    try expectEqual(snap.Group.usb, snap.Group.ALL[0]);
    try expectEqual(snap.Group.net, snap.Group.ALL[1]);
    try expectEqual(snap.Group.gpu_ui, snap.Group.ALL[2]);
    try expectEqual(snap.Group.kernel, snap.Group.ALL[3]);
    for (snap.Group.ALL) |g| try expect(g.title().len > 0);
}

test "a task label longer than the field truncates and never overruns" {
    var c = snap.CoreLine{};
    const long = "a-task-name-well-beyond-the-label-field-width";
    c.setTask(long, long);
    try expectEqual(snap.TASK_LABEL, c.taskName().len);
    try std.testing.expectEqualStrings(long[0..snap.TASK_LABEL], c.taskName());
    c.setTask("net", "rx");
    try std.testing.expectEqualStrings("net", c.taskName());
    try std.testing.expectEqualStrings("rx", c.activityName());
}

test "counter names that record failures read as faults, quiet ones do not (HUD-028)" {
    // One probe per mark word: this list is the alarm's trigger.
    for ([_][]const u8{
        "mouse.drops", "tls.fail",     "session_faults", "hid.orphan",
        "irq.spurious", "spin_exceeded", "rx.err",        "glb.bad",
    }) |bad| try expect(snap.isFault(bad));
    for ([_][]const u8{ "rx.frames", "kmr1.reqs", "sess.commits", "presents" }) |quiet|
        try expect(!snap.isFault(quiet));
}

test "the trace window is 30 seconds: ring length times the sampling period" {
    try expectEqual(30_000, snap.HISTORY * snap.SAMPLE_MS);
}
