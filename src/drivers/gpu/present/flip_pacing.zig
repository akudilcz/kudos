//! Pure flip-pacing decision core (the session update cycle + vsync
//! pacing → one flip per refresh). Extracted from present_real.waitFlipLatched
//! so the pacing arithmetic — the logic behind TWO shipped field bugs (the
//! in-blank-only pump gate that halved the rate to 30fps, and the same-vblank
//! re-entry that over-presented at ~78/s with ~30% of composites never scanned
//! out) — is host-testable. present_real keeps the hardware side (RG_VLINE reads,
//! rdtsc, the pause-spin wait loops) and calls `decide` with live values; this
//! module owns the refresh math, the 3/4-frame spacing rule, and the wait-path
//! selection. Imports nothing → its in-file tests run with `zig test` on the host.

/// The mode-timing scalars the refresh math needs (a subset of disp.Mode, which
/// this module must not import — disp is hardware-tied). present_real builds one
/// from the head's mode.
pub const Timings = struct {
    h: u32, // horizontal active pixels
    h_blank: u32, // horizontal blanking pixels
    v: u32, // vertical active lines
    v_blank: u32, // vertical blanking lines
    clock_khz: u32, // pixel clock in kHz
};

/// One refresh interval in microseconds from the head's mode timings — used only
/// as a safety timeout bound (TIMEOUT_FRAMES frames) so a stalled head never hangs
/// the wait. clk=0 (a degenerate mode) is clamped to 1 so the division cannot trap;
/// the resulting huge-but-finite interval still bounds the wait.
pub fn frameUs(t: Timings) u64 {
    const h_total: u64 = @as(u64, t.h) + t.h_blank;
    const v_total: u64 = @as(u64, t.v) + t.v_blank;
    const clk_khz: u64 = if (t.clock_khz != 0) t.clock_khz else 1;
    return h_total * v_total * 1000 / clk_khz;
}

/// Safety-timeout bound on the whole wait, in refresh intervals: a stalled head
/// (vline stuck) must never hang the session loop for more than 2 frames.
pub const TIMEOUT_FRAMES: u64 = 2;

/// The fast-path spacing threshold, in µs: only take the already-in-blank fast
/// path if at least ~0.75 of a refresh has passed since the last flip. Below that
/// we are still inside the SAME refresh the previous flip is latching into, and
/// flipping again would lap the panel (see `decide`).
pub fn spacingUs(frame_us: u64) u64 {
    return frame_us * 3 / 4;
}

/// Has at least the spacing threshold elapsed since the last flip? `last_flip == 0`
/// means no flip has ever armed (warm start) — always spaced. The subtraction is
/// wrapping (-%) so an rdtsc wraparound cannot trap; `now`/`last_flip`/
/// `spacing_ticks` share one unit (TSC ticks on hardware, anything in tests).
pub fn spacedEnough(now: u64, last_flip: u64, spacing_ticks: u64) bool {
    return last_flip == 0 or (now -% last_flip) >= spacing_ticks;
}

/// What the waiter must do this frame (the caller owns the actual spin loops):
///   go                    — previous flip has latched; arm the next flip NOW.
///   wait_active_then_edge — first wait OUT of blank (so the edge detector sees a
///                           real rising edge, not this same vblank), then wait
///                           for the next ACTIVE→BLANK edge, then go.
///   wait_edge             — wait for the next ACTIVE→BLANK edge, then go.
pub const Decision = enum { go, wait_active_then_edge, wait_edge };

/// ONE FLIP PER REFRESH. The immediate `go`
/// fast path (beam already in vblank → previous flip latched) is correct ONLY
/// once per refresh. The composite path is ~µs, so a fast loop iteration can
/// re-enter while the beam is STILL in the SAME vblank the previous flip is
/// latching into — taking the fast path would arm a SECOND flip this refresh,
/// lapping the panel (~78 presents/s + a phase beat, measured). Guard it on
/// elapsed time: only take the fast path if at least ~0.75 of a refresh has passed
/// since the last flip. Below that, we are too early in the same refresh → wait
/// for the NEXT rising edge into vblank — the previous flip's latch point, one
/// refresh boundary away at most. This is what phase-locks the loop to the panel.
/// If we are ALREADY in blank but not spaced enough, first wait OUT of blank so
/// the edge detector sees a real rising edge (not this same vblank).
///
/// `in_blank` = the head's live scanline is at/past v_active (vertical blank).
/// `now`/`last_flip`/`spacing_ticks` in one shared tick unit (see spacedEnough).
pub fn decide(in_blank: bool, now: u64, last_flip: u64, spacing_ticks: u64) Decision {
    const spaced = spacedEnough(now, last_flip, spacing_ticks);
    // Already in vblank AND a refresh has elapsed → the previous flip has latched; go.
    if (spaced and in_blank) return .go;
    // Too soon after the last flip (still inside its refresh) → force a full
    // out-of-blank + rising-edge wait, even if currently in blank (same-vblank
    // re-entry). When already in active the phase-1 wait falls through instantly,
    // so this is also correct mid-active.
    if (!spaced) return .wait_active_then_edge;
    // Spaced but mid-active: just catch the next ACTIVE→BLANK edge.
    return .wait_edge;
}
