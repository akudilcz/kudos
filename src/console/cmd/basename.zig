//! `basename [-a] [-s SUFFIX] PATH...` and `dirname PATH...` — the two halves
//! of a path, printed. Both are string operations (pathname.zig): neither asks
//! the store whether the path exists, which is what lets them name a file about
//! to be written as readily as one already there.
//!
//! basename's two shapes are coreutils': one path and an optional suffix
//! operand, or `-a` (implied by `-s`) where every operand is a path.

const console = @import("../console.zig");
const filter = @import("../filter.zig");
const opt = @import("../opt.zig");
const pathname = @import("../pathname.zig");

const BASE_USAGE = "usage: basename [-a] [-s SUFFIX] PATH...\n";
const BASE_SPEC = "as:";
const DIR_USAGE = "usage: dirname PATH...\n";

pub fn runBase(c: console.Console, args: []const u8) void {
    var all = false;
    var suffix: []const u8 = "";
    var sc = opt.Scan.init(BASE_SPEC, args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'a' => all = true,
            else => return opt.refuse(c, "basename", o, BASE_USAGE),
        },
        .val => |v| switch (v.letter) {
            's' => {
                suffix = v.arg;
                all = true; // -s means every operand is a path, as coreutils has it
            },
            else => return opt.refuse(c, "basename", o, BASE_USAGE),
        },
        else => return opt.refuse(c, "basename", o, BASE_USAGE),
    };

    var ops = opt.Operands.init(BASE_SPEC, args);
    const first = ops.next() orelse return c.write(BASE_USAGE);
    if (!all) {
        // The two-operand shape: `basename PATH [SUFFIX]`.
        const operand_suffix = ops.next() orelse "";
        return filter.line(c, pathname.base(first, operand_suffix));
    }
    filter.line(c, pathname.base(first, suffix));
    while (ops.next()) |path| filter.line(c, pathname.base(path, suffix));
}

pub fn runDir(c: console.Console, args: []const u8) void {
    var sc = opt.Scan.init("", args);
    while (sc.next()) |o| return opt.refuse(c, "dirname", o, DIR_USAGE);
    var ops = opt.Operands.init("", args);
    var named = false;
    while (ops.next()) |path| {
        named = true;
        filter.line(c, pathname.dir(path));
    }
    if (!named) c.write(DIR_USAGE);
}
