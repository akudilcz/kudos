//! Log — a tiny sink so leaf UI modules (e.g. src/ui/wm/window.zig) can emit a
//! diagnostic line without importing the freestanding trace bus (klog), keeping
//! them host-compilable. The real sink forwards to
//! klog (→ netdebug); the test sink is a no-op or captures for assertions.
//!
//! LEAF under src/iface/ — no HW import. The module exposes a process-wide `sink`
//! the kernel installs once at boot (like `klog.addSink`), so callers use
//! `log.puts(...)` directly rather than threading a handle through every UI type.

pub const ILog = struct {
    puts: *const fn (ctx: *anyopaque, s: []const u8) void,
    putHex: *const fn (ctx: *anyopaque, v: u64) void,
    ctx: *anyopaque,
};

/// The installed sink. Null until the kernel wires the real klog sink at boot;
/// a test installs a fake. When null, `puts`/`putHex` are silent (a UI leaf must
/// never hard-fail for lack of a log channel).
pub var sink: ?ILog = null;

pub fn puts(s: []const u8) void {
    if (sink) |k| k.puts(k.ctx, s);
}

pub fn putHex(v: u64) void {
    if (sink) |k| k.putHex(k.ctx, v);
}
