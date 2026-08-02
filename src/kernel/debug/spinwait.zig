//! Spinwait — the bounded busy-wait. Raw unbounded spins are banned (CLAUDE.md):
//! a spin that never gives up is a machine that goes silent with no diagnosis,
//! because the trace drain is pumped by the very loops that are now stuck.
//!
//! A conforming wait does three things a raw `while (!done()) {}` cannot:
//!   1. keeps the machine OBSERVABLE — it pumps the trace drain every PUMP_EVERY
//!      iterations, so queued log lines keep flowing while it waits;
//!   2. is BOUNDED — the caller states a budget, and `tick()` reports true once
//!      it is exhausted so the caller can fail loudly instead of hanging;
//!   3. REPORTS ITSELF — the first budget overrun logs the site name and the
//!      caller's return address (one line, once) and bumps a counter, so a wait
//!      that has started hanging is visible on the wire before it wedges anything.
//!
//! Usage:
//!     var sp = spinwait.start(FENCE_TIMEOUT_US, "gl.semDone");
//!     while (!fenceRetired()) {
//!         if (sp.tick()) return error.FenceTimeout;
//!     }

const tsc = @import("../cpu/tsc.zig");
const klog = @import("klog.zig");
const counter = @import("counter.zig");

/// Pump the trace drain every this many iterations. A spin iteration is tens of
/// nanoseconds; ~1k iterations keeps the pump cost invisible while draining far
/// more often than the drain's own interval gate admits.
const PUMP_EVERY: u32 = 1024;

/// The trace pump — netdebug installs its drain here at start(); null before the
/// NIC is claimed (the spin still bounds and reports through the diag ring).
/// A function pointer, not an import: kernel/ stays below drivers/.
pub var pump: ?*const fn () void = null;

/// Budget overruns across all sites — one glance at `debug.spin_exceeded` says
/// whether anything on the machine has been waiting past its stated budget.
var exceeded = counter.Counter{ .mod = .boot, .name = "spin_exceeded" };

/// Deadline policy — pure (time passed in), host-tested below.
pub const Budget = struct {
    deadline: u64,
    /// 0 disables expiry (no trustworthy clock yet — pre-TSC-calibration).
    enabled: bool,
    reported: bool = false,

    pub fn expiredAt(self: *Budget, now: u64) bool {
        if (!self.enabled) return false;
        return now >= self.deadline;
    }

    /// True exactly once, on the first expiry — the report gate.
    pub fn firstExpiry(self: *Budget, now: u64) bool {
        if (!self.expiredAt(now)) return false;
        if (self.reported) return false;
        self.reported = true;
        return true;
    }
};

pub const Spin = struct {
    budget: Budget,
    site: []const u8,
    n: u32 = 0,

    /// One wait iteration: pump the trace occasionally; report the first budget
    /// overrun; return true while the budget is exhausted (the caller bails or
    /// knowingly keeps waiting — either way the overrun is already on record).
    pub fn tick(self: *Spin) bool {
        self.n +%= 1;
        if (self.n % PUMP_EVERY == 0) {
            if (pump) |p| p();
        }
        const now = tsc.rdtsc();
        if (self.budget.firstExpiry(now)) {
            counter.register(&exceeded); // idempotent — first overrun anywhere registers it
            exceeded.inc();
            klog.puts("spinwait: budget exceeded at ");
            klog.puts(self.site);
            klog.puts(" ra=");
            klog.putHex(@returnAddress());
            klog.putc('\n');
            if (pump) |p| p();
        }
        return self.budget.expiredAt(now);
    }
};

/// Begin a bounded wait of `budget_us` microseconds, named for its site (short,
/// greppable: "xhci.portReset", "gl.semDone"). Before TSC calibration there is no
/// trustworthy clock, so the budget is disabled — the wait still pumps, and the
/// callers that can run that early (none today) keep their own bring-up bounds.
pub fn start(budget_us: u64, site: []const u8) Spin {
    const hz = tsc.hz();
    return .{
        .budget = .{
            .deadline = if (hz == 0) 0 else tsc.rdtsc() + tsc.usTicks(budget_us),
            .enabled = hz != 0,
        },
        .site = site,
    };
}

// ── tests (host: `zig build test`) ────────────────────────────────────────
const std = @import("std");
