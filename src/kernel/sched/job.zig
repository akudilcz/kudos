//! Cooperative long tasks — the "bite off a chunk per frame" pattern.
//!
//! A blocking call that runs for seconds (a network download, a large file read)
//! stalls whatever core it runs on. On core 0 that is the 60 Hz compositor, so
//! the frame budget blows and the desktop hitches (PERF-003/007). The fix is not
//! "yield more" inside the blocking call — it is to STOP blocking: model the long
//! task as a state machine that advances one BOUNDED step per call and returns.
//! The core-0 session loop calls `Runner.pump()` once per iteration, then
//! renders — so downloading and rendering interleave, one chunk of each per
//! frame, and neither starves the other.
//!
//! This module is the reusable core: pure (no hardware, no allocation), so it is
//! host-tested against fake jobs and shared by every long task. A concrete job
//! (the fetch, a big read) supplies its own `ctx` and `step`.

const std = @import("std");

/// What one `step` accomplished. `working` → call again next frame; `done`/
/// `failed` → the job retires (its `finish`, if any, runs once).
pub const Step = enum { working, done, failed };

pub const Job = struct {
    ctx: *anyopaque,
    /// Do ONE bounded chunk of work and report progress. MUST return promptly —
    /// no blocking, no unbounded loop — because the frame budget rides on it.
    /// The whole point is that many small steps replace one long stall.
    step: *const fn (ctx: *anyopaque) Step,
    /// Run once when the job retires, on the pumping core, with the outcome —
    /// the job publishes its result and/or frees its state here. Optional.
    finish: ?*const fn (ctx: *anyopaque, outcome: Step) void = null,
};

/// The most concurrent long tasks. Small on purpose: these are seconds-long
/// user operations (a download, a model read), not a thread pool. Overflow is a
/// loud refusal, never a silent drop.
pub const MAX_JOBS = 8;

/// A fixed-size set of active jobs the session loop services. No allocation, no
/// lock: submitted and pumped from the one core-0 loop.
pub const Runner = struct {
    slots: [MAX_JOBS]?Job = [_]?Job{null} ** MAX_JOBS,
    count: usize = 0,

    /// Register a job to be advanced each frame. Returns false if the runner is
    /// full (the caller reports it — nothing is silently dropped).
    pub fn submit(self: *Runner, job: Job) bool {
        for (&self.slots) |*s| {
            if (s.* == null) {
                s.* = job;
                self.count += 1;
                return true;
            }
        }
        return false;
    }

    /// Advance every active job by exactly ONE step, then retire the finished
    /// ones (running their `finish`). Called once per session-loop iteration.
    /// Bounded work: at most MAX_JOBS steps, each itself bounded, so a full
    /// runner still costs the frame only a fixed slice.
    pub fn pump(self: *Runner) void {
        for (&self.slots) |*s| {
            const job = s.* orelse continue;
            const outcome = job.step(job.ctx);
            if (outcome == .working) continue;
            // Clear the slot BEFORE finish so a finish that submits a follow-up
            // job sees the freed slot, and a re-entrant pump never re-steps this
            // retired job.
            s.* = null;
            self.count -= 1;
            if (job.finish) |f| f(job.ctx, outcome);
        }
    }

    /// How many jobs are active (0 → the loop has no long work in flight).
    pub fn active(self: *const Runner) usize {
        return self.count;
    }
};
