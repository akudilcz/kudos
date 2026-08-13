//! `rm [-rf] FILE...` — delete files (spec STO-008), and with `-r` whole
//! directories through the shared tree walk (fstree.zig). Without `-r` a
//! directory is refused: a delete that silently took a subtree would be the one
//! command in this shell whose mistake cannot be undone. `-f` makes a missing
//! operand not worth a complaint, as rm -f promises. Every other failure names
//! the resolved absolute path and what the store said, because "rm: error" on a
//! machine with several mounted stores does not tell you which one refused.

const std = @import("std");
const vfs = @import("vfs");
const console = @import("../console.zig");
const fstree = @import("../fstree.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");

const USAGE = "usage: rm [-rf] FILE...\n";

pub fn run(c: console.Console, args: []const u8) void {
    var recurse = false;
    var force = false;
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'r', 'R' => recurse = true,
            'f' => force = true,
            else => return opt.refuse(c, "rm", o, USAGE),
        },
        else => return opt.refuse(c, "rm", o, USAGE),
    };

    var ops = opt.Operands.init("", args);
    var any = false;
    while (ops.next()) |path| {
        any = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        if (recurse) {
            if ((vfs.kind(abs) orelse .file) == .dir) {
                _ = fstree.removeTree(c, "rm", abs);
                continue;
            }
        }
        vfs.remove(abs) catch |e| {
            if (force and e == error.NotFound) continue;
            c.write("rm: cannot remove '");
            c.write(abs);
            c.write("': ");
            c.write(patharg.writeErrorText(e));
            c.put('\n');
        };
    }
    if (!any) c.write(USAGE);
}
