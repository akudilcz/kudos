//! `background PATH` — change the desktop background image (spec R24).

const std = @import("std");
const vfs = @import("vfs");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const png = @import("modelcache").png;

/// `background PATH` — decode a PNG off the VFS (typically /usbdisk) and hand
/// it to the desktop, which swaps the wallpaper texture at the next frame
/// start. The decode runs here on the command worker, never on the frame
/// path; every failure is reported on the terminal.
pub fn run(c: console.Console, args: []const u8) void {
    if (args.len == 0) {
        c.write("usage: background PATH   (a .png, e.g. /usbdisk/pic.png)\n");
        return;
    }
    if (!std.mem.endsWith(u8, args, ".png")) {
        c.write("error: background must be a .png\n");
        return;
    }
    var buf: [vfs.MAX_PATH]u8 = undefined;
    const abs = patharg.resolve(c, args, &buf) orelse return;
    const data = vfs.read(abs) orelse {
        c.write("error: no such file '");
        c.write(abs);
        c.write("'\n");
        return;
    };
    const img = png.decode(c.a, data) catch |e| {
        c.write("error: decode failed: ");
        c.write(@errorName(e));
        c.put('\n');
        return;
    };
    if (!c.setBackground(img)) {
        img.deinit(c.a);
        c.write("error: a background change is already pending\n");
        return;
    }
    c.write("background: ");
    c.write(abs);
    c.put('\n');
}
