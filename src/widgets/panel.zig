//! The frame every HUD section sits in: a bordered field with a header strip
//! carrying a title on the left and a note on the right, and a body that fills
//! itself from the top down. One home for the frame means a screen of panels
//! shares one header height, one inset and one border — the difference between a
//! dashboard and a pile of boxes.
//!
//! The geometry (`bodyOf`, `titleBaseline`, `Rows`) is pure and host-tested;
//! `draw` and the `Rows` painting methods are the painter edge. Type comes from
//! the caller as a `Chrome`, not from a constant here: the page picks a step of
//! the type ladder to suit the screen it is on, and every panel on it must be set
//! at the same step.
//!
//! `Rows` is what keeps a panel inside its own frame. A body is filled by asking
//! it for room; it refuses what will not fit and counts the refusals, so a panel
//! with more readings than room says how many it dropped instead of drawing over
//! the band below it. Walked without a painter it MEASURES: the same code that
//! draws a panel says how tall the panel wants to be, which is how the page
//! divides its bands before anything is painted — a separate measuring routine
//! would drift from the drawing the first time either changed.

const std = @import("std");
const kgl = @import("kgl");
const rects = @import("rects");
const typeface = @import("typeface");
const theme = @import("theme");

/// Height of the header strip at the comfortable step of the type ladder — the
/// theme's dashboard header height, so a HUD panel and a system-monitor panel are
/// the same object. A page set a step smaller states its own in `Chrome`.
pub const HEADER_H: f32 = @floatFromInt(theme.HEADER_H);
/// Inset from the frame to its content, at the comfortable step.
pub const PAD: f32 = 10;
/// Width of the accent tick at the header's left edge.
pub const TICK_W: f32 = 3;
/// Fraction of the horizontal padding used above and below the body: a panel is
/// wider than it is generous, and vertical room is the scarce one.
pub const PAD_Y: f32 = 0.6;
/// What a body says when it ran out of room: the count, and what the caller
/// names the things it could not show.
pub const DROPPED_NOTE = "+{d} {s}";

/// The type and spacing a panel is drawn at. Defaults are the comfortable step.
pub const Chrome = struct {
    /// Type the title is set in.
    title: typeface.Role = .label,
    /// Type the note over the header is set in.
    note: typeface.Role = .fine,
    /// Type the body's rows are set in.
    row: typeface.Role = .body,
    /// Height of the header strip.
    header_h: f32 = HEADER_H,
    /// Inset from the frame to the body.
    pad: f32 = PAD,

    /// Height the frame costs before a single row is drawn — header plus the
    /// body's own padding, top and bottom.
    pub fn overhead(self: Chrome) f32 {
        return self.header_h + 2 * self.pad * PAD_Y;
    }
};

/// The content rectangle inside a panel: below the header, inset by the padding.
pub fn bodyOf(r: rects.Rect, c: Chrome) rects.Rect {
    return r.belowTop(c.header_h).insetXY(c.pad, c.pad * PAD_Y);
}

/// Baseline for the header's text, vertically centred in the strip.
pub fn titleBaseline(r: rects.Rect, role: typeface.Role, header_h: f32) f32 {
    const m = typeface.metrics(role);
    return r.y + (header_h + m.ascent - m.descent) * 0.5;
}

/// Draw the frame and its header. Returns the body rectangle, so a caller writes
/// `const body = panel.draw(...)` and cannot draw into a stale one.
pub fn draw(
    p: *kgl.Painter,
    sheet_tex: u32,
    r: rects.Rect,
    c: Chrome,
    title: []const u8,
    note: []const u8,
) rects.Rect {
    if (r.isEmpty()) return r;
    // Field, header strip, accent tick, then the border over all three so the
    // strip cannot bleed past the frame.
    p.fillRect(r.x, r.y, r.w, r.h, theme.GLASS_BG);
    p.fillRect(r.x, r.y, r.w, c.header_h, theme.HEADER);
    p.fillRect(r.x, r.y, TICK_W, c.header_h, theme.ACCENT);
    p.rect(r.x, r.y, r.w, r.h, theme.BORDER);

    p.glyphText(sheet_tex, typeface.sheetFor(c.title), title, r.x + c.pad, titleBaseline(r, c.title, c.header_h), theme.WHITE);
    if (note.len > 0) {
        const w = typeface.width(c.note, note);
        p.glyphText(sheet_tex, typeface.sheetFor(c.note), note, r.right() - c.pad - w, titleBaseline(r, c.note, c.header_h), theme.DIM);
    }
    return bodyOf(r, c);
}

/// A panel body being filled from the top down.
///
/// Every reading a panel shows is claimed through `take`, which hands back a
/// rectangle only when the body still has the room for it, and counts what it had
/// to refuse. `note` then spends the last line saying how much was dropped: a
/// panel that silently stops reading as complete is worse than a panel that is
/// visibly short.
///
/// With `painter` null the same walk MEASURES instead of drawing — see the module
/// comment. A measuring cursor is unbounded, so it refuses nothing and `used` is
/// the height the panel would like to have.
pub const Rows = struct {
    /// The body being filled. Its height is the budget.
    body: rects.Rect,
    /// Type the rows are set in.
    role: typeface.Role,
    /// Null when the walk is not painting — a measurement or a probe.
    painter: ?*kgl.Painter = null,
    /// The baked typeface texture, for the painter.
    tex: u32 = 0,
    /// Whether the body is the unbounded one a measurement uses.
    unbounded: bool = false,
    /// Extra room handed to every gap, so a fill of fixed rows reaches the
    /// bottom of a body taller than it asked for instead of leaving the slack in
    /// one lump at the end.
    stretch: f32 = 0,
    /// Pixels laid down so far, from the top of the body.
    used: f32 = 0,
    /// Gaps laid down so far — what the slack is divided between.
    gaps: usize = 0,
    /// Rows and bands the body had no room for.
    dropped: usize = 0,

    /// A cursor that draws into `body`.
    pub fn over(p: *kgl.Painter, tex: u32, body: rects.Rect, role: typeface.Role) Rows {
        return .{ .body = body, .role = role, .painter = p, .tex = tex };
    }

    /// A cursor that draws nothing and refuses nothing, to measure what a fill
    /// asks for.
    pub fn measuring(role: typeface.Role) Rows {
        return .{
            .body = .{ .x = 0, .y = 0, .w = MEASURE_W, .h = MEASURE_H },
            .role = role,
            .unbounded = true,
        };
    }

    /// A cursor that draws nothing but is bounded exactly as the drawing one is,
    /// to find out what a fill would have to hide in a body of this size.
    pub fn probing(body: rects.Rect, role: typeface.Role) Rows {
        return .{ .body = body, .role = role };
    }

    /// A measuring body is wide and tall enough that no fill can exhaust it, so
    /// what it reports is a demand rather than a fit.
    const MEASURE_W: f32 = 1 << 16;
    const MEASURE_H: f32 = 1 << 16;

    /// Slack allowed when a claim is weighed against the room left. A body's
    /// height is a sum of float sizes and its content is another; half a pixel is
    /// below what the rasteriser can draw and above what that arithmetic can
    /// drift by, and hiding a reading over it would be a lie about the machine
    /// told by a rounding error.
    pub const TOLERANCE: f32 = 0.5;

    /// Height of one row at this cursor's type.
    pub fn lineHeight(self: *const Rows) f32 {
        return typeface.lineHeight(self.role);
    }

    /// Room left below what has been laid down.
    pub fn room(self: *const Rows) f32 {
        return @max(0, self.body.h - self.used);
    }

    /// Claim `h` pixels across the body. Null — and a drop counted — when the
    /// body has no room for them.
    pub fn take(self: *Rows, h: f32) ?rects.Rect {
        if (h > self.room() + TOLERANCE) {
            self.dropped += 1;
            return null;
        }
        const r: rects.Rect = .{ .x = self.body.x, .y = self.body.y + self.used, .w = self.body.w, .h = h };
        self.used += h;
        return r;
    }

    /// Leave `h` pixels blank — a separation between groups of rows, widened by
    /// whatever `stretch` the body has to spread. Space is never "dropped":
    /// running out of it just ends the fill.
    pub fn space(self: *Rows, h: f32) void {
        self.used += @min(h + self.stretch, self.room());
        self.gaps += 1;
    }

    /// A row of `label` on the left and `value` on the right, on one baseline —
    /// the workhorse line of every panel body.
    pub fn row(self: *Rows, label: []const u8, value: []const u8, value_color: u32) void {
        const r = self.take(self.lineHeight()) orelse return;
        const p = self.painter orelse return;
        const base = r.y + typeface.metrics(self.role).ascent;
        p.glyphText(self.tex, typeface.sheetFor(self.role), label, r.x, base, theme.DIM);
        const w = typeface.width(self.role, value);
        p.glyphText(self.tex, typeface.sheetFor(self.role), value, r.right() - w, base, value_color);
    }

    /// A row of free text from the left edge.
    pub fn text(self: *Rows, str: []const u8, color: u32) void {
        const r = self.take(self.lineHeight()) orelse return;
        const p = self.painter orelse return;
        p.glyphText(self.tex, typeface.sheetFor(self.role), str, r.x, r.y + typeface.metrics(self.role).ascent, color);
    }

    /// Count `n` things the caller could not place. A fill that packs several
    /// readings into one claim — a row of tiles, say — says so itself; `take`
    /// counts only the claims it refused.
    pub fn drop(self: *Rows, n: usize) void {
        self.dropped += n;
    }

    /// Say how much was dropped, on the body's last line, naming the things in
    /// the caller's own words ("not shown", "more cores"). Drawn bottom-anchored
    /// rather than claimed: the room it needs is exactly the room that was too
    /// small for the reading it stands in for.
    pub fn note(self: *Rows, what: []const u8) void {
        if (self.dropped == 0) return;
        const p = self.painter orelse return;
        var buf: [48]u8 = undefined;
        const txt = std.fmt.bufPrint(&buf, DROPPED_NOTE, .{ self.dropped, what }) catch return;
        const base = self.body.bottom() - typeface.metrics(self.role).descent;
        p.glyphText(self.tex, typeface.sheetFor(self.role), txt, self.body.x, base, theme.YELLOW);
    }
};
