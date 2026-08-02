//! Shared UI palette. Single source of truth for every color
//! and shared layout metric used by the window chrome, the desktop, and the apps.
//! A color or dashboard dimension is defined here once and referenced elsewhere;
//! modules must not redeclare a local copy of one of these values.

const surface = @import("surface");
const Color = surface.Color; // 0xAARRGGBB premultiplied (see surface.zig)

// Every palette color carries alpha 0xFF: app windows are GLASS (per-pixel
// premultiplied alpha), so foreground pixels must
// composite OPAQUE — text/accents/bars stay at full brightness over the glass.
// Opaque composite paths ignore the byte, so it costs nothing elsewhere.

// GLASS opacity of every window's content BACKGROUND:
// ~70% opaque, so the wallpaper/desktop shows through. Owned here — one look
// and feel across the terminal and the dashboards.
pub const GLASS_ALPHA: u8 = 179; // 179/255 ≈ 0.7

// Window content surface background — the dark field every app paints onto, in
// two forms: CONTENT_BG is the opaque color (the WM default for a non-glass
// window), GLASS_BG is the same color premultiplied at GLASS_ALPHA with the
// alpha byte stamped in — the value every glass app rasters its background with
// and hands the WM via win.content_bg.
pub const CONTENT_BG: Color = 0xFF101418;
pub const GLASS_BG: Color = surface.premultiply(0xFF101418, GLASS_ALPHA);

// Primary text on the content background.
pub const TEXT: Color = 0xFFD8DCE0;

// Dashboard palette (system monitor + diagnostics console share it).
pub const HEADER: Color = 0xFF264653; // header strip / section background
pub const ACCENT: Color = 0xFF40E0E0; // cyan highlight
pub const DIM: Color = 0xFF8294A6; // de-emphasized text
pub const GREEN: Color = 0xFF27AE60; // ok / used-memory
pub const WHITE: Color = 0xFFEAEFF2; // bright label text
pub const BORDER: Color = 0xFF405060; // panel border / bar outline
pub const YELLOW: Color = 0xFFF1C40F; // warning
pub const RED: Color = 0xFFE74C3C; // critical

// Dashboard header strip height (px). Used for both the drawn strip and the
// row-count math that subtracts it from the content height.
pub const HEADER_H: usize = 28;

// ── macOS-like window chrome + dock (drawn on the GL painter) ──────────────
// These are STRAIGHT 0xAARRGGBB — the GL painter premultiplies them itself, and a
// translucent alpha (< 0xFF) is a real frosted panel over whatever is behind it.

/// The window body: a dark, mostly-opaque frosted panel.
pub const WINDOW_BG: u32 = 0xE81C1E22;
/// The title bar: a touch lighter than the body so the strip reads as a header.
pub const TITLE_BG: u32 = 0xF02A2D33;
/// Title text — bright on the focused window, dimmed on the rest.
pub const TITLE_TEXT: u32 = 0xFFECEEF2;
pub const TITLE_TEXT_DIM: u32 = 0xFF8A9099;

/// The three traffic-light buttons, in macOS order (close, minimise, zoom), and
/// the single grey they all fade to when the window is not focused.
pub const TL_CLOSE: u32 = 0xFFFF5F57;
pub const TL_MIN: u32 = 0xFFFEBC2E;
pub const TL_ZOOM: u32 = 0xFF28C840;
pub const TL_IDLE: u32 = 0xFF565A61;

/// Focus accent (macOS dark-mode blue) — focus rings, dock running-dots. Distinct
/// from the dashboard `ACCENT` (a cyan highlight) above; this is the WM chrome one.
pub const FOCUS_ACCENT: u32 = 0xFF0A84FF;

/// The dock: a frosted rounded slab floating above the wallpaper.
pub const DOCK_BG: u32 = 0xC22B2E35;
pub const DOCK_HAIRLINE: u32 = 0x40FFFFFF;

/// The 16 ANSI terminal colours, indexed by the SGR code a guest selects (0-7
/// the normal set, 8-15 the bright set). Any surface showing a stream that
/// carries colour — the VM console, a terminal — resolves through here, so one
/// guest's directory blue is every guest's directory blue.
///
/// Chosen for a dark field: the normal set is lifted well off black so it stays
/// legible on CONTENT_BG, and the bright set is separated from it by lightness
/// rather than by saturation alone.
pub const ANSI = [16]u32{
    0xFF3B4048, // black — a visible grey, since true black would vanish
    0xFFE06C75, // red
    0xFF98C379, // green
    0xFFE5C07B, // yellow
    0xFF61AFEF, // blue
    0xFFC678DD, // magenta
    0xFF56B6C2, // cyan
    0xFFABB2BF, // white
    0xFF5C6370, // bright black
    0xFFF07178, // bright red
    0xFFB5E890, // bright green
    0xFFFFD68A, // bright yellow
    0xFF7FC4FF, // bright blue
    0xFFDE95F0, // bright magenta
    0xFF6FD3DE, // bright cyan
    0xFFEAEFF2, // bright white
};

/// The colour an ANSI index selects, or `fallback` for the terminal default.
pub fn ansi(index: ?u4, fallback: u32) u32 {
    return if (index) |i| ANSI[i] else fallback;
}
