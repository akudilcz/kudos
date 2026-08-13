//! The dock — a frosted rounded app bar floating at the bottom of the desktop, drawn
//! on the GL painter: each app is a rounded accent tile with a top-lit gradient and a
//! white icon from the baked Phosphor atlas (src/ui/assets/dockicons.zig), drawn at
//! half its baked size so linear sampling keeps the edges crisp.
//!
//! The module is two halves: PURE layout + hit-testing (host-testable — where the slab
//! and each tile land, and which tile a click hits), and `draw`, which paints them
//! through `gles`. The desktop owns the app list and running state; it hands `draw` an
//! item per app each frame and asks `iconAt` where a click landed. Coordinates are screen
//! space, y down — the painter's `orthof` is the whole desktop before `draw`.

const std = @import("std");
const kgl = @import("kgl");
const theme = @import("theme");

/// Slab + tile metrics (px).
pub const DOCK_H: f32 = 68;
pub const ICON: f32 = 48;
pub const GAP: f32 = 14;
pub const PAD: f32 = 12; // slab padding around the tile row
pub const RADIUS: f32 = 20; // the slab's rounded corners
const TILE_RADIUS: f32 = 12; // each app tile's rounded corners

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// The dock's icon vocabulary, index for index with scripts/gen-icons.py's
/// ICONS list — the bake order is ABI. Add by appending to BOTH, never by
/// reordering. The caller cross-checks the count against the baked atlas.
pub const Icon = enum(u8) {
    terminal,
    system,
    clock,
    calculator,
    vm,
    agent,
};

/// One dock entry: the app's accent colour, the icon drawn on its tile, and whether the
/// app is currently open (a pill lights beneath it).
pub const Item = struct {
    accent: u32,
    icon: Icon,
    running: bool,
};

/// One RUNNING-window slot (DSK-021): every open window holds one, visible or
/// minimised. The slot draws the window title's initial rather than an app
/// icon — the letter is what visually separates "switch to this window" from
/// the launcher zone's "spawn a new one", beside the separator bar.
pub const WinItem = struct {
    accent: u32,
    /// The window title's first character, uppercased by the caller.
    ch: u8,
    focused: bool,
    minimized: bool,
};

/// Where a dock click landed: a LAUNCHER tile (spawn a new window of that
/// app, DSK-016) or a WINDOW slot (focus/restore that window, DSK-021).
pub const Hit = union(enum) { launcher: usize, window: usize };

/// The separator between the zones, and its breathing room.
pub const SEP_W: f32 = 2;
pub const SEP_GAP: f32 = 14;

/// Width of a row of `n` tiles including inner gaps.
fn rowWidth(n: usize) f32 {
    const nf: f32 = @floatFromInt(n);
    return if (n > 0) nf * ICON + (nf - 1) * GAP else 0;
}

/// The slab rectangle for `n_launch` launcher tiles and `n_win` window slots,
/// centred along the bottom of `screen_w × h`. The separator is only present
/// when both zones are.
pub fn slabRect(screen_w: f32, screen_h: f32, n_launch: usize, n_win: usize) Rect {
    var inner = rowWidth(n_launch);
    if (n_win > 0) inner += SEP_GAP + SEP_W + SEP_GAP + rowWidth(n_win);
    const w = inner + PAD * 2;
    return .{
        .x = (screen_w - w) * 0.5,
        .y = screen_h - DOCK_H - MARGIN,
        .w = w,
        .h = DOCK_H,
    };
}
pub const MARGIN: f32 = 16; // gap between the slab and the screen bottom

/// Launcher tile `i`'s rectangle within the slab.
pub fn iconRect(slab: Rect, i: usize) Rect {
    const fi: f32 = @floatFromInt(i);
    return .{
        .x = slab.x + PAD + fi * (ICON + GAP),
        .y = slab.y + (DOCK_H - ICON) * 0.5,
        .w = ICON,
        .h = ICON,
    };
}

/// The separator bar's rectangle (call only with both zones populated).
pub fn sepRect(slab: Rect, n_launch: usize) Rect {
    return .{
        .x = slab.x + PAD + rowWidth(n_launch) + SEP_GAP,
        .y = slab.y + (DOCK_H - ICON) * 0.5,
        .w = SEP_W,
        .h = ICON,
    };
}

/// Window slot `j`'s rectangle within the slab.
pub fn winRect(slab: Rect, n_launch: usize, j: usize) Rect {
    const fj: f32 = @floatFromInt(j);
    return .{
        .x = slab.x + PAD + rowWidth(n_launch) + SEP_GAP + SEP_W + SEP_GAP + fj * (ICON + GAP),
        .y = slab.y + (DOCK_H - ICON) * 0.5,
        .w = ICON,
        .h = ICON,
    };
}

/// Which tile a screen point hits, in either zone, or null.
pub fn hitAt(screen_w: f32, screen_h: f32, n_launch: usize, n_win: usize, px: f32, py: f32) ?Hit {
    const slab = slabRect(screen_w, screen_h, n_launch, n_win);
    if (py < slab.y or py > slab.y + slab.h) return null;
    var i: usize = 0;
    while (i < n_launch) : (i += 1) {
        const r = iconRect(slab, i);
        if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return .{ .launcher = i };
    }
    var j: usize = 0;
    while (j < n_win) : (j += 1) {
        const r = winRect(slab, n_launch, j);
        if (px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h) return .{ .window = j };
    }
    return null;
}

/// Lighten a colour toward white by `t` (0..1) — for the top-lit gradient on a tile.
pub fn lighten(c: u32, t: f32) u32 {
    var out: u32 = c & 0xFF000000; // keep alpha
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const ch: f32 = @floatFromInt((c >> shift) & 0xFF);
        const v: u32 = @intFromFloat(ch + (255.0 - ch) * t);
        out |= (v & 0xFF) << shift;
    }
    return out;
}

/// Darken a colour toward black by `t` (0..1) — the bottom of a tile's shade,
/// which is what gives the icon volume instead of reading as a flat chip.
pub fn darken(c: u32, t: f32) u32 {
    var out: u32 = c & 0xFF000000; // keep alpha
    const k = 1.0 - t;
    var shift: u5 = 0;
    while (shift < 24) : (shift += 8) {
        const ch: f32 = @floatFromInt((c >> shift) & 0xFF);
        const v: u32 = @intFromFloat(ch * k);
        out |= (v & 0xFF) << shift;
    }
    return out;
}

/// The icon's drawn edge on a tile, px. The atlas bakes cells at 2x this, so
/// the scale below is what keeps a bitmap from pixellating at tile size.
pub const ICON_GLYPH: f32 = 30;

/// Paint the dock: the launcher zone, the separator, then one slot per open
/// window (DSK-021). `icons_tex`/`icons` is the uploaded dockicons atlas (one
/// cell per Icon, in enum order); `glyph_tex`/`glyphs` is the TEXT atlas the
/// window slots draw their title initial from. The painter's projection must
/// already be the whole desktop.
pub fn draw(p: *kgl.Painter, icons_tex: u32, icons: kgl.Atlas, glyph_tex: u32, glyphs: kgl.Atlas, screen_w: f32, screen_h: f32, items: []const Item, wins: []const WinItem) void {
    const slab = slabRect(screen_w, screen_h, items.len, wins.len);
    // Frosted slab, then a 1px top highlight so the glass catches a light edge.
    p.fillRoundedRect(slab.x, slab.y, slab.w, slab.h, RADIUS, theme.DOCK_BG);
    p.fillRect(slab.x + RADIUS, slab.y, slab.w - 2 * RADIUS, 1, theme.DOCK_HAIRLINE);

    if (wins.len > 0) {
        const sep = sepRect(slab, items.len);
        p.fillRoundedRect(sep.x, sep.y, sep.w, sep.h, 1, theme.DOCK_HAIRLINE);
        for (wins, 0..) |w, j| {
            const r = winRect(slab, items.len, j);
            // Focused: an accent ring behind the tile — the one slot whose
            // window takes the next keystroke reads at a glance.
            if (w.focused)
                p.fillRoundedRect(r.x - 3, r.y - 3, r.w + 6, r.h + 6, TILE_RADIUS + 3, theme.FOCUS_ACCENT);
            // The body: the window's kind accent, dimmed while it waits in the
            // dock minimised.
            const body = if (w.minimized) darken(w.accent, 0.55) else darken(w.accent, 0.20);
            p.fillRoundedRect(r.x, r.y, r.w, r.h, TILE_RADIUS, body);
            if (!w.minimized)
                p.fillRoundedRect(r.x, r.y, r.w, r.h * 0.45, TILE_RADIUS, w.accent);
            // The title initial, not an app icon: a LETTER is what says "an
            // open window" against the launcher zone's pictures.
            const g = [_]u8{w.ch};
            const scale = ICON_GLYPH / glyphs.cell_h;
            const gx = r.x + (r.w - glyphs.cell_w * scale) * 0.5;
            const gy = r.y + (r.h - ICON_GLYPH) * 0.5;
            p.textScaled(glyph_tex, glyphs, &g, gx, gy + 1, scale, 0x50000000);
            p.textScaled(glyph_tex, glyphs, &g, gx, gy, scale, 0xFFFFFFFF);
        }
    }

    for (items, 0..) |it, i| {
        const r = iconRect(slab, i);
        // A soft drop shadow so the tile floats off the glass: the same rounded
        // silhouette, offset down and translucent-black. Two stacked passes give a
        // cheap penumbra without a blur kernel.
        p.fillRoundedRect(r.x - 1, r.y + 3, r.w + 2, r.h, TILE_RADIUS + 1, 0x30000000);
        p.fillRoundedRect(r.x, r.y + 2, r.w, r.h, TILE_RADIUS, 0x40000000);

        // The body, shaded top-to-bottom for volume: a darkened base establishes the
        // rounded silhouette and the grounded lower edge, then a lighter upper band
        // (its own rounded corners softening into the body) is the top-lit sheen.
        // Light-from-above is what turns a flat chip into a dimensional key.
        p.fillRoundedRect(r.x, r.y, r.w, r.h, TILE_RADIUS, darken(it.accent, 0.20));
        p.fillRoundedRect(r.x, r.y, r.w, r.h * 0.62, TILE_RADIUS, it.accent);
        p.fillRoundedRect(r.x, r.y, r.w, r.h * 0.30, TILE_RADIUS, lighten(it.accent, 0.28));
        // A crisp 1px top highlight — the glass catches the light at the very edge.
        p.fillRect(r.x + TILE_RADIUS, r.y + 1, r.w - 2 * TILE_RADIUS, 1, lighten(it.accent, 0.55));

        // The icon, centred and white with a 1px shadow beneath so it reads on
        // any accent. Drawn through the text path: each icon is one "glyph" of
        // the icons atlas, scaled from its 2x bake down to ICON_GLYPH.
        const g = [_]u8{@intFromEnum(it.icon)};
        const scale = ICON_GLYPH / icons.cell_h;
        const gx = r.x + (r.w - icons.cell_w * scale) * 0.5;
        const gy = r.y + (r.h - ICON_GLYPH) * 0.5;
        p.textScaled(icons_tex, icons, &g, gx, gy + 1, scale, 0x50000000);
        p.textScaled(icons_tex, icons, &g, gx, gy, scale, 0xFFFFFFFF);

        // Running indicator: a short rounded pill under the tile (mac-style), brighter
        // and wider than a dot so a glance reads which apps are live.
        if (it.running) {
            const pw: f32 = ICON * 0.42;
            p.fillRoundedRect(r.x + (r.w - pw) * 0.5, slab.y + slab.h - 6, pw, 3, 1.5, theme.FOCUS_ACCENT);
        }
    }
}
