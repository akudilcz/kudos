//! Module-root shim for host tests of the WM model (ui/wm/wm.zig). Rooted at
//! src/ui/ so window.zig's `../screen` relative imports resolve within the
//! module — a module rooted at wm/ itself could not reach them (a module
//! root's path is its own directory). The tests live in test/ui/wm/wm_test.zig and
//! import this module by name.

pub const wm = @import("wm/wm.zig");
pub const chrome = @import("wm/chrome.zig");
