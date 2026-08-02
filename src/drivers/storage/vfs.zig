//! VFS — kudos's single hierarchical namespace, rooted at `/`:
//!
//!     /
//!     ├── ramdisk/   the in-memory store (volatile, boot-seeded; flat)
//!     └── usbdisk/   the USB stick's FAT volume — appears once USB mass
//!                    storage is up; absent until then
//!
//! `/` contains exactly the mounts (files cannot be created there). Every
//! terminal has a cwd (default /ramdisk); relative paths resolve against
//! it, `.`/`..` work (`..` clamps at `/`). Consumers: the shell's
//! cd/ls/cat/show (shell.zig — each command documents its own surface) and
//! the model viewer's file reads (modelview.zig). The netdebug file
//! protocol deliberately stays on the flat iramdisk seam (fileserv.zig):
//! the VFS is READ-ONLY routing — `fetch`/netdebug writes go to the
//! ramdisk directly, and no create/delete/rename exists here (v1).
//!
//! Architecture: a thin, PURE routing layer — path normalization + a fixed
//! mount table; everything else is delegated to the mounted store through
//! the `ifilesys.IFileSys` seam. Imports only that iface + std, so this
//! file is its own host-test root (tests: test/drivers/storage/vfs_test.zig).
//!
//! Mounts are registered once at boot (main_root.zig: the ramdisk always;
//! "usbdisk" joins when the USB FAT volume comes up) — no unmount, and a
//! duplicate or overflowing mount is a loud @panic (boot wiring bug).

const std = @import("std");
pub const ifilesys = @import("ifilesys");

/// Longest absolute path (mount prefix + name) — matches the ramdisk /
/// netdebug name cap plus room for "/usbdisk/" nesting.
pub const MAX_PATH: usize = 64;

const MAX_MOUNTS: usize = 2;

const Mount = struct {
    name: []const u8, // without slashes, e.g. "ramdisk"
    fs: ifilesys.IFileSys,
};

var mounts: [MAX_MOUNTS]Mount = undefined;
var nmounts: usize = 0;

/// Register a mount at boot. Wiring bugs (duplicate name, table full) panic.
pub fn mount(name: []const u8, fs: ifilesys.IFileSys) void {
    if (nmounts == MAX_MOUNTS) @panic("vfs: mount table full");
    for (mounts[0..nmounts]) |m| {
        if (std.mem.eql(u8, m.name, name)) @panic("vfs: duplicate mount");
    }
    mounts[nmounts] = .{ .name = name, .fs = fs };
    nmounts += 1;
}

/// Test-only: reset the mount table (each test wires its own fakes).
pub fn unmountAllForTest() void {
    nmounts = 0;
}

// ── path normalization (pure) ────────────────────────────────────────────

/// Join `arg` onto `cwd` (used only when `arg` is relative; `cwd` must be
/// absolute and already normalized), resolve `.` and `..` (clamped at the
/// root), collapse duplicate '/', strip any trailing '/'. Returns the
/// normalized ABSOLUTE path written into `out` ("/" for the root), or null
/// when the result would overflow MAX_PATH.
pub fn normalize(cwd: []const u8, arg: []const u8, out: *[MAX_PATH]u8) ?[]const u8 {
    var len: usize = 0; // bytes of `out` used; component-aligned, no trailing '/'

    const absolute = arg.len > 0 and arg[0] == '/';
    if (!absolute) {
        // Seed with the cwd's components (cwd is normalized: no '.'/'..').
        var it = std.mem.tokenizeScalar(u8, cwd, '/');
        while (it.next()) |comp| {
            if (1 + len + comp.len > MAX_PATH) return null;
            out[len] = '/';
            @memcpy(out[len + 1 ..][0..comp.len], comp);
            len += 1 + comp.len;
        }
    }

    var it = std.mem.tokenizeScalar(u8, arg, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            // Drop the last component; at the root ".." stays at the root.
            while (len > 0 and out[len - 1] != '/') len -= 1;
            if (len > 0) len -= 1; // the component's leading '/'
            continue;
        }
        if (1 + len + comp.len > MAX_PATH) return null;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..comp.len], comp);
        len += 1 + comp.len;
    }

    if (len == 0) {
        out[0] = '/';
        return out[0..1];
    }
    return out[0..len];
}

/// Split a normalized absolute path into its mount and the mount-relative
/// rest (no leading '/'; "" = the mount root). Null when the first
/// component names no mount. The root "/" itself has no mount — callers
/// handle it first.
fn route(abs: []const u8) ?struct { fs: ifilesys.IFileSys, rest: []const u8 } {
    std.debug.assert(abs.len > 1 and abs[0] == '/');
    const body = abs[1..];
    const slash = std.mem.indexOfScalar(u8, body, '/');
    const head = if (slash) |i| body[0..i] else body;
    const rest = if (slash) |i| body[i + 1 ..] else "";
    for (mounts[0..nmounts]) |m| {
        if (std.mem.eql(u8, m.name, head)) return .{ .fs = m.fs, .rest = rest };
    }
    return null;
}

// ── the namespace operations ─────────────────────────────────────────────

/// Whole-file read of a normalized absolute path; null when it is not an
/// existing file (the root and mount roots are directories).
pub fn read(abs: []const u8) ?[]const u8 {
    if (abs.len <= 1) return null;
    const r = route(abs) orelse return null;
    if (r.rest.len == 0) return null; // a mount root is a directory
    return r.fs.read(r.rest);
}

/// What `abs` names: the root and mounts are directories; everything else
/// asks the mount. Null = absent.
pub fn kind(abs: []const u8) ?ifilesys.Kind {
    if (abs.len == 1) return .dir; // "/"
    const r = route(abs) orelse return null;
    if (r.rest.len == 0) return .dir;
    return r.fs.kind(r.rest);
}

/// Enumerate a directory. `/` lists the mounts themselves (as directories).
pub fn list(abs: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
    if (abs.len == 1) {
        for (mounts[0..nmounts]) |m| {
            cb(cb_ctx, .{ .name = m.name, .kind = .dir, .size = 0 });
        }
        return;
    }
    const r = route(abs) orelse return ifilesys.Error.NotFound;
    return r.fs.list(r.rest, cb, cb_ctx);
}
