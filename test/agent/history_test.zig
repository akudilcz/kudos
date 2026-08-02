//! Host tests of src/agent/history.zig — bounded conversation with a pinned
//! system message. Uses the testing allocator, so a leak fails the test.

const std = @import("std");
const history = @import("history");

test "pins system, evicts oldest turn past the cap, builds messages in order (AGT-001)" {
    var h = history.History.init(std.testing.allocator, 3);
    defer h.deinit();

    try h.setSystem("SYS");
    try h.push(.user, "u1");
    try h.push(.assistant, "a1");
    try h.push(.tool, "t1");
    try h.push(.user, "u2"); // over cap 3 -> evict "u1"

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msgs = try h.toMessages(arena.allocator());

    try std.testing.expectEqual(@as(usize, 4), msgs.len); // system + 3 turns
    try std.testing.expectEqualStrings("system", msgs[0].role);
    try std.testing.expectEqualStrings("SYS", msgs[0].content);
    try std.testing.expectEqualStrings("assistant", msgs[1].role);
    try std.testing.expectEqualStrings("a1", msgs[1].content);
    try std.testing.expectEqualStrings("tool", msgs[2].role);
    try std.testing.expectEqualStrings("user", msgs[3].role);
    try std.testing.expectEqualStrings("u2", msgs[3].content);
}

test "replacing the system message frees the old one" {
    var h = history.History.init(std.testing.allocator, 2);
    defer h.deinit();
    try h.setSystem("first");
    try h.setSystem("second");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msgs = try h.toMessages(arena.allocator());
    try std.testing.expectEqualStrings("second", msgs[0].content);
}

test "no system message: messages are just the turns" {
    var h = history.History.init(std.testing.allocator, 4);
    defer h.deinit();
    try h.push(.user, "hi");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const msgs = try h.toMessages(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqualStrings("user", msgs[0].role);
}
