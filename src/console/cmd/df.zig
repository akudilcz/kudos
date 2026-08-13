//! `df [-h]` — what each mounted store holds. The stores here live in RAM, so
//! "free" is the machine's free heap rather than a partition's remaining
//! blocks, and the line says that instead of printing a capacity the store does
//! not have.
//!
//! The mounts come from listing `/`, which IS the mount table (vfs.zig): asking
//! the file system what it holds keeps this command out of the mount table's
//! internals, and a store mounted later appears here without a change.

const std = @import("std");
const bytesize = @import("../bytesize.zig");
const console = @import("../console.zig");
const fstree = @import("../fstree.zig");
const heap = @import("../../kernel/memory/heap.zig");
const opt = @import("../opt.zig");
const vfs = @import("vfs");

const USAGE = "usage: df [-h]\n";
const SPEC = "h";

/// Sums the files under one mount.
const Used = struct {
    bytes: usize = 0,
    files: usize = 0,

    fn visit(ctx: ?*anyopaque, e: fstree.Seen) void {
        const u: *Used = @ptrCast(@alignCast(ctx.?));
        if (e.kind != .file) return;
        u.bytes += e.size;
        u.files += 1;
    }
};

/// Prints one line per mount, as `/` enumerates them.
const Mounts = struct {
    c: console.Console,
    human: bool,

    fn cb(ctx: ?*anyopaque, e: vfs.ifilesys.Entry) void {
        const m: *Mounts = @ptrCast(@alignCast(ctx.?));
        var abs_buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = std.fmt.bufPrint(&abs_buf, "/{s}", .{e.name}) catch return;
        var u = Used{};
        _ = fstree.walk(abs, &u, Used.visit);
        var size_buf: [bytesize.MAX_TEXT]u8 = undefined;
        var num_buf: [24]u8 = undefined;
        const used = if (m.human) bytesize.human(u.bytes, &size_buf) else std.fmt.bufPrint(&num_buf, "{d}", .{u.bytes}) catch "0";
        var line: [96]u8 = undefined;
        m.c.write(std.fmt.bufPrint(&line, "{s: <14} {d: >5} {s: >9}  RAM\n", .{ abs, u.files, used }) catch "");
    }
};

pub fn run(c: console.Console, args: []const u8) void {
    var human = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'h' => human = true,
            else => return opt.refuse(c, "df", o, USAGE),
        },
        else => return opt.refuse(c, "df", o, USAGE),
    };

    c.write("Mount           Files      Used  Backing\n");
    var m = Mounts{ .c = c, .human = human };
    vfs.list("/", Mounts.cb, &m) catch return c.write("df: the mount table could not be listed\n");

    // What "free" means for stores that live in the heap: the heap's own
    // remaining bytes, named as the shared resource it is.
    var free_buf: [bytesize.MAX_TEXT]u8 = undefined;
    var num_buf: [24]u8 = undefined;
    var line: [96]u8 = undefined;
    c.write(std.fmt.bufPrint(&line, "\nthese stores share the kernel heap — {s} free\n", .{
        if (human) bytesize.human(heap.freeBytes(), &free_buf) else std.fmt.bufPrint(&num_buf, "{d} bytes", .{heap.freeBytes()}) catch "?",
    }) catch "");
}
