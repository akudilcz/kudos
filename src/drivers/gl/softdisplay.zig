//! Bring-up for the CPU rasteriser as a draw device — the software counterpart
//! to the GPU bring-up in drivers/gpu/gpu.zig, and the only other publisher of
//! `idraw.device` in the tree.
//!
//! kudos renders on the RTX 4090; that is the product, and a `-Dsoft-display`
//! build is not part of it. This exists for the EMULATOR, where there is no GPU
//! and the desktop would otherwise be a blank screen — it is what makes the
//! desktop, and a guest VM's window inside it, visible and screenshottable on a
//! development machine. A software frame costs orders of magnitude more than a
//! flip and meets none of the presentation requirements; without the flag,
//! nothing here is reachable.
//!
//! The caller supplies the pump rather than this module reaching for it: the
//! system loop sits above the driver layer, and a driver that named it would be
//! importing upward. Where a frame LANDS is likewise not decided here — the
//! compositor points each context at the scanout when it creates it.

const std = @import("std");
const buildinfo = @import("buildinfo");
const klog = @import("../../kernel/debug/klog.zig");
const idraw = @import("idraw");
const soft = @import("soft");

/// The device's state for the session — the texture and buffer tables the
/// rasteriser owns, plus its context pool. It lives as long as the machine does.
var device: soft.Soft = undefined;

/// What the caller knows about the machine that this module must not look up
/// for itself: whether a GPU bring-up is about to run, and whether a scanout the
/// rasteriser can deliver into unconverted was adopted.
pub const Machine = struct {
    gpu_coming: bool,
    scanout_ready: bool,
};

/// Why the rasteriser was, or was not, published. Every refusal is a distinct
/// value rather than a bare false: "the desktop is not on the CPU" and "the
/// desktop is not drawn at all" are different machine states, and a caller
/// (or a test) must be able to tell them apart.
pub const Decision = enum {
    publish,
    /// Not a `-Dsoft-display` build — no kernel path reaches a software
    /// rasteriser at all (ARCH-015).
    not_built,
    /// A draw device already exists; publishing would displace it.
    device_exists,
    /// THE ARCH-015 RUNTIME GUARD: a GPU is coming, so the desktop must never
    /// rasterise on the CPU — publishing here would also strand every
    /// boot-time window on the software device forever.
    gpu_coming,
    /// No scanout to deliver into: staying headless beats painting garbage.
    no_scanout,
};

/// Whether the rasteriser may become the draw device. Pure: the whole policy,
/// with nothing to look up and nothing to mutate, so the refusals can be
/// checked rather than trusted.
pub fn decide(soft_display_build: bool, device_exists: bool, m: Machine) Decision {
    if (!soft_display_build) return .not_built;
    if (device_exists) return .device_exists;
    if (m.gpu_coming) return .gpu_coming;
    if (!m.scanout_ready) return .no_scanout;
    return .publish;
}

/// Publish the rasteriser as the system's draw device, answering whether it did.
/// `pump` is called between triangle batches and row bands of a frame: a
/// whole-screen CPU fill runs far longer than the USB queue is deep and longer
/// than the network's remote-reboot retry budget, so a frame that ignored it
/// would drop input and make the machine unreachable for its duration.
///
/// Publishes nothing on a build without `-Dsoft-display`; when a draw device
/// already exists; when a GPU is coming, since publishing here would strand
/// every boot-time window on the software device forever; or when there is no
/// scanout to deliver into, where staying headless beats painting garbage.
pub fn publish(alloc: std.mem.Allocator, m: Machine, pump: *const fn () void) bool {
    switch (decide(buildinfo.soft_display, idraw.device != null, m)) {
        .publish => {},
        .no_scanout => {
            klog.puts("soft-display: no 32-bit BGRA firmware framebuffer — staying headless\n");
            return false;
        },
        .not_built, .device_exists, .gpu_coming => return false,
    }
    device = .{ .alloc = alloc, .pump = pump };
    idraw.device = device.iface();
    klog.puts("soft-display: no GPU — rendering the desktop on the CPU\n");
    return true;
}
