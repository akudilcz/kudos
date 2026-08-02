//! Module root for the host desktop-screenshot generator (test/ui/desktop_shot.zig).
//! Rooted at src/ui/ so the GPU-drawn toolkit's relative imports (`screen/*`, `wm/*`,
//! `desktop/*`) resolve within this one module — which also keeps the `gltext.Atlas`
//! the chrome draws with and the one the generator builds the SAME type. `gles` and
//! `surface` come in by name. Test infrastructure only; the kernel never imports this.

pub const kgl = @import("kgl");
pub const glcomp = @import("wm/glcomp.zig");
pub const chrome = @import("wm/chrome.zig");
pub const dock = @import("desktop/dock.zig");
pub const theme = @import("theme"); // the shared palette module (see build.zig)
pub const font = @import("screen/font.zig");
pub const dockicons = @import("assets/dockicons.zig");
pub const png = @import("modelcache").png;
