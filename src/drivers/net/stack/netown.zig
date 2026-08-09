//! Who is allowed to drive the network stack right now (spec NET-018).
//!
//! Every global in the stack — the TX staging buffers, the ARP cache, the one
//! TCP connection, the NIC's single RX staging buffer — is written without a
//! lock, because the stack was built for a single driver and its comments still
//! say so. That stopped being true when the system task and the command worker
//! both became floating tasks: `net.pump()` runs from the 60 Hz session loop AND
//! from inside a fetch, so two cores could poll the NIC at once. The second
//! overwrote the frame the first was still parsing, the receive buffer took a
//! splice of two segments, and kudos acknowledged bytes it had never correctly
//! stored — so the peer never retransmitted, and the damage surfaced somewhere
//! else entirely: a TLS record that would not authenticate, or a fault that
//! retired the system task's core and took the desktop with it.
//!
//! The rule, made explicit and made a value: ONE holder at a time, claimed for
//! the length of an operation. Claiming is a TRY, never a wait — the holder is
//! the only one that pumps while it holds the stack, so a blocked caller could
//! not be woken by anyone else anyway, and a spinning render loop is precisely
//! what this exists to prevent. Everyone else SKIPS and gets on with its own
//! work, which is why a network request no longer stops the desktop.
//!
//! Pure: a token and two decisions, so both are host-testable. `net.zig` holds
//! the live token and supplies the caller's identity.

const std = @import("std");

/// The current holder, or null when the stack is free. An opaque token — the
/// kernel passes the calling task; a test passes anything comparable.
pub const Holder = ?*anyopaque;

/// Whether `caller` may take the stack, given who holds it.
///
/// A null caller is the boot stack before any scheduler exists: one thread of
/// control, so there is nobody to race and the claim always succeeds. A caller
/// that ALREADY holds it succeeds too — an operation that re-enters its own
/// claim (a send that pumps while resolving) must not deadlock against itself.
pub fn mayClaim(held: Holder, caller: Holder) bool {
    const c = caller orelse return true;
    const h = held orelse return true;
    return h == c;
}

/// Whether `caller` must keep its hands off: someone ELSE is driving.
///
/// The steady loops ask this and skip. Note what it is NOT — it is not "is the
/// stack busy": the holder itself must always be allowed through, or the task
/// doing the work would lock itself out of finishing it.
pub fn mustSkip(held: Holder, caller: Holder) bool {
    const h = held orelse return false; // free — anyone may drive
    return h != caller;
}
