//! Host tests of src/agent/loop.zig — the agent control flow, driven by
//! deterministic fakes: a scripted chat that streams canned OpenRouter SSE
//! bodies in small chunks, a tool executor that records calls and returns
//! scripted output, and a sink that captures assistant text. No network, no
//! factory.

const std = @import("std");
const inet = @import("inet");
const loop = @import("loop");
const history = loop.history;

/// Bytes each scripted chunk carries — small and unaligned on purpose, so every
/// test also exercises SSE lines split across transport chunks.
const CHUNK_BYTES = 7;

// A chat that streams the next canned response body each time it is called.
const ScriptedChat = struct {
    responses: []const []const u8,
    i: usize = 0,
    requests_seen: std.array_list.Managed([]u8),

    fn send(ctx: *anyopaque, request: []const u8, sink: inet.BodySink) anyerror!void {
        const self: *ScriptedChat = @ptrCast(@alignCast(ctx));
        try self.requests_seen.append(try self.requests_seen.allocator.dupe(u8, request));
        const body = self.responses[self.i];
        self.i += 1;
        var off: usize = 0;
        while (off < body.len) {
            const n = @min(CHUNK_BYTES, body.len - off);
            if (!sink.write(sink.ctx, body[off..][0..n])) return;
            off += n;
        }
    }
    fn chat(self: *ScriptedChat) loop.Chat {
        return .{ .ctx = self, .send = send };
    }
};

// A tool executor that records (name,args) and returns a scripted output per name.
const FakeTools = struct {
    calls: std.array_list.Managed([]u8),
    outputs: std.StringHashMap([]const u8),

    fn invoke(ctx: *anyopaque, name: []const u8, args: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *FakeTools = @ptrCast(@alignCast(ctx));
        const rec = try std.fmt.allocPrint(self.calls.allocator, "{s}({s})", .{ name, args });
        try self.calls.append(rec);
        try out.appendSlice(self.outputs.get(name) orelse "unknown tool");
    }
    fn tools(self: *FakeTools) loop.Tools {
        return .{ .ctx = self, .invoke = invoke };
    }
};

const CaptureSink = struct {
    buf: std.array_list.Managed(u8),
    writes: usize = 0,
    fn write(ctx: *anyopaque, text: []const u8) void {
        const self: *CaptureSink = @ptrCast(@alignCast(ctx));
        self.buf.appendSlice(text) catch {};
        self.writes += 1;
    }
    fn sink(self: *CaptureSink) loop.Sink {
        return .{ .ctx = self, .write = write };
    }
};

// A scripted clock: starts at zero, advances `step_ms` per reading — the budget
// wall-time bound is tested with time the test controls, never real time.
const FakeClock = struct {
    now: u64 = 0,
    step_ms: u64 = 0,
    fn millis(ctx: *anyopaque) u64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx));
        const t = self.now;
        self.now += self.step_ms;
        return t;
    }
    fn clock(self: *FakeClock) loop.Clock {
        return .{ .ctx = self, .millis = millis };
    }
};

test "happy path: compile then run then final answer, streamed" {
    const a = std.testing.allocator;

    // The model: (1) call compile_app — its arguments split across two delta
    // fragments, (2) call run_app, (3) answer. All streamed SSE bodies.
    const responses = [_][]const u8{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"compile_app","arguments":"{\"name\":"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"primesum\"}"}}]}}]}
        \\data: [DONE]
        ++ "\n",
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c2","function":{"name":"run_app","arguments":"{\"name\":\"primesum\"}"}}]}}]}
        \\data: [DONE]
        ++ "\n",
        \\data: {"choices":[{"delta":{"content":"Done — the sum of the first 20 primes is 639."}}]}
        \\data: [DONE]
        ++ "\n",
    };

    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    try ft.outputs.put("compile_app", "compiled primesum.kudos (702 bytes)");
    try ft.outputs.put("run_app", "sum of first 20 primes = 639");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();

    var hist = history.History.init(a, 32);
    defer hist.deinit();
    try hist.setSystem("SYS");

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "sum the first 20 primes", .{ .model = "m" });

    // Tools were called in order, with arguments assembled from the fragments.
    try std.testing.expectEqual(@as(usize, 2), ft.calls.items.len);
    try std.testing.expectEqualStrings("compile_app({\"name\":\"primesum\"})", ft.calls.items[0]);
    try std.testing.expectEqualStrings("run_app({\"name\":\"primesum\"})", ft.calls.items[1]);
    // The final answer reached the user.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "639") != null);
    // Three chat turns were taken, each requesting a stream.
    try std.testing.expectEqual(@as(usize, 3), chat.i);
    try std.testing.expect(std.mem.indexOf(u8, chat.requests_seen.items[0], "\"stream\":true") != null);
}

// AGT-005: the agent streams its answer as it arrives — buffering the whole
// response and writing once fails the write-count assertion below.
test "text deltas reach the sink incrementally, not as one final write" {
    const a = std.testing.allocator;
    const responses = [_][]const u8{
        \\data: {"choices":[{"delta":{"content":"one "}}]}
        \\data: {"choices":[{"delta":{"content":"two "}}]}
        \\data: {"choices":[{"delta":{"content":"three"}}]}
        \\data: [DONE]
        ++ "\n",
    };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 32);
    defer hist.deinit();

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "count", .{ .model = "m" });
    try std.testing.expectEqualStrings("one two three", cap.buf.items);
    // Each delta was shown as it arrived — at least one write per delta line.
    try std.testing.expect(cap.writes >= 3);
}

test "a non-streaming error body fails loudly with the service's text" {
    const a = std.testing.allocator;
    const responses = [_][]const u8{
        "{\"error\":{\"message\":\"Invalid API key\",\"code\":401}}",
    };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 32);
    defer hist.deinit();

    var clk = FakeClock{};
    try std.testing.expectError(error.ChatFailed, loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "go", .{ .model = "m" }));
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "[LLM error]") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "Invalid API key") != null);
}

test "compile-error is fed back and the model retries" {
    const a = std.testing.allocator;
    const responses = [_][]const u8{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"compile_app","arguments":"{}"}}]}}]}
        \\data: [DONE]
        ++ "\n",
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c2","function":{"name":"compile_app","arguments":"{}"}}]}}]}
        \\data: [DONE]
        ++ "\n",
        \\data: {"choices":[{"delta":{"content":"Fixed and compiled."}}]}
        \\data: [DONE]
        ++ "\n",
    };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    // First compile "fails" (the fed-back text is an error); model tries again.
    try ft.outputs.put("compile_app", "app.zig:1:1: error: expected expression");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 32);
    defer hist.deinit();

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "build x", .{ .model = "m" });
    try std.testing.expectEqual(@as(usize, 2), ft.calls.items.len); // retried
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "Fixed and compiled") != null);
    // The error text was fed back into the conversation as a turn.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const msgs = try hist.toMessages(arena.allocator());
    var saw_error = false;
    for (msgs) |m| if (std.mem.indexOf(u8, m.content, "expected expression") != null) {
        saw_error = true;
    };
    try std.testing.expect(saw_error);
}

// One endless tool-call turn, as a streamed SSE body.
const NOOP_TURN =
    \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"x","function":{"name":"noop","arguments":"{}"}}]}}]}
    \\data: [DONE]
++ "\n";

test "a model that never stops calling tools is bounded by the turn budget" {
    const a = std.testing.allocator;
    // Every response is a tool call; the loop must stop at the turn bound.
    const responses = [_][]const u8{ NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN, NOOP_TURN };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    try ft.outputs.put("noop", "ok");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 64);
    defer hist.deinit();

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "go", .{
        .model = "m",
        .limits = .{ .max_turns = 3 },
    });
    try std.testing.expectEqual(@as(usize, 3), ft.calls.items.len);
    // The exhaustion is stated: which bound, and the full spend.
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "budget exhausted (model turns)") != null);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "turns 3/3") != null);
}

test "the tool-call budget stops a fan-out mid-turn" {
    const a = std.testing.allocator;
    // One response asking for three tool calls; only two are budgeted.
    const responses = [_][]const u8{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"1","function":{"name":"noop","arguments":"{}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"2","function":{"name":"noop","arguments":"{}"}}]}}]}
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":2,"id":"3","function":{"name":"noop","arguments":"{}"}}]}}]}
        \\data: [DONE]
        ++ "\n",
    };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    try ft.outputs.put("noop", "ok");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 64);
    defer hist.deinit();

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "go", .{
        .model = "m",
        .limits = .{ .max_tool_calls = 2 },
    });
    try std.testing.expectEqual(@as(usize, 2), ft.calls.items.len);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "budget exhausted (tool calls)") != null);
}

test "reported usage tokens are charged and stop the next turn" {
    const a = std.testing.allocator;
    // Turn 1 wants a tool AND reports usage over the token bound; the loop must
    // not take turn 2.
    const responses = [_][]const u8{
        \\data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"1","function":{"name":"noop","arguments":"{}"}}]}}]}
        \\data: {"usage":{"total_tokens":5000},"choices":[{"delta":{}}]}
        \\data: [DONE]
        ++ "\n",
        \\data: {"choices":[{"delta":{"content":"never reached"}}]}
        \\data: [DONE]
        ++ "\n",
    };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    try ft.outputs.put("noop", "ok");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 64);
    defer hist.deinit();

    var clk = FakeClock{};
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "go", .{
        .model = "m",
        .limits = .{ .max_tokens = 4000 },
    });
    try std.testing.expectEqual(@as(usize, 1), chat.i); // second response never requested
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "budget exhausted (tokens)") != null);
}

test "the wall-clock budget stops the next turn" {
    const a = std.testing.allocator;
    const responses = [_][]const u8{ NOOP_TURN, NOOP_TURN, NOOP_TURN };
    var chat = ScriptedChat{ .responses = &responses, .requests_seen = std.array_list.Managed([]u8).init(a) };
    defer {
        for (chat.requests_seen.items) |r| a.free(r);
        chat.requests_seen.deinit();
    }
    var ft = FakeTools{ .calls = std.array_list.Managed([]u8).init(a), .outputs = std.StringHashMap([]const u8).init(a) };
    defer {
        for (ft.calls.items) |c| a.free(c);
        ft.calls.deinit();
        ft.outputs.deinit();
    }
    try ft.outputs.put("noop", "ok");
    var cap = CaptureSink{ .buf = std.array_list.Managed(u8).init(a) };
    defer cap.buf.deinit();
    var hist = history.History.init(a, 64);
    defer hist.deinit();

    // Each clock reading advances 40 s against a 60 s budget: reading 1 starts
    // the budget (t=0), reading 2 (t=40s) admits turn 1, reading 3 (t=80s) is
    // over budget — turn 2 must not run.
    var clk = FakeClock{ .step_ms = 40_000 };
    try loop.run(a, chat.chat(), ft.tools(), cap.sink(), clk.clock(), &hist, "go", .{
        .model = "m",
        .limits = .{ .max_ms = 60_000 },
    });
    try std.testing.expectEqual(@as(usize, 1), chat.i);
    try std.testing.expect(std.mem.indexOf(u8, cap.buf.items, "budget exhausted (time)") != null);
}
