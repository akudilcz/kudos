//! `mkdir [-p] DIR...` — create directories; `-p` creates missing parents and
//! does not mind a directory that already exists, as mkdir -p promises.

const std = @import("std");
const console = @import("../console.zig");
const ifilesys = @import("ifilesys");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const vfs = @import("vfs");

const USAGE = "usage: mkdir [-p] DIR...\n";

pub fn run(c: console.Console, args: []const u8) void {
    var parents = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'p' => parents = true,
            else => return opt.refuse(c, "mkdir", o, USAGE),
        },
        else => return opt.refuse(c, "mkdir", o, USAGE),
    };

    var ops = opt.Operands.init("", args);
    var any = false;
    while (ops.next()) |path| {
        any = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        if (parents) {
            makeParents(c, abs);
            continue;
        }
        vfs.mkdir(abs) catch |e| complain(c, abs, e);
    }
    if (!any) c.write(USAGE);
}

/// `-p`: create every component of `abs` in turn, treating AlreadyExists as
/// the success it is — for the parents and for the final directory alike.
fn makeParents(c: console.Console, abs: []const u8) void {
    var i: usize = 1; // abs is normalized: it starts with '/'
    while (i <= abs.len) : (i += 1) {
        if (i < abs.len and abs[i] != '/') continue;
        if (i == 1) continue; // "//" or a lone leading slash
        // What already exists needs no creating — and must not be attempted:
        // the first component is a MOUNT root ("/ramdisk"), which no store
        // can be asked to create.
        if (vfs.kind(abs[0..i]) != null) continue;
        vfs.mkdir(abs[0..i]) catch |e| switch (e) {
            error.Exists => {},
            else => {
                complain(c, abs[0..i], e);
                return;
            },
        };
    }
}

fn complain(c: console.Console, path: []const u8, e: ifilesys.WriteError) void {
    c.write("mkdir: cannot create '");
    c.write(path);
    c.write("': ");
    c.write(patharg.writeErrorText(e));
    c.put('\n');
}
