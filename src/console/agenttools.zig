//! The agent's tool surface: what the model can actually DO to this machine.
//!
//! `agent/tools.zig` holds the registry TYPE (a name, a description, a JSON
//! schema, a handler); this file is the one place kudos fills it in — compile a
//! module through the off-target factory (ARCH-012), run one contained
//! (AGT-008), hot-load a feature (AGT-010), read and change files, report
//! system state, capture the screen, open a window, type at the focused one
//! (AGT-006).
//!
//! The same registry is served three ways, so the answer to "what can the agent
//! do" has exactly one home: to the model as the `tools` array of a chat
//! request, to an external MCP client over netdebug (AGT-011/AGT-013), and —
//! merged with the tools of an MCP server kudos is itself a client of
//! (AGT-014/015/016) — back to the model again.
//!
//! The console (cmd/ai.zig) drives this file; it never reaches the other way.

const std = @import("std");
const abi = @import("abi");
const apprun = @import("apprun.zig");
const capabilities = @import("capabilities.zig");
const taskstat = @import("../kernel/sched/taskstat.zig");
const counter = @import("../kernel/debug/counter.zig");
const fileproto = @import("fileproto");
const fileserv = @import("../drivers/net/debug/fileserv.zig");
const heap = @import("../kernel/memory/heap.zig");
const hotload = @import("../kernel/loader/hotload.zig");
const ifilesys = @import("ifilesys");
const ilog = @import("ilog");
const inet = @import("inet");
const idesk = @import("idesk"); // the desktop-control seam: window requests + published readback
const imouse = @import("imouse"); // the one producer path every mouse event takes
const iramdisk = @import("iramdisk");
const keyboard = @import("../drivers/input/keyboard.zig");
const mcp = @import("../agent/mcp.zig");
const timer = @import("../kernel/timer/timer.zig");
const tools = @import("../agent/tools.zig");
const vfs = @import("vfs");
const features = hotload.features;

/// Where the AI.CFG file lives, named here because the tools that need one
/// (compile, without a factory) say so in their refusal.
/// The agent's configuration. On the RAMDISK, where a copy is seeded from the
/// build at boot (main_root.zig): the USB stick this used to live on is a real
/// device that no emulator run has, so a configuration kept only there was one
/// the agent could never be given under QEMU — which is where it is developed.
pub const CFG_PATH = "/ramdisk/AI.CFG";

/// Cap on the feature output captured into one tool result — a chatty feature
/// must not burn the request's token budget. Overflow is truncated LOUDLY.
const MAX_TOOL_OUTPUT_BYTES: usize = 8 * 1024;

// ── the compile factory (ARCH-012): compile/source requests ONLY ──────────────
const Endpoints = struct {
    host: [128]u8 = undefined,
    host_len: usize = 0,
    compile: [160]u8 = undefined,
    compile_len: usize = 0,
    fn compileUrl(self: *const Endpoints) []const u8 {
        return self.compile[0..self.compile_len];
    }
    /// Build a factory URL for `path_fmt` (e.g. "/sources/{s}") into `buf`.
    fn url(self: *const Endpoints, buf: []u8, comptime path_fmt: []const u8, args: anytype) ?[]const u8 {
        if (self.host_len == 0) return null;
        return std.fmt.bufPrint(buf, "http://{s}" ++ path_fmt, .{self.host[0..self.host_len]} ++ args) catch null;
    }
};
var g_ep: Endpoints = .{};

// The factory's shared secret (AI.CFG `token=`), sent on POSTs when set.
var g_token_buf: [96]u8 = undefined;
var g_token_len: usize = 0;

/// The factory's shared secret (AI.CFG `token=`).
pub fn setToken(tok: []const u8) void {
    setBuf(&g_token_buf, &g_token_len, tok);
}

/// Bind an external MCP server whose tools join the ones offered to the model
/// (AI.CFG `mcp=`, AGT-014).
pub fn setMcpServer(url: []const u8) void {
    setBuf(&g_mcp_url_buf, &g_mcp_url_len, url);
}

/// Copy `src` into the fixed buffer `dst`, truncated to its capacity, and
/// record the stored length in `len` — the one owner of the bounded
/// copy-into-a-global every AI.CFG-derived setting uses, here and in the
/// console that parses the file.
pub fn setBuf(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Point the compile tools at a factory host ("host:port", AI.CFG `factory=`).
pub fn setFactory(factory: []const u8) void {
    setBuf(&g_ep.host, &g_ep.host_len, factory);
    const ep = std.fmt.bufPrint(&g_ep.compile, "http://{s}/compile", .{factory}) catch {
        g_ep.compile_len = 0;
        return;
    };
    g_ep.compile_len = ep.len;
}

/// The factory host this build is pointed at, or null when none is configured
/// — what `/status` reports.
pub fn factoryHost() ?[]const u8 {
    return if (g_ep.host_len != 0) g_ep.host[0..g_ep.host_len] else null;
}

/// The headers every factory POST carries: JSON content, plus the shared
/// secret when one is configured.
fn postHeaders(buf: *[2]inet.Header) []const inet.Header {
    buf[0] = .{ .name = "Content-Type", .value = "application/json" };
    if (g_token_len == 0) return buf[0..1];
    buf[1] = .{ .name = "X-Factory-Token", .value = g_token_buf[0..g_token_len] };
    return buf[0..2];
}

// ── tools (loop.Tools): the agent's reach into the system ─────────────────────
const COMPILE_SCHEMA =
    \\{"type":"object","properties":{"name":{"type":"string"},"source":{"type":"string"}},"required":["name","source"]}
;
const NAME_SCHEMA =
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
;
const INVOKE_SCHEMA =
    \\{"type":"object","properties":{"name":{"type":"string"},"args":{"type":"string"}},"required":["name"]}
;
const NONE_SCHEMA =
    \\{"type":"object","properties":{}}
;

/// One string argument out of a tool-call JSON object, or null.
fn jsonStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}

/// Parse a tool call's JSON argument object onto `aa` (the handler's arena,
/// which must outlive every string pulled from the value). On malformed JSON,
/// report "bad tool arguments" to `out` and return null — the handler returns
/// without acting. The shared preamble of every tool handler.
fn parseToolArgs(aa: std.mem.Allocator, args_json: []const u8, out: *std.array_list.Managed(u8)) !?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, aa, args_json, .{}) catch {
        try out.appendSlice("bad tool arguments");
        return null;
    };
}

// Feature output captured into the calling tool's result, so the agent SEES
// what its feature did. Bounded; truncation is stated, never silent.
var g_capture_buf: [MAX_TOOL_OUTPUT_BYTES]u8 = undefined;
var g_capture_len: usize = 0;
var g_capture_truncated: bool = false;

fn captureWrite(_: *anyopaque, text: []const u8) void {
    const room = g_capture_buf.len - g_capture_len;
    const n = @min(text.len, room);
    @memcpy(g_capture_buf[g_capture_len..][0..n], text[0..n]);
    g_capture_len += n;
    if (n < text.len) g_capture_truncated = true;
}

var g_capture_ctx: u8 = 0;

fn captureSink() hotload.Sink {
    g_capture_len = 0;
    g_capture_truncated = false;
    return .{ .ctx = &g_capture_ctx, .write = captureWrite };
}

fn captured(out: *std.array_list.Managed(u8)) !void {
    try out.appendSlice(g_capture_buf[0..g_capture_len]);
    if (g_capture_truncated) try out.appendSlice("\n[output truncated]");
}

/// Compile `source` off-target (ARCH-012) and place `<name>.kudos` on the
/// ramdisk, appending to `out` what the user is to be told either way. The ONE
/// home of the compile request: the agent's compile tools and the shell's
/// `compile` command are both callers, so the factory protocol, the file name
/// and the wording of a refusal are stated once.
///
/// `kind` is the ABI kind the factory stamps ("app" or "feature"); anything the
/// factory does not know it rejects, and the rejection is the answer.
pub fn compileSource(
    kind: []const u8,
    name: []const u8,
    source: []const u8,
    out: *std.array_list.Managed(u8),
) anyerror!void {
    if (g_ep.host_len == 0) {
        try out.appendSlice("no compile factory configured — set `factory=<host:port>` in " ++ CFG_PATH);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const aa = arena.allocator();

    var req = std.array_list.Managed(u8).init(aa);
    try tools.printTo(&req, "{{\"abi_version\":{d},\"kind\":\"{s}\",\"name\":\"{s}\",\"source\":", .{ abi.ABI_VERSION, kind, name });
    {
        const j = try std.json.Stringify.valueAlloc(aa, source, .{});
        defer aa.free(j);
        try req.appendSlice(j);
    }
    try req.appendSlice("}");

    const n = inet.instance orelse {
        try out.appendSlice("network is down");
        return;
    };
    var hdrs: [2]inet.Header = undefined;
    const resp = try n.post(heap.allocator(), g_ep.compileUrl(), postHeaders(&hdrs), req.items);
    defer heap.allocator().free(resp);

    // A .kudos blob starts with the "KDOS" magic; anything else is compile errors.
    if (resp.len >= 4 and std.mem.eql(u8, resp[0..4], "KDOS")) {
        var fbuf: [80]u8 = undefined;
        const fname = std.fmt.bufPrint(&fbuf, "{s}.kudos", .{name}) catch return;
        // The success line below promises a loadable file; a failed save must
        // surface as the failure it is, never ride under that promise.
        const rd = iramdisk.instance orelse {
            try tools.printTo(out, "compiled {s}.kudos but no ramdisk is up — nothing was saved", .{name});
            return;
        };
        rd.put(fname, resp) catch |e| {
            try tools.printTo(out, "compiled {s}.kudos but saving it failed ({s})", .{ name, @errorName(e) });
            return;
        };
        if (std.mem.eql(u8, kind, "feature")) {
            try tools.printTo(out, "compiled feature {s}.kudos ({d} bytes). Hot-load it with the load_feature tool.", .{ name, resp.len });
        } else {
            try tools.printTo(out, "compiled {s}.kudos ({d} bytes). Run it with the run_app tool, or `run {s}` in a terminal.", .{ name, resp.len, name });
        }
    } else {
        try out.appendSlice("the compiler rejected the code:\n");
        try out.appendSlice(resp);
    }
}

fn compileKind(comptime kind: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name");
    const source = jsonStr(v, "source");
    if (name == null or source == null) {
        try out.appendSlice("compile needs name and source");
        return;
    }
    try compileSource(kind, name.?, source.?, out);
}

fn toolCompile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    try compileKind("app", args_json, out);
}

fn toolCompileFeature(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    try compileKind("feature", args_json, out);
}

fn toolLoadFeature(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse {
        try out.appendSlice("load_feature needs name");
        return;
    };

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        try out.appendSlice("name too long");
        return;
    };
    const blob = vfs.read(path) orelse {
        try tools.printTo(out, "no such compiled feature: {s} (compile_feature it first)", .{name});
        return;
    };

    const mem_len = hotload.runner.imageSize(blob) catch |e| {
        try tools.printTo(out, "not loadable: {s}", .{@errorName(e)});
        return;
    };
    // Resident: over-allocate, 16-byte align, and NEVER free (the feature's
    // code stays live for the boot) — the same contract as the feature command.
    const raw = heap.allocator().alloc(u8, mem_len + 16) catch {
        try out.appendSlice("out of memory");
        return;
    };
    const base = std.mem.alignForward(usize, @intFromPtr(raw.ptr), 16);
    const image = @as([*]u8, @ptrFromInt(base))[0..mem_len];

    const rc = hotload.registerBlob(blob, image, captureSink(), capabilities.feature) catch |e| {
        try tools.printTo(out, "load failed: {s}", .{@errorName(e)});
        return;
    };
    try captured(out);
    try tools.printTo(out, "\n[feature {s} registered, rc {d}] Its commands are callable with invoke_command.", .{ name, rc });
}

fn toolInvokeCommand(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse {
        try out.appendSlice("invoke_command needs name");
        return;
    };
    const cmd_args = jsonStr(v, "args") orelse "";
    // Only the feature registry is reachable here — never shell built-ins, so
    // the agent cannot invoke reboot/net/... through this tool by construction.
    if (!hotload.dispatch(captureSink(), name, cmd_args)) {
        try tools.printTo(out, "no such feature command: {s}", .{name});
        return;
    }
    try captured(out);
    try out.appendSlice("\n[command ran]");
}

fn toolListModules(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    _ = args_json;
    try out.appendSlice("compiled .kudos in ramdisk:\n");
    var count: usize = 0;
    if (iramdisk.instance) |rd| {
        var i: usize = 0;
        const n = rd.count();
        while (i < n) : (i += 1) {
            const e = rd.at(i);
            if (std.mem.endsWith(u8, e.name, ".kudos")) {
                try tools.printTo(out, "  {s}\n", .{e.name});
                count += 1;
            }
        }
    }
    if (count == 0) try out.appendSlice("  (none)\n");
    try out.appendSlice("registered feature commands:\n");
    if (features.len() == 0) try out.appendSlice("  (none)\n");
    var i: usize = 0;
    while (i < features.len()) : (i += 1) {
        try tools.printTo(out, "  {s}\n", .{features.at(i).name()});
    }
}

/// GET a factory path and append the body (the workspace surfaces are served
/// as plain text exactly so they can be handed to the model verbatim).
fn factoryGet(comptime path_fmt: []const u8, args: anytype, out: *std.array_list.Managed(u8)) anyerror!void {
    const n = inet.instance orelse {
        try out.appendSlice("network is down");
        return;
    };
    var urlbuf: [224]u8 = undefined;
    const u = g_ep.url(&urlbuf, path_fmt, args) orelse {
        try out.appendSlice("no factory configured");
        return;
    };
    const body = try n.fetch(heap.allocator(), u);
    defer heap.allocator().free(body);
    try out.appendSlice(body);
}

fn toolListSources(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    _ = args_json;
    try factoryGet("/sources", .{}, out);
}

fn toolReadSource(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse {
        try out.appendSlice("read_source needs name");
        return;
    };
    try factoryGet("/sources/{s}", .{name}, out);
}

fn toolReadAbi(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    _ = args_json;
    try factoryGet("/abi", .{}, out);
}

// ── AGT-006 tool surface: files, system state, screen capture, input ──────────

const PATH_SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
;
const WRITE_SCHEMA =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
;
const TEXT_SCHEMA =
    \\{"type":"object","properties":{"text":{"type":"string"},"window":{"type":"string"}},"required":["text"]}
;
const WINDOW_SCHEMA =
    \\{"type":"object","properties":{"action":{"type":"string","enum":["focus","maximise","minimise","restore","close"]},"window":{"type":"string"}},"required":["action"]}
;
const POINTER_SCHEMA =
    \\{"type":"object","properties":{"x":{"type":"integer"},"y":{"type":"integer"},"button":{"type":"string","enum":["none","left","right","middle"]}},"required":["x","y"]}
;

/// Read a file through the VFS (any mounted volume; the model passes an
/// absolute path like /ramdisk/motd.txt or /usbdisk/AI.CFG).
fn toolReadFile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("read_file needs path");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    const body = vfs.read(abs) orelse {
        try tools.printTo(out, "no such file: {s}", .{abs});
        return;
    };
    // A binary or huge file must not blow the token budget; truncate loudly.
    const shown = @min(body.len, MAX_TOOL_OUTPUT_BYTES);
    try out.appendSlice(body[0..shown]);
    if (shown < body.len) try tools.printTo(out, "\n[truncated {d} of {d} bytes]", .{ shown, body.len });
}

/// The absolute VFS path a tool argument names. A bare name (or a relative
/// path) means the ramdisk — the writable volume, where agent-authored files,
/// notes and compiled modules live — so the model may pass either form.
fn absPath(buf: *[vfs.MAX_PATH]u8, path: []const u8) ?[]const u8 {
    if (path.len != 0 and path[0] == '/') return vfs.normalize("/", path, buf);
    return vfs.normalize("/ramdisk", path, buf);
}

/// Why a mutation was refused, in the words the model can act on. One home for
/// the wording: every file tool below reports through it.
fn writeRefusal(e: ifilesys.WriteError) []const u8 {
    return switch (e) {
        error.NotFound => "no such path",
        error.NotADirectory => "a name along that path is a file, not a directory",
        error.IsADirectory => "that path is a directory",
        error.Exists => "something of that name is already there",
        error.NotEmpty => "the directory is not empty — delete what is in it first",
        error.ReadOnly => "that volume is read-only (only /ramdisk can be written)",
        error.NoSpace => "the volume is full",
        error.IoFailed => "the volume's medium failed",
    };
}

/// Write a file. Directories along the path do not have to be made first: a
/// name with '/' in it creates them (see drivers/storage/ramdisk.zig).
fn toolWriteFile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("write_file needs path");
    const content = jsonStr(v, "content") orelse return out.appendSlice("write_file needs content");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    vfs.write(abs, content) catch |e| {
        try tools.printTo(out, "cannot write {s}: {s}", .{ abs, writeRefusal(e) });
        return;
    };
    try tools.printTo(out, "wrote {d} bytes to {s}", .{ content.len, abs });
}

/// Delete a file.
fn toolDeleteFile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("delete_file needs path");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    vfs.remove(abs) catch |e| {
        try tools.printTo(out, "cannot delete {s}: {s}", .{ abs, writeRefusal(e) });
        return;
    };
    try tools.printTo(out, "deleted {s}", .{abs});
}

/// Create a directory.
fn toolMakeDir(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("make_dir needs path");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    vfs.mkdir(abs) catch |e| {
        try tools.printTo(out, "cannot create {s}: {s}", .{ abs, writeRefusal(e) });
        return;
    };
    try tools.printTo(out, "created directory {s}", .{abs});
}

/// Delete an empty directory.
fn toolDeleteDir(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("delete_dir needs path");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    vfs.rmdir(abs) catch |e| {
        try tools.printTo(out, "cannot delete {s}: {s}", .{ abs, writeRefusal(e) });
        return;
    };
    try tools.printTo(out, "deleted directory {s}", .{abs});
}

/// The listing sink: append each entry as one line, remembering any append
/// failure (the ListFn callback cannot itself return an error).
const ListSink = struct {
    out: *std.array_list.Managed(u8),
    err: bool = false,
    fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
        const self: *ListSink = @ptrCast(@alignCast(ctx.?));
        const tag = if (e.kind == .dir) "d" else "-";
        tools.printTo(self.out, "{s} {s} ({d} bytes)\n", .{ tag, e.name, e.size }) catch {
            self.err = true;
        };
    }
};

/// List a directory through the VFS.
fn toolListDir(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("list_dir needs path");
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = absPath(&buf, path) orelse return out.appendSlice("path too long");
    var sink = ListSink{ .out = out };
    vfs.list(abs, ListSink.cb, &sink) catch |e| {
        try tools.printTo(out, "cannot list {s}: {s}", .{ abs, @errorName(e) });
        return;
    };
    if (sink.err) return error.OutOfMemory;
    if (out.items.len == 0) try out.appendSlice("(empty)");
}

/// Run a compiled `.kudos` app and report what it printed and returned — the
/// step that closes the agent's loop: it writes a program, has the factory
/// compile it (ARCH-012), then EXECUTES it and reads the answer.
///
/// The image runs in a session of its own (console/apprun.zig), so a module
/// that faults kills that session's task and nothing else (AGT-009) — which is
/// what makes running freshly generated code a reasonable thing to do at all.
fn toolTasks(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    const n = taskstat.snapshotAll();
    try tools.printTo(out, "{d} tasks:\n", .{n});
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const t = taskstat.rowAt(i) orelse break;
        try tools.printTo(out, "  core {d} {s:<16} {s}{s} cpu {d} ms\n", .{
            t.core,
            t.nameSlice(),
            @tagName(t.state),
            if (t.is_current) " (running now)" else "",
            t.cpu_ms,
        });
    }
}

fn toolStopApp(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    if (apprun.stopSpawned(apprun.SPAWN_ID)) {
        try out.appendSlice("asked the detached app to stop; its window closes as it returns");
    } else {
        try out.appendSlice("no detached app is running");
    }
}

fn toolRunWindow(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse return out.appendSlice("run_window needs name");

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        try out.appendSlice("name too long");
        return;
    };
    const blob = vfs.read(path) orelse {
        try tools.printTo(out, "no such compiled app: {s} (compile_app it first)", .{name});
        return;
    };

    apprun.startWindowed(blob) catch |e| {
        try tools.printTo(out, "cannot start {s}: {s}", .{ name, switch (e) {
            error.NoSandbox => "this build has no session address spaces, so a module cannot be contained",
            error.NoSession => "no free session to contain the run",
            error.Busy => "a windowed app is already running (one window at a time; close it first)",
            else => apprun.reason(e),
        } });
        return;
    };
    try tools.printTo(out, "{s} is running detached. It may open its own window (list_windows shows it); " ++
        "it keeps running until that window closes. Its prints go nowhere — a windowed app talks by drawing.", .{name});
}

fn toolRunApp(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse return out.appendSlice("run_app needs name");

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        try out.appendSlice("name too long");
        return;
    };
    const blob = vfs.read(path) orelse {
        try tools.printTo(out, "no such compiled app: {s} (compile_app it first)", .{name});
        return;
    };

    const result = apprun.runContained(blob, apprun.RUN_BUDGET_MS) catch |e| {
        try tools.printTo(out, "cannot run {s}: {s}", .{ name, switch (e) {
            error.NoSandbox => "this build has no session address spaces, so a module cannot be contained",
            error.NoSession => "no free session to contain the run",
            error.Busy => "a previous run has not finished",
            else => apprun.reason(e),
        } });
        return;
    };
    try out.appendSlice(result.output);
    if (result.truncated) try tools.printTo(out, "\n[output truncated at {d} bytes]", .{apprun.MAX_OUTPUT_BYTES});
    if (result.timed_out) {
        try tools.printTo(out, "\n[stopped: still running after {d} s]", .{apprun.RUN_BUDGET_MS / std.time.ms_per_s});
    } else {
        try tools.printTo(out, "\n[exit {d}]", .{result.rc});
    }
}

/// System state: uptime plus every registered counter (the same movers the
/// netdebug `dbg:` stream reports), so the agent can read the machine's health.
fn toolSystemState(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    _ = args_json;
    try tools.printTo(out, "uptime_ms: {d}\ncounters:\n", .{timer.millis()});
    for (counter.all()) |c| {
        try tools.printTo(out, "  {s}.{s} = {d}\n", .{ @tagName(c.mod), c.name, c.v });
    }
}

/// Capture the desktop: arm the same sticky shot flag the KMR1 trigger uses;
/// the GPU session loop writes screenshot.png (ramdisk + stick). The image is
/// pulled out-of-band — the tool result confirms the capture was armed.
fn toolScreenCapture(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    _ = args_json;
    fileserv.requestShot();
    try out.appendSlice("screenshot armed — screenshot.png will be written to the ramdisk and the stick");
}

/// Open an application window (AGT-006 "applications"). The desktop sits above
/// the agent in the layering, so the request is parked in the remote-request
/// inbox and the desktop opens it on its own core (fileserv.takeSpawnRequest).
fn toolOpenApp(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const name = jsonStr(v, "name") orelse return out.appendSlice("open_app needs name");
    fileserv.requestSpawn(name);
    try tools.printTo(out, "requested to open the {s} window", .{name});
}

/// Inject typed text into the focused window, one key at a time, exactly as the
/// keyboard driver delivers real keystrokes (the agent driving the UI).
fn toolInjectText(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const text = jsonStr(v, "text") orelse return out.appendSlice("inject_text needs text");
    // Keystrokes go where focus is, so a named window is focused FIRST — the
    // alternative is typing a command into whatever happened to be in front,
    // which is how a remote injector loses a line into the wrong terminal.
    if (jsonStr(v, "window")) |w| {
        if (w.len != 0) {
            if (!idesk.postAction(.focus, w)) {
                try out.appendSlice("the desktop has not applied the last window request yet — try again");
                return;
            }
            try tools.printTo(out, "focused '{s}'; ", .{w});
        }
    }
    for (text) |ch| _ = keyboard.inject(.{ .ascii = ch, .key = .none });
    try tools.printTo(out, "injected {d} characters", .{text.len});
}


/// An integer argument, or `dflt` when absent or not a number. The model writes
/// JSON, and a coordinate it phrased as a string is still a coordinate.
fn jsonInt(v: std.json.Value, key: []const u8, dflt: i64) i64 {
    const x = v.object.get(key) orelse return dflt;
    return switch (x) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |t| std.fmt.parseInt(i64, t, 10) catch dflt,
        else => dflt,
    };
}

/// `list_windows` — what is on the desktop right now, as the desktop last
/// published it (AGT-024). The agent has no screen; this is how it looks.
fn toolListWindows(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    const text = idesk.windows();
    if (text.len == 0) {
        try out.appendSlice("no windows are open (or the desktop has not drawn yet)");
        return;
    }
    try out.appendSlice("windows (* = focused, keystrokes land there):\n");
    try out.appendSlice(text);
}

/// `window` — do to a window what a person does with the title bar and the dock
/// (AGT-023). The desktop owns the window list and applies this on its own core,
/// so the answer here is that the request was taken, not that it has happened.
fn toolWindow(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const action_name = jsonStr(v, "action") orelse return out.appendSlice("window needs action");
    const window = jsonStr(v, "window") orelse "";
    const action: idesk.Action = if (std.mem.eql(u8, action_name, "focus"))
        .focus
    else if (std.mem.eql(u8, action_name, "maximise") or std.mem.eql(u8, action_name, "maximize"))
        .maximise
    else if (std.mem.eql(u8, action_name, "minimise") or std.mem.eql(u8, action_name, "minimize"))
        .minimise
    else if (std.mem.eql(u8, action_name, "restore"))
        .restore
    else if (std.mem.eql(u8, action_name, "close"))
        .close
    else
        return tools.printTo(out, "no such window action: {s} (focus, maximise, minimise, restore, close)", .{action_name});
    if (!idesk.postAction(action, window)) {
        try out.appendSlice("the desktop has not applied the last window request yet — try again");
        return;
    }
    if (window.len == 0) {
        try tools.printTo(out, "asked the desktop to {s} the focused window", .{action_name});
    } else {
        try tools.printTo(out, "asked the desktop to {s} the window matching '{s}'", .{ action_name, window });
    }
}

/// `pointer` — put the pointer somewhere and press a button, through the one
/// producer path every real mouse event takes (imouse.inject). Absolute, so it
/// bypasses the acceleration curve: the agent means the pixel it names.
fn toolPointer(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const x = jsonInt(v, "x", -1);
    const y = jsonInt(v, "y", -1);
    if (x < 0 or y < 0) return out.appendSlice("pointer needs x and y (screen pixels, 0,0 top left)");
    const button = jsonStr(v, "button") orelse "none";
    const mask: u8 = if (std.mem.eql(u8, button, "left"))
        1
    else if (std.mem.eql(u8, button, "right"))
        2
    else if (std.mem.eql(u8, button, "middle"))
        4
    else
        0;
    const px: i32 = @intCast(x);
    const py: i32 = @intCast(y);
    // Move first with no button, then the press, then the release: that is the
    // event sequence a hand produces, and the compositor is edge-triggered on
    // the transitions — a position and a press in one event is a click whose
    // press the desktop never saw arrive anywhere.
    imouse.inject(.{ .dx = 0, .dy = 0, .abs = .{ .x = px, .y = py }, .buttons = 0 });
    if (mask != 0) {
        imouse.inject(.{ .dx = 0, .dy = 0, .abs = .{ .x = px, .y = py }, .buttons = mask });
        imouse.inject(.{ .dx = 0, .dy = 0, .abs = .{ .x = px, .y = py }, .buttons = 0 });
        try tools.printTo(out, "moved the pointer to {d},{d} and clicked {s}", .{ x, y, button });
    } else {
        try tools.printTo(out, "moved the pointer to {d},{d}", .{ x, y });
    }
}

/// `dashboard` — the numbers the F1 display is showing, from the sample it drew
/// (AGT-024). Not a second sampler: the desktop publishes what it drew, so the
/// agent and the screen can never disagree.
fn toolDashboard(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    const text = idesk.dashboard();
    if (text.len == 0) {
        try out.appendSlice("the heads-up display has not sampled yet (no desktop on this build?)");
        return;
    }
    try out.appendSlice(text);
}

const registry = tools.Registry{ .tools = &.{
    .{ .name = "compile_app", .description = "Compile a single Zig .kudos app source and save it so it can be run.", .params_schema = COMPILE_SCHEMA, .handler = toolCompile },
    .{ .name = "run_app", .description = "Run a compiled .kudos app and return everything it printed plus its exit code.", .params_schema = NAME_SCHEMA, .handler = toolRunApp },
    .{ .name = "run_window", .description = "Run a compiled .kudos app DETACHED with permission to open its own window(s); it keeps running until they close. For apps whose answer is what they draw, not what they print.", .params_schema = NAME_SCHEMA, .handler = toolRunWindow },
    .{ .name = "stop_app", .description = "Stop the detached app started by run_window.", .params_schema = NONE_SCHEMA, .handler = toolStopApp },
    .{ .name = "tasks", .description = "List what the machine is running: every task, its core, state and CPU time.", .params_schema = NONE_SCHEMA, .handler = toolTasks },
    .{ .name = "read_file", .description = "Read a file. path is absolute (/ramdisk/motd.txt, /usbdisk/AI.CFG) or relative to /ramdisk.", .params_schema = PATH_SCHEMA, .handler = toolReadFile },
    .{ .name = "write_file", .description = "Create or replace a file under /ramdisk, making any directories its path names.", .params_schema = WRITE_SCHEMA, .handler = toolWriteFile },
    .{ .name = "delete_file", .description = "Delete a file under /ramdisk.", .params_schema = PATH_SCHEMA, .handler = toolDeleteFile },
    .{ .name = "make_dir", .description = "Create a directory under /ramdisk.", .params_schema = PATH_SCHEMA, .handler = toolMakeDir },
    .{ .name = "delete_dir", .description = "Delete a directory under /ramdisk. It must be empty.", .params_schema = PATH_SCHEMA, .handler = toolDeleteDir },
    .{ .name = "list_dir", .description = "List a directory (/ lists the mounted volumes; entries are marked d for directory).", .params_schema = PATH_SCHEMA, .handler = toolListDir },
    .{ .name = "system_state", .description = "Report system state: uptime and every registered counter (USB, net, GPU, ...).", .params_schema = NONE_SCHEMA, .handler = toolSystemState },
    .{ .name = "screen_capture", .description = "Capture the desktop to screenshot.png (ramdisk + USB stick).", .params_schema = NONE_SCHEMA, .handler = toolScreenCapture },
    .{ .name = "open_app", .description = "Open an application window: ai, term, system, clock, or calc.", .params_schema = NAME_SCHEMA, .handler = toolOpenApp },
    .{ .name = "inject_text", .description = "Type text as if entered on the keyboard. Give `window` to focus that window first (its title, or part of it); otherwise it goes to whatever has focus. Use \\n to press Enter.", .params_schema = TEXT_SCHEMA, .handler = toolInjectText },
    .{ .name = "list_windows", .description = "List the desktop's windows: title, size, position, which one has focus (*), which are in the dock.", .params_schema = NONE_SCHEMA, .handler = toolListWindows },
    .{ .name = "window", .description = "Act on a window as a person would: focus, maximise, minimise, restore or close it. `window` names it by part of its title; omit it to act on the focused one.", .params_schema = WINDOW_SCHEMA, .handler = toolWindow },
    .{ .name = "pointer", .description = "Move the pointer to a screen pixel and optionally click (left, right, middle).", .params_schema = POINTER_SCHEMA, .handler = toolPointer },
    .{ .name = "dashboard", .description = "Read the F1 heads-up display: cores and their load, memory and heap, frame rate and present timing, network, USB, guests.", .params_schema = NONE_SCHEMA, .handler = toolDashboard },
    .{ .name = "compile_feature", .description = "Compile a single Zig .kudos feature source (register(api) entry) and save it for load_feature.", .params_schema = COMPILE_SCHEMA, .handler = toolCompileFeature },
    .{ .name = "load_feature", .description = "Hot-load a compiled feature .kudos into the running kernel; its register(api) runs and may register commands.", .params_schema = NAME_SCHEMA, .handler = toolLoadFeature },
    .{ .name = "invoke_command", .description = "Run a command registered by a loaded feature and return its output.", .params_schema = INVOKE_SCHEMA, .handler = toolInvokeCommand },
    .{ .name = "list_modules", .description = "List compiled .kudos modules and the commands loaded features registered.", .params_schema = NONE_SCHEMA, .handler = toolListModules },
    .{ .name = "list_sources", .description = "List the module sources previously built (JSON: name, kind, bytes).", .params_schema = NONE_SCHEMA, .handler = toolListSources },
    .{ .name = "read_source", .description = "Read one previously built module's Zig source.", .params_schema = NAME_SCHEMA, .handler = toolReadSource },
    .{ .name = "read_abi", .description = "Read the .kudos ABI contract (abi.zig): the Api/FeatureApi every module is written against.", .params_schema = NONE_SCHEMA, .handler = toolReadAbi },
} };

// ── MCP server over netdebug (AGT-011 / AGT-013) ──────────────────────────────
//
// The SAME tool registry the LLM calls is served to external MCP clients: one
// JSON-RPC request in (over the KMR1 OP_MCP op), the response written to the
// ramdisk for the client to pull. Defined once — the registry is the single
// source of truth for what kudos can do, whether the caller is the model or a
// remote MCP client.
var mcp_ctx: u8 = 0;

fn mcpServe(body: []const u8) void {
    const resp = mcp.handle(heap.allocator(), registry, &mcp_ctx, body) catch |e| {
        logMcp("mcp.handle failed: {s}", .{@errorName(e)});
        return;
    };
    defer heap.allocator().free(resp);
    const rd = iramdisk.instance orelse return;
    rd.put(fileproto.MCP_RESPONSE_FILE, resp) catch |e|
        logMcp("mcp response write failed: {s}", .{@errorName(e)});
}

fn logMcp(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "ai: " ++ fmt ++ "\n", args)) |s| ilog.puts(s) else |_| {}
}

/// Wire the MCP-over-netdebug server, once at boot (main_root.zig). Makes kudos an
/// MCP server whenever the network is up — independent of whether a user has
/// opened the agent console.
pub fn initMcpServer() void {
    fileserv.setMcpHandler(mcpServe);
}

// ── MCP client: federate an external MCP server's tools (AGT-014/015/016) ──────
//
// When AI.CFG names an `mcp` endpoint, the agent binds to it: it lists the
// server's tools once and offers them to the model alongside its own, and
// routes a call to one of them back out to that server. kudos is thus an MCP
// server (above) and an MCP client at the same time (AGT-016).
var g_mcp_url_buf: [192]u8 = undefined;
var g_mcp_url_len: usize = 0;
var g_remote_arena: ?std.heap.ArenaAllocator = null;
var g_remote_tools: []const mcp.RemoteTool = &.{};

fn remoteMcpUrl() ?[]const u8 {
    return if (g_mcp_url_len != 0) g_mcp_url_buf[0..g_mcp_url_len] else null;
}

/// POST one JSON-RPC message to the bound MCP server and return the response
/// body (caller frees). The same inet.post seam the LLM chat rides.
fn remoteMcpPost(alloc: std.mem.Allocator, request: []const u8) ![]u8 {
    const url = remoteMcpUrl() orelse return error.NoMcpServer;
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
    if (remoteMcpUrl() == null) return;

    const req = mcp.buildRequest(heap.allocator(), 1, "tools/list", "{}") catch return;
    defer heap.allocator().free(req);
    const resp = remoteMcpPost(heap.allocator(), req) catch |e| {
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

/// The tool set offered to the model: the local registry plus any federated
/// remote tools (AGT-015). Splices the remote tools into the local array.
pub fn mergedToolsJson(alloc: std.mem.Allocator) ![]u8 {
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
fn isRemoteTool(name: []const u8) bool {
    for (g_remote_tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// Route a call to a federated tool back to the bound MCP server (AGT-014) and

/// Route a call to a federated tool back to the bound MCP server (AGT-014) and
/// append its text result.
fn callRemoteTool(name: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    const req = try mcp.buildToolCall(heap.allocator(), 2, name, args_json);
    defer heap.allocator().free(req);
    const resp = remoteMcpPost(heap.allocator(), req) catch |e| {
        try tools.printTo(out, "remote tool '{s}' failed: {s}", .{ name, @errorName(e) });
        return;
    };
    defer heap.allocator().free(resp);
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const text = mcp.parseToolCallText(arena.allocator(), resp) catch "";
    try out.appendSlice(text);
}

/// Where tool activity is announced as it happens, so a user watching the
/// console sees WHAT the agent is doing while it does it. The console sets it;
/// null means nobody is watching and the tools still run.
pub var announce: ?*const fn (text: []const u8) void = null;

/// Run one tool call for the agent loop (`loop.Tools.invoke`).
pub fn invoke(ctx: *anyopaque, name: []const u8, args: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    // Echo the tool activity to the terminal, Claude-Code style, then run it.
    if (announce) |say| {
        say("\n\xe2\x97\x8f "); // "● "
        say(name);
        say("\n");
    }
    // A federated remote tool routes back out to its MCP server (AGT-014);
    // everything else is a local tool.
    if (isRemoteTool(name)) return callRemoteTool(name, args, out);
    try registry.dispatch(ctx, name, args, out);
}

