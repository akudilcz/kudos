//! `tee [-a] FILE...` — write the pipe's text to files AND on to the terminal,
//! so a stage's output can be kept and read in the same line:
//! `ls -l | tee listing.txt | grep zig`.

const std = @import("std");
const console = @import("../console.zig");
const opt = @import("../opt.zig");
const patharg = @import("../patharg.zig");
const redirect = @import("../redirect.zig");
const vfs = @import("vfs");

const USAGE = "usage: tee [-a] FILE...\n";
const SPEC = "a";

pub fn run(c: console.Console, args: []const u8) void {
    var append = false;
    var sc = opt.Scan.init(SPEC, args);
    while (sc.next()) |o| switch (o) {
        .flag => |ch| switch (ch) {
            'a' => append = true,
            else => return opt.refuse(c, "tee", o, USAGE),
        },
        else => return opt.refuse(c, "tee", o, USAGE),
    };

    const data = c.stdin orelse {
        c.write("tee: no input (tee reads what a pipe feeds it)\n");
        return;
    };

    var ops = opt.Operands.init(SPEC, args);
    var named = false;
    while (ops.next()) |path| {
        named = true;
        var buf: [vfs.MAX_PATH]u8 = undefined;
        const abs = patharg.resolve(c, path, &buf) orelse continue;
        write(c, path, abs, data, append);
    }
    if (!named) c.write("tee: no file named — nothing was kept\n");
    // The pipe's text passes through whatever the files did: a tee that failed
    // to write must not also swallow the output it was teeing.
    c.write(data);
}

/// The most an appended file may come to. The same budget a `>>` redirection
/// works to (redirect.MAX_BYTES), because they are the same operation typed two
/// ways, and a file that would pass it is refused whole rather than truncated.
const APPEND_MAX_BYTES: usize = redirect.MAX_BYTES;

/// Write (or append) `data` to `abs`, naming the store's refusal.
fn write(c: console.Console, shown: []const u8, abs: []const u8, data: []const u8, append: bool) void {
    if (!append) {
        vfs.write(abs, data) catch |e| return complain(c, shown, e);
        return;
    }
    // Append with no seek: read what is there and write the whole file back.
    // The store holds a file as ONE value, so this IS the append.
    const existing = vfs.read(abs) orelse "";
    if (existing.len == 0) {
        vfs.write(abs, data) catch |e| return complain(c, shown, e);
        return;
    }
    var joined: [APPEND_MAX_BYTES]u8 = undefined;
    if (existing.len + data.len > joined.len) {
        var buf: [96]u8 = undefined;
        c.write("tee: ");
        c.write(shown);
        c.write(std.fmt.bufPrint(&buf, ": appending would take more than {d} bytes — not written\n", .{joined.len}) catch ": too large — not written\n");
        return;
    }
    @memcpy(joined[0..existing.len], existing);
    @memcpy(joined[existing.len..][0..data.len], data);
    vfs.write(abs, joined[0 .. existing.len + data.len]) catch |e| complain(c, shown, e);
}

fn complain(c: console.Console, path: []const u8, e: vfs.ifilesys.WriteError) void {
    c.write("tee: ");
    c.write(path);
    c.write(": ");
    c.write(patharg.writeErrorText(e));
    c.put('\n');
}
