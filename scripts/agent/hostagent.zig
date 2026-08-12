//! Host driver that runs the REAL agent loop end-to-end on the development
//! machine: the agent's `loop.run` wired to a real HTTP chat transport (pointed
//! at a stub OpenRouter) and a real tool registry — compile via the real
//! factory over HTTP, run/load/invoke via the real kernel loader and hot-load
//! core, sources read back from the factory workspace. It differs from the
//! kernel only in the transports (host HTTP vs in-kernel HTTPS) and the
//! executable-memory source (mmap vs the kernel heap). This is the laptop
//! proof that the whole self-improvement cycle composes.
//!
//! Usage: hostagent <openrouter_url> <factory_base_url> <prompt...>

const std = @import("std");
const inet = @import("inet");
const ifilesys = @import("ifilesys");
const ramdisk = @import("ramdisk");
const vfs = @import("vfs");
const loop = @import("loop");
const agent_tools = loop.tools;
const prompt = @import("prompt");
const hotload = @import("hotload");
const runner = hotload.runner;
const abi = runner.abi;

const Agent = struct {
    alloc: std.mem.Allocator,
    http: *std.http.Client,
    openrouter_url: []const u8,
    factory_base: []const u8,
    // Blobs produced by the compile tools, keyed by name, for run/load tools.
    blobs: std.StringHashMap([]u8),
    // Scratch captured from a running app's api.print.
    run_out: std.array_list.Managed(u8),
    arena: []u8,
    used: usize = 0,
    rng: u64 = 0x9e3779b97f4a7c15,

    fn post(self: *Agent, url: []const u8, body: []const u8, out: *std.array_list.Managed(u8)) !std.http.Status {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .response_writer = &aw.writer,
        });
        try out.appendSlice(aw.written());
        return res.status;
    }

    fn get(self: *Agent, url: []const u8, out: *std.array_list.Managed(u8)) !std.http.Status {
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        const res = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
        });
        try out.appendSlice(aw.written());
        return res.status;
    }

    // ── loop.Chat ────────────────────────────────────────────────────────────
    fn chatSend(ctx: *anyopaque, request: []const u8, sink: inet.BodySink) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        // The kernel streams the HTTPS response body straight into the sink; here
        // the stub OpenRouter answers over plain HTTP, so post into a buffer and
        // hand the whole body to the sink — loop's SSE parser is chunk-agnostic.
        var body = std.array_list.Managed(u8).init(self.alloc);
        defer body.deinit();
        const st = try self.post(self.openrouter_url, request, &body);
        if (st != .ok) return error.ChatHttp;
        _ = sink.write(sink.ctx, body.items);
    }

    // ── tools: compile_app / compile_feature ({name, source}) ─────────────────
    fn compileKind(self: *Agent, kind: []const u8, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        const source = parsed.object.get("source").?.string;

        // Build the factory request.
        var reqbuf = std.array_list.Managed(u8).init(a.allocator());
        try agent_tools.printTo(&reqbuf, "{{\"abi_version\":{d},\"kind\":\"{s}\",\"name\":\"{s}\",\"source\":", .{ abi.ABI_VERSION, kind, name });
        const src_json = try std.json.Stringify.valueAlloc(a.allocator(), source, .{});
        try reqbuf.appendSlice(src_json);
        try reqbuf.appendSlice("}");

        const url = try std.fmt.allocPrint(a.allocator(), "{s}/compile", .{self.factory_base});
        var resp = std.array_list.Managed(u8).init(self.alloc);
        defer resp.deinit();
        const st = try self.post(url, reqbuf.items, &resp);
        if (st == .ok) {
            const blob = try self.alloc.dupe(u8, resp.items);
            try self.blobs.put(try self.alloc.dupe(u8, name), blob);
            try agent_tools.printTo(out, "compiled {s}.kudos ({d} bytes)", .{ name, blob.len });
        } else {
            try agent_tools.printTo(out, "compile failed ({d}):\n{s}", .{ @intFromEnum(st), resp.items });
        }
    }

    fn toolCompile(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        try self.compileKind("app", args_json, out);
    }

    fn toolCompileFeature(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        try self.compileKind("feature", args_json, out);
    }

    // ── tool: load_feature({name}) — register through the shared hot-load core ─
    fn toolLoadFeature(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        const blob = self.blobs.get(name) orelse {
            try agent_tools.printTo(out, "no such feature: {s}", .{name});
            return;
        };
        const mem_len = try runner.imageSize(blob);
        const page = std.heap.pageSize();
        // Resident on purpose (never munmapped): the image backs the callbacks
        // the feature registered, exactly like the kernel's never-freed image.
        const image = try std.posix.mmap(null, std.mem.alignForward(usize, mem_len, page), .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        const rc = hotload.registerBlob(blob, image[0..mem_len], captureSink(out), apiGetInterface) catch |e| {
            try agent_tools.printTo(out, "load failed: {s}", .{@errorName(e)});
            return;
        };
        try agent_tools.printTo(out, "[feature registered, rc {d}]", .{rc});
    }

    // ── tool: invoke_command({name, args?}) — run a feature-registered command ─
    fn toolInvoke(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        _ = ctx;
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        const cmd_args = if (parsed.object.get("args")) |v| v.string else "";
        if (!hotload.dispatch(captureSink(out), name, cmd_args))
            try agent_tools.printTo(out, "no such feature command: {s}", .{name});
    }

    // ── tools: list_sources / read_source — the factory workspace, read-only ──
    fn toolListSources(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        _ = args_json;
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var urlbuf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&urlbuf, "{s}/sources", .{self.factory_base});
        _ = try self.get(url, out);
    }

    fn toolReadSource(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        var urlbuf: [256]u8 = undefined;
        const url = try std.fmt.bufPrint(&urlbuf, "{s}/sources/{s}", .{ self.factory_base, name });
        _ = try self.get(url, out);
    }

    // ── tool: run_app({name}) — load and execute the .kudos ───────────────────
    fn toolRun(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        const blob = self.blobs.get(name) orelse {
            try agent_tools.printTo(out, "no such app: {s}", .{name});
            return;
        };

        const mem_len = try runner.imageSize(blob);
        const page = std.heap.pageSize();
        const image = try std.posix.mmap(null, std.mem.alignForward(usize, mem_len, page), .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        defer std.posix.munmap(image);
        const entry = try runner.loadApp(blob, image[0..mem_len]);

        self.run_out.clearRetainingCapacity();
        self.used = 0;
        const api = abi.Api{
            .version = abi.ABI_VERSION,
            .ctx = self,
            .print = apiPrint,
            .poll_key = apiPollKey,
            .millis = apiMillis,
            .sleep_ms = apiSleepMs,
            .yield = apiYield,
            .cancelled = apiCancelled,
            .rand = apiRand,
            .alloc = apiAlloc,
            .file_read = apiFileRead,
            .file_write = apiFileWrite,
            .get_interface = apiGetInterface,
        };
        const rc = entry(&api);
        try agent_tools.printTo(out, "{s}[exit {d}]", .{ self.run_out.items, rc });
    }

    // ── AGT-006 tool surface (host parity): files + system state ──────────────
    // These run the REAL store and the REAL namespace (drivers/storage), so the
    // tree semantics the model meets here are the ones it meets in the kernel.

    /// The absolute VFS path a tool argument names; a bare or relative one means
    /// the ramdisk. Same rule as the kernel's file tools (console/agenttools.zig).
    fn absPath(buf: *[vfs.MAX_PATH]u8, path: []const u8) ?[]const u8 {
        if (path.len != 0 and path[0] == '/') return vfs.normalize("/", path, buf);
        return vfs.normalize("/ramdisk", path, buf);
    }

    fn argPath(args_json: []const u8, a: std.mem.Allocator, buf: *[vfs.MAX_PATH]u8) !?[]const u8 {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, args_json, .{});
        return absPath(buf, parsed.object.get("path").?.string);
    }

    fn toolReadFile(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = (try argPath(args_json, a.allocator(), &buf)) orelse return out.appendSlice("path too long");
        const body = vfs.read(abs) orelse {
            try agent_tools.printTo(out, "no such file: {s}", .{abs});
            return;
        };
        try out.appendSlice(body);
    }

    fn toolWriteFile(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), args_json, .{});
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = absPath(&buf, parsed.object.get("path").?.string) orelse return out.appendSlice("path too long");
        const content = parsed.object.get("content").?.string;
        vfs.write(abs, content) catch |e| {
            try agent_tools.printTo(out, "cannot write {s}: {s}", .{ abs, @errorName(e) });
            return;
        };
        try agent_tools.printTo(out, "wrote {d} bytes to {s}", .{ content.len, abs });
    }

    fn toolDeleteFile(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = (try argPath(args_json, a.allocator(), &buf)) orelse return out.appendSlice("path too long");
        vfs.remove(abs) catch |e| {
            try agent_tools.printTo(out, "cannot delete {s}: {s}", .{ abs, @errorName(e) });
            return;
        };
        try agent_tools.printTo(out, "deleted {s}", .{abs});
    }

    fn toolMakeDir(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = (try argPath(args_json, a.allocator(), &buf)) orelse return out.appendSlice("path too long");
        vfs.mkdir(abs) catch |e| {
            try agent_tools.printTo(out, "cannot create {s}: {s}", .{ abs, @errorName(e) });
            return;
        };
        try agent_tools.printTo(out, "created directory {s}", .{abs});
    }

    fn toolDeleteDir(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = (try argPath(args_json, a.allocator(), &buf)) orelse return out.appendSlice("path too long");
        vfs.rmdir(abs) catch |e| {
            try agent_tools.printTo(out, "cannot delete {s}: {s}", .{ abs, @errorName(e) });
            return;
        };
        try agent_tools.printTo(out, "deleted directory {s}", .{abs});
    }

    /// The listing sink: one line per entry, directories marked — the kernel
    /// tool's shape, so a model's expectations carry across.
    const ListSink = struct {
        out: *std.array_list.Managed(u8),
        fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
            const self: *ListSink = @ptrCast(@alignCast(ctx.?));
            const tag = if (e.kind == .dir) "d" else "-";
            agent_tools.printTo(self.out, "{s} {s} ({d} bytes)\n", .{ tag, e.name, e.size }) catch {};
        }
    };

    fn toolListDir(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = (try argPath(args_json, a.allocator(), &buf)) orelse return out.appendSlice("path too long");
        var sink = ListSink{ .out = out };
        vfs.list(abs, ListSink.cb, &sink) catch |e| {
            try agent_tools.printTo(out, "cannot list {s}: {s}", .{ abs, @errorName(e) });
            return;
        };
        if (out.items.len == 0) try out.appendSlice("(empty)");
    }

    fn toolSystemState(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        _ = args_json;
        const self: *Agent = @ptrCast(@alignCast(ctx));
        try agent_tools.printTo(out, "uptime_ms: 0\ncounters:\n  host.files = {d}\n  host.blobs = {d}\n", .{ ramdisk.list().len, self.blobs.count() });
    }

    fn toolOpenApp(ctx: *anyopaque, args_json: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
        const self: *Agent = @ptrCast(@alignCast(ctx));
        var a = std.heap.ArenaAllocator.init(self.alloc);
        defer a.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a.allocator(), args_json, .{});
        const name = parsed.object.get("name").?.string;
        // No desktop on the host rig — record the request, as the kernel parks it.
        try agent_tools.printTo(out, "requested to open the {s} window", .{name});
    }

    fn tools(self: *Agent) loop.Tools {
        _ = self;
        return .{ .ctx = undefined, .invoke = invoke };
    }
};

// The agent's tool registry — the host rig's parity with the kernel table.
const registry = agent_tools.Registry{ .tools = &.{
    .{ .name = "compile_app", .description = "compile a zig app to .kudos", .params_schema = SCHEMA_COMPILE, .handler = Agent.toolCompile },
    .{ .name = "compile_feature", .description = "compile a zig feature to .kudos", .params_schema = SCHEMA_COMPILE, .handler = Agent.toolCompileFeature },
    .{ .name = "run_app", .description = "run a compiled .kudos", .params_schema = SCHEMA_RUN, .handler = Agent.toolRun },
    .{ .name = "load_feature", .description = "hot-load a compiled feature .kudos", .params_schema = SCHEMA_RUN, .handler = Agent.toolLoadFeature },
    .{ .name = "invoke_command", .description = "run a feature-registered command", .params_schema = SCHEMA_INVOKE, .handler = Agent.toolInvoke },
    .{ .name = "list_sources", .description = "list module sources in the factory workspace", .params_schema = SCHEMA_NONE, .handler = Agent.toolListSources },
    .{ .name = "read_source", .description = "read one module source from the factory workspace", .params_schema = SCHEMA_RUN, .handler = Agent.toolReadSource },
    .{ .name = "read_file", .description = "read a file from the virtual file system", .params_schema = SCHEMA_PATH, .handler = Agent.toolReadFile },
    .{ .name = "write_file", .description = "create or replace a file under /ramdisk", .params_schema = SCHEMA_WRITE, .handler = Agent.toolWriteFile },
    .{ .name = "delete_file", .description = "delete a file under /ramdisk", .params_schema = SCHEMA_PATH, .handler = Agent.toolDeleteFile },
    .{ .name = "make_dir", .description = "create a directory under /ramdisk", .params_schema = SCHEMA_PATH, .handler = Agent.toolMakeDir },
    .{ .name = "delete_dir", .description = "delete an empty directory under /ramdisk", .params_schema = SCHEMA_PATH, .handler = Agent.toolDeleteDir },
    .{ .name = "list_dir", .description = "list a directory", .params_schema = SCHEMA_PATH, .handler = Agent.toolListDir },
    .{ .name = "system_state", .description = "report uptime and counters", .params_schema = SCHEMA_NONE, .handler = Agent.toolSystemState },
    .{ .name = "open_app", .description = "open an application window by name", .params_schema = SCHEMA_RUN, .handler = Agent.toolOpenApp },
} };

// Tool activity is echoed to stdout like the kernel console streams it
// ("● tool"), so a transcript shows what actually executed, not just words.
fn invoke(ctx: *anyopaque, name: []const u8, args: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    defer {
        var hdr_buf: [128]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "\n\xe2\x97\x8f {s}\n", .{name}) catch "\n* tool\n";
        _ = std.os.linux.write(1, hdr.ptr, hdr.len);
        _ = std.os.linux.write(1, out.items.ptr, out.items.len);
        _ = std.os.linux.write(1, "\n", 1);
    }
    try registry.dispatch(ctx, name, args, out);
}

const SCHEMA_COMPILE =
    \\{"type":"object","properties":{"name":{"type":"string"},"source":{"type":"string"}},"required":["name","source"]}
;
const SCHEMA_RUN =
    \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
;
const SCHEMA_INVOKE =
    \\{"type":"object","properties":{"name":{"type":"string"},"args":{"type":"string"}},"required":["name"]}
;
const SCHEMA_NONE =
    \\{"type":"object","properties":{}}
;
const SCHEMA_PATH =
    \\{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}
;
const SCHEMA_WRITE =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
;

// Feature output captured into the invoking tool's result buffer — the host
// analogue of the kernel agent's capture sink.
fn sinkCaptureWrite(ctx: *anyopaque, text: []const u8) void {
    const out: *std.array_list.Managed(u8) = @ptrCast(@alignCast(ctx));
    out.appendSlice(text) catch {};
}

fn captureSink(out: *std.array_list.Managed(u8)) hotload.Sink {
    return .{ .ctx = out, .write = sinkCaptureWrite };
}

// ── Api backed by the Agent's captured-output buffer / bump arena ─────────────
fn ap(p: *anyopaque) *Agent {
    return @ptrCast(@alignCast(p));
}
fn apiPrint(p: *anyopaque, s: [*]const u8, len: usize) callconv(.c) void {
    ap(p).run_out.appendSlice(s[0..len]) catch {};
}
fn apiPollKey(_: *anyopaque) callconv(.c) i32 {
    return -1;
}
fn apiMillis(_: *anyopaque) callconv(.c) u64 {
    return 0;
}
fn apiSleepMs(_: *anyopaque, _: u64) callconv(.c) void {}
fn apiYield(_: *anyopaque) callconv(.c) void {}
fn apiCancelled(_: *anyopaque) callconv(.c) bool {
    return false;
}
fn apiRand(p: *anyopaque) callconv(.c) u64 {
    const s = ap(p);
    s.rng = s.rng *% 6364136223846793005 +% 1;
    return s.rng;
}
fn apiAlloc(p: *anyopaque, n: usize, log2_align: u8) callconv(.c) ?[*]u8 {
    const s = ap(p);
    const al = @as(usize, 1) << @intCast(log2_align);
    const base = std.mem.alignForward(usize, s.used, al);
    if (base + n > s.arena.len) return null;
    s.used = base + n;
    return s.arena.ptr + base;
}
fn ramName(path: []const u8) []const u8 {
    const pfx = "/ramdisk/";
    return if (std.mem.startsWith(u8, path, pfx)) path[pfx.len..] else path;
}
fn apiFileRead(_: *anyopaque, path: [*]const u8, path_len: usize, out: [*]u8, cap: usize) callconv(.c) isize {
    const data = ramdisk.get(ramName(path[0..path_len])) orelse return -1;
    const n = @min(data.len, cap);
    @memcpy(out[0..n], data[0..n]);
    return @intCast(n);
}
fn apiFileWrite(_: *anyopaque, path: [*]const u8, path_len: usize, data: [*]const u8, len: usize) callconv(.c) bool {
    ramdisk.put(ramName(path[0..path_len]), data[0..len]) catch return false;
    return true;
}
fn apiGetInterface(_: *anyopaque, _: u32, _: u32) callconv(.c) ?*const anyopaque {
    // No capability is published on the host rig: no window, no desktop, no
    // machine behind it. A module binding one takes the same refusal a kudos that
    // does not publish it would give.
    return null;
}

const Stdout = struct {
    fn write(_: *anyopaque, text: []const u8) void {
        _ = std.os.linux.write(1, text.ptr, text.len);
    }
};

const HostClock = struct {
    fn millis(_: *anyopaque) u64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
    }
};

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const argv = init.minimal.args.vector;
    if (argv.len < 4) {
        std.debug.print("usage: hostagent <openrouter_url> <factory_base_url> <prompt...>\n", .{});
        std.process.exit(2);
    }
    const openrouter_url = std.mem.span(argv[1]);
    const factory_base = std.mem.span(argv[2]);
    var prompt_text = std.array_list.Managed(u8).init(a);
    for (argv[3..], 0..) |w, i| {
        if (i != 0) try prompt_text.append(' ');
        try prompt_text.appendSlice(std.mem.span(w));
    }

    // The real store, mounted in the real namespace — the file tools and the
    // app Api both reach the system through it, as they do in the kernel.
    ramdisk.init(a);
    vfs.mount("ramdisk", ramdisk.fileSys());

    var http = std.http.Client{ .allocator = a, .io = init.io };
    defer http.deinit();

    var agent = Agent{
        .alloc = a,
        .http = &http,
        .openrouter_url = openrouter_url,
        .factory_base = factory_base,
        .blobs = std.StringHashMap([]u8).init(a),
        .run_out = std.array_list.Managed(u8).init(a),
        .arena = try a.alloc(u8, abi.APP_ARENA_MAX_BYTES),
    };

    var hist = loop.history.History.init(a, 64);
    defer hist.deinit();
    // The real system prompt, so a live model writes ABI-correct code — the
    // same guard the kernel uses. Stubbed tests ignore prompt content.
    try hist.setSystem(prompt.SYSTEM);

    // KUDOS_AGENT_MODEL selects a real model for a live run; the stub scripts
    // ignore the model field, so the default keeps them working unchanged.
    const model = init.environ_map.get("KUDOS_AGENT_MODEL") orelse "stub";

    const chat = loop.Chat{ .ctx = &agent, .send = Agent.chatSend };
    const tool_iface = loop.Tools{ .ctx = &agent, .invoke = invoke };
    const sink = loop.Sink{ .ctx = undefined, .write = Stdout.write };
    const clock = loop.Clock{ .ctx = undefined, .millis = HostClock.millis };

    const tj = try registry.toolsJson(a);
    try loop.run(a, chat, tool_iface, sink, clock, &hist, prompt_text.items, .{ .model = model, .tools_json = tj });
    _ = std.os.linux.write(1, "\n", 1);
}
