//! Where a text filter's input comes from, and how its lines are counted.
//!
//! Every filter in the command set (`cat`, `head`, `tail`, `grep`, `wc`, `sort`,
//! `uniq`, `cut`, `nl`, `more`) reads the same way: the files the line names, or
//! what a pipe fed it when it names none, or a refusal when there is neither.
//! Written once here, that rule is one behaviour with one wording; written per
//! command it was five slightly different ones, and the difference always shows
//! up as a tool that reads a pipe its neighbour ignores.
//!
//! `Inputs` is an ITERATOR, not a callback: a filter's body stays a plain loop,
//! and a missing file is reported and skipped exactly as coreutils does — one
//! bad name never costs the good ones their output.

const std = @import("std");
const console = @import("console.zig");
const opt = @import("opt.zig");
const patharg = @import("patharg.zig");
const vfs = @import("vfs");

/// One readable input: its text, and the name to print for it. `path` is empty
/// when the text came from the pipe, which is also how a filter knows not to
/// print a file header for it.
pub const Input = struct {
    path: []const u8,
    data: []const u8,
};

/// The inputs one command line names, in order.
pub const Inputs = struct {
    c: console.Console,
    /// The command's own name — every complaint is prefixed with it.
    name: []const u8,
    ops: opt.Operands,
    spec: []const u8,
    args: []const u8,
    started: bool = false,
    named_any: bool = false,

    /// `spec` is the option spec the command scanned with, so the operand pass
    /// skips the same words the option pass consumed.
    pub fn init(c: console.Console, name: []const u8, spec: []const u8, args: []const u8) Inputs {
        return .{ .c = c, .name = name, .ops = opt.Operands.init(spec, args), .spec = spec, .args = args };
    }

    /// The next input, or null at the end. A named file that cannot be read is
    /// reported and skipped; the pipe is yielded once, and only when the line
    /// named no file at all.
    pub fn next(self: *Inputs) ?Input {
        while (self.ops.next()) |path| {
            self.named_any = true;
            var buf: [vfs.MAX_PATH]u8 = undefined;
            const abs = patharg.resolve(self.c, path, &buf) orelse continue;
            if (vfs.kind(abs) == .dir) {
                self.complain(path, "is a directory");
                continue;
            }
            const data = vfs.read(abs) orelse {
                self.complain(path, "no such file");
                continue;
            };
            self.started = true;
            return .{ .path = path, .data = data };
        }
        if (self.named_any or self.started) return null;
        self.started = true;
        const data = self.c.stdin orelse {
            self.c.write(self.name);
            self.c.write(": no input (pipe something in or name a file)\n");
            return null;
        };
        return .{ .path = "", .data = data };
    }

    /// Whether the line names MORE THAN ONE file — what decides whether a
    /// filter prints per-file headers, as `tail`, `wc` and `grep` each do.
    pub fn many(self: *const Inputs) bool {
        var ops = opt.Operands.init(self.spec, self.args);
        _ = ops.next();
        return ops.next() != null;
    }

    fn complain(self: *Inputs, path: []const u8, what: []const u8) void {
        self.c.write(self.name);
        self.c.write(": ");
        self.c.write(path);
        self.c.write(": ");
        self.c.write(what);
        self.c.put('\n');
    }
};

/// The lines of `data`, WITHOUT the empty one a trailing newline would other-
/// wise yield: "a\nb\n" is two lines, which is what every tool here counts.
pub fn lines(data: []const u8) std.mem.SplitIterator(u8, .scalar) {
    const body = if (data.len > 0 and data[data.len - 1] == '\n') data[0 .. data.len - 1] else data;
    return std.mem.splitScalar(u8, body, '\n');
}

/// How many lines `lines` would yield.
pub fn lineCount(data: []const u8) usize {
    if (data.len == 0) return 0;
    var it = lines(data);
    var n: usize = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// Write one line and the newline it is printed with — the shape every filter's
/// inner loop ends in.
pub fn line(c: console.Console, text: []const u8) void {
    c.write(text);
    c.put('\n');
}
