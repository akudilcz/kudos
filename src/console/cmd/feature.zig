//! `feature <name>` — hot-load a compiled feature `.kudos` into the running
//! kernel (spec AGT-010). Reads /ramdisk/<name>.kudos and hands it to the
//! shared hot-load core (`kernel/loader/hotload.zig`) with this console as the
//! output sink; the same core serves the agent's load_feature tool with a
//! capture sink instead. `feature` with no argument lists the commands features
//! have registered.
//!
//! Unlike an app, a feature stays resident for the rest of the boot — its code
//! backs any callback it registered — so its image is deliberately never freed.

const std = @import("std");
const capabilities = @import("../capabilities.zig");
const console = @import("../console.zig");
const vfs = @import("vfs");
const heap = @import("../../kernel/memory/heap.zig");
const hotload = @import("../../kernel/loader/hotload.zig");
const runner = hotload.runner;
const features = hotload.features;

fn consoleWrite(ctx: *anyopaque, text: []const u8) void {
    const c: *console.Console = @ptrCast(@alignCast(ctx));
    c.write(text);
}

/// The hot-load output sink over `c`, which must stay addressable for the
/// duration of the (synchronous) hot-load call it is handed to.
fn consoleSink(c: *console.Console) hotload.Sink {
    return .{ .ctx = c, .write = consoleWrite };
}

fn list(c: console.Console) void {
    const n = features.len();
    if (n == 0) {
        c.write("no feature commands registered\n");
        return;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        c.write("  ");
        c.write(features.at(i).name());
        c.write("\n");
    }
}

fn report(c: console.Console, e: anyerror) void {
    c.write("feature: ");
    c.write(switch (e) {
        error.BadMagic, error.TooSmall => "not a .kudos file",
        error.BadVersion => "built for a different ABI version",
        error.WrongKind => "that is an app, not a feature",
        error.BadCrc, error.BadLengths => "corrupt image",
        else => "load failed",
    });
    c.write("\n");
}

/// Run a feature-registered command if one matches `name`, routing its output
/// to `c`. Returns whether a feature command handled the line — the shell
/// consults this after its built-in table misses (spec AGT-010).
pub fn dispatch(c: console.Console, name: []const u8, args: []const u8) bool {
    var cc = c;
    return hotload.dispatch(consoleSink(&cc), name, args);
}

pub fn run(c: console.Console, args: []const u8) void {
    var cc = c;
    const name = std.mem.trim(u8, args, " \t");
    if (name.len == 0 or std.mem.eql(u8, name, "list")) return list(c);

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&pathbuf, "/ramdisk/{s}.kudos", .{name}) catch {
        c.write("feature: name too long\n");
        return;
    };
    const blob = vfs.read(path) orelse {
        c.write("feature: no such feature: ");
        c.write(name);
        c.write("\n");
        return;
    };

    const mem_len = runner.imageSize(blob) catch |e| return report(c, e);
    const a = heap.allocator();
    // Resident: over-allocate, 16-byte align, and NEVER free (the feature's
    // code stays live for the boot).
    const raw = a.alloc(u8, mem_len + 16) catch {
        c.write("feature: out of memory\n");
        return;
    };
    const base = std.mem.alignForward(usize, @intFromPtr(raw.ptr), 16);
    const image = @as([*]u8, @ptrFromInt(base))[0..mem_len];

    const rc = hotload.registerBlob(blob, image, consoleSink(&cc), capabilities.feature) catch |e| return report(c, e);
    var buf: [48]u8 = undefined;
    c.write(std.fmt.bufPrint(&buf, "feature '{s}' loaded (rc {d})\n", .{ name, rc }) catch "\n");
}
