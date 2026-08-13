//! Model-viewer app: a spinning, Blinn-Phong-lit 3D model — the boot teapot and
//! every `show <file>` window — hosted in a normal desktop window. The app owns
//! no GPU knowledge and no pixels: its 3D draws INLINE in the whole-desktop GL
//! frame (Desktop.renderGles calls `drawInline` with the one desktop context),
//! confined to the window's content rectangle by viewport + scissor.
//!
//! MESH LOADING: each instance carries its model's absolute VFS path (vfs.zig —
//! /ramdisk/… or /usbdisk/…); the mesh (+ its base-color texture) is loaded on
//! first draw through ui/assets/modelcache.zig into the desktop context's objects.
//! Models are .glb only (glTF 2.0 binary — ui/assets/glb.zig + png.zig; scratch
//! from the desktop heap, freed after upload). A parse failure latches
//! `load_failed`: the desktop draws a loud in-window placeholder, no retry
//! storm.

const std = @import("std");
const ilog = @import("ilog");
const gles = @import("gles");
const modelcache = @import("modelcache");
const Window = @import("../ui/wm/window.zig").Window;

/// A model-load failure logs its reason through the `ilog` seam (host-safe): the failure
/// shows only as an in-window placeholder, so without a log line it is invisible to
/// netdebug/bootlog and undiagnosable afterwards.
fn logf(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return ilog.puts("modelview: (log overflow)\n");
    ilog.puts(s);
}

const tsc = @import("../kernel/cpu/tsc.zig");
// spin.zig owns the viewer's motion AND pose (camera, tilt, lamp) — pure, so
// the render oracle frames its goldens from the same facts drawn here.
const spin = @import("spin.zig");

pub const ModelView = struct {
    win: *Window,
    a: std.mem.Allocator,
    name: []const u8, // heap-owned copy (freed in deinit)
    /// This window's copy of the mesh, as objects in the DESKTOP's GL context
    /// (loaded on first drawInline). Freed via deinitGl on close.
    model: ?modelcache.Model = null,
    load_failed: bool = false,

    pub fn create(a: std.mem.Allocator, win: *Window, name: []const u8) !*ModelView {
        const self = try a.create(ModelView);
        errdefer a.destroy(self);
        const owned = try a.dupe(u8, name);
        self.* = .{ .win = win, .a = a, .name = owned };
        return self;
    }

    /// Free the CPU-side state. The mesh's GL objects live in the desktop's
    /// context — the desktop hands that context to `deinitGl` before this.
    pub fn deinit(self: *ModelView) void {
        self.a.free(self.name);
        self.model = null;
    }

    /// Give the mesh's buffers back to the (shared, desktop-owned) context on
    /// window close — the context would free them at teardown anyway, but a
    /// closed window should not make the GL heaps wait for that.
    pub fn deinitGl(self: *ModelView, g: *gles.Context) void {
        if (self.model) |m| m.deinit(g);
        self.model = null;
    }

    /// Release everything this window owns and free it (App.close). The mesh's
    /// GL objects go back to the shared context first — the caller has already
    /// completed any deferred frame, so nothing is sampling them.
    pub fn close(self: *ModelView, a: std.mem.Allocator, g: ?*gles.Context) void {
        if (g) |ctx| self.deinitGl(ctx);
        self.deinit();
        a.destroy(self);
    }

    /// Passive view: no key handling.
    pub fn onKey(self: *ModelView, ascii: u8) void {
        _ = self;
        _ = ascii;
    }

    /// Re-layout after resize: nothing retained to re-flow — the next frame draws
    /// at the new content size.
    pub fn onResize(self: *ModelView) bool {
        _ = self;
        return true;
    }

    /// A spinning model animates every frame; a failed load is a static
    /// placeholder. The desktop throttles how often this damage is honoured on
    /// the software rasteriser.
    pub fn tick(self: *ModelView) bool {
        return !self.load_failed;
    }

    /// Draw the model INLINE in the whole-desktop GL frame (the unified pipeline): the
    /// caller's context is the one desktop-wide frame, already mid-recording; this call
    /// confines itself to the window's content rectangle with viewport + scissor, clears
    /// only DEPTH (the frame's colour around it must survive), renders the lit spinning
    /// model, and puts the 2D state back (the caller's painter re-establishes the rest).
    ///
    /// `x_px`/`y_top_px` are the content area's top-left in SCREEN pixels (y down);
    /// `frame_h` converts to GL's bottom-up coordinates. Returns false when there is
    /// nothing to draw (model missing/failed) so the caller can place a 2D placeholder.
    pub fn drawInline(self: *ModelView, g: *gles.Context, x_px: i32, y_top_px: i32, cw: u32, ch: u32, frame_h: u32) bool {
        if (cw == 0 or ch == 0) return false;
        if (self.model == null and !self.load_failed) {
            self.model = modelcache.load(self.a, g, self.name) catch |err| {
                logf("modelview: {s} load failed: {s}\n", .{ self.name, @errorName(err) });
                self.load_failed = true;
                return false;
            };
        }
        const model = self.model orelse return false;

        const y_gl: i32 = @as(i32, @intCast(frame_h)) - (y_top_px + @as(i32, @intCast(ch)));
        gles.viewport(g, x_px, y_gl, @intCast(cw), @intCast(ch));
        gles.scissor(g, x_px, y_gl, @intCast(cw), @intCast(ch));
        gles.enable(g, gles.GL_SCISSOR_TEST);
        // Fresh depth for THIS window only in z (the clear is full-target, which is fine:
        // nothing 2D reads depth, and each model window clears again before it draws).
        gles.clearDepthf(g, 1.0);
        gles.clear(g, gles.GL_DEPTH_BUFFER_BIT);

        const angle: f32 = spin.angleRad(tsc.micros());
        const aspect: f32 = @as(f32, @floatFromInt(cw)) / @as(f32, @floatFromInt(ch));
        const near: f32 = 0.1;
        const top = near * @tan(std.math.pi / 6.0); // half of a 60-degree vertical FOV
        gles.matrixMode(g, gles.GL_PROJECTION);
        gles.loadIdentity(g);
        gles.frustumf(g, -top * aspect, top * aspect, -top, top, near, 100.0);
        gles.matrixMode(g, gles.GL_MODELVIEW);
        gles.loadIdentity(g);
        gles.translatef(g, 0, 0, -spin.CAM_DIST);
        gles.rotatef(g, spin.CAM_PITCH_DEG, 1, 0, 0);
        gles.rotatef(g, angle * 180.0 / std.math.pi, 0, 1, 0); // glRotate is DEGREES
        gles.rotatef(g, spin.MODEL_TILT_DEG, 1, 0, 0);

        gles.enable(g, gles.GL_DEPTH_TEST);
        gles.enable(g, gles.GL_CULL_FACE);
        gles.enable(g, gles.GL_LIGHTING);
        gles.enable(g, gles.GL_LIGHT0);
        gles.enable(g, gles.GL_NORMALIZE);
        gles.lightfv(g, gles.GL_LIGHT0, gles.GL_POSITION, &spin.LAMP_DIR);
        gles.lightfv(g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &spin.LAMP_COLOR);
        gles.lightfv(g, gles.GL_LIGHT0, gles.GL_SPECULAR, &spin.LAMP_COLOR);
        gles.lightModelfv(g, gles.GL_LIGHT_MODEL_AMBIENT, &spin.LAMP_AMBIENT);
        gles.materialf(g, gles.GL_FRONT_AND_BACK, gles.GL_SHININESS, spin.LAMP_SHININESS);

        // Draw every submesh with its own material and blend mode. Per-primitive
        // material handling (opaque pass, then a blended pass with depth writes
        // off for glTF alphaMode BLEND/MASK, spec R36) lives in Model.draw.
        model.draw(g);

        // Hand the context back 2D-clean: everything the painter's begin() does not
        // re-establish is turned off here. The BUFFER BINDINGS matter most: with a
        // vertex buffer left bound, the next glVertexPointer means "offset into that
        // buffer" (the specification's rule) — the painter's client-array pointers
        // would become wild device offsets and the engine would fetch unmapped
        // addresses. That is a hang, not a glitch: the fault is invisible while the
        // GSP event ring is silent, and the fence simply never retires.
        gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, 0);
        gles.bindBuffer(g, gles.GL_ELEMENT_ARRAY_BUFFER, 0);
        gles.disableClientState(g, gles.GL_NORMAL_ARRAY);
        gles.disable(g, gles.GL_DEPTH_TEST);
        gles.disable(g, gles.GL_CULL_FACE);
        gles.disable(g, gles.GL_LIGHTING);
        gles.disable(g, gles.GL_LIGHT0);
        gles.disable(g, gles.GL_NORMALIZE);
        gles.disable(g, gles.GL_SCISSOR_TEST);
        return true;
    }
};
