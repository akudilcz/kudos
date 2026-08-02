//! Window chrome, drawn on the GL painter — a macOS-like frosted rounded window
//! with traffic-light buttons and a centred title. No CPU pixels: the whole frame
//! is `gles` geometry (a rounded-rect fan for the body, discs for the buttons,
//! textured quads for the title glyphs), MSAA-antialiased by the pipeline.
//!
//! `draw` renders into a window-local frame — the painter's `orthof` is already set
//! to this window's `w × h`, origin top-left — so an app draws its content over the
//! body in the region below `TITLE_H`. The button hit-tests are pure and take
//! WINDOW-LOCAL coordinates, so the WM converts a screen click once and asks here.

const kgl = @import("kgl");
const theme = @import("theme");

/// Corner radius of the window body.
pub const RADIUS: f32 = 10;
/// Title-bar height — where the traffic lights sit and the title centres.
pub const TITLE_H: f32 = 28;

/// Traffic-light geometry: three discs down the left of the title bar. The hit radius is
/// generous (the dots are small, but a forgiving target matters under pointer acceleration
/// and for a real hand), and the pitch keeps the gaps between adjacent hit circles clear.
const TL_R: f32 = 7; // drawn radius
const TL_HIT_R: f32 = 11; // click radius — forgiving, still < half the pitch so gaps stay dead
pub const TL_Y: f32 = TITLE_H * 0.5;
const TL_X0: f32 = 20; // centre of the first (close) button
const TL_PITCH: f32 = 24;

/// Which traffic light, left to right.
pub const Button = enum { close, minimise, zoom };

pub fn buttonX(b: Button) f32 {
    return TL_X0 + TL_PITCH * @as(f32, @floatFromInt(@intFromEnum(b)));
}

/// Draw the whole window frame: a frosted rounded body, the three traffic lights
/// (full colour when focused, a uniform grey when not), and the centred title.
/// `atlas_tex`/`atlas` are the uploaded monospace font texture and its layout.
pub fn draw(
    p: *kgl.Painter,
    atlas_tex: u32,
    atlas: kgl.Atlas,
    w: f32,
    h: f32,
    focused: bool,
    title: []const u8,
) void {
    // The frosted body — one rounded panel; the title bar blends into it (Big Sur
    // style) rather than being a separate strip, which keeps the top corners clean.
    p.fillRoundedRect(0, 0, w, h, RADIUS, theme.WINDOW_BG);
    // A 1px top-edge highlight so the glass catches the light along its upper rim,
    // consistent with the dock's tiles. Brighter when focused.
    const rim: u32 = if (focused) 0x30FFFFFF else 0x18FFFFFF;
    p.fillRect(RADIUS, 0, w - 2 * RADIUS, 1, rim);

    // Traffic lights: a coloured bead with a small offset gloss highlight up-left,
    // the way a lit sphere catches a specular dot — reads as a glossy button, not a
    // flat dot.
    const cols = if (focused)
        [3]u32{ theme.TL_CLOSE, theme.TL_MIN, theme.TL_ZOOM }
    else
        [3]u32{ theme.TL_IDLE, theme.TL_IDLE, theme.TL_IDLE };
    inline for (.{ Button.close, Button.minimise, Button.zoom }, 0..) |b, i| {
        const cx = buttonX(b);
        p.disc(cx, TL_Y, TL_R, cols[i]);
        if (focused) p.disc(cx - TL_R * 0.3, TL_Y - TL_R * 0.3, TL_R * 0.35, 0x60FFFFFF);
    }

    // Centred title, clipped to a sane cap (windows never carry a 128-char title).
    const shown = title[0..@min(title.len, 128)];
    const tw = kgl.textWidth(atlas, shown);
    // Keep the title clear of the traffic lights on the left.
    const min_x = buttonX(.zoom) + TL_HIT_R + 6;
    var tx = (w - tw) * 0.5;
    if (tx < min_x) tx = min_x;
    const ty = (TITLE_H - atlas.cell_h) * 0.5;
    const color = if (focused) theme.TITLE_TEXT else theme.TITLE_TEXT_DIM;
    p.text(atlas_tex, atlas, shown, tx, ty, color);
}

// ── hit-tests (pure; window-local coordinates, y down) ─────────────────────

/// The traffic light at (px,py), or null. The WM maps this to close / minimise / zoom.
///
/// The hit area is a SQUARE of half-side TL_HIT_R around each button, not a disc: a square
/// is uniformly forgiving (a disc misses the diagonal corners, which under pointer
/// acceleration is the difference between a click landing and sliding off), and TL_HIT_R is
/// kept below half the pitch so a dead gap still separates adjacent buttons. The drawn dot
/// is still a small circle — this is only where a click counts.
pub fn buttonAt(px: f32, py: f32) ?Button {
    if (py < TL_Y - TL_HIT_R or py > TL_Y + TL_HIT_R) return null;
    inline for (.{ Button.close, Button.minimise, Button.zoom }) |b| {
        const cx = buttonX(b);
        if (px >= cx - TL_HIT_R and px <= cx + TL_HIT_R) return b;
    }
    return null;
}

/// Whether (px,py) is on the title bar (the drag handle) — the top strip, minus
/// the buttons, which `buttonAt` claims first.
pub fn onTitleBar(px: f32, py: f32) bool {
    return py >= 0 and py < TITLE_H and px >= 0 and buttonAt(px, py) == null;
}
