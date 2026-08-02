//! cmdtoken — the single-flight hand-off of one committed command line from
//! the terminal's input side to its one executor.
//!
//! The token is CONSUMED at claim, not at completion: `claim` takes `pending`
//! true→false and raises `running` in one atomic exchange, so exactly one
//! claimer ever wins no matter how many dispatchers poll. The claim must
//! consume: two dispatchers executing one command concurrently on two cores
//! would write the unsynchronized terminal grid and fault both tasks.
//!
//! `running` is the close-deferral guard: a session close defers while an
//! execution is in flight (the executor's stack lives in arenas the teardown
//! would free). It is raised by the winning claim and cleared by `complete` as
//! the executor's last act.
//!
//! Pure atomics over two flags — no IO, no imports; host-tested.

pub const CmdToken = struct {
    /// A committed line awaits an executor (posted by the input side).
    pending: bool = false,
    /// An execution is in flight (the close-deferral guard).
    running: bool = false,

    /// Post a committed line for the executor.
    pub fn post(self: *CmdToken) void {
        @atomicStore(bool, &self.pending, true, .release);
    }

    /// Claim for execution: consume `pending` and raise `running` in one
    /// exchange. Exactly one claimer wins; a second finds the token consumed.
    pub fn claim(self: *CmdToken) bool {
        if (@cmpxchgStrong(bool, &self.pending, true, false, .acq_rel, .acquire) != null) return false;
        @atomicStore(bool, &self.running, true, .release);
        return true;
    }

    /// Execution finished — clears the close-deferral guard. The executor's
    /// LAST act touching the session (a queued close may free it after this).
    pub fn complete(self: *CmdToken) void {
        @atomicStore(bool, &self.running, false, .release);
    }

    pub fn isPending(self: *const CmdToken) bool {
        return @atomicLoad(bool, &self.pending, .acquire);
    }

    pub fn isRunning(self: *const CmdToken) bool {
        return @atomicLoad(bool, &self.running, .acquire);
    }
};
