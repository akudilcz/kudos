//! The tickless timer-arming policy (KRN-007/KRN-008): given what the core is
//! about to run and what its sleeper list holds, decide what the one-shot
//! TSC-deadline timer is armed to — or that it is disarmed entirely, which is
//! what lets an idle core halt with zero periodic wakeups. Pure decision only;
//! sleep.armPreemption applies it to the LAPIC.

/// What the reschedule arms on this core.
pub const Decision = union(enum) {
    /// No deadline: the core, going idle with no sleeper, halts until a wakeup
    /// IPI or device interrupt — the tickless idle KRN-007 requires.
    disarm,
    /// One-shot deadline at this absolute TSC value.
    arm: u64,
};

/// Choose the deadline for the core now switching to `is_idle` or a runnable
/// task. `rt` is the earliest sleeper's absolute wake time on this core (0 for
/// none); `quantum` is the fairness slice in TSC ticks.
///
/// The idle branch arms for ANY sleeper — even one whose deadline has already
/// passed: a TSC deadline in the past fires immediately, so the release happens
/// on the next instruction boundary. Never disarm on `rt <= now`: a deadline can
/// slip past while the reschedule is in flight with its interrupt already
/// consumed, leaving the core in `sti; hlt` over a due sleeper nothing releases.
///
/// The runnable branch takes the nearer of the fairness quantum and a REAL
/// still-future sleeper deadline; a past `rt` is stale (its interrupt already
/// fired) and can never re-arm a deadline in the past and storm the core.
pub fn choose(is_idle: bool, now: u64, rt: u64, quantum: u64) Decision {
    if (is_idle) return if (rt != 0) .{ .arm = rt } else .disarm;
    const quantum_deadline = now + quantum;
    return .{ .arm = if (rt > now and rt < quantum_deadline) rt else quantum_deadline };
}
