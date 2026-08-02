//! The OpenRouter chat-completions wire format: build a request body and
//! accumulate a streamed Server-Sent-Events (SSE) response — text deltas,
//! tool-call fragments, and the usage report — into one assistant message.
//! Pure over std.json — bytes in, bytes out — so the whole protocol layer is
//! host-tested against captured JSON with no network.

const std = @import("std");
const tools = @import("tools.zig");

/// The OpenRouter chat-completions endpoint (AGT-003). The default the agent
/// talks to when AI.CFG names no `url=` override.
pub const CHAT_COMPLETIONS_URL = "https://openrouter.ai/api/v1/chat/completions";

/// One chat message in a request.
pub const Msg = struct {
    role: []const u8,
    content: []const u8,
};

/// Serialise a chat-completions request body. `tools_json`, when non-empty, is a
/// pre-built JSON array of tool definitions (from the tool registry) spliced in
/// verbatim, so this module needs no knowledge of the tool schema. A streamed
/// request also asks for `stream_options.include_usage`: the budget (AGT-012)
/// charges reported tokens, and a stream reports usage only when asked.
pub fn buildChatRequest(
    alloc: std.mem.Allocator,
    model: []const u8,
    messages: []const Msg,
    stream: bool,
    tools_json: []const u8,
) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    errdefer list.deinit();
    const w = &list.writer;
    try w.writeAll("{\"model\":");
    try tools.jsonTo(w, alloc, model);
    try w.writeAll(",\"stream\":");
    try w.writeAll(if (stream) "true" else "false");
    if (stream) try w.writeAll(",\"stream_options\":{\"include_usage\":true}");
    try w.writeAll(",\"messages\":");
    try tools.jsonTo(w, alloc, messages);
    if (tools_json.len != 0) {
        try w.writeAll(",\"tools\":");
        try w.writeAll(tools_json);
    }
    try w.writeAll("}");
    return list.toOwnedSlice();
}

/// A tool call the model asked for.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    /// The `arguments` string, itself a JSON object the handler parses.
    arguments: []const u8,
};

/// The assistant's message, assembled from a completed stream.
pub const Message = struct {
    content: ?[]const u8 = null,
    tool_calls: []const ToolCall = &.{},
    finish_reason: ?[]const u8 = null,
    /// `usage.total_tokens` the service reported for this turn (0 when absent) —
    /// what the agent's budget (budget.zig) charges.
    total_tokens: usize = 0,
};

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn str(v: std.json.Value) ?[]const u8 {
    return if (v == .string) v.string else null;
}

/// One streamed tool call under assembly: the id and name arrive once in the
/// call's first fragment; the `arguments` JSON string arrives as concatenated
/// fragments across many deltas.
const PartialCall = struct {
    id: std.array_list.Managed(u8),
    name: std.array_list.Managed(u8),
    arguments: std.array_list.Managed(u8),
};

/// Incremental parser for a streamed SSE response body. Feed arbitrary byte
/// chunks with `push`: assistant text accumulates in `text()` (a caller shows
/// the suffix it has not yet shown — that is the token-by-token display of
/// spec AGT-005), tool calls assemble from their fragments, and the usage
/// report is kept for the budget. `message()` returns the whole assistant
/// message once the stream ends. Handles `data:` lines split across chunk
/// boundaries and stops at the `[DONE]` sentinel.
pub const SseAccumulator = struct {
    arena: std.mem.Allocator,
    /// Bytes of the current line not yet terminated by '\n'.
    pending: std.array_list.Managed(u8),
    content: std.array_list.Managed(u8),
    calls: std.array_list.Managed(PartialCall),
    /// Non-SSE lines seen before any event: a service that rejects the request
    /// answers with a plain JSON error body, and that text must reach the user.
    stray: std.array_list.Managed(u8),
    finish_reason: ?[]const u8 = null,
    total_tokens: usize = 0,
    /// True once any `data:` line arrived — the response really is a stream.
    saw_event: bool = false,
    done: bool = false,

    pub fn init(arena: std.mem.Allocator) SseAccumulator {
        return .{
            .arena = arena,
            .pending = std.array_list.Managed(u8).init(arena),
            .content = std.array_list.Managed(u8).init(arena),
            .calls = std.array_list.Managed(PartialCall).init(arena),
            .stray = std.array_list.Managed(u8).init(arena),
        };
    }

    pub fn push(self: *SseAccumulator, chunk: []const u8) !void {
        try self.pending.appendSlice(chunk);
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
            try self.handleLine(self.pending.items[0..nl]);
            // Drop the consumed line (+newline) from the front.
            const rest = self.pending.items[nl + 1 ..];
            std.mem.copyForwards(u8, self.pending.items, rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
    }

    /// All assistant text so far; grows as deltas arrive.
    pub fn text(self: *const SseAccumulator) []const u8 {
        return self.content.items;
    }

    /// The assembled assistant message. Complete once the stream has ended;
    /// slices point into the accumulator's arena.
    pub fn message(self: *SseAccumulator) !Message {
        var out = try self.arena.alloc(ToolCall, self.calls.items.len);
        var n: usize = 0;
        for (self.calls.items) |pc| {
            if (pc.name.items.len == 0) continue; // a call never named is not callable
            out[n] = .{
                .id = pc.id.items,
                .name = pc.name.items,
                .arguments = if (pc.arguments.items.len != 0) pc.arguments.items else "{}",
            };
            n += 1;
        }
        return .{
            .content = if (self.content.items.len != 0) self.content.items else null,
            .tool_calls = out[0..n],
            .finish_reason = self.finish_reason,
            .total_tokens = self.total_tokens,
        };
    }

    /// The body of a response that never streamed (`saw_event` false) — the
    /// service's error text, collected so the caller can SHOW it rather than
    /// fail silently.
    pub fn errorText(self: *SseAccumulator) ![]const u8 {
        try self.stray.appendSlice(self.pending.items);
        self.pending.clearRetainingCapacity();
        return self.stray.items;
    }

    fn handleLine(self: *SseAccumulator, raw: []const u8) !void {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0) return;
        if (std.mem.startsWith(u8, l, "data:")) {
            self.saw_event = true;
            const data = std.mem.trim(u8, l["data:".len..], " \t");
            if (std.mem.eql(u8, data, "[DONE]")) {
                self.done = true;
                return;
            }
            try self.applyData(data);
            return;
        }
        if (l[0] == ':') return; // SSE comment — OpenRouter's keepalive
        if (!self.saw_event) {
            try self.stray.appendSlice(l);
            try self.stray.append('\n');
        }
    }

    /// Fold one `data:` JSON payload into the accumulating message. Everything
    /// taken from the payload is COPIED out: the parse may alias `data`, which
    /// lives in the pending buffer the caller is about to shift.
    fn applyData(self: *SseAccumulator, data: []const u8) !void {
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, data, .{}) catch return;
        if (field(root, "usage")) |u| if (field(u, "total_tokens")) |tt| {
            if (tt == .integer and tt.integer > 0) self.total_tokens = @intCast(tt.integer);
        };
        const choices = field(root, "choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice = choices.array.items[0];
        if (field(choice, "finish_reason")) |fr| if (str(fr)) |s| {
            self.finish_reason = try self.arena.dupe(u8, s);
        };
        const delta = field(choice, "delta") orelse return;
        if (field(delta, "content")) |c| if (str(c)) |s| try self.content.appendSlice(s);
        if (field(delta, "tool_calls")) |tc| if (tc == .array) {
            for (tc.array.items) |frag| try self.applyCallFragment(frag);
        };
    }

    /// Route one tool-call fragment to its slot by `index` and append what it
    /// carries. A fragment without an index continues the current call —
    /// fragments arrive in order, and a provider that omits the index streams
    /// one call at a time.
    fn applyCallFragment(self: *SseAccumulator, frag: std.json.Value) !void {
        const idx: usize = blk: {
            if (field(frag, "index")) |v| {
                if (v == .integer and v.integer >= 0) break :blk @intCast(v.integer);
            }
            break :blk self.calls.items.len -| 1;
        };
        while (self.calls.items.len <= idx) {
            try self.calls.append(.{
                .id = std.array_list.Managed(u8).init(self.arena),
                .name = std.array_list.Managed(u8).init(self.arena),
                .arguments = std.array_list.Managed(u8).init(self.arena),
            });
        }
        const pc = &self.calls.items[idx];
        if (field(frag, "id")) |v| if (str(v)) |s| try pc.id.appendSlice(s);
        if (field(frag, "function")) |func| {
            if (field(func, "name")) |v| if (str(v)) |s| try pc.name.appendSlice(s);
            if (field(func, "arguments")) |v| if (str(v)) |s| try pc.arguments.appendSlice(s);
        }
    }
};
