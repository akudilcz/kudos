//! Host tests of src/drivers/gl/es/objects.zig.

const std = @import("std");
const objects = @import("objects");
const Error = objects.Error;
const MAX_OBJECTS = objects.MAX_OBJECTS;
const Table = objects.Table;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "a generated name is not yet an object — binding is what makes it one" {
    var t = Table{};
    var names: [1]u32 = undefined;
    try t.gen(1, &names);
    try expect(!t.isObject(names[0])); // generated, not bound
    try t.ensureNamed(names[0]);
    try expect(t.isObject(names[0])); // now it exists
}

test "zero is never a name" {
    var t = Table{};
    try expect(!t.isObject(0));
    try expect(t.record(0) == null);
    t.delete(0); // a no-op, not a crash
}

test "gen never returns a name that is already live" {
    var t = Table{};
    var a: [4]u32 = undefined;
    var b: [4]u32 = undefined;
    try t.gen(4, &a);
    try t.gen(4, &b);
    for (a) |x| for (b) |y| try expect(x != y);
    for (a) |x| try expect(x != 0);
}

test "a deleted name returns to the pool and can be handed out again" {
    var t = Table{};
    var a: [1]u32 = undefined;
    try t.gen(1, &a);
    t.delete(a[0]);
    var b: [1]u32 = undefined;
    try t.gen(1, &b);
    try expectEqual(a[0], b[0]);
    try expect(!t.isObject(b[0])); // and it is fresh: not an object again yet
}

test "an object with no storage is a real state, not an error" {
    var t = Table{};
    var a: [1]u32 = undefined;
    try t.gen(1, &a);
    try t.ensureNamed(a[0]);
    try expect(t.isObject(a[0])); // it exists
    try expect(t.deviceHandle(a[0]) == null); // but glBufferData has not run
}

test "a failed gen reserves nothing rather than some" {
    var t = Table{};
    var all: [MAX_OBJECTS]u32 = undefined;
    try t.gen(MAX_OBJECTS, &all);
    var one: [1]u32 = undefined;
    try std.testing.expectError(Error.OutOfNames, t.gen(1, &one));

    // Free one, then ask for two: it must fail AND leave that one free, not consume it.
    t.delete(all[5]);
    var two: [2]u32 = undefined;
    try std.testing.expectError(Error.OutOfNames, t.gen(2, &two));
    try t.gen(1, &one);
    try expectEqual(all[5], one[0]);
}

test "setDeviceHandle records what glBufferData gave the object" {
    var t = Table{};
    var a: [1]u32 = undefined;
    try t.gen(1, &a);
    try t.ensureNamed(a[0]);
    t.setDeviceHandle(a[0], 42, 1024, .dynamic);
    const r = t.record(a[0]).?;
    try expectEqual(@as(?u32, 42), r.handle);
    try expectEqual(@as(usize, 1024), r.size);
    try expect(r.usage == .dynamic);
}
