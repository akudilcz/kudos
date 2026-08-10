//! The VM console app: a desktop window onto one guest virtual machine. It shows
//! that guest's serial console (a text grid fed from its ivirt mailbox slot) and,
//! once the guest publishes a virtio-gpu scanout, the guest framebuffer as a
//! textured quad. Keystrokes go to the guest serial port. The console grid and
//! the mailbox are pure/host-tested (apps/vmconsole.zig, iface/ivirt.zig); this
//! file owns the window, the per-frame texture upload, and the input wiring.
//!
//! One window per guest: every instance carries the `id` of the mailbox slot its
//! guest owns, so two VM windows show two independent Linux consoles.
//!
//! Lifecycle: closing the window stops the guest (kudos has no headless VM
//! surface, and a hidden guest would pin a core). Minimising keeps it running.

const std = @import("std");
const kgl = @import("kgl");
const gles = @import("gles");
const meter = @import("meter");
const Window = @import("../ui/wm/window.zig").Window;
const theme = @import("theme");
const vmconsole = @import("vmconsole.zig");
const ivirt = @import("ivirt");

const STATUS_H: f32 = 20; // status line height above the console/framebuffer
const RETURN: u8 = 0x0D; // Enter → carriage return to the guest tty
const SERIAL_DRAIN_PER_TICK: usize = 1024; // per-frame bound: a boot burst cannot starve the frame

// The `.fetching` view's geometry: the progress bar's height and the fraction
// of the window width it spans, centred in the content area.
const FETCH_BAR_H: f32 = 14;
const FETCH_BAR_SPAN: f32 = 0.6;

const MB: u64 = 1 << 20;

/// Linux button codes for the pointer's buttons, in the bit order the mouse
/// event's mask carries them: left, right, middle (BTN_LEFT/RIGHT/MIDDLE in
/// linux/input-event-codes.h).
const BUTTONS = [_]u16{ 0x110, 0x111, 0x112 };

fn mbWhole(bytes: u64) u64 {
    return bytes / MB;
}
fn mbTenth(bytes: u64) u64 {
    return (bytes % MB) * 10 / MB;
}

pub const Vm = struct {
    a: std.mem.Allocator,
    win: *Window,
    /// The mailbox slot of the guest this window shows. Fixed for the window's
    /// life: the slot is not reusable until this window has closed AND the guest
    /// has finished (kernel/virt/vmslots.zig), so it can never come to name a
    /// different guest under us.
    id: ivirt.Id,
    /// The core this guest's vCPU bound itself to once it started, or null while
    /// it has not — shown in the status strip so the machine's layout is readable
    /// at a glance. Read once at window creation; a vCPU never moves after
    /// binding, so it cannot go stale.
    core: ?u32,
    console: vmconsole.Console,
    /// The pointer position and button mask last SENT to the guest, in the
    /// mailbox's absolute range. The desktop samples the pointer every frame
    /// whether or not it moved; a guest is told what changed, so these are what
    /// "changed" is measured against.
    ptr_x: u32 = 0,
    ptr_y: u32 = 0,
    ptr_buttons: u8 = 0,
    /// Keystrokes owed to the guest's serial port, in order (VIRT-036). Drained
    /// as far as the guest's ring will take on every send and every tick.
    serial: vmconsole.SerialQueue = .{},
    fb_tex: u32 = 0, // guest scanout texture, 0 = none
    fb_gen: u32 = 0, // ivirt generation the texture was built for
    /// The scanout's own pixel size, kept because the window draws it at that
    /// size rather than stretched to fit (see drawGl).
    fb_w: u32 = 0,
    fb_h: u32 = 0,
    /// Whether the guest has FLUSHED at least one real frame into the scanout.
    /// The framebuffer view may only replace the serial grid once this is true:
    /// SET_SCANOUT arrives before any pixel transfer, and an armed-but-never-
    /// painted scanout must never blank a console that is carrying the boot log.
    fb_presented: bool = false,

    pub fn create(a: std.mem.Allocator, win: *Window, id: ivirt.Id, core: ?u32) !*Vm {
        const self = try a.create(Vm);
        self.* = .{ .a = a, .win = win, .id = id, .core = core, .console = vmconsole.Console.init() };
        return self;
    }

    /// Keystrokes go to the guest serial port. Named keys (the arrows, as the
    /// keyboard path encodes them in the ASCII stream) travel as their VT100
    /// escape sequences — a full-screen guest UI (the installer's menus)
    /// navigates by them. Enter is translated to CR, which is what a
    /// line-oriented tty expects.
    pub fn onKey(self: *Vm, ascii: u8) void {
        if (vmconsole.keySequence(ascii)) |seq| {
            for (seq) |b| self.sendSerial(b);
            return;
        }
        self.sendSerial(if (ascii == '\n') RETURN else ascii);
    }

    /// One byte to the guest's serial port, in order, waiting if it must (spec
    /// VIRT-036). Queue first, then push as far as the guest's ring allows —
    /// never straight through, so nothing can overtake what is already waiting.
    fn sendSerial(self: *Vm, b: u8) void {
        if (!self.serial.offer(b)) ivirt.countInputDrop(self.id);
        _ = self.drainSerial();
    }

    /// Hand the guest as much of the queue as its ring will take. Returns true
    /// when a byte moved, so a window that still owes bytes keeps being ticked.
    fn drainSerial(self: *Vm) bool {
        var moved = false;
        while (self.serial.next()) |b| {
            if (!ivirt.conInput(self.id, b)) break;
            self.serial.advance();
            moved = true;
        }
        return moved;
    }

    /// Deliver one key edge to the guest's virtio keyboard. The guest sees the
    /// whole keyboard here — releases, modifiers, and the keys that type no
    /// character — which is what an input stack inside it needs and what the
    /// serial path (onKey) structurally cannot carry.
    ///
    /// Both paths run for every keystroke: whether this guest reads evdev or its
    /// serial console is the guest's business, and a window cannot know which.
    /// A guest with no virtio-input driver never drains these, and the drop
    /// shows in the mailbox's counter rather than as silence.
    pub fn onRawKey(self: *Vm, code: u16, down: bool) bool {
        return ivirt.inputPost(self.id, .{ .key = .{ .code = code, .down = down } });
    }

    /// Deliver the pointer to the guest: its position inside the window's
    /// content, scaled into the range the guest's tablet declares, plus any
    /// button that changed. Position is sent only when it moved and a button
    /// only on its edge — a guest is told what changed, not re-told sixty times
    /// a second what did not.
    pub fn onPointer(self: *Vm, x: u32, y: u32, w: u32, h: u32, buttons: u8) void {
        // Scale in the window's own terms: the content rect is the guest's whole
        // screen, whatever size the user has dragged it to.
        const ax: u32 = @intCast(@as(u64, x) * ivirt.ABS_RANGE / @max(w - 1, 1));
        const ay: u32 = @intCast(@as(u64, y) * ivirt.ABS_RANGE / @max(h - 1, 1));
        if (ax != self.ptr_x or ay != self.ptr_y) {
            self.ptr_x = ax;
            self.ptr_y = ay;
            _ = ivirt.inputPost(self.id, .{ .motion = .{ .x = ax, .y = ay } });
        }
        const changed = buttons ^ self.ptr_buttons;
        if (changed == 0) return;
        self.ptr_buttons = buttons;
        for (BUTTONS, 0..) |code, bit| {
            const mask = @as(u8, 1) << @intCast(bit);
            if (changed & mask != 0)
                _ = ivirt.inputPost(self.id, .{ .button = .{ .code = code, .down = buttons & mask != 0 } });
        }
    }

    /// Drain guest serial output into the console grid, and report whether this
    /// window changed (spec VIRT-035) — which is what makes the desktop render a
    /// frame at all.
    ///
    /// The guest's own painting counts, and on a graphical guest it is the whole
    /// answer: once its compositor owns the screen no serial byte ever arrives
    /// again, so serial alone reports "nothing changed" forever while the guest
    /// redraws behind it. The flush flag is PEEKED here and consumed in prepareGl
    /// — taking it here would swallow the flush and upload a stale texture.
    pub fn tick(self: *Vm) bool {
        var fed = self.drainSerial();
        var n: usize = 0;
        while (n < SERIAL_DRAIN_PER_TICK) : (n += 1) {
            const b = ivirt.conRead(self.id) orelse break;
            self.console.feed(b);
            fed = true;
        }
        return fed or ivirt.fbDirty(self.id);
    }

    pub fn onResize(self: *Vm) bool {
        _ = self;
        return true;
    }

    /// Per-frame GL work on core 0: bring the guest scanout texture up to date.
    /// Called inside the open desktop frame, before the window's content draw.
    pub fn prepareGl(self: *Vm, g: *gles.Context) void {
        const fb = ivirt.fb(self.id) orelse {
            // Scanout retracted: drop the texture so drawGl falls back to serial.
            if (self.fb_tex != 0) {
                gles.deleteTextures(g, 1, @ptrCast(&self.fb_tex));
                self.fb_tex = 0;
            }
            self.fb_presented = false;
            return;
        };
        const bytes = @as([*]const u8, @ptrCast(fb.ptr))[0 .. @as(usize, fb.w) * fb.h * 4];
        // Re-upload the scanout on a new resource (gen change / first frame) or a
        // guest FLUSH. Always consume the dirty flag so it cannot pin a redraw.
        const flushed = ivirt.takeFbDirty(self.id);
        if (flushed) self.fb_presented = true;
        if (fb.gen != self.fb_gen or self.fb_tex == 0 or flushed) {
            if (self.fb_tex != 0) gles.deleteTextures(g, 1, @ptrCast(&self.fb_tex));
            self.fb_tex = kgl.uploadImage(g, fb.w, fb.h, bytes);
            self.fb_gen = fb.gen;
            self.fb_w = fb.w;
            self.fb_h = fb.h;
        }
    }

    pub fn deinitGl(self: *Vm, g: *gles.Context) void {
        if (self.fb_tex != 0) {
            gles.deleteTextures(g, 1, @ptrCast(&self.fb_tex));
            self.fb_tex = 0;
        }
    }

    pub fn drawGl(self: *Vm, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        const w: f32 = @floatFromInt(cw);
        const h: f32 = @floatFromInt(ch);

        // Background + status line.
        p.rect(0, 0, w, h, theme.CONTENT_BG);
        p.rect(0, 0, w, STATUS_H, theme.BORDER);
        var buf: [64]u8 = undefined;
        const label = if (self.core) |c|
            std.fmt.bufPrint(&buf, "{s} VM {d} on core {d}", .{ @tagName(ivirt.state(self.id)), self.id, c }) catch "VM"
        else
            std.fmt.bufPrint(&buf, "{s} VM {d}", .{ @tagName(ivirt.state(self.id)), self.id }) catch "VM";
        p.text(atlas_tex, atlas, label, 6, 4, theme.ACCENT);

        // A netboot in flight: the download is the window's whole story, so it
        // gets a progress bar rather than a blank console (VIRT-010).
        if (ivirt.state(self.id) == .fetching) {
            self.drawFetch(p, atlas_tex, atlas, w, h);
            return;
        }

        // The guest framebuffer wins only once the guest has flushed real
        // pixels into it (fb_presented); before that the serial grid — which
        // may be carrying the boot log — stays visible.
        if (self.fb_tex != 0 and self.fb_presented) {
            // ONE GUEST PIXEL PER SCREEN PIXEL, centred in whatever room the
            // window has. Stretching the scanout to the content rectangle
            // resamples it by whatever fraction the window happens to be, and
            // what a fractional downscale destroys first is text: the console
            // font is 8x16, so a dropped row is the bottom of a glyph, and the
            // lines read as though each is eating the one above it. A guest
            // that has drawn a picture deserves to have it shown, not
            // interpolated — so the picture keeps its size and the window pads
            // around it.
            const view_w = w;
            const view_h = h - STATUS_H;
            const tex_w: f32 = @floatFromInt(self.fb_w);
            const tex_h: f32 = @floatFromInt(self.fb_h);
            // A scanout larger than the window is CROPPED, never squashed — and
            // cropped from the BOTTOM, because a console's newest rows are its
            // last ones: the prompt is what a person needs to see, and it is the
            // first thing a top-anchored crop would cut. Horizontally it stays
            // centred, where no such asymmetry applies.
            const draw_w = @min(tex_w, view_w);
            const draw_h = @min(tex_h, view_h);
            const u_span = draw_w / tex_w;
            const v_span = draw_h / tex_h;
            const uv = [4]f32{ (1 - u_span) / 2, 1 - v_span, (1 + u_span) / 2, 1 };
            const x = @floor((view_w - draw_w) / 2);
            const y = STATUS_H + @floor((view_h - draw_h) / 2);
            p.imageCrop(self.fb_tex, x, y, draw_w, draw_h, uv, 0xFFFFFFFF);
            return;
        }
        const line_h = atlas.cell_h;
        var r: usize = 0;
        while (r < vmconsole.ROWS) : (r += 1) {
            const y = STATUS_H + @as(f32, @floatFromInt(r)) * line_h;
            if (y >= h) break;
            self.drawRow(p, atlas_tex, atlas, r, y + 2);
        }
        // The cursor, exactly as the focused terminal draws its own: a filled
        // cell on the blink beat. A quiet console with a live cursor reads as
        // waiting; without one it reads as dead.
        if (focused and blink_on) {
            const cx = 6 + @as(f32, @floatFromInt(self.console.cx)) * atlas.cell_w;
            const cy = STATUS_H + 2 + @as(f32, @floatFromInt(self.console.cy)) * line_h;
            if (cy < h) p.rect(cx, cy, atlas.cell_w, line_h, theme.ACCENT);
        }
    }

    /// One console row as same-colour runs: each cell resolves its SGR pen
    /// through theme.ANSI (null pen = default white), and consecutive cells
    /// sharing a colour draw as one text call.
    fn drawRow(self: *const Vm, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, r: usize, y: f32) void {
        const cells = self.console.row(r);
        const colors = self.console.rowColors(r);
        var start: usize = 0;
        while (start < cells.len) {
            const pen = colors[start];
            var end = start + 1;
            while (end < cells.len and colors[end] == pen) end += 1;
            const rgba = if (pen) |c| theme.ANSI[c] else theme.WHITE;
            const x = 6 + @as(f32, @floatFromInt(start)) * atlas.cell_w;
            p.text(atlas_tex, atlas, cells[start..end], x, y, rgba);
            start = end;
        }
    }

    /// The `.fetching` view: which netboot half is downloading and how far it
    /// has come, as a labelled progress bar. The half's size is unknown until
    /// the server answers, so the text states only what is known and the bar
    /// stays empty (`meter` fills nothing of a zero total) until then.
    fn drawFetch(self: *Vm, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, w: f32, h: f32) void {
        const pr = ivirt.fetchProgress(self.id);
        const half = switch (pr.half) {
            .kernel => "kernel",
            .initramfs => "initramfs",
        };
        var buf: [96]u8 = undefined;
        const label = if (pr.total > 0)
            std.fmt.bufPrint(&buf, "fetching {s}  {d}.{d} / {d}.{d} MB", .{
                half, mbWhole(pr.done), mbTenth(pr.done), mbWhole(pr.total), mbTenth(pr.total),
            }) catch "fetching"
        else
            std.fmt.bufPrint(&buf, "fetching {s}  {d}.{d} MB", .{
                half, mbWhole(pr.done), mbTenth(pr.done),
            }) catch "fetching";
        const bar_w = w * FETCH_BAR_SPAN;
        const x = (w - bar_w) / 2;
        const y = (h + STATUS_H) / 2;
        p.text(atlas_tex, atlas, label, x, y - atlas.cell_h - FETCH_BAR_H / 2, theme.WHITE);
        meter.drawTinted(p, .{ .x = x, .y = y, .w = bar_w, .h = FETCH_BAR_H }, pr.done, pr.total, theme.ACCENT);
    }
};
