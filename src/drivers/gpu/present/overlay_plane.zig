//! Pure overlay-plane arm state machine (Step 2b).
//! Decides, from the per-frame route decision + the plane's persistent state, what
//! the flip path must do to the HW overlay window this frame: arm content, blank it
//! once, or leave it alone. Extracted from present_real.zig's presentFlip so the
//! transition logic — which is HARD to get right (an NVDisplay window keeps
//! scanning its last image, so a routed→unrouted edge MUST emit a one-shot blank or
//! the last glass ghosts) — is host-testable. present_real holds the `Plane` state
//! on OverlayHw and calls `step` each flip; the HW method emission stays there.
//!
//! Imports nothing → a shared named module compiled by the kernel and the host
//! tests alike (like overlay_select / compositor_geom).

/// The overlay plane's persistent state (survives across flips). `showing_content`
/// is the load-bearing one: `active` alone can't detect the routed→unrouted edge
/// because the flip path clears the per-frame arm every frame.
pub const Plane = struct {
    showing_content: bool = false, // real glass pixels are latched on the plane now
};

/// What the flip path must do to the overlay this frame.
pub const Action = struct {
    do_overlay: bool, // touch the overlay at all (arm image+wimm+update, interlock it)
    blank: bool, // the arm is a BLANK (K1=0) — clears a ghost; else it's content
    swap: bool, // swap the overlay front/back buffers (content only; blank reads none)
    next: Plane, // the plane state to store for the next frame
};

/// One frame's decision. `armed` = this frame's route decision (a glass window is
/// routed to the plane). `st` = the plane's current persistent state.
///
///   armed:            content this frame → co-flip real pixels
///   !armed & was showing content: the routed→unrouted EDGE → one-shot blank
///   !armed & not showing content: nothing to do → single-window flip
pub fn step(st: Plane, armed: bool) Action {
    if (armed) {
        // Content co-flip: arm the window-sized plane, swap buffers, remember we're
        // showing content so the next un-route is detected.
        return .{ .do_overlay = true, .blank = false, .swap = true, .next = .{ .showing_content = true } };
    }
    if (st.showing_content) {
        // Un-route edge: blank the plane ONCE (K1=0), no buffer swap (nothing
        // written), and clear showing_content so we don't blank again.
        return .{ .do_overlay = true, .blank = true, .swap = false, .next = .{ .showing_content = false } };
    }
    // Idle: plane already transparent/latched, leave it — single-window flip.
    return .{ .do_overlay = false, .blank = false, .swap = false, .next = st };
}
