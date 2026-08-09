//! `ai` / `ai <prompt>` — the kudos agent console.
//!
//! A Claude-Code-style surface: type a natural-language prompt and the agent
//! streams a reply, calling tools (compile an app, ...) inline as it works; or
//! type a `/command` for a session action. Runs on core 0 (it needs the
//! network). The conversation persists across invocations — this is the one
//! on-demand agent (spec AGT-001), reset with `/reset`.
//!
//! Transport: chat streams DIRECTLY from the LLM service over the in-kernel
//! HTTPS stack (inet.postStream, TLS 1.3 + CA verification — AGT-003/AGT-005),
//! authorised by the AI.CFG credential (AGT-004). The LAN factory relay serves
//! ONLY compile and source requests — the compiler stays off-target (ARCH-012).

const std = @import("std");
const console = @import("../console.zig");
const aiconsole = @import("../../agent/aiconsole.zig");
const loop = @import("../../agent/loop.zig");
const tools = @import("../../agent/tools.zig");
const prompt = @import("../../agent/prompt.zig");
const config = @import("../../agent/config.zig");
const credential = @import("../../agent/credential.zig");
const buildinfo = @import("buildinfo");
const openrouter = @import("../../agent/openrouter.zig");
const abi = @import("abi");
const inet = @import("inet");
const iramdisk = @import("iramdisk");
const vfs = @import("vfs");
const heap = @import("../../kernel/memory/heap.zig");
const timer = @import("../../kernel/timer/timer.zig");
const hotload = @import("../../kernel/loader/hotload.zig");
const ifilesys = @import("ifilesys");
const keyboard = @import("../../drivers/input/keyboard.zig");
const fileserv = @import("../../drivers/net/debug/fileserv.zig");
const fileproto = @import("fileproto");
const mcp = @import("../../agent/mcp.zig");
const ilog = @import("ilog");
const klog = @import("../../kernel/debug/klog.zig");
const counter = @import("../../kernel/debug/counter.zig");
const features = hotload.features;

const CFG_PATH = "/usbdisk/AI.CFG";
const DEFAULT_MODEL = "moonshotai/kimi-k3";
const HISTORY_TURNS = 32;
/// Cap on the feature output captured into one tool result — a chatty feature
/// must not burn the request's token budget. Overflow is truncated LOUDLY.
const MAX_TOOL_OUTPUT_BYTES: usize = 8 * 1024;

// The one persistent conversation and its live model choice.
var g_history: ?loop.history.History = null;
var g_model_buf: [96]u8 = undefined;
var g_model_len: usize = 0;

fn model() []const u8 {
    return if (g_model_len != 0) g_model_buf[0..g_model_len] else DEFAULT_MODEL;
}

/// Copy `src` into the fixed buffer `dst`, truncated to its capacity, and
/// record the stored length in `len` — the one owner of the bounded
/// copy-into-global every AI.CFG-derived setting uses.
fn setBuf(dst: []u8, len: *usize, src: []const u8) void {
    const n = @min(src.len, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

fn setModel(name: []const u8) void {
    setBuf(&g_model_buf, &g_model_len, name);
}

fn history() *loop.history.History {
    if (g_history == null) {
        g_history = loop.history.History.init(heap.allocator(), HISTORY_TURNS);
        // A dropped system prompt would run the agent unguided — leave a trace.
        g_history.?.setSystem(prompt.SYSTEM) catch {
            klog.puts("ai: system prompt dropped (OutOfMemory)\n");
        };
    }
    return &g_history.?;
}

// ── transport (loop.Chat): stream the request straight to the LLM service ─────

// The LLM chat endpoint: AI.CFG `url=` when set, else the OpenRouter default
// (AGT-003). Chat rides the kernel HTTPS stack; only compile and source
// requests go to the LAN factory below.
var g_llm_buf: [160]u8 = undefined;
var g_llm_len: usize = 0;

fn llmUrl() []const u8 {
    return if (g_llm_len != 0) g_llm_buf[0..g_llm_len] else openrouter.CHAT_COMPLETIONS_URL;
}

/// loop.Chat transport: POST the request to the LLM service over HTTPS and
/// stream the response body into `sink` as it arrives (AGT-003/AGT-005), with
/// the credential on every request (AGT-004).
fn chatSend(_: *anyopaque, request: []const u8, sink: inet.BodySink) anyerror!void {
    const n = inet.instance orelse return error.NoNetwork;
    if (!credential.isUnlocked()) return error.NoApiKey;
    const hdrs = [_]inet.Header{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Authorization", .value = credential.authorization() },
    };
    try n.postStream(heap.allocator(), llmUrl(), &hdrs, request, sink);
}

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

fn setEndpoints(factory: []const u8) void {
    setBuf(&g_ep.host, &g_ep.host_len, factory);
    const ep = std.fmt.bufPrint(&g_ep.compile, "http://{s}/compile", .{factory}) catch {
        g_ep.compile_len = 0;
        return;
    };
    g_ep.compile_len = ep.len;
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

fn compileKind(comptime kind: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const aa = arena.allocator();
    const v = (try parseToolArgs(aa, args_json, out)) orelse return;
    const name = jsonStr(v, "name");
    const source = jsonStr(v, "source");
    if (name == null or source == null) {
        try out.appendSlice("compile needs name and source");
        return;
    }
    if (g_ep.host_len == 0) {
        try out.appendSlice("no compile factory configured — set `factory=<host:port>` in " ++ CFG_PATH);
        return;
    }

    var req = std.array_list.Managed(u8).init(aa);
    try tools.printTo(&req, "{{\"abi_version\":{d},\"kind\":\"" ++ kind ++ "\",\"name\":\"{s}\",\"source\":", .{ abi.ABI_VERSION, name.? });
    {
        const j = try std.json.Stringify.valueAlloc(aa, source.?, .{});
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
        const fname = std.fmt.bufPrint(&fbuf, "{s}.kudos", .{name.?}) catch return;
        // The success line below promises a loadable file; a failed save must
        // surface as the failure it is, never ride under that promise.
        const rd = iramdisk.instance orelse {
            try tools.printTo(out, "compiled {s}.kudos but no ramdisk is up — nothing was saved", .{name.?});
            return;
        };
        rd.put(fname, resp) catch |e| {
            try tools.printTo(out, "compiled {s}.kudos but saving it failed ({s})", .{ name.?, @errorName(e) });
            return;
        };
        if (comptime std.mem.eql(u8, kind, "feature")) {
            try tools.printTo(out, "compiled feature {s}.kudos ({d} bytes). Hot-load it with the load_feature tool.", .{ name.?, resp.len });
        } else {
            try tools.printTo(out, "compiled {s}.kudos ({d} bytes). Run it in a terminal with: run {s}", .{ name.?, resp.len, name.? });
        }
    } else {
        try out.appendSlice("the compiler rejected the code:\n");
        try out.appendSlice(resp);
    }
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

    const rc = hotload.registerBlob(blob, image, captureSink()) catch |e| {
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
    \\{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}
;

/// Read a file through the VFS (any mounted volume; the model passes an
/// absolute path like /ramdisk/motd.txt or /usbdisk/AI.CFG).
fn toolReadFile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("read_file needs path");
    const body = vfs.read(path) orelse {
        try tools.printTo(out, "no such file: {s}", .{path});
        return;
    };
    // A binary or huge file must not blow the token budget; truncate loudly.
    const shown = @min(body.len, MAX_TOOL_OUTPUT_BYTES);
    try out.appendSlice(body[0..shown]);
    if (shown < body.len) try tools.printTo(out, "\n[truncated {d} of {d} bytes]", .{ shown, body.len });
}

/// Write a file into the ramdisk (the writable volume; agent-authored data and
/// notes live there, same as compiled modules).
fn toolWriteFile(_: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(heap.allocator());
    defer arena.deinit();
    const v = (try parseToolArgs(arena.allocator(), args_json, out)) orelse return;
    const path = jsonStr(v, "path") orelse return out.appendSlice("write_file needs path");
    const content = jsonStr(v, "content") orelse return out.appendSlice("write_file needs content");
    const rd = iramdisk.instance orelse return out.appendSlice("ramdisk unavailable");
    // The ramdisk is a flat name→bytes store; strip a leading /ramdisk/ so the
    // model may pass either form.
    const name = if (std.mem.startsWith(u8, path, "/ramdisk/")) path["/ramdisk/".len..] else path;
    rd.put(name, content) catch |e| {
        try tools.printTo(out, "write failed: {s}", .{@errorName(e)});
        return;
    };
    try tools.printTo(out, "wrote {d} bytes to /ramdisk/{s}", .{ content.len, name });
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
    var sink = ListSink{ .out = out };
    vfs.list(path, ListSink.cb, &sink) catch |e| {
        try tools.printTo(out, "cannot list {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    if (sink.err) return error.OutOfMemory;
    if (out.items.len == 0) try out.appendSlice("(empty)");
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
    for (text) |ch| _ = keyboard.inject(.{ .ascii = ch, .key = .none });
    try tools.printTo(out, "injected {d} characters", .{text.len});
}

const registry = tools.Registry{ .tools = &.{
    .{ .name = "compile_app", .description = "Compile a single Zig .kudos app source and save it so the user can run it.", .params_schema = COMPILE_SCHEMA, .handler = toolCompile },
    .{ .name = "read_file", .description = "Read a file from the virtual file system by absolute path (e.g. /ramdisk/motd.txt, /usbdisk/AI.CFG).", .params_schema = PATH_SCHEMA, .handler = toolReadFile },
    .{ .name = "write_file", .description = "Write a file into the ramdisk. path may be a bare name or /ramdisk/<name>.", .params_schema = WRITE_SCHEMA, .handler = toolWriteFile },
    .{ .name = "list_dir", .description = "List a virtual-file-system directory by absolute path (/ lists the mounted volumes).", .params_schema = PATH_SCHEMA, .handler = toolListDir },
    .{ .name = "system_state", .description = "Report system state: uptime and every registered counter (USB, net, GPU, ...).", .params_schema = NONE_SCHEMA, .handler = toolSystemState },
    .{ .name = "screen_capture", .description = "Capture the desktop to screenshot.png (ramdisk + USB stick).", .params_schema = NONE_SCHEMA, .handler = toolScreenCapture },
    .{ .name = "open_app", .description = "Open an application window: ai, term, system, clock, or calc.", .params_schema = NAME_SCHEMA, .handler = toolOpenApp },
    .{ .name = "inject_text", .description = "Type text into the focused window as if entered on the keyboard.", .params_schema = TEXT_SCHEMA, .handler = toolInjectText },
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
fn discoverRemoteTools() void {
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
fn mergedToolsJson(alloc: std.mem.Allocator) ![]u8 {
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

fn toolsInvoke(ctx: *anyopaque, name: []const u8, args: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    // Echo the tool activity to the terminal, Claude-Code style, then run it.
    if (g_console) |c| {
        c.write("\n\xe2\x97\x8f "); // "● "
        c.write(name);
        c.write("\n");
    }
    // A federated remote tool routes back out to its MCP server (AGT-014);
    // everything else is a local tool.
    if (isRemoteTool(name)) return callRemoteTool(name, args, out);
    try registry.dispatch(ctx, name, args, out);
}

// ── output sink (loop.Sink): stream assistant text to the terminal ────────────
// The console of the LAST `ai` invocation (a Console is a value; its contexts
// live as long as the hosting window). Static because the loop's sink and the
// tool-activity echo both fire from callbacks with no per-call state.
var g_console: ?console.Console = null;

fn sinkWrite(_: *anyopaque, text: []const u8) void {
    if (g_console) |c| c.write(text);
}

// ── clock (loop.Clock): the budget's wall-time source ─────────────────────────
fn clockMillis(_: *anyopaque) u64 {
    return timer.millis();
}
var g_clock_ctx: u8 = 0;

// The loop contracts (Chat/Tools/Sink) want a context, but every callback here
// reaches its console through g_console (chatSend needs none at all) — same
// dummy-context pattern as g_clock_ctx.
var g_loop_ctx: u8 = 0;

// ── slash commands ────────────────────────────────────────────────────────────
fn cmdHelp(c: console.Console) void {
    c.write(
        \\ai — the kudos agent
        \\  <prompt>        talk to the agent (it writes, compiles, hot-loads
        \\                  and exercises apps & features)
        \\  /improve [focus] budgeted self-improvement run: build, load & try
        \\                  one new feature (optionally about <focus>)
        \\  /login [pass]   decrypt the service credential (asks if given
        \\                  no passphrase); required once per boot before chat
        \\  /help           this help
        \\  /reset          clear the conversation
        \\  /status         model, endpoints, network, ABI
        \\  /apps           list compiled .kudos apps
        \\  /model <name>   switch the model
        \\  /clear          clear the screen
        \\  /quit           close the agent window (agent window only)
        \\Then run a compiled app in a terminal:  run <name>
        \\
    );
}

fn cmdStatus(c: console.Console) void {
    var buf: [640]u8 = undefined;
    const up = if (inet.instance) |n| n.isUp() else false;
    const lim = loop.budget.Limits{};
    const imp = loop.budget.IMPROVE_LIMITS;
    c.write(std.fmt.bufPrint(&buf, "model:   {s}\nllm:     {s}\nkey:     {s}\nfactory: {s}\nnetwork: {s}\nABI:     v{d}\nbudget:  chat: {d} turns, {d} tool calls, {d} tokens, {d} s\n         improve: {d} turns, {d} tool calls, {d} tokens, {d} s\n", .{
        model(),
        llmUrl(),
        switch (credential.from()) {
            .sealed => "sealed into this build (AGT-017)",
            .cfg_file => "from " ++ CFG_PATH,
            .none => "MISSING — /login to decrypt, or set key= in " ++ CFG_PATH,
        },
        if (g_ep.host_len != 0) g_ep.host[0..g_ep.host_len] else "(set factory= in " ++ CFG_PATH ++ ")",
        if (up) "up" else "down",
        abi.ABI_VERSION,
        lim.max_turns,
        lim.max_tool_calls,
        lim.max_tokens,
        lim.max_ms / std.time.ms_per_s,
        imp.max_turns,
        imp.max_tool_calls,
        imp.max_tokens,
        imp.max_ms / std.time.ms_per_s,
    }) catch "");
}

fn cmdApps(c: console.Console) void {
    const rd = iramdisk.instance orelse {
        c.write("(no ramdisk)\n");
        return;
    };
    var count: usize = 0;
    var i: usize = 0;
    const n = rd.count();
    while (i < n) : (i += 1) {
        const e = rd.at(i);
        if (std.mem.endsWith(u8, e.name, ".kudos")) {
            c.write("  ");
            c.write(e.name);
            c.write("\n");
            count += 1;
        }
    }
    if (count == 0) c.write("(no compiled apps yet — ask me to build one)\n");
}

fn loadConfig() config.Config {
    const text = vfs.read(CFG_PATH) orelse return .{};
    return config.parse(text);
}

/// `/login` was typed with no passphrase and one was asked for: the NEXT line
/// is that passphrase, not a prompt for the model.
var g_awaiting_passphrase: bool = false;

/// The greeting an agent session opens with (AGT-018). It names the two things
/// a first-time user needs — where the commands are, and that the credential
/// starts encrypted — because the session opens straight into its conversation
/// and there is nowhere else to learn them.
fn banner() []const u8 {
    return if (credential.isSealedIntoBuild())
        \\kudos agent — /help for commands, /quit to leave
        \\the service credential is encrypted; /login to decrypt it
        \\
        \\
    else
        \\kudos agent — /help for commands, /quit to leave
        \\
        \\
    ;
}

/// What to say when a chat is attempted with no usable credential — the two
/// cases need opposite actions from the user.
fn lockedMessage() []const u8 {
    return if (credential.isSealedIntoBuild())
        "the service credential is encrypted — decrypt it first:\n\n    /login <passphrase>\n\n"
    else
        "no credential: seal one into the build (scripts/agent/sealkey.sh) or set key= in " ++ CFG_PATH ++ "\n";
}

/// `ai ...` — the shell command entry (core-0 table).
pub fn run(c: console.Console, args: []const u8) void {
    g_console = c;
    const cfg = loadConfig();
    if (cfg.factory) |f| setEndpoints(f);
    // An unattended build may open its own seal; otherwise the credential waits
    // for `/login`. Either way a stick that carries its own `key=` overrides it
    // below — whoever plugged the stick in is the later decision.
    if (credential.from() == .none) credential.tryBakedPassphrase();
    if (cfg.api_key) |k| {
        credential.useConfigKey(k);
    }
    if (cfg.url) |u| setBuf(&g_llm_buf, &g_llm_len, u);
    if (cfg.model) |m| if (g_model_len == 0) setModel(m);
    if (cfg.mcp) |u| setBuf(&g_mcp_url_buf, &g_mcp_url_len, u);
    if (cfg.token) |tk| setBuf(&g_token_buf, &g_token_len, tk);

    // A `/login` with no passphrase asked for one; this line IS the answer, so
    // it is taken verbatim before any parsing — a passphrase may begin with `/`
    // or look like anything else, and the console must not interpret it.
    if (g_awaiting_passphrase) {
        g_awaiting_passphrase = false;
        c.write(credential.unlock(std.mem.trim(u8, args, " \t\r\n")));
        return;
    }

    const input = aiconsole.parse(args);
    // Refuse what SPENDS the credential while it is still encrypted, and say
    // what to do about it (AGT-022). Session commands still run — /login
    // especially — and so does OPENING a session, which is where /login is typed.
    if (aiconsole.gate(input, credential.isUnlocked()) == .locked) return c.write(lockedMessage());

    switch (input) {
        .login => |pass| {
            if (pass.len == 0) {
                // Ask, rather than fail: `/login` on its own is the natural way
                // to type it, and answering "usage:" to that is a shell being
                // pedantic at somebody who did the obvious thing.
                g_awaiting_passphrase = true;
                c.write("passphrase: ");
            } else {
                c.write(credential.unlock(pass));
            }
            return;
        },
        .help => return cmdHelp(c),
        .status => return cmdStatus(c),
        .apps => return cmdApps(c),
        .clear => {
            c.clear();
            return;
        },
        .reset => {
            if (g_history) |*h| h.deinit();
            g_history = null;
            c.write("conversation reset\n");
            return;
        },
        .model => |m| {
            if (m.len == 0) {
                c.write("model: ");
                c.write(model());
                c.write("\n");
            } else {
                setModel(m);
                c.write("model set\n");
            }
            return;
        },
        .quit => {
            // Leave the conversation and hand the terminal back to the shell —
            // the counterpart of `ai`, and what a user who typed `ai` expects
            // to undo. Closing the window instead would take the shell with it.
            if (c.ai_mode) {
                c.setAiMode(false);
                c.write("left the agent — back to the shell\n");
            } else {
                c.write("not in an agent session; type `ai` to start one\n");
            }
            return;
        },
        .unknown => |w| {
            c.write("unknown command ");
            c.write(w);
            c.write(" — try /help\n");
            return;
        },
        .prompt => |p| {
            if (p.len == 0) {
                // `ai` on its own means "talk to the agent", so THIS terminal
                // becomes the conversation — the way running a chat client in a
                // shell does. Opening a second window instead would leave the
                // user looking at the terminal they just typed into.
                if (c.ai_mode) return; // already in it; a blank line is a blank line
                c.setAiMode(true);
                c.write(banner());
                // Sealed and nobody has opened it yet: ask right here. Entering
                // the session and THEN being told to type /login is a step the
                // user has to discover; asking is the same information offered
                // at the moment it is needed.
                if (!credential.isUnlocked() and credential.isSealedIntoBuild()) {
                    g_awaiting_passphrase = true;
                    c.write("passphrase: ");
                }
                return;
            }
            // The standing conversation, at the default per-request budget.
            runLoop(c, history(), p, .{});
        },
        .improve => |focus| {
            // A self-improvement run is isolated: a fresh conversation with the
            // improve system prompt and a wider stated budget, so it neither
            // pollutes the standing chat nor silently borrows its budget.
            var hist = loop.history.History.init(heap.allocator(), HISTORY_TURNS);
            defer hist.deinit();
            hist.setSystem(prompt.IMPROVE_SYSTEM) catch {
                c.write("out of memory — /improve aborted\n");
                return;
            };
            var pbuf: [128]u8 = undefined;
            const p = if (focus.len == 0)
                "Improve kudos."
            else
                std.fmt.bufPrint(&pbuf, "Improve kudos: {s}", .{focus}) catch "Improve kudos.";
            runLoop(c, &hist, p, loop.budget.IMPROVE_LIMITS);
        },
    }
}

/// Drive one budgeted agent run over `hist` with the given limits, streaming to
/// the terminal. Shared by a chat prompt and an `/improve` session.
fn runLoop(c: console.Console, hist: *loop.history.History, p: []const u8, limits: loop.budget.Limits) void {
    if (!credential.isUnlocked()) {
        c.write("no API key — set `key=<LLM service key>` in " ++ CFG_PATH ++ "\n");
        return;
    }
    const arena_alloc = heap.allocator();
    // Bind the external MCP server (if any) once per turn, then offer the model
    // the local tools plus the federated remote ones.
    discoverRemoteTools();
    const tj = mergedToolsJson(arena_alloc) catch {
        c.write("out of memory\n");
        return;
    };
    defer arena_alloc.free(tj);

    const chat = loop.Chat{ .ctx = &g_loop_ctx, .send = chatSend };
    const tool_iface = loop.Tools{ .ctx = &g_loop_ctx, .invoke = toolsInvoke };
    const sink = loop.Sink{ .ctx = &g_loop_ctx, .write = sinkWrite };
    const clock = loop.Clock{ .ctx = &g_clock_ctx, .millis = clockMillis };
    loop.run(arena_alloc, chat, tool_iface, sink, clock, hist, p, .{ .model = model(), .tools_json = tj, .limits = limits }) catch |e| {
        c.write("\nagent error: ");
        c.write(@errorName(e));
        c.write("\n");
        return;
    };
    c.write("\n");
}
