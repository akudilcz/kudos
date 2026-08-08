//! The ONE module root for host tests — and nothing else.
//!
//! WHY THIS FILE EXISTS. A Zig module's import path is its own directory, and a
//! file may not `@import` outside it. Most source files legitimately reach
//! across their subsystem (`drivers/gpu/display/dp.zig` names `../gsp/rm.zig`;
//! `drivers/gl/softdisplay.zig` traces through `kernel/debug/klog.zig`), so a
//! module rooted at any one of them cannot resolve. Rooting HERE puts the
//! module path at `src/`, which contains every group, so the cross-group
//! imports resolve and the pure declarations become host-testable.
//!
//! It is a PATH, not a test: it holds no assertions and no logic, only the
//! re-exports a suite needs to name a file. Suites import it by module name
//! and reach through the namespace of the group they are testing —
//! `@import("testroot").gl.softdisplay`. Zig analyses lazily, so a suite
//! compiles only what it actually references.
//!
//! Adding a host-testable file means one line here. It stays ONE file so
//! `src/` root holds only module roots: the two kernel entry points and this.

pub const kernel = struct {
    pub const backtrace = @import("kernel/debug/backtrace.zig");
    pub const counter = @import("kernel/debug/counter.zig");
    pub const deadman = @import("kernel/debug/deadman.zig");
    pub const crashlog = @import("kernel/debug/crashlog.zig");
    pub const spinwait = @import("kernel/debug/spinwait.zig");
    pub const debug = @import("kernel/debug/debug.zig");
    pub const lockorder = @import("kernel/sched/lockorder.zig");
    pub const heap = @import("kernel/memory/heap.zig");
    pub const pmm = @import("kernel/memory/pmm.zig");
    pub const gueststage = @import("kernel/virt/gueststage.zig");
    pub const layout = @import("kernel/virt/layout.zig");
    pub const guestlist = @import("kernel/virt/guestlist.zig");
    pub const guestacpi = @import("kernel/virt/acpi.zig");
    pub const virtio_gpudev = @import("kernel/virt/virtio/gpudev.zig");
    pub const linuxload = @import("kernel/virt/linuxload.zig");
    pub const virtio_netdev = @import("kernel/virt/virtio/netdev.zig");
    pub const netbridge = @import("kernel/virt/netbridge.zig");
    pub const virtio_inputdev = @import("kernel/virt/virtio/inputdev.zig");
    pub const klog = @import("kernel/debug/klog.zig");
    pub const taskstat = @import("kernel/sched/taskstat.zig");
};

pub const gpu = struct {
    pub const dp = @import("drivers/gpu/display/dp.zig");
    pub const modeset = @import("drivers/gpu/display/modeset.zig");
    pub const push = @import("drivers/gpu/core/push.zig");
    pub const prof = @import("drivers/gpu/prof.zig");
};

pub const gl = struct {
    pub const softdisplay = @import("drivers/gl/softdisplay.zig");
};

pub const storage = struct {
    pub const ramdisk = @import("drivers/storage/ramdisk.zig");
    pub const bootlog = @import("drivers/storage/bootlog.zig");
    pub const fat = @import("drivers/storage/fat.zig");
};

// assets re-exports the NAMED modelcache module, never the file by path:
// modelcache.zig is a named-module root (console.zig reaches it as
// `@import("modelcache")`), and a file that roots a module must not also be
// path-imported — the binary would hold it in two modules at once. Same rule
// the layering gate enforces for soft.zig. png rides modelcache's re-export.
pub const assets = struct {
    pub const modelcache = @import("modelcache");
    pub const png = @import("modelcache").png;
};

pub const net = struct {
    pub const tlsclient = @import("drivers/net/stack/tlsclient.zig");
};

pub const terminal = struct {
    pub const terminal = @import("apps/terminal.zig");
    pub const window = @import("ui/wm/window.zig");
    pub const font = @import("ui/screen/font.zig");
};
