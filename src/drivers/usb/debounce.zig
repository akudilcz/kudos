//! USB connect-debounce stability window. Pure logic — the port-status sampling
//! and the sleeps live in the driver; this owns only the decision. Mirrors
//! Linux `hub_port_debounce` (linux-source-7.0.0 drivers/usb/core/hub.c:4696):
//! the connect bit must read UNCHANGED for a full stability window,
//! polled on a fixed step, within a total budget. Any bounce — the connect bit
//! flipping, or a latched connect-change bit — restarts the window, so one
//! lucky read of a still-bouncing contact can never pass.

/// Linux hub.c debounce constants (all milliseconds).
pub const STABLE_MS: u32 = 100; // HUB_DEBOUNCE_STABLE: unchanged this long => stable
pub const STEP_MS: u32 = 25; // HUB_DEBOUNCE_STEP: sample cadence
pub const TIMEOUT_MS: u32 = 2000; // HUB_DEBOUNCE_TIMEOUT: total budget

pub const Verdict = enum {
    pending, // keep sampling (sleep STEP_MS, feed the next sample)
    stable_connected, // connect held for STABLE_MS and the device is present
    stable_empty, // connect held for STABLE_MS and the port is empty
    timeout, // never stable within TIMEOUT_MS
};

/// Feed one `(connected, change)` sample per STEP_MS tick; the caller sleeps
/// between feeds and clears the change bit it sampled. State machine only —
/// no timer, no register access.
pub const Debounce = struct {
    total_ms: u32 = 0,
    stable_ms: u32 = 0,
    connected: ?bool = null, // last latched connect state; null until first sample

    pub fn feed(self: *Debounce, connected: bool, change: bool) Verdict {
        const unchanged = if (self.connected) |c| c == connected else false;
        if (!change and unchanged) {
            self.stable_ms += STEP_MS;
            if (self.stable_ms >= STABLE_MS) {
                return if (connected) .stable_connected else .stable_empty;
            }
        } else {
            // Bounce (or first sample): restart the stability window on the
            // newly observed state.
            self.stable_ms = 0;
            self.connected = connected;
        }
        self.total_ms += STEP_MS;
        if (self.total_ms >= TIMEOUT_MS) return .timeout;
        return .pending;
    }
};

const std = @import("std");
