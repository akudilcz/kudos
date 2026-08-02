//! A usage meter: an outlined bar whose fill states how much of something is
//! spent, coloured by how close that is to trouble. The one home of "what counts
//! as healthy" for every bar kudos draws, so a memory bar and a disk bar cannot
//! disagree about when amber starts.
//!
//! The judgement (`statusOf`) is a pure function of used/total and is host-tested;
//! `draw` is the painter edge that maps it to the theme's reserved status ramp.
//! Status colour is never decorative: a bar is green, amber or red because of what
//! it reads, and the reading is always written beside it, so colour is a second
//! encoding rather than the only one.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const theme = @import("theme");
const barfill = @import("barfill");

/// Fraction of capacity at which a meter stops reading as healthy.
pub const WARN_AT: f32 = 0.70;
/// Fraction of capacity at which a meter reads as a fault in the making.
pub const CRITICAL_AT: f32 = 0.90;

/// What a fill level means. Named states rather than colours: the mapping to the
/// palette lives in one place below, and a caller can act on `.critical` without
/// knowing it is red.
pub const Status = enum {
    ok,
    warn,
    critical,

    /// The theme colour that states this status.
    pub fn color(self: Status) u32 {
        return switch (self) {
            .ok => theme.GREEN,
            .warn => theme.YELLOW,
            .critical => theme.RED,
        };
    }
};

/// The status of `used` out of `total`. An empty capacity reads as ok: a volume
/// that is not there cannot be full.
pub fn statusOf(used: u64, total: u64) Status {
    if (total == 0) return .ok;
    const frac = @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(total));
    if (frac >= CRITICAL_AT) return .critical;
    if (frac >= WARN_AT) return .warn;
    return .ok;
}

/// Fill fraction, clamped to 0..1 — a used figure larger than the capacity is a
/// bug in the reporter, and a bar that overshoots its outline hides it.
pub fn fraction(used: u64, total: u64) f32 {
    if (total == 0) return 0;
    if (used >= total) return 1;
    return @as(f32, @floatFromInt(used)) / @as(f32, @floatFromInt(total));
}

/// Draw the meter in `r`: a 1 px outline with the fill inside it. The fill's width
/// comes from barfill so this bar and the system monitor's bar are the same bar.
pub fn draw(p: *kgl.Painter, r: rects.Rect, used: u64, total: u64) void {
    drawTinted(p, r, used, total, statusOf(used, total).color());
}

/// `draw` with the fill colour chosen by the caller — for bars whose colour
/// carries identity (which memory pool this is) rather than health.
pub fn drawTinted(p: *kgl.Painter, r: rects.Rect, used: u64, total: u64, color: u32) void {
    if (r.isEmpty()) return;
    p.fillRect(r.x, r.y, r.w, r.h, theme.CONTENT_BG);
    p.rect(r.x, r.y, r.w, r.h, theme.BORDER);
    const inner_w: usize = @intFromFloat(@max(0, r.w));
    const fill: f32 = @floatFromInt(barfill.fillWidth(inner_w, @intCast(used), @intCast(total)));
    if (fill > 0) p.fillRect(r.x + 1, r.y + 1, fill, @max(0, r.h - 2), color);
}
