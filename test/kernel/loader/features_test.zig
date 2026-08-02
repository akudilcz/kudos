//! Feature-command registry (kernel/loader/features.zig) — the table the shell
//! consults for a command word its built-in set does not know (spec AGT-010).
//! The registry is module-global state, so one test walks the whole lifecycle
//! in order: register → exact lookup → replace-in-place → fill → loud overflow.

const std = @import("std");
const features = @import("features");

var hits_a: usize = 0;
var hits_b: usize = 0;
var last_args_len: usize = 0;

fn runA(_: *anyopaque, _: [*]const u8, args_len: usize) callconv(.c) void {
    hits_a += 1;
    last_args_len = args_len;
}
fn runB(_: *anyopaque, _: [*]const u8, args_len: usize) callconv(.c) void {
    hits_b += 1;
    last_args_len = args_len;
}

var ctx: u8 = 0;

test "feature registry lifecycle: register, exact lookup, replace, overflow (MOD-004)" {
    // Empty and over-long names are refused, never truncated.
    try std.testing.expect(!features.registerCommand("", runA, &ctx));
    const too_long = "x" ** (features.MAX_NAME + 1);
    try std.testing.expect(!features.registerCommand(too_long, runA, &ctx));
    try std.testing.expectEqual(@as(usize, 0), features.len());

    // Register and invoke through the table.
    try std.testing.expect(features.registerCommand("prime", runA, &ctx));
    const e = features.lookup("prime").?;
    try std.testing.expectEqualStrings("prime", e.name());
    e.run(e.ctx, "17", 2);
    try std.testing.expectEqual(@as(usize, 1), hits_a);
    try std.testing.expectEqual(@as(usize, 2), last_args_len);

    // Exact match only — `primer` is not `prime`, and vice versa.
    try std.testing.expect(features.lookup("primer") == null);
    try std.testing.expect(features.lookup("prim") == null);

    // Re-registering the same name replaces in place: same count, new handler.
    try std.testing.expect(features.registerCommand("prime", runB, &ctx));
    try std.testing.expectEqual(@as(usize, 1), features.len());
    const e2 = features.lookup("prime").?;
    e2.run(e2.ctx, "", 0);
    try std.testing.expectEqual(@as(usize, 1), hits_a);
    try std.testing.expectEqual(@as(usize, 1), hits_b);

    // Fill the table; the entry past the cap is refused loudly, and the
    // registered set survives intact.
    var namebuf: [features.MAX_NAME]u8 = undefined;
    var i: usize = features.len();
    while (i < features.MAX_COMMANDS) : (i += 1) {
        const name = std.fmt.bufPrint(&namebuf, "cmd{d}", .{i}) catch unreachable;
        try std.testing.expect(features.registerCommand(name, runA, &ctx));
    }
    try std.testing.expectEqual(features.MAX_COMMANDS, features.len());
    try std.testing.expect(!features.registerCommand("one-too-many", runA, &ctx));
    try std.testing.expectEqual(features.MAX_COMMANDS, features.len());
    try std.testing.expect(features.lookup("prime") != null);
    try std.testing.expect(features.lookup("one-too-many") == null);

    // Replacement still works at capacity — it is an update, not an insert.
    try std.testing.expect(features.registerCommand("prime", runA, &ctx));
}
