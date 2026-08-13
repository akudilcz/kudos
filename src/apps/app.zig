//! The App interface: a closed union over the app types. The
//! desktop hosts a list of these and dispatches window/input/draw generically.

const std = @import("std");
const kgl = @import("kgl"); // the 2D toolkit the unified GL desktop draws through
const gles = @import("gles"); // the shared GL context an app returns its objects to
const Window = @import("../ui/wm/window.zig").Window;
const framebuffer = @import("../ui/screen/framebuffer.zig");
const Terminal = @import("terminal.zig").Terminal;
const System = @import("system.zig").System;
const ModelView = @import("modelview.zig").ModelView;
const Clock = @import("clock.zig").Clock;
const Calculator = @import("calculator.zig").Calculator;
const VmApp = @import("vm.zig").Vm;
const BlobWindow = @import("blobwin.zig").BlobWindow;

/// Kinds spawnApp can open directly. The model viewer is NOT here — it needs
/// a model name, so it has its own spawner (desktop.spawnModel). The catalogue
/// lives in the desktop-control contract (iface/idesk.zig), which the console
/// commands that spawn these apps also name; this group takes it from there
/// rather than from the console, so the two peers share a definition without
/// either importing the other.
pub const Kind = @import("idesk").AppKind;

pub const App = union(enum) {
    term: *Terminal,
    system: *System,
    model: *ModelView,
    clock: *Clock,
    calc: *Calculator,
    vm: *VmApp,
    /// A window whose content a loaded .kudos module renders (MOD-012). No Kind
    /// and no dock tile: it exists only while the module that opened it runs.
    blob: *BlobWindow,

    /// The hosting window this app is drawn into — every app kind owns a `win`
    /// field, so this is the one field common to the whole union.
    pub fn window(self: App) *Window {
        return switch (self) {
            inline else => |a| a.win,
        };
    }

    /// The spawnable Kind this app is an instance of, or null for the model
    /// viewer (which has no Kind — it needs a model name, so it has its own
    /// spawner and no dock tile).
    pub fn kind(self: App) ?Kind {
        return switch (self) {
            .term => .term,
            .system => .system,
            .clock => .clock,
            .calc => .calc,
            .vm => .vm,
            .model, .blob => null,
        };
    }

    /// Deliver one ASCII keystroke to the focused app's own key handler.
    pub fn onKey(self: App, ascii: u8) void {
        switch (self) {
            inline else => |a| a.onKey(ascii),
        }
    }

    /// Deliver one key EDGE — press or release, by Linux key code — to an app
    /// that has a use for one. Only the VM console does: its guest runs its own
    /// input stack, which needs the key-up an ASCII stream cannot express.
    /// Returns whether the app took it.
    pub fn onRawKey(self: App, code: u16, down: bool) bool {
        return switch (self) {
            .vm => |v| v.onRawKey(code, down),
            else => false,
        };
    }

    /// Draw this app's content into the whole-desktop GL frame, content-locally (the
    /// caller positioned the painter's origin and scissor). Model windows are absent
    /// here on purpose: their 3D is drawn inline by the desktop (ModelView.drawInline),
    /// not through the 2D painter.
    pub fn drawGl(self: App, p: *kgl.Painter, atlas_tex: u32, atlas: kgl.Atlas, cw: usize, ch: usize, focused: bool, blink_on: bool) void {
        switch (self) {
            .term => |t| t.drawGl(p, atlas_tex, atlas, focused, blink_on),
            .system => |sm| sm.drawGl(p, atlas_tex, atlas, cw, ch, focused, blink_on),
            .clock => |c| c.drawGl(p, atlas_tex, atlas, cw, ch, focused, blink_on),
            .calc => |c| c.drawGl(p, atlas_tex, atlas, cw, ch, focused, blink_on),
            .vm => |v| v.drawGl(p, atlas_tex, atlas, cw, ch, focused, blink_on),
            .blob => |b| b.drawGl(p, atlas_tex, atlas, cw, ch, focused, blink_on),
            .model => {},
        }
    }

    /// Re-lay-out after the hosting window was resized. Each app recomputes its content geometry. Returns
    /// whether the app needs a FULL re-raster + full logical upload (true) or the
    /// resize-damage strips suffice because its retained pixels stayed valid
    /// (false — the terminal with a stable view). Apps that repaint everything
    /// per draw (system) return true.
    pub fn onResize(self: App) bool {
        return switch (self) {
            inline else => |a| a.onResize(),
        };
    }

    /// Release everything this app owns and free it — the ONE teardown, so the
    /// desktop closes every app the same way and knows what none of them own.
    /// `g` is the shared GL context when one exists (apps holding textures or
    /// meshes give them back through it); null on a software-rasterised boot.
    ///
    /// The caller completes any deferred GPU frame BEFORE this: the GPU may
    /// still be sampling a texture an app is about to delete. That rule is
    /// stated once, at the call site, instead of once per textured app.
    ///
    /// Adding an app kind that allocates is now impossible to get wrong: the
    /// union will not compile until its `close` exists.
    pub fn close(self: App, a: std.mem.Allocator, g: ?*gles.Context) void {
        switch (self) {
            inline else => |x| x.close(a, g),
        }
    }

    /// Per-app animation step. Returns true if the app's content changed and a
    /// re-render is warranted: the system monitor's periodic live-figure refresh.
    /// Terminals are driven by input/blink/command output instead.
    pub fn tick(self: App) bool {
        return switch (self) {
            .system => |a| a.tick(),
            .model => |a| a.tick(),
            .clock => |a| a.tick(),
            .calc => |a| a.tick(),
            .vm => |a| a.tick(),
            .blob => |a| a.tick(),
            .term => false,
        };
    }
};
