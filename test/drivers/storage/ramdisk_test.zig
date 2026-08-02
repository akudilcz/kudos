//! Host tests of src/drivers/storage/ramdisk.zig (reached through the storage_root module-root shim).

const std = @import("std");
const ramdisk = @import("testroot").storage.ramdisk;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const get = ramdisk.get;
const init = ramdisk.init;
const iramdisk = ramdisk.iramdisk;
const list = ramdisk.list;
const put = ramdisk.put;
const testing = std.testing;

/// Fresh empty store on the test allocator, so each test starts clean.
fn testReset() void {
    init(std.testing.allocator);
}

/// The module's own symmetric teardown (frees every duped name/data + the list).
fn testDeinit() void {
    ramdisk.deinit();
}

test {
    std.testing.refAllDecls(ramdisk);
}

test "get() on an empty store returns null" {
    testReset();
    defer testDeinit();
    try expect(get("missing.txt") == null);
}

// STO-001: the ramdisk is the in-memory file store; ownership and replace
// semantics below are its contract.
test "put() then get() round-trips the data, and the caller's buffer can be freed after" {
    testReset();
    defer testDeinit();
    const buf = try testing.allocator.dupe(u8, "hello world");
    try put("greeting.txt", buf);
    testing.allocator.free(buf); // put() must have copied; this must not corrupt the store
    const got = get("greeting.txt").?;
    try expectEqualStrings("hello world", got);
}

test "put() with an existing name REPLACES the contents, does not duplicate the entry" {
    testReset();
    defer testDeinit();
    try put("a.txt", "first");
    try put("a.txt", "second"); // same name: replace, not append
    try expectEqualStrings("second", get("a.txt").?);
    try expectEqual(@as(usize, 1), list().len); // still exactly one entry, not two
}

test "list() reflects insertion order and count across multiple distinct files" {
    testReset();
    defer testDeinit();
    try put("a.txt", "1");
    try put("b.txt", "2");
    try put("c.txt", "3");
    const l = list();
    try expectEqual(@as(usize, 3), l.len);
    try expectEqualStrings("a.txt", l[0].name);
    try expectEqualStrings("b.txt", l[1].name);
    try expectEqualStrings("c.txt", l[2].name);
}

test "init() yields an EMPTY store and publishes it through the iramdisk seam" {
    iramdisk.instance = null;
    init(testing.allocator); // the actual boot-time entry point, not a re-implementation
    defer testDeinit();

    // The driver seeds nothing. Which files a system boots with is the caller's
    // decision (src/main_root.zig `seedRamdisk`), so a store that arrives pre-populated
    // would mean the driver had grown a policy it has no business holding.
    try expectEqual(@as(usize, 0), list().len);

    // Everything above the driver layer reaches the store through this, so init that
    // forgot to publish would leave the shell and the file server with no file system
    // at all while the driver itself looked perfectly healthy.
    try expect(iramdisk.instance != null);
    try expectEqual(@as(usize, 0), iramdisk.instance.?.count());
}
