//! Host tests of src/kernel/sched/job.zig — the cooperative-job runner: one
//! bounded step per pump, retire on done/failed, loud overflow.

const std = @import("std");
const job = @import("job");

/// A fake long task: `working` for `steps_left` pumps, then the scripted
/// outcome. Records how many steps ran and the outcome finish saw.
const Fake = struct {
    steps_left: u32,
    outcome: job.Step = .done,
    steps_run: u32 = 0,
    finished_with: ?job.Step = null,

    fn step(ctx: *anyopaque) job.Step {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.steps_run += 1;
        if (self.steps_left > 0) {
            self.steps_left -= 1;
            return .working;
        }
        return self.outcome;
    }
    fn finish(ctx: *anyopaque, outcome: job.Step) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.finished_with = outcome;
    }
    fn job_(self: *Fake) job.Job {
        return .{ .ctx = self, .step = step, .finish = finish };
    }
};

test "one step per pump; retires on done and runs finish once" {
    var r = job.Runner{};
    var f = Fake{ .steps_left = 2 }; // working, working, done
    try std.testing.expect(r.submit(f.job_()));
    try std.testing.expectEqual(@as(usize, 1), r.active());

    r.pump(); // step 1 -> working
    try std.testing.expectEqual(@as(u32, 1), f.steps_run);
    try std.testing.expectEqual(@as(usize, 1), r.active());
    try std.testing.expect(f.finished_with == null);

    r.pump(); // step 2 -> working
    try std.testing.expectEqual(@as(u32, 2), f.steps_run);

    r.pump(); // step 3 -> done, retires
    try std.testing.expectEqual(@as(u32, 3), f.steps_run);
    try std.testing.expectEqual(@as(usize, 0), r.active());
    try std.testing.expectEqual(job.Step.done, f.finished_with.?);

    // A retired job is never stepped again.
    r.pump();
    try std.testing.expectEqual(@as(u32, 3), f.steps_run);
}

test "failed outcome retires and reports failed to finish" {
    var r = job.Runner{};
    var f = Fake{ .steps_left = 0, .outcome = .failed };
    _ = r.submit(f.job_());
    r.pump();
    try std.testing.expectEqual(@as(usize, 0), r.active());
    try std.testing.expectEqual(job.Step.failed, f.finished_with.?);
}

test "runner is full-safe: submit past MAX_JOBS refuses loudly" {
    var r = job.Runner{};
    var fakes: [job.MAX_JOBS]Fake = undefined;
    for (&fakes) |*f| {
        f.* = Fake{ .steps_left = 100 };
        try std.testing.expect(r.submit(f.job_()));
    }
    try std.testing.expectEqual(job.MAX_JOBS, r.active());
    // One more must be refused, not silently dropped.
    var overflow = Fake{ .steps_left = 0 };
    try std.testing.expect(!r.submit(overflow.job_()));
}

test "pump advances all active jobs one step each" {
    var r = job.Runner{};
    var a = Fake{ .steps_left = 5 };
    var b = Fake{ .steps_left = 5 };
    _ = r.submit(a.job_());
    _ = r.submit(b.job_());
    r.pump();
    try std.testing.expectEqual(@as(u32, 1), a.steps_run);
    try std.testing.expectEqual(@as(u32, 1), b.steps_run);
    try std.testing.expectEqual(@as(usize, 2), r.active());
}
