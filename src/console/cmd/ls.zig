//! `ls [-alh] [PATH...]` — list directories and name files. Directories print
//! in cyan with a trailing '/'; `ls /` shows the mounts. Several arguments (a
//! glob's usual product) list each; a file argument prints as its own one-line
//! entry, the way ls answers `ls *.zig`. `-l` is the long listing (kind, size,
//! name), `-a` includes dot-names, `-h` prints -l's sizes human-readably.

const std = @import("std");
const vfs = @import("vfs");
const ifilesys = @import("ifilesys");
const bytesize = @import("../bytesize.zig");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");

/// The cyan directory entries print in — a pale tint from the same family as
/// the terminal's prompt green (0xFF80FFB0), on a console that colors at all.
const DIR_FG: u32 = 0xFF80FFFF;

const USAGE = "usage: ls [-alh] [PATH...]\n";

const Style = struct {
    long: bool = false,
    all: bool = false,
    human: bool = false,
};

pub fn run(c: console.Console, args: []const u8) void {
    var st = Style{};
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'l' => st.long = true,
            'a' => st.all = true,
            'h' => st.human = true,
            else => return opt.refuse(c, "ls", o, USAGE),
        },
        else => return opt.refuse(c, "ls", o, USAGE),
    };
    var ops = opt.Operands.init("", args);
    var any = false;
    while (ops.next()) |path| {
        any = true;
        listOne(c, path, st);
    }
    if (!any) listOne(c, ".", st);
}

fn listOne(c: console.Console, path: []const u8, st: Style) void {
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, path, &buf) orelse return;
    // A file argument is its own entry; only a directory is enumerated.
    if (vfs.kind(abs)) |k| {
        if (k == .file) {
            const size = if (vfs.read(abs)) |d| d.len else 0;
            printEntry(c, st, .file, size, path);
            return;
        }
    }
    var p = Print{ .c = c, .st = st };
    vfs.list(abs, Print.cb, &p) catch |e| {
        c.write(switch (e) {
            error.NotADirectory => "ls: not a directory: '",
            error.NotFound => "ls: no such directory '",
            error.IoFailed => "ls: i/o error reading '",
        });
        c.write(abs);
        c.write("'\n");
    };
}

const Print = struct {
    c: console.Console,
    st: Style,

    fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
        const p: *Print = @ptrCast(@alignCast(ctx.?));
        if (!p.st.all and e.name.len > 0 and e.name[0] == '.') return;
        printEntry(p.c, p.st, e.kind, e.size, e.name);
    }
};

/// One listing line, both shapes. Long rows carry a kind column and a size
/// column ('-' for a directory: the store has no directory sizes); the short
/// shape keeps this shell's established `name  (N bytes)` / `dir/` rows.
fn printEntry(c: console.Console, st: Style, kind: ifilesys.Kind, size: usize, name: []const u8) void {
    var line: [96]u8 = undefined;
    if (st.long) {
        if (kind == .dir) {
            c.write(std.fmt.bufPrint(&line, "d {s: >8} ", .{"-"}) catch return);
        } else if (st.human) {
            var hb: [bytesize.MAX_TEXT]u8 = undefined;
            c.write(std.fmt.bufPrint(&line, "- {s: >8} ", .{bytesize.human(size, &hb)}) catch return);
        } else {
            c.write(std.fmt.bufPrint(&line, "- {d: >8} ", .{size}) catch return);
        }
        writeName(c, kind, name);
        return;
    }
    if (kind == .dir) {
        writeName(c, kind, name);
        return;
    }
    c.write(name);
    c.write(std.fmt.bufPrint(&line, "  ({d} bytes)\n", .{size}) catch return);
}

fn writeName(c: console.Console, kind: ifilesys.Kind, name: []const u8) void {
    if (kind == .dir) {
        c.setColor(DIR_FG);
        c.write(name);
        c.write("/\n");
        c.resetColor();
        return;
    }
    c.write(name);
    c.put('\n');
}
