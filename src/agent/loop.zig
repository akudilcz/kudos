//! The agent loop: the tool-calling cycle that turns a user request
//! into actions. It is written over injected capabilities — a chat transport, a
//! tool executor, and an output sink — so the same logic runs in the kernel
//! (real HTTPS, the tool registry, the terminal) and in a host test (scripted
//! fakes). Conversation state lives in a caller-owned `History`.
//!
//! Each turn: build a streamed request from the history, show each text delta
//! the moment it arrives (spec AGT-005), and either (a) run the tool calls the
//! model asked for and feed their results back, or (b) take the assistant's
//! text as the final answer. Every run is bounded by a stated budget
//! (budget.zig, spec AGT-012) over turns, tool calls, tokens, and time, so a
//! model that never stops calling tools cannot loop forever — and when a bound
//! ends the request, the user is shown exactly which one and the spend.

const std = @import("std");
pub const tools = @import("tools.zig");
const inet = @import("inet");
const openrouter = @import("openrouter.zig");
/// Re-exported so a caller (and the host test) shares this module's instance.
pub const history = @import("history.zig");
/// Re-exported for the same reason: callers state limits in this type.
pub const budget = @import("budget.zig");

/// Chat transport: send a request body and deliver raw response-body bytes to
/// `sink` as they arrive (kernel: inet.postStream over HTTPS; host test:
/// scripted chunks). `sink.write` returning false ends the transfer early —
/// how the stream stops at the SSE `[DONE]` sentinel.
pub const Chat = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, request: []const u8, sink: inet.BodySink) anyerror!void,
};

/// Tool executor: run tool `name` with JSON `args`, append a result string to
/// `out`. The result text is fed back to the model verbatim.
pub const Tools = struct {
    ctx: *anyopaque,
    invoke: *const fn (ctx: *anyopaque, name: []const u8, args: []const u8, out: *std.array_list.Managed(u8)) anyerror!void,
};

/// Where assistant text is shown to the user as it is produced.
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, text: []const u8) void,
};

/// Time source for the wall-clock bound — a real seam (kernel: timer.millis;
/// host test: a scripted clock).
pub const Clock = struct {
    ctx: *anyopaque,
    millis: *const fn (ctx: *anyopaque) u64,
};

pub const Options = struct {
    model: []const u8,
    /// Pre-built JSON tool-definitions array, or "" for a plain chat.
    tools_json: []const u8 = "",
    /// The stated budget for this request (spec AGT-012).
    limits: budget.Limits = .{},
};

pub const RunError = error{OutOfMemory} || anyerror;

/// Bridges the transport's byte chunks to the SSE accumulator and the user's
/// sink: each chunk may complete text deltas, and any new text is shown at
/// once — this is what makes tokens appear as they are produced (spec AGT-005).
/// An allocation failure inside the callback is remembered (the transport's
/// bool-returning sink cannot carry it) and re-raised after the send.
const DeltaRelay = struct {
    acc: *openrouter.SseAccumulator,
    sink: Sink,
    shown: usize = 0,
    err: ?anyerror = null,

    fn write(ctx: *anyopaque, chunk: []const u8) bool {
        const self: *DeltaRelay = @ptrCast(@alignCast(ctx));
        self.acc.push(chunk) catch |e| {
            self.err = e;
            return false;
        };
        const text = self.acc.text();
        if (text.len > self.shown) {
            self.sink.write(self.sink.ctx, text[self.shown..]);
            self.shown = text.len;
        }
        return !self.acc.done;
    }
};

/// Show which bound ended the request, with the full budget statement — the
/// exhaustion is never silent (spec AGT-012).
fn reportExhausted(sink: Sink, bud: *const budget.Budget, now_ms: u64, what: budget.Exhausted) void {
    var msg_buf: [224]u8 = undefined;
    var stmt_buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(
        &msg_buf,
        "\n[agent: budget exhausted ({s}) — {s}]\n",
        .{ what.label(), bud.statement(now_ms, &stmt_buf) },
    ) catch "\n[agent: budget exhausted]\n";
    sink.write(sink.ctx, text);
}

/// Run one user request to completion: a final assistant answer, or the first
/// exhausted budget bound. Appends all turns to `hist`.
pub fn run(
    alloc: std.mem.Allocator,
    chat: Chat,
    toolbox: Tools,
    sink: Sink,
    clock: Clock,
    hist: *history.History,
    user_prompt: []const u8,
    opts: Options,
) RunError!void {
    try hist.push(.user, user_prompt);
    var bud = budget.Budget.init(opts.limits, clock.millis(clock.ctx));

    while (true) {
        // Spend nothing once any bound is out; charge the turn we are taking.
        const now = clock.millis(clock.ctx);
        if (bud.over(now)) |what| return reportExhausted(sink, &bud, now, what);
        if (bud.chargeTurn()) |what| return reportExhausted(sink, &bud, now, what);

        var arena_i = std.heap.ArenaAllocator.init(alloc);
        defer arena_i.deinit();
        const arena = arena_i.allocator();

        const msgs = try hist.toMessages(arena);
        const req = try openrouter.buildChatRequest(arena, opts.model, msgs, true, opts.tools_json);

        var acc = openrouter.SseAccumulator.init(arena);
        var relay = DeltaRelay{ .acc = &acc, .sink = sink };
        try chat.send(chat.ctx, req, .{ .ctx = &relay, .write = DeltaRelay.write });
        if (relay.err) |e| return e;
        if (!acc.saw_event) {
            // The service did not stream at all: its body is an error statement
            // (bad key, bad model, ...). Show it — a refusal is never silent.
            sink.write(sink.ctx, "\n[LLM error] ");
            sink.write(sink.ctx, try acc.errorText());
            sink.write(sink.ctx, "\n");
            return error.ChatFailed;
        }
        const msg = try acc.message();
        bud.chargeTokens(msg.total_tokens);

        // Record any assistant text (already shown as it streamed).
        if (msg.content) |c| if (c.len != 0) try hist.push(.assistant, c);

        if (msg.tool_calls.len == 0) return; // final answer (or nothing more to do)

        // Record the intent, run each tool, feed results back as user turns.
        for (msg.tool_calls) |call| {
            if (bud.chargeToolCall()) |what|
                return reportExhausted(sink, &bud, clock.millis(clock.ctx), what);
            var out = std.array_list.Managed(u8).init(arena);
            toolbox.invoke(toolbox.ctx, call.name, call.arguments, &out) catch |e| {
                out.clearRetainingCapacity();
                try tools.printTo(&out, "tool error: {s}", .{@errorName(e)});
            };
            const note = try std.fmt.allocPrint(
                arena,
                "Tool `{s}` returned:\n{s}",
                .{ call.name, out.items },
            );
            try hist.push(.user, note);
        }
    }
}
