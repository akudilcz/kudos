//! Module-local logging for src/drivers/gpu/. kudos is freestanding — std.log pulls
//! in std.Thread/posix, which don't exist on this target — so the whole kernel
//! logs via klog.puts. This wraps that in a printf-style helper so the GPU
//! module logs consistently without each call site hand-rolling a bufPrint.

const std = @import("std");
const klog = @import("../../../kernel/debug/klog.zig");
const gate = @import("../../../kernel/debug/gate.zig");

/// Formatted log line to klog, prefixed for grepability. Gated on `mod` (all
/// GPU logging is `.gpu`) — dropped, with no formatting cost, unless enabled.
/// Truncates silently past 256 bytes (a log line, not data) — the only place in
/// this module where a truncation is acceptable, since it cannot corrupt state.
pub fn print(mod: gate.Mod, comptime fmt: []const u8, args: anytype) void {
    if (!gate.on(mod)) return;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch {
        klog.puts("gpu: <log line too long>\n");
        return;
    };
    klog.puts(line);
}

/// The whole GPU stack logs under the `.gpu` tag. Each gpu file binds this as
/// its `log` so call sites stay `log(fmt, args)` — the module tag is fixed once
/// at the import, not repeated at 200+ sites. (`gpu` IS `print` pre-bound to
/// `.gpu`.)
pub fn gpu(comptime fmt: []const u8, args: anytype) void {
    print(.gpu, fmt, args);
}
