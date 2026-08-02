//! The desktop's boot layout: the geometry of the boot terminal, its first
//! placement at boot, and re-tiling after a logical resolution change. One
//! concern of the Desktop: every function takes the Desktop and keeps its
//! call order.

const std = @import("std");
const framebuffer = @import("../screen/framebuffer.zig");
const desktop_mod = @import("desktop.zig");
const Desktop = desktop_mod.Desktop;
const lifecycle = @import("lifecycle.zig");

/// Boot terminal geometry: offset from
/// the top-left corner, sized to a QUARTER of the screen area (half in each
/// axis) so the wallpaper and the screensaver square stay visible around it.
const BOOT_TERM_ORIGIN: usize = 100;

const BootRect = struct { x: i32, y: i32, w: usize, h: usize };

/// The boot terminal's rect for the CURRENT screen size — the one owner of
/// that geometry (spawnBootLayout places it here, retileBoot restores it
/// after a resolution change). Null when the screen is too small to hold a
/// usable window at this origin.
fn bootTermRect() ?BootRect {
    const sw = framebuffer.width();
    const sh = framebuffer.height();
    // Half the screen in each axis = a quarter of the area.
    const w = sw / 2;
    const h = sh / 2;
    if (sw <= BOOT_TERM_ORIGIN + 2 or sh <= BOOT_TERM_ORIGIN + 2) return null;
    return .{
        .x = @intCast(BOOT_TERM_ORIGIN),
        .y = @intCast(BOOT_TERM_ORIGIN),
        // Never run off the right/bottom edge on a small screen.
        .w = @min(w, sw - BOOT_TERM_ORIGIN - 1),
        .h = @min(h, sh - BOOT_TERM_ORIGIN - 1),
    };
}

/// Re-apply the boot geometry at the CURRENT screen size — called after a
/// logical resize so the desktop uses the whole panel. Only the boot
/// terminal is retiled; later windows are left where they are.
pub fn retileBoot(d: *Desktop) void {
    const r = bootTermRect() orelse return;
    if (d.apps.items.len > 0) {
        const win = d.apps.items[0].window();
        win.x = r.x;
        win.y = r.y;
        _ = d.applyResize(win, r.w, r.h);
    }
    d.wm.markFull();
}

pub fn spawnBootLayout(d: *Desktop) !void {
    // No on-screen diagnostics console: the trace streams live over netdebug
    // (DIAG-004), which is where every suite reads it, and an auto-scrolling
    // log window would mark damage continuously for nobody's benefit.

    // The boot terminal takes a quarter of the screen (bootTermRect). It is an
    // ordinary session like any other — it claims the first session slot, so it
    // names itself `term #0`, and its editor task runs wherever there is room.
    const r = bootTermRect() orelse return error.ScreenTooSmall;
    _ = try lifecycle.spawnTerm(d, r.x, r.y, r.w, r.h, null, false);
    d.spawn_count += 1; // so the next runtime `term` is "term #1"
}
