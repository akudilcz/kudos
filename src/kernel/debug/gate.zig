//! Module debug gate — the single owner of "which subsystems log".
//!
//! Diagnostics are off by default. Every structured emit (`debug.set*`,
//! `gpu/log.print`) names its owning `Mod`; the emit is dropped unless that
//! module's tag is in the enabled set. The gate lives UPSTREAM of `klog.puts`,
//! so a disabled tag costs nothing (no formatting, no emitted byte, no diag-ring
//! write, no netdebug line) and one tag governs all capture channels at once.
//!
//! The enabled set is chosen explicitly at boot with a single `enable(&.{…})`
//! call in `main_root.zig` — the list IS the configuration (no implicit per-module
//! defaults). Granularity is per subsystem: a subsystem is diagnosed as a unit.

const std = @import("std");

/// One tag per logging subsystem. Add a tag here when a new subsystem starts
/// emitting; every emit call site passes the tag that owns it.
pub const Mod = enum {
    boot, // main_root.zig bring-up sequence
    usb, // xhci controller + HID enumeration/transfer/reports
    net, // net/nic/igc/udp/netdebug stack
    pci, // pci enumeration
    irq, // interrupt handlers (isr)
    gpu, // GPU display stack
    sched, // scheduler
    smp, // AP bring-up
    cpu, // cpu/tsc feature detection
    mem, // pmm/heap
    ui, // desktop/wm/framebuffer/apps
    acpi, // acpi tables
    term, // terminal-output mirror (test-hooks builds only; see terminal.zig putChar)
};

/// The enabled set — initialised EMPTY (all logging off). `enable` is the only
/// writer; emit front-ends read it via `on`.
var enabled = std.EnumSet(Mod).initEmpty();

/// Replace the enabled set with exactly `mods` (does NOT accumulate). One call
/// in `main_root.zig` is the whole truth of what an image logs.
pub fn enable(mods: []const Mod) void {
    enabled = std.EnumSet(Mod).initEmpty();
    for (mods) |m| enabled.insert(m);
}

/// Is this module's logging enabled? Emit front-ends gate on this.
pub fn on(m: Mod) bool {
    return enabled.contains(m);
}
