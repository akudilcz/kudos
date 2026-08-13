//! `seq [-s SEP] [FIRST [STEP]] LAST` — the integers from FIRST to LAST, one a
//! line. What a shell reaches for to make a list to loop over or to generate
//! test input: `seq 1 100 > numbers.txt`.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");

/// Most numbers one `seq` prints. A range is a typo away from being enormous,
/// and a terminal filling for minutes is indistinguishable from a hang.
const MAX_COUNT: usize = 100_000;

const USAGE = "usage: seq [-s SEP] [FIRST [STEP]] LAST\n";
const SPEC = "s:";

pub fn run(c: console.Console, args: []const u8) void {
    var sep: []const u8 = "\n";
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .val => |v| switch (v.letter) {
            's' => sep = v.arg,
            else => return opt.refuse(c, "seq", o, USAGE),
        },
        else => return opt.refuse(c, "seq", o, USAGE),
    };

    var nums: [3]i64 = undefined;
    var n: usize = 0;
    var ops = opt.Operands.init(SPEC, args);
    while (ops.next()) |word| {
        if (n == nums.len) return c.write(USAGE);
        nums[n] = std.fmt.parseInt(i64, word, 10) catch {
            c.write("seq: not a number: ");
            c.write(word);
            c.put('\n');
            return;
        };
        n += 1;
    }
    // seq's three shapes: LAST; FIRST LAST; FIRST STEP LAST.
    const first: i64, const step: i64, const last: i64 = switch (n) {
        1 => .{ 1, 1, nums[0] },
        2 => .{ nums[0], 1, nums[1] },
        3 => .{ nums[0], nums[1], nums[2] },
        else => return c.write(USAGE),
    };
    if (step == 0) return c.write("seq: a step of zero never reaches the end\n");

    const span = if (step > 0) last - first else first - last;
    if (span < 0) return; // an empty sequence, as seq(1) prints nothing for one
    const count: usize = @intCast(@divFloor(span, if (step > 0) step else -step) + 1);
    if (count > MAX_COUNT) {
        var buf: [72]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "seq: {d} numbers is more than the {d} this prints\n", .{ count, MAX_COUNT }) catch "seq: too many numbers\n");
        return;
    }

    var v = first;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [24]u8 = undefined;
        c.write(std.fmt.bufPrint(&buf, "{d}", .{v}) catch "");
        c.write(sep);
        v += step;
    }
    // A separator that is not a newline leaves the cursor mid-line, exactly as
    // `seq -s ,` does; end the line so the next prompt starts on its own.
    if (!std.mem.eql(u8, sep, "\n")) c.put('\n');
}
