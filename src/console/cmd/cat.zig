//! `cat PATH` — print a file.

const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

/// `cat PATH` — print a file's contents (with a trailing newline if it
/// lacks one); errors name the resolved absolute path.
pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: cat PATH\n");
        return;
    }
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, args, &buf) orelse return;
    if (vfs.read(abs)) |data| {
        c.write(data);
        if (data.len == 0 or data[data.len - 1] != '\n') c.put('\n');
    } else {
        c.write("error: no such file '");
        c.write(abs);
        c.write("'\n");
    }
}
