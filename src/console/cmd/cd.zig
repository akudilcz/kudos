//! `cd [PATH]` — change the terminal's working directory.

const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");

/// `cd [PATH]` — change this terminal's working directory; the target must
/// be a directory (`/`, a mount root, or a directory on the volume). With
/// no argument, print the cwd.
pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write(c.cwd());
        c.put('\n');
        return;
    }
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, args, &buf) orelse return;
    switch (vfs.kind(abs) orelse {
        c.write("error: no such directory '");
        c.write(abs);
        c.write("'\n");
        return;
    }) {
        .dir => c.setCwd(abs),
        .file => {
            c.write("error: '");
            c.write(abs);
            c.write("' is a file\n");
        },
    }
}
