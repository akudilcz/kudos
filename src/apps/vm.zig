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
    fb_tex: u32 = 0, // guest scanout texture, 0 = none
    fb_gen: u32 = 0, // ivirt generation the texture was built for
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
            for (seq) |b| _ = ivirt.conInput(self.id, b);
            return;
        }
        const b: u8 = if (ascii == '\n') RETURN else ascii;
        _ = ivirt.conInput(self.id, b);
    }

    /// Drain guest serial output into the console grid. Returns true when
    /// something was fed.
    pub fn tick(self: *Vm) bool {
        var fed = false;
        var n: usize = 0;
        while (n < SERIAL_DRAIN_PER_TICK) : (n += 1) {
            const b = ivirt.conRead(self.id) orelse break;
            self.console.feed(b);
            fed = true;
        }
        return fed;
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
            p.image(self.fb_tex, 0, STATUS_H, w, h - STATUS_H, 0xFFFFFFFF);
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
