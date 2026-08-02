//! Bidirectional Model Context Protocol (MCP) over JSON-RPC 2.0, as pure
//! message building and parsing — the transport (netdebug, TCP, stdio) is
//! injected by the caller.
//!
//! Server direction (kudos exposes its tools, AGT-013): `handle` turns an
//! incoming JSON-RPC request into a response, answering `initialize`,
//! `tools/list`, and `tools/call` from a `tools.Registry`.
//!
//! Client direction (kudos binds an external server, AGT-014): `buildRequest`
//! frames a call, `parseToolsList` reads a discovered tool set, and
//! `parseToolCallText` reads a result — so external tools can be federated into
//! the agent's registry (AGT-015).

const std = @import("std");
/// Re-exported so a caller (and the host test) shares this module's instance.
pub const tools = @import("tools.zig");

pub const PROTOCOL_VERSION = "2024-11-05";

// ── shared JSON-RPC helpers ──────────────────────────────────────────────────

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// Write the `"id":<...>` member (number or null; MCP ids are also allowed to be
/// strings, which we echo when present).
fn writeId(w: anytype, alloc: std.mem.Allocator, id: ?std.json.Value) !void {
    try w.writeAll("\"id\":");
    if (id) |v| switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .string => |s| try tools.jsonTo(w, alloc, s),
        else => try w.writeAll("null"),
    } else try w.writeAll("null");
}

// ── server side ──────────────────────────────────────────────────────────────

/// Handle one JSON-RPC request against `registry`, returning the response
/// bytes. `ctx` is passed to tool handlers on a `tools/call`. Notifications
/// (no `id`, e.g. `notifications/initialized`) return an empty slice — nothing
/// to send back.
pub fn handle(
    alloc: std.mem.Allocator,
    registry: tools.Registry,
    ctx: *anyopaque,
    body: []const u8,
) ![]u8 {
    var arena_i = std.heap.ArenaAllocator.init(alloc);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return parseError(alloc);
    const id = field(root, "id");
    const method = if (field(root, "method")) |m| (if (m == .string) m.string else "") else "";

    if (id == null) return alloc.dupe(u8, ""); // a notification: no reply

    if (std.mem.eql(u8, method, "initialize")) return initializeResult(alloc, id);
    if (std.mem.eql(u8, method, "tools/list")) return toolsListResult(alloc, registry, id);
    if (std.mem.eql(u8, method, "tools/call")) return toolsCallResult(alloc, registry, ctx, id, field(root, "params"));
    return methodNotFound(alloc, id);
}

fn initializeResult(alloc: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    const w = &list.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",");
    try writeId(w, alloc, id);
    try w.writeAll(",\"result\":{\"protocolVersion\":\"" ++ PROTOCOL_VERSION ++
        "\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"kudos\",\"version\":\"1\"}}}");
    return list.toOwnedSlice();
}

fn toolsListResult(alloc: std.mem.Allocator, registry: tools.Registry, id: ?std.json.Value) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    const w = &list.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",");
    try writeId(w, alloc, id);
    try w.writeAll(",\"result\":{\"tools\":[");
    for (registry.tools, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try tools.jsonTo(w, alloc, t.name);
        try w.writeAll(",\"description\":");
        try tools.jsonTo(w, alloc, t.description);
        try w.writeAll(",\"inputSchema\":");
        try w.writeAll(t.params_schema);
        try w.writeByte('}');
    }
    try w.writeAll("]}}");
    return list.toOwnedSlice();
}

fn toolsCallResult(
    alloc: std.mem.Allocator,
    registry: tools.Registry,
    ctx: *anyopaque,
    id: ?std.json.Value,
    params: ?std.json.Value,
) ![]u8 {
    const p = params orelse return invalidParams(alloc, id);
    const name = if (field(p, "name")) |n| (if (n == .string) n.string else null) else null;
    if (name == null) return invalidParams(alloc, id);

    // Re-serialise the arguments object into the JSON string the handler parses.
    var args: std.Io.Writer.Allocating = .init(alloc);
    defer args.deinit();
    if (field(p, "arguments")) |a| {
        try tools.jsonTo(&args.writer, alloc, a);
    } else {
        try args.writer.writeAll("{}");
    }

    var out = std.array_list.Managed(u8).init(alloc);
    defer out.deinit();
    var is_error = false;
    registry.dispatch(ctx, name.?, args.written(), &out) catch |e| {
        is_error = true;
        out.clearRetainingCapacity();
        try tools.printTo(&out, "error: {s}", .{@errorName(e)});
    };

    var list: std.Io.Writer.Allocating = .init(alloc);
    const w = &list.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",");
    try writeId(w, alloc, id);
    try w.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try tools.jsonTo(w, alloc, out.items);
    try w.print("}}],\"isError\":{s}}}}}", .{if (is_error) "true" else "false"});
    return list.toOwnedSlice();
}

fn errorResponse(alloc: std.mem.Allocator, id: ?std.json.Value, code: i32, message: []const u8) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    const w = &list.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",");
    try writeId(w, alloc, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try tools.jsonTo(w, alloc, message);
    try w.writeAll("}}");
    return list.toOwnedSlice();
}

fn methodNotFound(alloc: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    return errorResponse(alloc, id, -32601, "method not found");
}
fn invalidParams(alloc: std.mem.Allocator, id: ?std.json.Value) ![]u8 {
    return errorResponse(alloc, id, -32602, "invalid params");
}
fn parseError(alloc: std.mem.Allocator) ![]u8 {
    return errorResponse(alloc, null, -32700, "parse error");
}

// ── client side ──────────────────────────────────────────────────────────────

/// Build a JSON-RPC request. `params_json` is spliced verbatim (or "" for none).
pub fn buildRequest(alloc: std.mem.Allocator, id: i64, method: []const u8, params_json: []const u8) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    const w = &list.writer;
    try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try tools.jsonTo(w, alloc, method);
    if (params_json.len != 0) {
        try w.writeAll(",\"params\":");
        try w.writeAll(params_json);
    }
    try w.writeByte('}');
    return list.toOwnedSlice();
}

/// Build a `tools/call` request for a bound server.
pub fn buildToolCall(alloc: std.mem.Allocator, id: i64, name: []const u8, arguments_json: []const u8) ![]u8 {
    var params: std.Io.Writer.Allocating = .init(alloc);
    defer params.deinit();
    const w = &params.writer;
    try w.writeAll("{\"name\":");
    try tools.jsonTo(w, alloc, name);
    try w.writeAll(",\"arguments\":");
    try w.writeAll(if (arguments_json.len != 0) arguments_json else "{}");
    try w.writeByte('}');
    return buildRequest(alloc, id, "tools/call", params.written());
}

/// A tool discovered from a bound MCP server. Slices point into `arena`.
pub const RemoteTool = struct {
    name: []const u8,
    description: []const u8,
    /// The `inputSchema` object, re-serialised.
    input_schema: []const u8,
};

/// Parse a `tools/list` response into the discovered tools (arena-owned).
pub fn parseToolsList(arena: std.mem.Allocator, body: []const u8) ![]RemoteTool {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const result = field(root, "result") orelse return &.{};
    const arr = field(result, "tools") orelse return &.{};
    if (arr != .array) return &.{};
    var outp = try arena.alloc(RemoteTool, arr.array.items.len);
    var n: usize = 0;
    for (arr.array.items) |t| {
        const name = if (field(t, "name")) |v| (if (v == .string) v.string else null) else null;
        if (name == null) continue;
        var schema: std.Io.Writer.Allocating = .init(arena);
        if (field(t, "inputSchema")) |s| {
            try tools.jsonTo(&schema.writer, arena, s);
        } else {
            try schema.writer.writeAll("{\"type\":\"object\"}");
        }
        outp[n] = .{
            .name = name.?,
            .description = if (field(t, "description")) |d| (if (d == .string) d.string else "") else "",
            .input_schema = schema.written(),
        };
        n += 1;
    }
    return outp[0..n];
}

/// Serialise discovered remote tools into the LLM's function-tool format
/// (the same `{"type":"function","function":{...}}` shape tools.Registry
/// emits), for splicing into the request's tools array (AGT-015). `leading`
/// prepends a comma so remote tools append after the local ones. Names are
/// emitted verbatim — the caller namespaces them if needed to avoid clashes.
pub fn remoteToolsJson(alloc: std.mem.Allocator, remote: []const RemoteTool, leading: bool) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(alloc);
    errdefer list.deinit();
    const w = &list.writer;
    for (remote, 0..) |t, i| {
        if (leading or i != 0) try w.writeByte(',');
        try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
        try tools.jsonTo(w, alloc, t.name);
        try w.writeAll(",\"description\":");
        try tools.jsonTo(w, alloc, t.description);
        try w.writeAll(",\"parameters\":");
        try w.writeAll(t.input_schema);
        try w.writeAll("}}");
    }
    return list.toOwnedSlice();
}

/// Extract the concatenated text of a `tools/call` result (arena-owned).
pub fn parseToolCallText(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const result = field(root, "result") orelse return "";
    const content = field(result, "content") orelse return "";
    if (content != .array) return "";
    var out = std.array_list.Managed(u8).init(arena);
    for (content.array.items) |item| {
        if (field(item, "text")) |t| if (t == .string) try out.appendSlice(t.string);
    }
    return out.items;
}
