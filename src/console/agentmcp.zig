//! MCP in both directions: kudos as an MCP server, and kudos as an MCP client.
//!
//! Both halves are about FEDERATING a tool registry over a protocol — serving
//! one out, and splicing someone else's in. That is a different concern from
//! implementing the tools themselves (console/agenttools.zig), and the two meet
//! at exactly one point: the registry, which is passed IN rather than imported,
//! so this file knows the protocol and nothing about what the tools do.
//!
//! Server (AGT-011/AGT-013): the same registry the model calls is served to
//! external MCP clients — one JSON-RPC request in over the KMR1 OP_MCP op, the
//! response written to the ramdisk for the client to pull.
//!
//! Client (AGT-014/015/016): when AI.CFG names an `mcp` endpoint, the agent
//! binds to it, lists its tools once, offers them to the model alongside its
//! own, and routes a call to one of them back out. kudos is both at once.

const std = @import("std");
const fileproto = @import("fileproto");
const fileserv = @import("../drivers/net/debug/fileserv.zig");
const heap = @import("../kernel/memory/heap.zig");
const ilog = @import("ilog");
const inet = @import("inet");
const iramdisk = @import("iramdisk");
const mcp = @import("../agent/mcp.zig");
const tools = @import("../agent/tools.zig");

/// The registry served to MCP clients, handed over at boot. Held as a value
/// because the alternative — importing the file that owns it — is the cycle
/// this seam exists to avoid.
var g_registry: ?tools.Registry = null;
var mcp_ctx: u8 = 0;

fn logMcp(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "ai: " ++ fmt ++ "\n", args)) |s| ilog.puts(s) else |_| {}
}

fn serve(body: []const u8) void {
    const reg = g_registry orelse return;
    const resp = mcp.handle(heap.allocator(), reg, &mcp_ctx, body) catch |e| {
        logMcp("mcp.handle failed: {s}", .{@errorName(e)});
        return;
    };
    defer heap.allocator().free(resp);
    const rd = iramdisk.instance orelse return;
    rd.put(fileproto.MCP_RESPONSE_FILE, resp) catch |e|
        logMcp("mcp response write failed: {s}", .{@errorName(e)});
}

/// Wire the MCP-over-netdebug server, once at boot (main_root.zig). Makes kudos
/// an MCP server whenever the network is up — independent of whether a user has
/// opened the agent console.
pub fn initServer(registry: tools.Registry) void {
    g_registry = registry;
    fileserv.setMcpHandler(serve);
}

// ── the client half ───────────────────────────────────────────────────────────
var g_url_buf: [192]u8 = undefined;
var g_url_len: usize = 0;
var g_remote_arena: ?std.heap.ArenaAllocator = null;
var g_remote_tools: []const mcp.RemoteTool = &.{};

/// Bind an external MCP server whose tools join the ones offered to the model
/// (AI.CFG `mcp=`, AGT-014). Truncates to capacity, as every AI.CFG setting does.
pub fn setServer(url: []const u8) void {
    const n = @min(url.len, g_url_buf.len);
    @memcpy(g_url_buf[0..n], url[0..n]);
    g_url_len = n;
}

fn serverUrl() ?[]const u8 {
    return if (g_url_len != 0) g_url_buf[0..g_url_len] else null;
}

/// POST one JSON-RPC message to the bound MCP server and return the response
/// body (caller frees). The same inet.post seam the LLM chat rides.
fn post(alloc: std.mem.Allocator, request: []const u8) ![]u8 {
    const url = serverUrl() orelse return error.NoMcpServer;
    const n = inet.instance orelse return error.NoNetwork;
    var hdrs: [1]inet.Header = .{.{ .name = "content-type", .value = "application/json" }};
    return n.post(alloc, url, &hdrs, request);
}

/// Discover the bound server's tools once per session (AGT-014). Failure is
/// non-fatal — the agent keeps its own tools and reports the reason.
pub fn discoverRemoteTools() void {
    if (g_remote_arena) |*a| a.deinit();
    g_remote_arena = null;
    g_remote_tools = &.{};
    if (serverUrl() == null) return;

    const req = mcp.buildRequest(heap.allocator(), 1, "tools/list", "{}") catch return;
    defer heap.allocator().free(req);
    const resp = post(heap.allocator(), req) catch |e| {
        logMcp("remote MCP tools/list failed: {s}", .{@errorName(e)});
        return;
    };
    defer heap.allocator().free(resp);

    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    const remote = mcp.parseToolsList(arena.allocator(), resp) catch {
        arena.deinit();
        return;
    };
    g_remote_arena = arena; // owns the remote tool slices for the session
    g_remote_tools = remote;
    if (remote.len != 0) logMcp("bound MCP server: {d} remote tools federated", .{remote.len});
}

/// The tool set offered to the model: the caller's registry plus any federated
/// remote tools (AGT-015). Splices the remote tools into the local array.
pub fn mergedToolsJson(alloc: std.mem.Allocator, registry: tools.Registry) ![]u8 {
    const local = try registry.toolsJson(alloc);
    if (g_remote_tools.len == 0) return local;
    defer alloc.free(local);
    const remote = try mcp.remoteToolsJson(alloc, g_remote_tools, true);
    defer alloc.free(remote);
    // local is "[...]"; insert the remote tools (each comma-led) before the ']'.
    var out = std.array_list.Managed(u8).init(alloc);
    try out.appendSlice(local[0 .. local.len - 1]);
    try out.appendSlice(remote);
    try out.append(']');
    return out.toOwnedSlice();
}

/// True when `name` is a federated remote tool (dispatch must route it out).
pub fn isRemoteTool(name: []const u8) bool {
    for (g_remote_tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// Route a call to a federated tool back to the bound MCP server (AGT-014) and
/// append its text result.
pub fn callRemoteTool(name: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    const req = try mcp.buildToolCall(heap.allocator(), 2, name, args_json);
    defer heap.allocator().free(req);
    const resp = post(heap.allocator(), req) catch |e| {
        try tools.printTo(out, "remote tool '{s}' failed: {s}", .{ name, @errorName(e) });
        return;
    };
    defer heap.allocator().free(resp);
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const text = mcp.parseToolCallText(arena.allocator(), resp) catch "";
    try out.appendSlice(text);
}
