//! The desktop's boot layout: the geometry of the boot terminals, their first
//! placement at boot, and re-tiling after a logical resolution change. One
//! concern of the Desktop: every function takes the Desktop and keeps its
//! call order.
//!
//! SMP boots four terminals tiled 2x2, filling the screen with no overlap;
//! two of the tiles open straight into their job (BOOT_AUTOSTART). The
//! single-core build hosts ONE terminal inline — it has no session tasks to
//! run three more shells — and keeps the quarter-screen boot tile.

const std = @import("std");
const buildinfo = @import("buildinfo");
const framebuffer = @import("../screen/framebuffer.zig");
const window_mod = @import("../wm/window.zig");
const desktop_mod = @import("desktop.zig");
const dock = @import("dock.zig");
const Desktop = desktop_mod.Desktop;
const lifecycle = @import("lifecycle.zig");

/// Single-core boot terminal geometry: offset from
/// the top-left corner, sized to a QUARTER of the screen area (half in each
/// axis) so the wallpaper and the screensaver square stay visible around it.
const BOOT_TERM_ORIGIN: usize = 100;

/// The SMP boot grid: 2 columns x 2 rows of terminal tiles.
const BOOT_COLS: usize = 2;
const BOOT_ROWS: usize = 2;
const BOOT_TILES: usize = BOOT_COLS * BOOT_ROWS;

/// What each boot tile runs, indexed in spawn order (row-major from the
/// top-left): null is a plain shell; a line is TYPED into the tile's session
/// (Terminal.autotype) so it echoes, dispatches, and prompts exactly as a
/// typed command — there is no second dispatch path. `kudos vm 3` boots the
/// staged compiler guest; `kudos ai` enters the agent conversation.
const BOOT_AUTOSTART = [BOOT_TILES]?[]const u8{
    null, // top-left: plain shell, keeps focus
    "kudos ai", // top-right: the AI agent
    "kudos vm 3", // bottom-left: the compiler guest
    null, // bottom-right: plain shell
};

const BootRect = struct { x: i32, y: i32, w: usize, h: usize };

/// Boot tile `i`'s OUTER window rect at the CURRENT screen size (row-major
/// from the top-left). Integer division gives every column/row the same floor
/// size and the LAST column/row the rounding slack, so the tiles cover the
/// screen exactly: no overlap, no uncovered strip.
fn tileRect(i: usize) BootRect {
    const sw = framebuffer.width();
    // The tiles partition the screen ABOVE the dock strip: a tile under the
    // slab would put its close box and its content's bottom rows beneath
    // frosted glass.
    const dock_strip: usize = @intFromFloat(dock.DOCK_H + 2 * dock.MARGIN);
    const sh_full = framebuffer.height();
    const sh = if (sh_full > dock_strip * 2) sh_full - dock_strip else sh_full;
    const col = i % BOOT_COLS;
    const row = i / BOOT_COLS;
    const x = col * (sw / BOOT_COLS);
    const y = row * (sh / BOOT_ROWS);
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = if (col == BOOT_COLS - 1) sw - x else sw / BOOT_COLS,
        .h = if (row == BOOT_ROWS - 1) sh - y else sh / BOOT_ROWS,
    };
}

/// The single-core boot terminal's rect for the CURRENT screen size. Null when
/// the screen is too small to hold a usable window at this origin.
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
/// logical resize so the desktop uses the whole panel. The resize fires at GPU
/// bring-up, before any window can have been opened or closed, so the leading
/// entries of the app list ARE the boot terminals in spawn order. Only the
/// boot windows are retiled; later windows are left where they are.
pub fn retileBoot(d: *Desktop) void {
    if (buildinfo.smp) {
        const n = @min(d.apps.items.len, BOOT_TILES);
        for (d.apps.items[0..n], 0..) |a, i| {
            const win = a.window();
            const r = tileRect(i);
            win.x = r.x;
            win.y = r.y;
            _ = d.applyResize(win, r.w, r.h);
        }
    } else {
        const r = bootTermRect() orelse return;
        if (d.apps.items.len > 0) {
            const win = d.apps.items[0].window();
            win.x = r.x;
            win.y = r.y;
            _ = d.applyResize(win, r.w, r.h);
        }
    }
    d.wm.markFull();
}

pub fn spawnBootLayout(d: *Desktop) !void {
    // No on-screen diagnostics console: the trace streams live over netdebug
    // (DIAG-004), which is where every suite reads it, and an auto-scrolling
    // log window would mark damage continuously for nobody's benefit.

    if (!buildinfo.smp) {
        // One inline terminal on a quarter of the screen — an ordinary session
        // like any other: it claims the first session slot, so it names itself
        // `term #0`.
        const r = bootTermRect() orelse return error.ScreenTooSmall;
        _ = try lifecycle.spawnTerm(d, r.x, r.y, r.w, r.h, null, false);
        d.spawn_count += 1; // offsets the next cascaded window off the boot tile
        return;
    }

    // SMP: four terminals tiled 2x2, filling the screen. Each is an ordinary
    // session (claimed in order, so the tiles name themselves term #0..#3);
    // the autostart lines are typed into their sessions and run once the
    // scheduler starts their editor tasks — the key rings hold until then.
    var first: ?*window_mod.Window = null;
    for (BOOT_AUTOSTART, 0..) |autostart, i| {
        const r = tileRect(i);
        const win = try lifecycle.spawnTerm(d, r.x, r.y, r.w, r.h, null, false);
        if (i == 0) first = win;
        if (autostart) |line| {
            if (d.appFor(win)) |a| a.term.autotype(line);
        }
        d.spawn_count += 1; // offsets the next cascaded window per boot tile
    }
    // Every spawn took focus as it opened; the user's first keystrokes belong
    // to the plain top-left shell.
    if (first) |w| d.wm.focus(w);
}
