//! Detecting a task that ran off the low end of its stack (spec MEM-011).
//!
//! Kernel task stacks are plain heap allocations with NO guard page — the guard
//! MEM-010 describes is punched for SESSION stacks only
//! (memory/sessionspace.zig). So overflowing one does not fault. It quietly
//! overwrites whatever the allocator placed below, and the damage surfaces later
//! and elsewhere: this project spent a long hunt on a TLS handshake that needed
//! ~105 KiB across two live frames against a 128 KiB stack and presented as an
//! invalid-opcode at a mid-instruction address inside `memmove`, with a
//! backtrace naming unrelated functions.
//!
//! A canary does NOT prevent the overflow, and nothing here should suggest it
//! does. What it buys is attribution: silent, deferred, misattributed heap
//! corruption becomes one line naming the task that overflowed, at the first
//! moment we know that task is not running.
//!
//! Pure — a byte slice in, a verdict out — so the detection itself is tested
//! rather than trusted.

const std = @import("std");

/// The value written at the LOW end of a task stack. Recognisable on sight in a
/// memory dump, and not a value any plausible computation produces by accident.
pub const VALUE: u64 = 0xC0FFEE_57AC_C0DE;

/// Bytes a canary occupies at the bottom of the stack.
pub const BYTES = @sizeOf(u64);

/// Write the canary at the low end of `stack`. Called when a task is spawned and
/// again after a report, so a second overflow is reported as a NEW one rather
/// than the first one echoing forever.
pub fn arm(stack: []u8) void {
    if (stack.len < BYTES) return;
    std.mem.writeInt(u64, stack[0..BYTES], VALUE, .little);
}

/// Whether `stack` still holds its canary. False means the task grew past the
/// bottom of its own stack and has been writing into the allocation below it.
///
/// A stack too small to hold the canary reports intact: there is nothing to
/// check, and inventing a failure would be a false alarm on every switch.
pub fn intact(stack: []const u8) bool {
    if (stack.len < BYTES) return true;
    return std.mem.readInt(u64, stack[0..BYTES], .little) == VALUE;
}
