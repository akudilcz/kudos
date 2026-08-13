//! `stat [-c FORMAT] FILE...` — what the store knows about a name. The store
//! has no timestamps, owners or permissions, so stat prints the fields it
//! really has rather than inventing the rest, and a FORMAT naming a field that
//! does not exist here is refused by name.
//!
//! `-c FORMAT` is stat(1)'s own flag and its own directives: `%n` the name, `%s`
//! the size in bytes, `%F` the kind ("regular file"/"directory"), `%%` a
//! percent. That is what makes `stat -c %s file` — the one an agent types to
//! get a size it can compute with — mean here what it means everywhere.

const std = @import("std");
const bytesize = @import("../bytesize.zig");
const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: stat [-c FORMAT] FILE...   (%n name, %s size, %F kind)\n";
const SPEC = "c:";

pub fn run(c: console.Console, args: []const u8) void {
    var format: ?[]const u8 = null;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            'c' => format = v.arg,
            else => return opt.refuse(c, "stat", o, USAGE),
        },
        else => return opt.refuse(c, "stat", o, USAGE),
    };

    var ops = opt.Operands.init(SPEC, args);
    var named = false;
    while (ops.next()) |path| {
        named = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        const k = vfs.kind(abs) orelse {
            c.write("stat: cannot stat '");
            c.write(path);
            c.write("': No such file or directory\n");
            continue;
        };
        const data: []const u8 = if (k == .file) (vfs.read(abs) orelse "") else "";
        if (format) |f| {
            if (!formatted(c, f, abs, k, data)) return; // the wording named the directive
        } else {
            long(c, abs, k, data);
        }
    }
    if (!named) c.write(USAGE);
}

/// stat's default, multi-line report.
fn long(c: console.Console, abs: []const u8, k: vfs.ifilesys.Kind, data: []const u8) void {
    c.write("  File: ");
    filter.line(c, abs);
    if (k == .dir) return c.write("  Type: directory\n");
    var hbuf: [bytesize.MAX_TEXT]u8 = undefined;
    var line: [96]u8 = undefined;
    c.write(std.fmt.bufPrint(&line, "  Type: regular file\n  Size: {d} ({s})\n Lines: {d}\n", .{
        data.len,
        bytesize.human(data.len, &hbuf),
        filter.lineCount(data),
    }) catch "  Type: regular file\n");
}

/// One `-c FORMAT` line. False when a directive is not one of ours — the
/// message names it, and the caller stops rather than printing the rest of a
/// line the user did not ask for.
fn formatted(c: console.Console, f: []const u8, abs: []const u8, k: vfs.ifilesys.Kind, data: []const u8) bool {
    var i: usize = 0;
    while (i < f.len) : (i += 1) {
        if (f[i] != '%') {
            // `\n` in a format is the newline stat(1) writes there.
            if (f[i] == '\\' and i + 1 < f.len and f[i + 1] == 'n') {
                c.put('\n');
                i += 1;
                continue;
            }
            c.put(f[i]);
            continue;
        }
        i += 1;
        if (i >= f.len) break;
        switch (f[i]) {
            'n' => c.write(abs),
            's' => {
                var buf: [24]u8 = undefined;
                c.write(std.fmt.bufPrint(&buf, "{d}", .{data.len}) catch "0");
            },
            'F' => c.write(if (k == .dir) "directory" else "regular file"),
            '%' => c.put('%'),
            else => {
                c.write("stat: unknown directive: %");
                c.put(f[i]);
                c.put('\n');
                c.write(USAGE);
                return false;
            },
        }
    }
    c.put('\n');
    return true;
}
