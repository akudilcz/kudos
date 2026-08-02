//! Power-of-two alignment helpers. Single source of truth for
//! the round-up / round-down arithmetic shared by the frame allocator and the
//! heap; `a` must be a power of two.

/// Round `x` UP to the next multiple of `a` (`a` must be a power of two).
pub fn up(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

/// Round `x` DOWN to the previous multiple of `a` (`a` must be a power of two).
pub fn down(x: usize, a: usize) usize {
    return x & ~(a - 1);
}

// ── tests (host: `zig build test`) ───────────────────────────────────────────
const std = @import("std");
