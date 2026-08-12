//! Host tests of src/console/grants.zig — the capability grant table (MOD-007,
//! MOD-008, MOD-009, MOD-010).
//!
//! The expected grants are written out LONGHAND below rather than derived from the
//! table, on purpose: a test that computes its expectation from the thing it is
//! testing passes whatever the table says. Widening what untrusted code may reach
//! has to fail here and be corrected deliberately, which makes the widening visible
//! in the diff that did it.

const std = @import("std");
const grants = @import("grants");
const Grant = grants.Grant;
const abi = @import("abi");

const WINDOW = @intFromEnum(abi.Interface.window);
const VFS = @intFromEnum(abi.Interface.vfs);
const NET = @intFromEnum(abi.Interface.net);
const GL = @intFromEnum(abi.Interface.gl);
const INPUT = @intFromEnum(abi.Interface.input);
const METRICS = @intFromEnum(abi.Interface.metrics);
const DESK = @intFromEnum(abi.Interface.desk);
const GUESTS = @intFromEnum(abi.Interface.guests);
const TASK = @intFromEnum(abi.Interface.task);
const TASKCTL = @intFromEnum(abi.Interface.taskctl);

test "the published set is exactly what is expected (MOD-007)" {
    // id, version, {app_terminal, app_headless, feature}
    const expected = [_]struct { id: u32, version: u32, a: bool, h: bool, f: bool }{
        .{ .id = WINDOW, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = GL, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = VFS, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = NET, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = INPUT, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = METRICS, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = DESK, .version = 1, .a = false, .h = false, .f = true },
        .{ .id = GUESTS, .version = 1, .a = false, .h = false, .f = true },
        .{ .id = TASK, .version = 1, .a = true, .h = true, .f = true },
        .{ .id = TASKCTL, .version = 1, .a = false, .h = false, .f = true },
    };
    try std.testing.expectEqual(expected.len, grants.TABLE.len);
    for (expected) |e| {
        const row = grants.find(e.id, e.version) orelse {
            std.debug.print("no row publishes id {d} v{d}\n", .{ e.id, e.version });
            return error.MissingGrant;
        };
        try std.testing.expectEqual(e.a, row.app_terminal);
        try std.testing.expectEqual(e.h, row.app_headless);
        try std.testing.expectEqual(e.f, row.feature);
        // Every row explains itself — `caps` prints this, and a grant with no
        // stated reason is one nobody reviewed.
        try std.testing.expect(row.why.len > 0);
    }
}

test "an unpublished id is refused to every kind of run (MOD-008)" {
    // Unknown ids must never resolve, and a zeroed request least of all.
    for ([_]u32{
        0, // no interface has id 0
        9999,
    }) |id| {
        try std.testing.expect(!grants.allows(.app_terminal, id, 1));
        try std.testing.expect(!grants.allows(.app_headless, id, 1));
        try std.testing.expect(!grants.allows(.feature, id, 1));
        try std.testing.expect(grants.find(id, 1) == null);
    }
}

test "a version this kudos does not publish is refused (MOD-009)" {
    // Exact match, not "at least": handing a v2 asker the v1 vtable would let it
    // call through offsets past the end of the struct.
    try std.testing.expect(grants.allows(.app_terminal, WINDOW, 1));
    try std.testing.expect(!grants.allows(.app_terminal, WINDOW, 2));
    try std.testing.expect(!grants.allows(.app_terminal, WINDOW, 0));
    try std.testing.expect(!grants.allows(.feature, METRICS, 2));
}

test "windows are granted to every run kind, including the agent's (MOD-008)" {
    // A window is owned by handle and torn down when its module returns or its
    // close box is clicked, so a run with no terminal can hold one safely — and
    // the agent, which has no terminal, is the ABI's main user.
    for ([_]u32{ WINDOW, GL, INPUT }) |id| {
        try std.testing.expect(grants.allows(.app_terminal, id, 1));
        try std.testing.expect(grants.allows(.app_headless, id, 1));
        try std.testing.expect(grants.allows(.feature, id, 1));
    }
}

test "machine-level control is feature-only (MOD-008, MOD-010)" {
    // Anyone's windows, the guest VMs, and placing work on the machine belong to
    // the person at it; a feature's commands act FOR that person, an app acts for
    // itself. No app kind, watched or not, may reach these.
    for ([_]u32{ DESK, GUESTS, TASKCTL }) |id| {
        try std.testing.expect(!grants.allows(.app_terminal, id, 1));
        try std.testing.expect(!grants.allows(.app_headless, id, 1));
        try std.testing.expect(grants.allows(.feature, id, 1));
    }
}

test "reading what runs is published to all; controlling it is not (MOD-017, MOD-018)" {
    for ([_]Grant{ .app_terminal, .app_headless, .feature }) |g| {
        try std.testing.expect(grants.allows(g, TASK, 1));
    }
    try std.testing.expect(grants.allows(.feature, TASKCTL, 1));
    try std.testing.expect(!grants.allows(.app_terminal, TASKCTL, 1));
}

test "the namespace and network capabilities reach every kind of run (MOD-010)" {
    // Both are bounded the same for everyone: vfs is the ramdisk namespace the
    // base Api already writes, net is a parked fetch the system core performs.
    for ([_]u32{ VFS, NET }) |id| {
        try std.testing.expect(grants.allows(.app_terminal, id, 1));
        try std.testing.expect(grants.allows(.app_headless, id, 1));
        try std.testing.expect(grants.allows(.feature, id, 1));
    }
}

test "a feature's grant is a superset of a headless app's (MOD-010)" {
    // A feature runs at full kernel trust: anything a sandboxed app may reach, it
    // may reach. The reverse must never hold, which is what makes the distinction
    // worth having.
    for (grants.TABLE) |row| {
        if (row.app_headless) try std.testing.expect(row.feature);
    }
}

test "read-only figures are published to every kind of run (MOD-010)" {
    try std.testing.expect(grants.allows(.app_terminal, METRICS, 1));
    try std.testing.expect(grants.allows(.app_headless, METRICS, 1));
    try std.testing.expect(grants.allows(.feature, METRICS, 1));
}

test "no capability is published twice (MOD-007)" {
    for (grants.TABLE, 0..) |row, i| {
        for (grants.TABLE, 0..) |other, j| {
            if (i == j) continue;
            try std.testing.expect(!(row.id == other.id and row.version == other.version));
        }
    }
}
