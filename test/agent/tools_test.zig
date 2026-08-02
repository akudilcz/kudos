//! Host tests of src/agent/tools.zig — the tool registry: JSON serialisation
//! for the chat request and dispatch routing, with fake handlers.

const std = @import("std");
const tools = @import("tools");

var last_args: [128]u8 = undefined;
var last_args_len: usize = 0;

fn echoHandler(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    @memcpy(last_args[0..args_json.len], args_json);
    last_args_len = args_json.len;
    try out.appendSlice("echo:");
    try out.appendSlice(args_json);
}

fn failHandler(_: *anyopaque, _: []const u8, _: *std.array_list.Managed(u8)) anyerror!void {
    return error.Boom;
}

const registry = tools.Registry{ .tools = &.{
    .{ .name = "run_app", .description = "run a .kudos", .params_schema = 
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    , .handler = echoHandler },
    .{ .name = "boom", .description = "always fails", .params_schema = "{\"type\":\"object\"}", .handler = failHandler },
} };

test "toolsJson is valid JSON carrying names, descriptions, and schemas" {
    const a = std.testing.allocator;
    const js = try registry.toolsJson(a);
    defer a.free(js);
    // valid JSON
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try std.json.parseFromSlice(std.json.Value, arena.allocator(), js, .{});
    // carries the tool surface
    try std.testing.expect(std.mem.indexOf(u8, js, "\"name\":\"run_app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"required\":[\"name\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"name\":\"boom\"") != null);
}

test "dispatch routes to the handler and returns its output" {
    const a = std.testing.allocator;
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();
    var dummy: u8 = 0;
    try registry.dispatch(&dummy, "run_app", "{\"name\":\"primesum\"}", &out);
    try std.testing.expectEqualStrings("echo:{\"name\":\"primesum\"}", out.items);
    try std.testing.expectEqualStrings("{\"name\":\"primesum\"}", last_args[0..last_args_len]);
}

test "unknown tool is an error, handler errors propagate" {
    const a = std.testing.allocator;
    var out = std.array_list.Managed(u8).init(a);
    defer out.deinit();
    var dummy: u8 = 0;
    try std.testing.expectError(error.UnknownTool, registry.dispatch(&dummy, "nope", "{}", &out));
    try std.testing.expectError(error.Boom, registry.dispatch(&dummy, "boom", "{}", &out));
}
