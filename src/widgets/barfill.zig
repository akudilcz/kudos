//! Pure usage-bar fill math for the System monitor's bars. Kept apart from
//! system.zig so it carries NO freestanding import and is host-unit-tested in
//! isolation — system.zig itself imports pmm/ramdisk/framebuffer/cpu and cannot
//! be a host test root. Single source of truth for the bar geometry: system.zig's
//! `bar()` calls `fillWidth` here rather than re-deriving it.

const std = @import("std");

/// Interior fill width of a usage bar of outer width `w` at `used/total`, in
/// pixels. The bar has a 1px outline each side, so the interior is `w - 2`
/// (saturating: 0 when w < 2, so a too-narrow window can't underflow-wrap). The
/// `inner * used` product is formed in u128 before the divide so it cannot
/// overflow for any usize operand, and the result is clamped to the interior:
/// under ReleaseFast a `(w-2)` underflow or an `inner * used` overflow (used =
/// raw bytes, up to many GiB) is silent UB (bogus geometry), not a trap.
/// Returns 0 when there is nothing to fill.
pub fn fillWidth(w: usize, used: usize, total: usize) usize {
    if (total == 0 or w < 2) return 0;
    const inner = w - 2;
    return @intCast(@min(
        @as(u128, inner),
        @as(u128, inner) * @as(u128, used) / @as(u128, total),
    ));
}
