//! Host tests of src/agent/mcp.zig — bidirectional MCP over JSON-RPC. Server
//! side (handle) is driven by a tool registry; client side (build/parse) reads
//! discovery and results; and a round-trip proves the two compose.

const std = @import("std");
const mcp = @import("mcp");
const tools = mcp.tools;

fn addHandler(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args_json, .{});
    const a = v.object.get("a").?.integer;
    const b = v.object.get("b").?.integer;
    var nb: [32]u8 = undefined;
    try out.appendSlice(std.fmt.bufPrint(&nb, "{d}", .{a + b}) catch unreachable);
}

const registry = tools.Registry{ .tools = &.{
    .{ .name = "add", .description = "add two ints", .params_schema = 
    \\{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"}},"required":["a","b"]}
    , .handler = addHandler },
} };

fn parseOk(a: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, body, .{});
}

test "server: tools/list enumerates the registry and echoes the id" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}";
    const resp = try mcp.handle(a, registry, &dummy, req);
    defer a.free(resp);

    var p = try parseOk(a, resp);
    defer p.deinit();
    try std.testing.expectEqual(@as(i64, 7), p.value.object.get("id").?.integer);
    const list = p.value.object.get("result").?.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("add", list.items[0].object.get("name").?.string);
}

test "server: tools/call dispatches and wraps the result as content text" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"add\",\"arguments\":{\"a\":2,\"b\":3}}}";
    const resp = try mcp.handle(a, registry, &dummy, req);
    defer a.free(resp);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const text = try mcp.parseToolCallText(arena.allocator(), resp);
    try std.testing.expectEqualStrings("5", text);
}

test "server: unknown tool comes back as isError content, not a crash" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}";
    const resp = try mcp.handle(a, registry, &dummy, req);
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "UnknownTool") != null);
}

test "server: initialize and method-not-found and notifications" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;

    const init_resp = try mcp.handle(a, registry, &dummy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}");
    defer a.free(init_resp);
    try std.testing.expect(std.mem.indexOf(u8, init_resp, mcp.PROTOCOL_VERSION) != null);

    const nf = try mcp.handle(a, registry, &dummy, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"bogus\"}");
    defer a.free(nf);
    try std.testing.expect(std.mem.indexOf(u8, nf, "-32601") != null);

    // A notification (no id) yields nothing to send.
    const note = try mcp.handle(a, registry, &dummy, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    defer a.free(note);
    try std.testing.expectEqual(@as(usize, 0), note.len);
}

test "client: parseToolsList reads a discovered tool set" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[
        \\{"name":"weather","description":"get weather","inputSchema":{"type":"object"}},
        \\{"name":"search","inputSchema":{"type":"object","properties":{"q":{"type":"string"}}}}]}}
    ;
    const remote = try mcp.parseToolsList(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 2), remote.len);
    try std.testing.expectEqualStrings("weather", remote[0].name);
    try std.testing.expectEqualStrings("get weather", remote[0].description);
    try std.testing.expect(std.mem.indexOf(u8, remote[1].input_schema, "\"q\"") != null);
}

// The bidirectional proof: the CLIENT builds a request, the SERVER handles it
// from the registry, and the CLIENT parses the result — end to end.
test "round-trip: client build -> server handle -> client parse (AGT-016)" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;

    // 1) client frames a tools/call
    const req = try mcp.buildToolCall(a, 42, "add", "{\"a\":10,\"b\":20}");
    defer a.free(req);

    // 2) server handles it against the local registry
    const resp = try mcp.handle(a, registry, &dummy, req);
    defer a.free(resp);

    // 3) client parses the result text
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const text = try mcp.parseToolCallText(arena.allocator(), resp);
    try std.testing.expectEqualStrings("30", text);

    // and a tools/list round-trips into discoverable tools
    const lreq = try mcp.buildRequest(a, 1, "tools/list", "");
    defer a.free(lreq);
    const lresp = try mcp.handle(a, registry, &dummy, lreq);
    defer a.free(lresp);
    const remote = try mcp.parseToolsList(arena.allocator(), lresp);
    try std.testing.expectEqual(@as(usize, 1), remote.len);
    try std.testing.expectEqualStrings("add", remote[0].name);
}

test "federation: remote tools serialise into the model's function-tool format (AGT-015)" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Discover two remote tools, then merge them as the agent does: the local
    // tools array with the remote ones spliced in before its closing ']'.
    const list_body =
        \\{"jsonrpc":"2.0","id":1,"result":{"tools":[
        \\{"name":"weather","description":"get weather","inputSchema":{"type":"object","properties":{"city":{"type":"string"}}}}]}}
    ;
    const remote = try mcp.parseToolsList(arena.allocator(), list_body);
    const frag = try mcp.remoteToolsJson(a, remote, true);
    defer a.free(frag);

    // The fragment is comma-led (splices after local tools) and names the tool
    // in the {"type":"function",...} shape the LLM request expects.
    try std.testing.expect(frag[0] == ',');
    try std.testing.expect(std.mem.indexOf(u8, frag, "\"type\":\"function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag, "\"name\":\"weather\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag, "\"city\"") != null);

    // Spliced into a local "[...]" array, the whole thing is valid JSON.
    const local = "[{\"type\":\"function\",\"function\":{\"name\":\"read_file\"}}]";
    const merged = try std.mem.concat(a, u8, &.{ local[0 .. local.len - 1], frag, "]" });
    defer a.free(merged);
    var p = std.heap.ArenaAllocator.init(a);
    defer p.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, p.allocator(), merged, .{});
    try std.testing.expectEqual(@as(usize, 2), v.array.items.len); // local + remote
}
