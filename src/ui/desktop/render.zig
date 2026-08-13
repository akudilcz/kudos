//! The desktop's compositing/render path: the one gles context the whole
//! desktop draws through (GlesComp), the whole-desktop GL frame (wallpaper,
//! screensaver cube, window chrome and content, dock), the deferred
//! frame-completion handshake with the present ring, and the wallpaper
//! hand-off from the `background` command. One concern of the Desktop: every
//! function takes the Desktop and keeps its call order.

const std = @import("std");
const klog = @import("../../kernel/debug/klog.zig");
const framebuffer = @import("../screen/framebuffer.zig");
const gles = @import("gles"); // the draw API (context lifecycle for the gles compositor)
const kgl = @import("kgl"); // the 2D library the compositor draws through
const glcomp = @import("../wm/glcomp.zig"); // the gles compositor primitives
const typeface = @import("typeface"); // the baked scalable face (spec RND-009)
const hud = @import("hud.zig"); // the heads-up display, drawn over everything
const dock = @import("dock.zig"); // the frosted app dock (drawn on the gles path)
const cursor = @import("cursor.zig"); // the software mouse pointer image
const font = @import("../screen/font.zig"); // the glyph atlas the title text samples
const dockicons = @import("../assets/dockicons.zig"); // the dock's baked icon atlas

comptime {
    // The bake order is ABI: one atlas cell per dock.Icon, index for index.
    if (@typeInfo(dock.Icon).@"enum".fields.len != dockicons.COUNT)
        @compileError("dock.Icon and the baked icon atlas disagree — regenerate scripts/gen-icons.py");
}
const square = @import("../wm/square.zig");
// The screensaver cube is lit with the machine's ONE lamp — spin.zig owns the
// lighting facts, so every lit surface on the desktop reads as one world.
const spin = @import("../../apps/spin.zig");
const BlobWindow = @import("../../apps/blobwin.zig").BlobWindow; // the module-drawn window (never_inline'd replay)
const vfs = @import("vfs");
const png = @import("modelcache").png;
const iaccel = @import("iaccel"); // the GPU-acceleration seam (iface/iaccel.zig)
const desktop_mod = @import("desktop.zig");
const Desktop = desktop_mod.Desktop;

/// Wallpaper gradient for the gles compositor (top → bottom, 0xAARRGGBB).
/// The default wallpaper, seeded into the ramdisk from
/// assets/media/background.png (spec R23) by main.seedRamdisk.
const DEFAULT_WALLPAPER_PATH = "/ramdisk/background.png";
const WP_TOP: u32 = 0xFF1E4E8C;
const WP_BOTTOM: u32 = 0xFF6B3F9E;

/// The GL desktop's per-session state: the one gles context the whole desktop draws
/// through, the 2D painter over it, and the uploaded glyph atlas. Built once, lazily,
/// on the first frame after a draw device is published.
pub const GlesComp = struct {
    alloc: std.mem.Allocator,
    gctx: gles.Context,
    painter: kgl.Painter,
    atlas_tex: u32,
    /// The baked scalable typeface (spec RND-009), uploaded once beside the
    /// fixed-cell atlas. 0 until the bake succeeded — every draw that uses it
    /// checks typeface.ready() first.
    sheet_tex: u32 = 0,
    atlas: kgl.Atlas,
    /// The dock's baked icon atlas (assets/dockicons.zig), uploaded beside the
    /// glyph atlases; one cell per dock.Icon, in enum order.
    icons_tex: u32,
    icons: kgl.Atlas,
    /// The wallpaper image texture, or null when no asset decoded (gradient
    /// fallback). Swapped at frame start when `background` picks a new image.
    wallpaper_tex: ?u32 = null,
    /// The software mouse pointer image (ui/desktop/cursor.zig), drawn only
    /// when no hardware cursor plane is up (`iaccel.accel.cursor` null).
    cursor_tex: u32 = 0,

    /// Decode + upload the wallpaper image from `path` on this context.
    /// Null (with a loud log line) on any failure — the caller falls back to
    /// the gradient rather than a black screen.
    fn loadWallpaper(g: *gles.Context, alloc: std.mem.Allocator, path: []const u8) ?u32 {
        const data = vfs.read(path) orelse {
            klog.puts("desktop: wallpaper file missing — gradient fallback\n");
            return null;
        };
        const img = png.decode(alloc, data) catch |e| {
            klog.puts("desktop: wallpaper decode failed (");
            klog.puts(@errorName(e));
            klog.puts(") — gradient fallback\n");
            return null;
        };
        defer img.deinit(alloc);
        return kgl.uploadImage(g, @intCast(img.w), @intCast(img.h), img.bgra);
    }

    fn init(alloc: std.mem.Allocator, screen_w: usize, screen_h: usize) ?GlesComp {
        // The desktop is ONE draw target covering the whole screen, not a window. The
        // GPU backend keys on the reserved DESKTOP_WIN_BASE to de-tile straight into the
        // scanout ring's compose buffer (see present.mirrorTarget). The software
        // backend has no ring: it delivers in place, so it is pointed at the
        // firmware scanout itself and its frames are the picture.
        const dst: gles.Dst = if (softTarget()) |t| .{
            .win_base = t.base,
            .stride_px = t.stride_px,
            .off_x = 0,
            .off_y = 0,
        } else .{
            .win_base = iaccel.DESKTOP_WIN_BASE,
            .stride_px = @intCast(screen_w),
            .off_x = 0,
            .off_y = 0,
        };
        var g = gles.createContext(alloc, dst) orelse return null;
        const painter = kgl.Painter.init(alloc) catch {
            gles.destroyContext(&g);
            return null;
        };
        // Upload the glyph atlas once (a device resource that outlives the frame); a frame
        // must be open for texture creation, so open one and close it with the empty frame.
        // `finish` drains that throwaway frame's de-tile so the context is idle before the
        // first real render (else its next beginFrame would see a frame still in flight).
        gles.beginFrame(&g, @intCast(screen_w), @intCast(screen_h));
        const atlas_tex = kgl.uploadAtlas(&g, @intCast(font.ATLAS_W), @intCast(font.ATLAS_H), &font.ATLAS_LA);
        const icons_tex = kgl.uploadAtlas(&g, @intCast(dockicons.ATLAS_W), @intCast(dockicons.ATLAS_H), &dockicons.ATLAS_LA);
        // The default wallpaper rides the same throwaway frame (textures need
        // an open frame). This is boot-time, before the first present, so the
        // decode cost never touches a 60 Hz frame (R10).
        const wallpaper_tex = loadWallpaper(&g, alloc, DEFAULT_WALLPAPER_PATH);
        // The scalable typeface's sheet, on the same throwaway frame. The upload
        // wants luminance-alpha pairs; the bake is one byte per texel, so it is
        // expanded through a scratch buffer that is freed straight away — a
        // one-off at boot, never on a frame.
        const sheet_tex = uploadTypeface(&g, alloc);
        // The software pointer's arrow, baked and uploaded on the same
        // throwaway frame. Uploaded unconditionally (one small texture);
        // drawn only when there is no hardware cursor plane.
        const cursor_px = cursor.bake();
        const cursor_tex = kgl.uploadImage(&g, cursor.W, cursor.H, &cursor_px);
        gles.swapBuffers(&g);
        gles.finish(&g);
        return .{
            .alloc = alloc,
            .gctx = g,
            .painter = painter,
            .atlas_tex = atlas_tex,
            .sheet_tex = sheet_tex,
            .atlas = .{
                .cell_w = @floatFromInt(font.WIDTH),
                .cell_h = @floatFromInt(font.HEIGHT),
                .first = font.FIRST_CHAR,
                .count = @intCast(font.GLYPH_COUNT),
            },
            .icons_tex = icons_tex,
            .icons = .{
                .cell_w = @floatFromInt(dockicons.CELL),
                .cell_h = @floatFromInt(dockicons.CELL),
                .first = 0,
                .count = @intCast(dockicons.COUNT),
            },
            .wallpaper_tex = wallpaper_tex,
            .cursor_tex = cursor_tex,
        };
    }
};

/// Draw one desktop frame. Apps draw INTO the frame (drawGl / drawInline,
/// renderGles) — there is no per-window raster pass; damage tracked in the WM
/// gates whether the software device redraws at all.
pub fn render(d: *Desktop) void {
    // Apply the frame's ONE coalesced resize request — onMouse only records it.
    if (d.pending_resize) |req| {
        d.pending_resize = null;
        _ = d.applyResize(req.win, req.w, req.h);
    }
    // Keep the HW cursor plane in sync outside mouse events too (initial
    // position, logical resizes) — two MMIO writes, ≤ once per frame.
    if (iaccel.accel.cursor) |gc| gc(d.cursor_x, d.cursor_y);
    // Until a draw device is live (the GPU bring-up window on a machine whose
    // GPU is coming), there is nothing to render with — the firmware
    // framebuffer holds the boot log until the GL desktop takes over.
    if (glesDesktopActive()) renderGles(d);
}

/// Hand the desktop a decoded background image (spec R24). Returns false
/// while a previous hand-off is still waiting (the caller reports "busy"
/// and keeps ownership). Called from the core-0 command worker; the
/// render task uploads and frees it at the next frame start.
pub fn setBackground(d: *Desktop, img: png.Image) bool {
    const if_was = d.structure_lock.acquireIrqSave();
    defer d.structure_lock.releaseIrqRestore(if_was);
    if (d.bg_pending != null) return false;
    d.bg_pending = img;
    // A new wallpaper repaints everything — the frame that swaps it in must
    // not be clipped to some smaller damage box.
    d.wm.markFull();
    return true;
}

/// Upload a pending background inside the just-opened frame and swap it
/// in; the old texture is deleted once the new one exists. Upload-only on
/// the frame path — the decode already happened on the command worker.
fn applyPendingBackground(d: *Desktop, gc: *GlesComp) void {
    const img = blk: {
        const if_was = d.structure_lock.acquireIrqSave();
        defer d.structure_lock.releaseIrqRestore(if_was);
        const img = d.bg_pending orelse break :blk null;
        d.bg_pending = null;
        break :blk img;
    } orelse return;
    defer img.deinit(d.a);
    const tex = kgl.uploadImage(&gc.gctx, @intCast(img.w), @intCast(img.h), img.bgra);
    if (gles.getError(&gc.gctx) != gles.GL_NO_ERROR) {
        klog.puts("desktop: background upload failed — wallpaper unchanged\n");
        return;
    }
    if (gc.wallpaper_tex) |old| gles.deleteTextures(&gc.gctx, 1, @ptrCast(&old));
    gc.wallpaper_tex = tex;
}

/// Upload the baked typeface sheet as a texture, or 0 when there is no bake to
/// upload. The sheet is 8-bit coverage and the atlas format is luminance-alpha,
/// so it is expanded through a scratch buffer that is released immediately: this
/// runs once, at bring-up, long before the first present.
fn uploadTypeface(g: *gles.Context, alloc: std.mem.Allocator) u32 {
    if (!typeface.ready()) {
        klog.puts("desktop: no scalable typeface baked — HUD text unavailable\n");
        return 0;
    }
    const src = typeface.sheetBytes();
    const la = alloc.alloc(u8, src.len * 2) catch {
        klog.puts("desktop: typeface sheet upload buffer FAILED\n");
        return 0;
    };
    defer alloc.free(la);
    typeface.expandToLuminanceAlpha(la);
    return kgl.uploadAtlas(g, typeface.SHEET_W, typeface.sheetHeight(), la);
}

/// Render the whole desktop as ONE GL frame — wallpaper, screensaver cube, every
/// window's frosted chrome and content (2D apps as batched painter draws, 3D models
/// inline), then the dock — through `kgl → gles → idraw` onto the GPU. The backend
/// de-tiles the finished frame into the scanout ring and flips it. The caller
/// (render) has already checked glesDesktopActive; until the GPU present ring is up
/// there is nothing to render with — the firmware framebuffer holds the boot log
/// through the GPU bring-up window.
fn renderGles(d: *Desktop) void {
    const sw: usize = framebuffer.width();
    const sh: usize = framebuffer.height();
    // never_inline: chrome bring-up (context, atlas, wallpaper, typeface) runs
    // once at boot, but inlining parks its ~45 KiB of context/upload staging in
    // THIS per-frame function's stack frame for every frame after.
    if (d.gles_comp == null) d.gles_comp = @call(.never_inline, GlesComp.init, .{ d.a, sw, sh });
    // A device is present but the context did not come up: nothing can draw
    // this frame; leave the last delivered frame standing.
    const gc = if (d.gles_comp) |*x| x else return;
    // Reset the per-frame damage accumulation. kudos redraws the WHOLE desktop
    // every frame on the GPU — the flip cadence IS the desktop's heartbeat at
    // the panel rate, and the card does the work — so the damage box only serves
    // to clear the accumulation, never to skip or scissor a frame.
    const damage = d.wm.takeSceneDamage();
    // The software rasteriser is the exception: a whole-screen CPU frame costs
    // orders of magnitude more than a flip, and it delivers straight into the
    // scanout, so an unchanged desktop is already on screen. Redrawing it would
    // buy nothing and starve everything else on the loop.
    if (softTarget() != null and damage == null) return;
    // On that same rasteriser the frame's cost is the shaded area, so the whole
    // frame is scissored to the damage bounding box: a cursor move shades a few
    // hundred pixels, a keystroke its window, never the screen (soft.zig clips
    // the raster bbox before any pixel is shaded). Null = shade everything
    // (the GPU path, or full damage).
    const clip: ?Clip = if (softTarget() != null and damage != null and !damage.?.full)
        .{ .x = damage.?.x, .y = damage.?.y, .w = damage.?.w, .h = damage.?.h }
    else
        null;

    // Complete the PREVIOUS deferred frame first: its de-tile drained while we
    // were between frames, so the wait is near-free, and the flip it arms frees
    // the compose buffer this frame is about to target.
    completeOpenFrame(d);

    const wf: f32 = @floatFromInt(sw);
    const hf: f32 = @floatFromInt(sh);
    const blink_on = (d.blink_phase & 1) == 0;

    gles.beginFrame(&gc.gctx, @intCast(sw), @intCast(sh));
    applyPendingBackground(d, gc);
    gc.painter.begin(&gc.gctx, @intCast(sw), @intCast(sh));
    // AFTER painter.begin — begin() resets the scissor to whole-frame, and an
    // unclipped wallpaper pass would erase everything the clipped passes
    // above it then fail to redraw.
    applyClip(gc, sh, clip);
    if (gc.wallpaper_tex) |tex| {
        glcomp.wallpaperImage(&gc.painter, wf, hf, tex);
    } else {
        glcomp.wallpaper(&gc.painter, wf, hf, WP_TOP, WP_BOTTOM);
    }
    // The screensaver cube — above the wallpaper, below every window. A 3D
    // draw mid-2D-frame: flush the painter batch, hand the context to the
    // confined cube, then re-open the 2D state (the model-window shape).
    gc.painter.end();
    drawScreensaverCube(gc, d.wm.square.x, d.wm.square.y, d.wm.square.step_phase, sh, clip);
    gc.painter.begin(&gc.gctx, @intCast(sw), @intCast(sh));
    applyClip(gc, sh, clip); // begin() reset the scissor; restore the frame clip
    for (d.wm.windows.items) |win| {
        if (win.minimized) continue; // hidden until restored from the dock
        gc.painter.setOrigin(0, 0);
        glcomp.windowFrame(&gc.painter, .{
            .x = @floatFromInt(win.x),
            .y = @floatFromInt(win.y),
            .w = @floatFromInt(win.w),
            .h = @floatFromInt(win.h),
            .title = win.title,
            .focused = d.wm.focused == win,
        }, gc.atlas_tex, gc.atlas);
        const cx: i32 = win.contentX();
        const cy: i32 = win.contentY();
        // A model window's 3D draws INLINE, into the same frame: flush the 2D batch,
        // hand the context to the model (viewport + scissor confine it to the content
        // rect, lit + depth-tested), then re-open the 2D state for the next window.
        if (d.modelFor(win)) |mv| {
            gc.painter.end();
            const drawn = mv.drawInline(&gc.gctx, cx, cy, @intCast(win.contentW()), @intCast(win.contentH()), @intCast(sh));
            gc.painter.begin(&gc.gctx, @intCast(sw), @intCast(sh));
            applyClip(gc, sh, clip); // begin() reset the scissor; restore the frame clip
            if (!drawn) {
                gc.painter.setOrigin(@floatFromInt(cx), @floatFromInt(cy));
                gc.painter.text(gc.atlas_tex, gc.atlas, "cannot show: missing/bad model file", 12, 12, 0xFFFF6B6B);
            }
            continue;
        }
        // A 2D app draws its content straight into the frame, content-locally,
        // scissored to the content rectangle so nothing bleeds past the chrome.
        // Flush around the scissor change: the painter batches, and a batch takes
        // the scissor state that is live when it flushes.
        if (d.appFor(win)) |a2| {
            // A scene-mode module window is 3D, not 2D: it replays its recorded
            // frame INLINE the way a model window does (MOD-015), in its own
            // function so neither its locals nor the painter cycle around it
            // ride this per-frame stack frame (already 49 KiB — stackdebt.txt).
            if (a2 == .blob and a2.blob.mode == .scene) {
                drawSceneWindow(gc, a2.blob, cx, cy, win.contentW(), win.contentH(), sw, sh, clip);
                continue;
            }
            gc.painter.end();
            // The VM console and the blob window own GL resources (the guest
            // scanout / the module's frame texture) that must be uploaded inside
            // the open frame, after the batch flush, before their draws sample
            // them. Steady state: a no-op.
            if (a2 == .vm) a2.vm.prepareGl(&gc.gctx);
            // never_inline: same stack rule as drawInline above — the upload's
            // staging must not ride every frame's stack.
            if (a2 == .blob) @call(.never_inline, BlobWindow.prepareGl, .{ a2.blob, &gc.gctx });
            scissorWithin(gc, sh, cx, cy, win.contentW(), win.contentH(), clip);
            gc.painter.setOrigin(@floatFromInt(cx), @floatFromInt(cy));
            a2.drawGl(&gc.painter, gc.atlas_tex, gc.atlas, win.contentW(), win.contentH(), d.wm.focused == win, blink_on);
            gc.painter.end();
            gles.disable(&gc.gctx, gles.GL_SCISSOR_TEST);
            applyClip(gc, sh, clip); // back to the frame's damage clip
        }
    }
    // The dock, over the wallpaper and windows — a rounded frosted bar of app tiles.
    var dock_items: [desktop_mod.DOCK_APPS.len]dock.Item = undefined;
    for (desktop_mod.DOCK_APPS, 0..) |da, i| dock_items[i] = .{
        .accent = da.accent,
        .icon = da.icon,
        .running = d.kindRunning(da.kind),
    };
    glcomp.dockBar(&gc.painter, gc.icons_tex, gc.icons, wf, hf, &dock_items);

    // The heads-up display goes over everything, including the dock (spec
    // HUD-003): it is a view of the machine, not another window in it.
    // never_inline: the HUD's dozens of widget draws merge to a ~55 KiB frame
    // when inlined here — that scratch belongs on the stack only in the
    // frames where the HUD is actually shown, not on every present.
    gc.painter.setOrigin(0, 0);
    if (gc.sheet_tex != 0) @call(.never_inline, hud.draw, .{ &gc.painter, gc.sheet_tex });

    // The software pointer, topmost of all: with no hardware cursor plane the
    // pointer only exists as pixels in this frame (input.zig repaints on every
    // pointer sample in that mode, so it tracks).
    if (iaccel.accel.cursor == null) {
        gc.painter.image(
            gc.cursor_tex,
            @floatFromInt(d.cursor_x),
            @floatFromInt(d.cursor_y),
            @floatFromInt(cursor.W),
            @floatFromInt(cursor.H),
            0xFFFFFFFF,
        );
    }

    gc.painter.setOrigin(0, 0);
    gc.painter.end();
    gles.swapBuffers(&gc.gctx);
    // The frame is kicked, NOT completed — its finish (wait for the de-tile to
    // land) and flip are DEFERRED to the start of the next render, so the GPU
    // drains during the inter-frame gap instead of on this frame's critical
    // path. The CPU build then overlaps the GPU wait rather than stacking on it,
    // halving the serial per-frame cost at the price of one frame of latency.
    d.frame_open = true;
}

/// Complete the deferred hardware frame: wait for its de-tile to land and
/// flip it (present.presentDesktopFrame via the seam). Must run before the
/// next frame's build targets the ring, and before ANY GL resource the open
/// frame may still be fetching from is freed (lifecycle.closeWindow) — a
/// freed buffer heap extent is reused by the very next staging write.
pub fn completeOpenFrame(d: *Desktop) void {
    if (!d.frame_open) return;
    d.frame_open = false;
    if (d.gles_comp) |*gc| {
        gles.finish(&gc.gctx);
        if (iaccel.accel.whole_frame_end) |frame_end| frame_end();
    }
}

/// The firmware scanout this desktop delivers into, or null when it renders on
/// the GPU. Non-null only on an emulated boot of a `-Dsoft-display` build,
/// where the software rasteriser is the published draw device: it delivers in
/// place, so the target must be real memory rather than the GPU ring sentinel.
fn softTarget() ?framebuffer.LinearTarget {
    if (!gles.hasSoftwareDevice()) return null;
    return framebuffer.linearTarget();
}

/// The frame's damage clip on the software rasteriser, screen coordinates
/// (y down). Null when the whole frame is to be shaded.
const Clip = struct { x: i32, y: i32, w: u32, h: u32 };

/// One scene-mode module window, inside the open desktop frame: flush the 2D
/// batch, hand the context to the replay (which confines itself with viewport +
/// scissor), then re-open the 2D state for the windows after it. Its own
/// function so its locals — and the replay's whole call tree — stay OUT of
/// renderGles's per-frame stack frame (the caller pins that with never_inline).
noinline fn drawSceneWindow(
    gc: *GlesComp,
    blob: *BlobWindow,
    cx: i32,
    cy: i32,
    cw: usize,
    ch: usize,
    sw: usize,
    sh: usize,
    clip: ?Clip,
) void {
    gc.painter.end();
    const drawn = blob.drawInline(&gc.gctx, cx, cy, @intCast(cw), @intCast(ch), @intCast(sh));
    gc.painter.begin(&gc.gctx, @intCast(sw), @intCast(sh));
    applyClip(gc, sh, clip); // begin() reset the scissor; restore the frame clip
    if (!drawn) {
        gc.painter.setOrigin(@floatFromInt(cx), @floatFromInt(cy));
        gc.painter.text(gc.atlas_tex, gc.atlas, "waiting for the app's first frame ...", 12, 12, 0xFF8A9099);
    }
}

/// The screensaver's rotating lit cube, confined to its SIZE×SIZE box at
/// (x, y): the viewport maps kgl's tight orthographic projection into the box
/// (square.PROJ_HALF_EXTENT is the cube's circumsphere radius, so no rotation
/// can project outside it) and the scissor — the box ∩ the frame's damage
/// clip — guarantees regardless that no pixel escapes the rect tickSquare
/// marked. The spin angle derives from the motion's own cadence phase — one
/// clock drives both. Geometry and pose are the screensaver's (square.zig),
/// the lamp is the machine's (spin.zig). Its own noinline function so its
/// locals stay out of renderGles's per-frame stack (the scene-replay rule).
noinline fn drawScreensaverCube(gc: *GlesComp, x: i32, y: i32, phase: u64, sh: usize, clip: ?Clip) void {
    const g = &gc.gctx;
    const y_gl: i32 = @as(i32, @intCast(sh)) - (y + square.SIZE);
    gles.viewport(g, x, y_gl, square.SIZE, square.SIZE);
    scissorWithin(gc, sh, x, y, @intCast(square.SIZE), @intCast(square.SIZE), clip);
    kgl.litMesh(g, .{
        .verts = &square.VERTS,
        .norms = &square.NORMS,
        .material = square.MATERIAL,
        .tilt_deg = square.TILT_DEG,
        .spin_deg = square.angleDeg(phase),
        .half_extent = square.PROJ_HALF_EXTENT,
        .lamp_dir = spin.LAMP_DIR,
        .lamp_color = spin.LAMP_COLOR,
        .lamp_ambient = spin.LAMP_AMBIENT,
        .shininess = spin.LAMP_SHININESS,
    });
    gles.disable(g, gles.GL_SCISSOR_TEST); // the caller's applyClip restores the frame clip
}

/// Scissor the context to `clip` (whole-frame damage), or DISABLE the scissor
/// when there is none — scissor state persists in the context across frames,
/// so a full-damage frame after a clipped one must actively clear it.
/// Callers re-apply after any scope that set its own scissor state.
fn applyClip(gc: *GlesComp, screen_h: usize, clip: ?Clip) void {
    const c = clip orelse {
        gles.disable(&gc.gctx, gles.GL_SCISSOR_TEST);
        return;
    };
    const y_gl: i32 = @as(i32, @intCast(screen_h)) - (c.y + @as(i32, @intCast(c.h)));
    gles.scissor(&gc.gctx, c.x, y_gl, @intCast(c.w), @intCast(c.h));
    gles.enable(&gc.gctx, gles.GL_SCISSOR_TEST);
}

/// Scissor to a screen-space rectangle ∩ the frame clip: an app's content
/// scissor must never widen the frame's damage clip, or a keystroke's frame
/// would re-shade the whole window body.
fn scissorWithin(gc: *GlesComp, screen_h: usize, x: i32, y: i32, w: usize, h: usize, clip: ?Clip) void {
    var x0 = x;
    var y0 = y;
    var x1 = x + @as(i32, @intCast(w));
    var y1 = y + @as(i32, @intCast(h));
    if (clip) |c| {
        x0 = @max(x0, c.x);
        y0 = @max(y0, c.y);
        x1 = @min(x1, c.x + @as(i32, @intCast(c.w)));
        y1 = @min(y1, c.y + @as(i32, @intCast(c.h)));
    }
    const cw: i32 = @max(0, x1 - x0);
    const ch: i32 = @max(0, y1 - y0);
    const y_gl: i32 = @as(i32, @intCast(screen_h)) - (y0 + ch);
    gles.scissor(&gc.gctx, x0, y_gl, cw, ch);
    gles.enable(&gc.gctx, gles.GL_SCISSOR_TEST);
}

/// Whether the whole-desktop path is live this frame. On the GPU that means a
/// draw device AND its present ring (whole_frame_end, published by
/// present.enableDesktopMirror) — until the first GPU present the firmware
/// framebuffer holds the boot log. The software device needs no ring: it
/// delivers straight into the scanout, so a target is the whole condition. A
/// boot with neither never activates and runs headless — the WM logic still
/// ticks, asserted via the test-hook mirrors.
fn glesDesktopActive() bool {
    if (softTarget() != null) return true;
    return gles.hasGpuDevice() and iaccel.accel.whole_frame_end != null;
}
