//! Host tests of src/agent/openrouter.zig — the chat wire format: request
//! build, and streamed SSE accumulation (text deltas, tool-call assembly,
//! usage for the budget, and the non-stream error body).

const std = @import("std");
const openrouter = @import("openrouter");

test "buildChatRequest emits model, stream flag + usage option, messages, and optional tools" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const msgs = [_]openrouter.Msg{
        .{ .role = "system", .content = "you are the kudos agent" },
        .{ .role = "user", .content = "hi \"there\"" },
    };
    const body = try openrouter.buildChatRequest(a, "x/y", &msgs, true, "[{\"type\":\"function\"}]");
    // model + stream present
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"x/y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    // a stream asks for the usage report the budget charges
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
    // content is JSON-escaped
    try std.testing.expect(std.mem.indexOf(u8, body, "hi \\\"there\\\"") != null);
    // tools spliced verbatim
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[{\"type\":\"function\"}]") != null);
    // and the whole thing re-parses as JSON
    _ = try std.json.parseFromSlice(std.json.Value, a, body, .{});
}

test "no tools -> no tools field; no stream -> no stream_options" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const msgs = [_]openrouter.Msg{.{ .role = "user", .content = "hi" }};
    const body = try openrouter.buildChatRequest(a, "m", &msgs, false, "");
    try std.testing.expect(std.mem.indexOf(u8, body, "tools") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stream_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":false") != null);
}

test "SseAccumulator reassembles text deltas across arbitrary chunk splits" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    const stream =
        "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"lo, \"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    // Feed the bytes in tiny, deliberately unaligned slices.
    var i: usize = 0;
    while (i < stream.len) : (i += 7) {
        try acc.push(stream[i..@min(i + 7, stream.len)]);
    }
    try std.testing.expect(acc.done);
    try std.testing.expect(acc.saw_event);
    try std.testing.expectEqualStrings("Hello, world", acc.text());
    const m = try acc.message();
    try std.testing.expectEqualStrings("Hello, world", m.content.?);
    try std.testing.expectEqual(@as(usize, 0), m.tool_calls.len);
}

test "tool calls assemble from indexed fragments, arguments piecewise" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    const stream =
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"compile_app","arguments":"{\"name\":"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"read_file","arguments":"{\"path\":\"/x\"}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"primesum\"}"}}]}}]}
        \\data: {"choices":[{"finish_reason":"tool_calls","delta":{}}]}
        \\data: [DONE]
    ++ "\n";
    try acc.push(stream);

    const m = try acc.message();
    try std.testing.expectEqual(@as(usize, 2), m.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", m.tool_calls[0].id);
    try std.testing.expectEqualStrings("compile_app", m.tool_calls[0].name);
    try std.testing.expectEqualStrings("{\"name\":\"primesum\"}", m.tool_calls[0].arguments);
    try std.testing.expectEqualStrings("read_file", m.tool_calls[1].name);
    try std.testing.expectEqualStrings("{\"path\":\"/x\"}", m.tool_calls[1].arguments);
    try std.testing.expectEqualStrings("tool_calls", m.finish_reason.?);
}

test "a fragment without an index continues the current call" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    const stream =
        \\data: {"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"noop","arguments":"{\"a\":"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"1}"}}]}}]}
        \\data: [DONE]
    ++ "\n";
    try acc.push(stream);

    const m = try acc.message();
    try std.testing.expectEqual(@as(usize, 1), m.tool_calls.len);
    try std.testing.expectEqualStrings("{\"a\":1}", m.tool_calls[0].arguments);
}

test "a named call with no arguments gets the empty object" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    try acc.push("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c\",\"function\":{\"name\":\"list_modules\"}}]}}]}\ndata: [DONE]\n");
    const m = try acc.message();
    try std.testing.expectEqual(@as(usize, 1), m.tool_calls.len);
    try std.testing.expectEqualStrings("{}", m.tool_calls[0].arguments);
}

test "the usage report in the final chunk is kept for the budget" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    const stream =
        \\data: {"choices":[{"delta":{"content":"hi"}}]}
        \\data: {"usage":{"prompt_tokens":100,"completion_tokens":23,"total_tokens":123},"choices":[{"delta":{}}]}
        \\data: [DONE]
    ++ "\n";
    try acc.push(stream);
    const m = try acc.message();
    try std.testing.expectEqual(@as(usize, 123), m.total_tokens);
    try std.testing.expectEqualStrings("hi", m.content.?);
}

test "SSE comment keepalives are ignored" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    try acc.push(": OPENROUTER PROCESSING\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\ndata: [DONE]\n");
    try std.testing.expectEqualStrings("ok", acc.text());
    try std.testing.expectEqualStrings("", try acc.errorText());
}

test "a non-SSE body is captured as error text, never dropped" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    var acc = openrouter.SseAccumulator.init(a);
    // A rejected request: a plain JSON body, no data: lines, no trailing newline.
    try acc.push("{\"error\":{\"message\":\"Invalid API key\",\n\"code\":401}}");
    try std.testing.expect(!acc.saw_event);
    const err = try acc.errorText();
    try std.testing.expect(std.mem.indexOf(u8, err, "Invalid API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, err, "401") != null);
}
