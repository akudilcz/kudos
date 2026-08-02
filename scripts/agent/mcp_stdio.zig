//! A stdio MCP server built on the REAL kudos MCP handler (src/agent/mcp.zig)
//! over a demo registry of kudos-flavoured tools. It reads newline-delimited
//! JSON-RPC on stdin and writes responses on stdout — the MCP stdio transport —
//! so an MCP client (e.g. Claude Code) can register it directly.
//!
//! This is the laptop stand-in for kudos serving MCP: in production the exact
//! same `mcp.handle(registry, ...)` runs in the kernel and the transport is a
//! netdebug KMR1 op instead of stdio, with the registry filled by real handlers
//! (screenshot, files, run, ...). The tool set is defined ONCE, here in the
//! registry, and both transports serve it.

const std = @import("std");
const mcp = @import("mcp");
const tools = mcp.tools;

fn toolStatus(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    try out.appendSlice("{\"build\":1,\"up_ms\":12345,\"cores_online\":4,\"desktop\":\"60Hz\"}");
}
fn toolListFiles(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    try out.appendSlice("/ramdisk/primesum.kudos\n/ramdisk/primesum.zig\n/usbdisk/background.png");
}
fn toolScreenshot(_: *anyopaque, _: []const u8, out: *std.array_list.Managed(u8)) anyerror!void {
    try out.appendSlice("captured /ramdisk/screenshot.png (stub)");
}

const registry = tools.Registry{ .tools = &.{
    .{ .name = "kudos_status", .description = "kudos health and state", .params_schema = "{\"type\":\"object\"}", .handler = toolStatus },
    .{ .name = "list_files", .description = "list virtual-file-system files", .params_schema =
        \\{"type":"object","properties":{"path":{"type":"string"}}}
    , .handler = toolListFiles },
    .{ .name = "screenshot", .description = "capture the desktop", .params_schema = "{\"type\":\"object\"}", .handler = toolScreenshot },
} };

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const io = init.io;
    var dummy: u8 = 0;

    var in_buf: [256 * 1024]u8 = undefined;
    var fr = std.Io.File.stdin().reader(io, &in_buf);
    const stdin = &fr.interface;
    var out_buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &fw.interface;

    while (true) {
        const line = (stdin.takeDelimiter('\n') catch break) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const resp = try mcp.handle(a, registry, &dummy, trimmed);
        defer a.free(resp);
        if (resp.len == 0) continue; // a notification: nothing to send
        try stdout.writeAll(resp);
        try stdout.writeByte('\n');
        try stdout.flush();
    }
}
