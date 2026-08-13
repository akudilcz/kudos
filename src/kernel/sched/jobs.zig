//! The one core-0 job runner, serviced by the session loop.
//!
//! A long task (a download, a big read) registers a cooperative Job here
//! (job.zig) instead of blocking; the session loop calls `pump()` once per
//! iteration, so every active job advances one bounded step per frame and the
//! compositor keeps rendering between steps. Submitting is how a command
//! (e.g. `net fetch`) backgrounds its work: it registers the job and returns,
//! and the job publishes its own result when it finishes.
//!
//! One global instance because there is one session loop. Submitted and pumped
//! from that single core-0 loop, so no lock.

const job = @import("job");

pub const Job = job.Job;
pub const Step = job.Step;

var runner: job.Runner = .{};

/// Register a job to advance each frame. False if the runner is full (the
/// caller reports it — nothing is silently dropped).
pub fn submit(j: job.Job) bool {
    return runner.submit(j);
}

/// Advance every active job one bounded step; retire the finished. A row in
/// the steady loops' service table (boot/services.zig), stepped once per
/// iteration next to the network pump and the render.
pub fn step() void {
    runner.pump();
}

/// Active job count (0 → no long work in flight).
pub fn active() usize {
    return runner.active();
}
