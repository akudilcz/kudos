//! The registry of shell commands published at runtime by loaded feature
//! `.kudos` binaries (spec AGT-010). A feature calls `FeatureApi.register_command`
//! during its `register`; that lands here, and the shell consults this table for
//! any command word not found in its built-in set. Fixed-size with a loud
//! overflow — grow the constant, never resize at runtime.

const std = @import("std");

/// The C-ABI entry a feature registers for its command.
pub const RunFn = *const fn (ctx: *anyopaque, args: [*]const u8, args_len: usize) callconv(.c) void;

pub const MAX_COMMANDS = 32;
pub const MAX_NAME = 32;

const Entry = struct {
    name_buf: [MAX_NAME]u8 = undefined,
    name_len: usize = 0,
    run: RunFn,
    ctx: *anyopaque,

    pub fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var table: [MAX_COMMANDS]Entry = undefined;
var count: usize = 0;

/// Register a feature command. Returns false if the name is too long or the
/// table is full (the caller/feature is told; nothing is silently dropped).
/// Re-registering an existing name replaces that entry in place, so a reloaded
/// feature updates its command rather than shadowing it with a dead duplicate.
pub fn registerCommand(name: []const u8, run: RunFn, ctx: *anyopaque) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, table[i].name(), name)) {
            table[i].run = run;
            table[i].ctx = ctx;
            return true;
        }
    }
    if (count == MAX_COMMANDS) return false;
    var e = &table[count];
    @memcpy(e.name_buf[0..name.len], name);
    e.name_len = name.len;
    e.run = run;
    e.ctx = ctx;
    count += 1;
    return true;
}

/// Find a registered command by exact name.
pub fn lookup(name: []const u8) ?*const Entry {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, table[i].name(), name)) return &table[i];
    }
    return null;
}

/// Number of registered feature commands.
pub fn len() usize {
    return count;
}

/// The i-th registered command (i < len()).
pub fn at(i: usize) *const Entry {
    return &table[i];
}
