//! glcomp — the desktop compositor, expressed as a `kgl` client.
//!
//! The whole desktop is one drawn frame: the wallpaper, then every window (its frosted
//! chrome and, over it, the app's content), then the dock — back to front, through `kgl`,
//! lowered onto whatever backs the `idraw` seam — the GPU on the product path (ARCH-015),
//! the software rasteriser only under `-Dsoft-display` and host tests. There is no sysmem
//! back-buffer and no per-window blit list; there are only draw calls, batched.
//!
//! It is deliberately a set of primitives — `wallpaper`, `windowFrame`, `dockBar` — rather
//! than one `compose(everything)` call, because the caller must interleave each window's
//! CONTENT between its frame and the next window's frame to get the stacking right (a
//! higher window's chrome must cover a lower window's content). desktop.renderGles
//! drives them in scene order: wallpaper, then per window back-to-front its frame
//! followed by the hosted app's content draw, then the dock.
//!
//! Chrome geometry and the traffic-light hit-tests live in `chrome.zig`; the dock in
//! `dock.zig`. This file only orders them into a desktop.

const kgl = @import("kgl");
const chrome = @import("chrome.zig");
const dock = @import("../desktop/dock.zig");

/// One window to place on the desktop: its screen rectangle, title, and focus. Content is
/// the app's to draw, over the frame, at the same origin.
pub const Window = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    title: []const u8,
    focused: bool,
};

/// The wallpaper: a vertical gradient from `top` to `bottom` (both 0xAARRGGBB) — one
/// quad whose vertex colours the GPU interpolates, so the gradient is band-free at any
/// panel height. A real image would be one `p.image` instead; the gradient needs no
/// asset and reads as a desktop.
pub fn wallpaper(p: *kgl.Painter, w: f32, h: f32, top: u32, bottom: u32) void {
    p.fillRectGradientV(0, 0, w, h, top, bottom);
}

/// The wallpaper as a full-screen image (spec R22): one textured quad,
/// stretched to the panel. Untinted (white modulate). The gradient above
/// stays as the loud no-asset fallback.
pub fn wallpaperImage(p: *kgl.Painter, w: f32, h: f32, tex: u32) void {
    p.image(tex, 0, 0, w, h, kgl.UNTINTED);
}

/// A window's frame: a soft drop shadow so it floats, then the chrome. Leaves the painter
/// origin at (win.x, win.y) so the app can draw its content in window-local coordinates
/// straight after; the next `windowFrame` (or `dockBar`) resets it.
pub fn windowFrame(p: *kgl.Painter, win: Window, atlas_tex: u32, atlas: kgl.Atlas) void {
    p.setOrigin(win.x, win.y);
    // A tight, faint drop shadow: two translucent black rounded rects, biased
    // downward as if lit from above. Small spread + low alpha reads as depth
    // without the smudged halo a wide dark shadow leaves on a bright wallpaper.
    p.fillRoundedRect(-2, 2, win.w + 4, win.h + 6, chrome.RADIUS + 2, 0x1C000000);
    p.fillRoundedRect(0, 3, win.w, win.h + 3, chrome.RADIUS, 0x24000000);
    chrome.draw(p, atlas_tex, atlas, win.w, win.h, win.focused, win.title);
}

/// The dock along the bottom. Resets the origin first, so it lands in screen space
/// whatever the last window left it at.
pub fn dockBar(p: *kgl.Painter, icons_tex: u32, icons: kgl.Atlas, screen_w: f32, screen_h: f32, items: []const dock.Item) void {
    p.setOrigin(0, 0);
    dock.draw(p, icons_tex, icons, screen_w, screen_h, items);
}
