//! `show PATH [max]` — open a model-viewer window on a `.glb` file.

const std = @import("std");
const vfs = @import("vfs");
const modelcache = @import("modelcache");
const console = @import("../console.zig");
const patharg = @import("../patharg.zig");
const complete = @import("../complete.zig");

/// `show PATH [max]` — open a model-viewer window on a `.glb` file; `max`
/// opens it maximised. PATH resolves against the cwd exactly like every other
/// path command (cat/ls/cd), so a relative name or a bare filename both find
/// the file in the current directory. A bare name that is NOT in the cwd then
/// falls back to /ramdisk then /usbdisk (the grab-a-model convenience). The
/// shell only VALIDATES (file exists, .glb extension) and spawns — parse +
/// VRAM upload happen in the app's first draw on core 0 (modelview.zig), so a
/// file that turns out malformed still opens a window with the loud in-window
/// placeholder.
pub fn run(c: console.Console, args: []const u8) void {
    var it = std.mem.tokenizeScalar(u8, args, ' ');
    const name = it.next() orelse {
        c.write("usage: kudos show PATH [max]\n");
        return;
    };
    const max_arg = it.next();
    const maximized = max_arg != null and std.mem.eql(u8, max_arg.?, "max");
    if (max_arg != null and !maximized) {
        c.write("usage: kudos show PATH [max]\n");
        return;
    }
    if (!modelcache.supportedName(name)) {
        c.write("error: '");
        c.write(name);
        c.write("' is not a .glb model\n");
        return;
    }

    // Resolve against the cwd first, like every other path command. This is
    // what makes a relative name or a bare filename find the file sitting in
    // the current directory.
    var buf: [vfs.MAX_PATH]u8 = undefined;
    var abs: []const u8 = patharg.resolve(c, name, &buf) orelse return;
    if (vfs.kind(abs) != .file) {
        // Not in the cwd. A BARE name (no '/') also gets the grab-a-model
        // search of the fixed mounts, in order, so `show duck.glb` still works
        // from anywhere.
        if (std.mem.indexOfScalar(u8, name, '/') != null) {
            c.write("error: no such file '");
            c.write(abs);
            c.write("'\n");
            return;
        }
        abs = for (complete.BARE_ROOTS) |root| {
            const cand = vfs.normalize(root, name, &buf) orelse continue;
            if (vfs.kind(cand) == .file) break cand;
        } else {
            c.write("error: '");
            c.write(name);
            c.write("' not found in the cwd, /ramdisk, or /usbdisk\n");
            return;
        };
    }

    c.spawnModel(abs, maximized) catch {
        c.write("error: could not open a model window\n");
        return;
    };
    c.write("opened ");
    c.write(abs);
    c.write("\n");
}
