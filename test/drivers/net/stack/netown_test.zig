//! Host tests of who may drive the network stack (spec NET-018).
//!
//! The two decisions here are three lines each and both were wrong in the tree
//! for as long as SMP has existed — not because they were coded badly, but
//! because nobody wrote them down at all. The failure they caused was a TLS
//! record that would not authenticate and a fault that retired the system
//! task's core, neither of which points anywhere near a missing rule about who
//! may call `net.pump()`.

const std = @import("std");
const netown = @import("netown");

const expect = std.testing.expect;

// Two distinguishable task tokens. Only their identity matters.
var task_a: u8 = 0;
var task_b: u8 = 0;
const a: netown.Holder = @ptrCast(&task_a);
const b: netown.Holder = @ptrCast(&task_b);

test "a free stack may be claimed by anyone (NET-018)" {
    try expect(netown.mayClaim(null, a));
    try expect(netown.mayClaim(null, b));
    try expect(!netown.mustSkip(null, a));
    try expect(!netown.mustSkip(null, b));
}

test "a held stack turns everyone else away (NET-018)" {
    // This is the whole fix: while one task is mid-request, the render loop
    // must not pump, send, or poll the NIC. Racing it is what spliced two
    // frames into the receive buffer and had kudos acknowledge bytes it never
    // stored.
    try expect(!netown.mayClaim(a, b));
    try expect(netown.mustSkip(a, b));
}

test "the holder is never turned away from its own claim (NET-018)" {
    // A send that resolves its next hop pumps the stack while it does so, so an
    // operation re-enters its own claim. Treating "held" as "busy" without
    // asking WHO holds it would deadlock the task against itself, mid-request.
    try expect(netown.mayClaim(a, a));
    try expect(!netown.mustSkip(a, a));
}

test "a busy stack tells the render loop to SKIP, never to wait (NET-019)" {
    // The decision is deliberately a predicate and not a lock acquisition.
    // Blocking here would be correct for the data and wrong for the machine:
    // the 60 Hz loop would stall for as long as the request took — up to the
    // TLS silence budget of fifteen seconds — and the desktop would freeze
    // every time the agent was asked a question. The loop asks, is told to skip,
    // and spends the frame rendering instead.
    try expect(netown.mustSkip(a, b));
    try expect(netown.mustSkip(b, a));
    // And the instant the holder releases, the loop drives again — no handover,
    // no wakeup, nothing to get wrong.
    try expect(!netown.mustSkip(null, b));
}

test "before a scheduler exists there is nobody to race (NET-018)" {
    // The boot stack is a single thread of control and drives the stack
    // directly. Refusing it would make the network unusable before the
    // scheduler starts — which is exactly when DHCP and the netboot fetch run.
    try expect(netown.mayClaim(null, null));
    try expect(netown.mayClaim(a, null));
    try expect(!netown.mustSkip(null, null));
}
