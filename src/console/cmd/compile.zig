//! `compile PATH [NAME]` — turn a Zig source file on a mounted store into a
//! runnable `.kudos` app, by sending it to the compile factory (ARCH-012).
//!
//! kudos carries no compiler, so this command is a network round trip: the
//! source goes to the factory named by AI.CFG's `factory=` — the same one the
//! agent's compile tool uses, and the same request — and what comes back is a
//! position-independent image the loader verifies, saved as
//! `/ramdisk/<name>.kudos` and run with `run <name>`.
//!
//! It runs on the core-0 command worker, like `net fetch`, because the round
//! trip blocks and a session task must not be held on the network.

const std = @import("std");
const console = @import("../console.zig");
const agenttools = @import("../agenttools.zig");
const vfs = @import("vfs");

const USAGE =
    \\usage: compile PATH [NAME] | compile factory [HOST:PORT]
    \\  PATH  a Zig source file (e.g. hello.zig), absolute or relative
    \\  NAME  the module name; default: the file name without its extension
    \\  factory        show which factory compiles are sent to
    \\  factory H:P    send them somewhere else, from now until reboot
    \\
;

/// The module name a bare path implies: the file name with any extension cut.
/// `/ramdisk/apps/hello.zig` is the module `hello`, because that is the name
/// the user then types at `run`.
fn defaultName(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |d| base[0..d] else base;
}

pub fn run(c: console.Console, args: []const u8) void {
    const trimmed = std.mem.trim(u8, args, " \t");
    if (trimmed.len == 0) {
        c.write(USAGE);
        return;
    }
    const sp = std.mem.indexOfScalar(u8, trimmed, ' ');
    const path_arg = if (sp) |i| trimmed[0..i] else trimmed;
    const name_arg = if (sp) |i| std.mem.trim(u8, trimmed[i + 1 ..], " \t") else "";

    // `factory` is where compiles GO, and it has to be settable at runtime: the
    // zig-server guest announces its address when its DHCP lease lands, which is
    // after this kernel booted and read AI.CFG. A compiler you cannot point at
    // is a compiler you cannot use.
    if (std.mem.eql(u8, path_arg, "factory")) {
        if (name_arg.len != 0) agenttools.setFactory(name_arg);
        if (agenttools.factoryHost()) |h| {
            c.write("compile: factory ");
            c.write(h);
            c.write("\n");
        } else {
            c.write("compile: no factory set — `compile factory HOST:PORT`, or set\n");
            c.write("compile: factory=<host:port> in AI.CFG on the USB drive\n");
        }
        return;
    }

    var pathbuf: [vfs.MAX_PATH]u8 = undefined;
    const path = vfs.normalize(c.cwd(), path_arg, &pathbuf) orelse {
        c.write("compile: path too long\n");
        return;
    };
    const source = vfs.read(path) orelse {
        c.write("compile: no such file: ");
        c.write(path);
        c.write("\n");
        return;
    };

    const name = if (name_arg.len != 0) name_arg else defaultName(path);
    if (name.len == 0) {
        c.write("compile: that path has no name to give the module\n");
        return;
    }

    // The factory answer is a paragraph either way — the saved file and how to
    // run it, or the compiler's own errors — so it is built as text and then
    // written, exactly as the agent's tool does.
    var out = std.array_list.Managed(u8).init(c.a);
    defer out.deinit();
    c.write("compile: sending ");
    c.write(path);
    c.write(" to the factory ...\n");
    agenttools.compileSource("app", name, source, &out) catch |e| {
        c.write("compile: the factory could not be reached (");
        c.write(@errorName(e));
        c.write(")\n");
        return;
    };
    c.write(out.items);
    c.write("\n");
}
