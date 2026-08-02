//! The agent's tool registry: the one place kudos capabilities are described as
//! callable functions. A `Registry` is consumed two ways — serialised into the
//! `tools` array of a chat request (so the model can call them), and dispatched
//! by name when the model does. The registry itself is pure: handlers are
//! function pointers the kernel fills with real implementations (vfs, apps,
//! screenshot, run, ...) and a host test fills with fakes. The same registry is
//! also what the netdebug MCP bridge enumerates for an external client.

const std = @import("std");

/// Serialise `v` as JSON onto an old-style (array-list) writer. Zig 0.15's
/// std.json.Stringify writes only to the new `*std.Io.Writer`, while these
/// builders assemble into array-list writers — so the value is rendered to an
/// owned buffer first and spliced. One home for the bridge; every JSON
/// assembler in the agent goes through it.
pub fn jsonTo(w: anytype, alloc: std.mem.Allocator, v: anytype) !void {
    const s = try std.json.Stringify.valueAlloc(alloc, v, .{});
    defer alloc.free(s);
    try w.writeAll(s);
}

/// Formatted append onto a managed byte list — the one helper every agent
/// caller uses, so std's absence of a list writer adapter is handled once.
pub fn printTo(out: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(out.allocator, fmt, args);
    defer out.allocator.free(s);
    try out.appendSlice(s);
}

/// Runs a tool: parse `args_json`, do the work, append a result string to `out`
/// (which is fed back to the model and/or returned to an MCP caller).
pub const Handler = *const fn (ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void;

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object for the parameters, spliced into the request
    /// verbatim (e.g. `{"type":"object","properties":{...}}`).
    params_schema: []const u8,
    handler: Handler,
};

pub const DispatchError = error{UnknownTool} || anyerror;

pub const Registry = struct {
    tools: []const Tool,

    pub fn find(self: Registry, name: []const u8) ?*const Tool {
        for (self.tools) |*t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }

    /// Route a call to its handler; append its result to `out`.
    pub fn dispatch(self: Registry, ctx: *anyopaque, name: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) DispatchError!void {
        const tool = self.find(name) orelse return error.UnknownTool;
        try tool.handler(ctx, args_json, out);
    }

    /// Build the OpenRouter/OpenAI `tools` array JSON. Names and descriptions
    /// are JSON-escaped; each schema is spliced verbatim.
    pub fn toolsJson(self: Registry, alloc: std.mem.Allocator) ![]u8 {
        var list: std.Io.Writer.Allocating = .init(alloc);
        errdefer list.deinit();
        const w = &list.writer;
        try w.writeByte('[');
        for (self.tools, 0..) |t, i| {
            if (i != 0) try w.writeByte(',');
            try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try jsonTo(w, alloc, t.name);
            try w.writeAll(",\"description\":");
            try jsonTo(w, alloc, t.description);
            try w.writeAll(",\"parameters\":");
            try w.writeAll(t.params_schema);
            try w.writeAll("}}");
        }
        try w.writeByte(']');
        return list.toOwnedSlice();
    }
};
