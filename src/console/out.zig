//! Out — the output + liveness sink a local command writes through, so one
//! command body serves both line editors: the SMP per-core editor
//! (session.zig, output via its req ring) and the single-core terminal
//! (terminal.zig, output straight to its grid). The two differ only in
//! *where* output goes and how "still running" is decided; both are behind
//! the two function pointers here.

const std = @import("std");

pub const Out = struct {
    ctx: *anyopaque,
    /// Emit one character to the terminal.
    putFn: *const fn (ctx: *anyopaque, ch: u8) void,
    /// Whether the terminal is still alive (false once torn down). Single-core
    /// passes a constant-true; SMP checks the session's `alive` flag.
    aliveFn: *const fn (ctx: *anyopaque) bool,

    /// Emit one character to the terminal.
    pub fn put(self: Out, ch: u8) void {
        self.putFn(self.ctx, ch);
    }
    /// Emit a string, one character at a time.
    pub fn str(self: Out, s: []const u8) void {
        for (s) |c| self.put(c);
    }
    /// Emit a u64 in base-10.
    pub fn num(self: Out, v: u64) void {
        var buf: [20]u8 = undefined;
        self.str(std.fmt.bufPrint(&buf, "{d}", .{v}) catch return);
    }
    /// Whether the terminal is still open (a long command polls this to bail out).
    pub fn alive(self: Out) bool {
        return self.aliveFn(self.ctx);
    }
};
