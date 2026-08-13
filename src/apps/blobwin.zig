//! The desktop-side host of a window whose content a loaded `.kudos` module
//! renders (MOD-012). The module owns no GL and no window: it blits BGRA pixels
//! into the `iface/iwindow.zig` slot, or records a scene the desktop replays,
//! and pops its input back out. One of these per module window.
//!
//! The desktop never dereferences module memory: uploaded pixels are the
//! mailbox's static buffer, filled on the module's core. Closing is a handshake —
//! the close box marks the slot, the module observes it and returns.

const std = @import("std");
const kgl = @import("kgl");
const gles = @import("gles");
const ilog = @import("ilog");
const iscene = @import("iscene");
const iwindow = @import("iwindow");
const theme = @import("theme");
// The replay's lamp: spin.zig owns the viewer's lighting facts, so a module's
// lit scene and a model window read as one world.
const spin = @import("spin.zig");
const Window = @import("../ui/wm/window.zig").Window;

pub const BlobWindow = struct {
    win: *Window,
    a: std.mem.Allocator,
    /// The mailbox slot this window is (MOD-012); every module call names it.
    handle: u32,
    /// Fixed at create: blitted pixels, or a replayed scene.
    mode: iwindow.Mode,
    /// The module's frame as a texture (pixels mode), 0 = none yet.
    tex: u32 = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    /// A taken frame awaiting upload inside the next open GL frame.
    pending: ?iwindow.Frame = null,
    /// Frames the validator refused; the window shows the last good one.
    frames_refused: u64 = 0,
    scene_drawn: bool = false,

    pub fn create(a: std.mem.Allocator, win: *Window, handle: u32, mode: iwindow.Mode) !*BlobWindow {
        const self = try a.create(BlobWindow);
        self.* = .{ .win = win, .a = a, .handle = handle, .mode = mode };
        return self;
    }

    /// Free the slot. A module still running sees its handle die and returns.
    pub fn deinit(self: *BlobWindow) void {
        if (iwindow.indexOf(self.handle)) |i| iscene.reset(i);
        iwindow.destroy(self.handle);
        self.pending = null;
    }

    /// Give the texture back to the shared context on close.
    pub fn deinitGl(self: *BlobWindow, g: *gles.Context) void {
        if (self.tex != 0) {
            gles.deleteTextures(g, 1, @ptrCast(&self.tex));
            self.tex = 0;
        }
    }

    /// Release everything this window owns and free it (App.close). Resetting
    /// the mailbox is how the module — still running on its own core — learns
    /// its window is gone and returns.
    pub fn close(self: *BlobWindow, a: std.mem.Allocator, g: ?*gles.Context) void {
        if (g) |ctx| self.deinitGl(ctx);
        self.deinit();
        a.destroy(self);
    }

    /// A keystroke for the module (MOD-013). Focus-scoped by construction: the
    /// desktop routes keys only to the focused app.
    pub fn onKey(self: *BlobWindow, ascii: u8) void {
        iwindow.pushKey(self.handle, ascii);
    }

    /// Publish the new content size; the module reads it through `WindowApi.size`.
    pub fn onResize(self: *BlobWindow) bool {
        iwindow.setSize(self.handle, @intCast(self.win.contentW()), @intCast(self.win.contentH()));
        return true;
    }

    /// Damage when the module delivered a frame. A pixels frame is taken here;
    /// a scene frame is consumed by drawInline mid-frame.
    pub fn tick(self: *BlobWindow) bool {
        switch (self.mode) {
            .pixels => {
                if (iwindow.takeDirty(self.handle)) |f| {
                    self.pending = f;
                    return true;
                }
                return false;
            },
            .scene => {
                const i = iwindow.indexOf(self.handle) orelse return false;
                return iscene.takeFrame(i) != null;
            },
        }
    }

    /// Per-frame GL work on core 0, inside the open frame: upload the taken frame.
    pub fn prepareGl(self: *BlobWindow, g: *gles.Context) void {
        const f = self.pending orelse return;
        self.pending = null;
        if (self.tex != 0) gles.deleteTextures(g, 1, @ptrCast(&self.tex));
        const bytes = @as([*]const u8, @ptrCast(f.buf))[0 .. @as(usize, f.w) * f.h * 4];
        self.tex = kgl.uploadImage(g, f.w, f.h, bytes);
        self.tex_w = f.w;
        self.tex_h = f.h;
    }

    /// The module's pixels, one texel per screen pixel, centred and cropped
    /// rather than stretched — a fractional resample destroys fine content first.
    pub fn drawGl(self: *BlobWindow, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        _ = focused;
        _ = blink_on;
        const w: f32 = @floatFromInt(cw);
        const h: f32 = @floatFromInt(ch);
        p.rect(0, 0, w, h, theme.CONTENT_BG);
        if (self.tex == 0) {
            p.text(atlas_tex, atlas, "waiting for the app's first frame ...", 12, 12, theme.TITLE_TEXT_DIM);
            return;
        }
        const tex_w: f32 = @floatFromInt(self.tex_w);
        const tex_h: f32 = @floatFromInt(self.tex_h);
        const draw_w = @min(tex_w, w);
        const draw_h = @min(tex_h, h);
        const u_span = draw_w / tex_w;
        const v_span = draw_h / tex_h;
        const uv = [4]f32{ (1 - u_span) / 2, (1 - v_span) / 2, (1 + u_span) / 2, (1 + v_span) / 2 };
        const x = @floor((w - draw_w) / 2);
        const y = @floor((h - draw_h) / 2);
        p.imageCrop(self.tex, x, y, draw_w, draw_h, uv, 0xFFFFFFFF);
    }

    /// Replay the module's recorded scene inline in the desktop frame (MOD-015):
    /// confine to the content rect with viewport + scissor, clear this patch,
    /// replay validated commands, hand the context back 2D-clean. False when
    /// there is nothing to show yet, so the caller can place a placeholder.
    pub fn drawInline(self: *BlobWindow, g: *gles.Context, x_px: i32, y_top_px: i32, cw: u32, ch: u32, frame_h: u32) bool {
        if (cw == 0 or ch == 0) return false;
        const win_i = iwindow.indexOf(self.handle) orelse return false;
        const slot = iscene.takeFrame(win_i) orelse return self.scene_drawn;
        // Validation is the safety story (MOD-016): a refused frame makes NO GL
        // call. Counted and logged so a module recording garbage is visible.
        const verdict = iscene.validate(slot);
        if (verdict != .ok) {
            iscene.release(win_i);
            self.frames_refused += 1;
            var buf: [96]u8 = undefined;
            ilog.puts(std.fmt.bufPrint(&buf, "blobwin: frame refused: {s} (total {d})\n", .{
                @tagName(verdict), self.frames_refused,
            }) catch "blobwin: frame refused\n");
            return self.scene_drawn;
        }

        const y_gl: i32 = @as(i32, @intCast(frame_h)) - (y_top_px + @as(i32, @intCast(ch)));
        gles.viewport(g, x_px, y_gl, @intCast(cw), @intCast(ch));
        gles.scissor(g, x_px, y_gl, @intCast(cw), @intCast(ch));
        gles.enable(g, gles.GL_SCISSOR_TEST);
        gles.clearDepthf(g, 1.0);
        gles.clearColor(g, 0.06, 0.07, 0.09, 1.0);
        var lit = false;
        for (slot.cmds[0..slot.ncmds]) |cmd| {
            if (cmd.op == .clear_color)
                gles.clearColor(g, @bitCast(cmd.a), @bitCast(cmd.b), @bitCast(cmd.c), @bitCast(cmd.d));
            if (cmd.op == .enable and cmd.a == iscene.GL_LIGHTING) lit = true;
        }
        gles.clear(g, gles.GL_COLOR_BUFFER_BIT | gles.GL_DEPTH_BUFFER_BIT);

        gles.matrixMode(g, gles.GL_PROJECTION);
        gles.loadIdentity(g);
        gles.matrixMode(g, gles.GL_MODELVIEW);
        gles.loadIdentity(g);
        gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
        // The painter leaves ITS client arrays armed at ITS batch memory. Left
        // enabled, a replayed draw fetches per-vertex colours and texcoords from
        // a stale buffer at the module's vertex count: garbage here, and the
        // lit-plus-COLOR_ARRAY fence hang on the 4090.
        gles.disableClientState(g, gles.GL_COLOR_ARRAY);
        gles.disableClientState(g, gles.GL_TEXTURE_COORD_ARRAY);
        gles.disable(g, gles.GL_TEXTURE_2D);
        if (lit) {
            // The module says WHETHER the scene is lit; the machine owns the lamp.
            gles.enable(g, gles.GL_LIGHT0);
            gles.enable(g, gles.GL_NORMALIZE);
            gles.lightfv(g, gles.GL_LIGHT0, gles.GL_POSITION, &spin.LAMP_DIR);
            gles.lightfv(g, gles.GL_LIGHT0, gles.GL_DIFFUSE, &spin.LAMP_COLOR);
            gles.lightfv(g, gles.GL_LIGHT0, gles.GL_SPECULAR, &spin.LAMP_COLOR);
            gles.lightModelfv(g, gles.GL_LIGHT_MODEL_AMBIENT, &spin.LAMP_AMBIENT);
            gles.materialf(g, gles.GL_FRONT_AND_BACK, gles.GL_SHININESS, spin.LAMP_SHININESS);
        }

        // A thin switch that trusts the validator: every span, count and enum
        // below passed it.
        for (slot.cmds[0..slot.ncmds]) |cmd| {
            switch (cmd.op) {
                .enable => gles.enable(g, cmd.a),
                .disable => gles.disable(g, cmd.a),
                .matrix_mode => gles.matrixMode(g, cmd.a),
                .load_identity => gles.loadIdentity(g),
                .load_matrix => gles.loadMatrixf(g, slot.floats[cmd.off..].ptr),
                .mult_matrix => gles.multMatrixf(g, slot.floats[cmd.off..].ptr),
                .rotate => gles.rotatef(g, @bitCast(cmd.a), @bitCast(cmd.b), @bitCast(cmd.c), @bitCast(cmd.d)),
                .translate => gles.translatef(g, @bitCast(cmd.a), @bitCast(cmd.b), @bitCast(cmd.c)),
                .scale => gles.scalef(g, @bitCast(cmd.a), @bitCast(cmd.b), @bitCast(cmd.c)),
                .color => {
                    // color4f colours an unlit draw, the material a lit one.
                    const col = [4]f32{ @bitCast(cmd.a), @bitCast(cmd.b), @bitCast(cmd.c), @bitCast(cmd.d) };
                    gles.color4f(g, col[0], col[1], col[2], col[3]);
                    gles.materialfv(g, gles.GL_FRONT_AND_BACK, gles.GL_AMBIENT_AND_DIFFUSE, &col);
                },
                .vertices => gles.vertexPointer(g, 3, gles.GL_FLOAT, 0, slot.floats[cmd.off..].ptr),
                .normals => {
                    gles.enableClientState(g, gles.GL_NORMAL_ARRAY);
                    gles.normalPointer(g, gles.GL_FLOAT, 0, slot.floats[cmd.off..].ptr);
                },
                .draw_arrays => gles.drawArrays(g, cmd.a, @intCast(cmd.b), @intCast(cmd.c)),
                .draw_elements => gles.drawElements(g, cmd.a, @intCast(cmd.n), gles.GL_UNSIGNED_SHORT, slot.indices[cmd.off..].ptr),
                .clear_color => {}, // consumed above
                .depth_func => gles.depthFunc(g, cmd.a),
                .front_face => gles.frontFace(g, cmd.a),
            }
        }
        iscene.release(win_i);
        self.scene_drawn = true;

        // Hand the context back 2D-clean: a buffer or client array left armed
        // turns the painter's next batch into wild fetches, which hangs.
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
