//! In-RAM file store: a flat name -> bytes map in the heap.
//! Seeded with files embedded into the kernel. No disk, no persistence.

const std = @import("std");

const crc32 = @import("crc32.zig");

/// One ramdisk file: its name and its heap-owned contents. `generation`
/// bumps on every put() to the name; `crc` is the lazily-computed CRC-32 of
/// `data` for that generation (0xffff_ffff sentinel = not yet computed —
/// CRC-32 of real data can also be that value, so `crc_valid` is the flag).
/// Both serve the netdebug mirror.
pub const File = struct {
    name: []const u8,
    data: []const u8,
    generation: u32 = 1,
    crc: u32 = 0,
    crc_valid: bool = false,
};

/// CRC-32 of a file, computed on first use per generation.
pub fn fileCrc(f: *File) u32 {
    if (!f.crc_valid) {
        f.crc = crc32.crc32(f.data);
        f.crc_valid = true;
    }
    return f.crc;
}

// ── iramdisk.IRamdisk implementation (the `fs()` seam) ──────────────────────

pub const iramdisk = @import("iramdisk");

fn vtPut(_: *anyopaque, name: []const u8, data: []const u8) iramdisk.PutError!void {
    put(name, data) catch return error.OutOfMemory;
}
fn vtGet(_: *anyopaque, name: []const u8) ?[]const u8 {
    return get(name);
}
fn vtCount(_: *anyopaque) usize {
    return files.items.len;
}
fn vtAt(_: *anyopaque, i: usize) iramdisk.Entry {
    const f = &files.items[i];
    return .{ .name = f.name, .data = f.data, .generation = f.generation, .crc32 = fileCrc(f) };
}
const vtable = iramdisk.IRamdisk.VTable{ .put = vtPut, .get = vtGet, .count = vtCount, .at = vtAt };
var fs_ctx: u8 = 0; // module-global store; ctx unused

/// The store as an iramdisk.IRamdisk (the seam netdebug's fileserv consumes).
pub fn fs() iramdisk.IRamdisk {
    return .{ .ctx = @ptrCast(&fs_ctx), .vtable = &vtable };
}

// ── ifilesys.IFileSys implementation (the /ramdisk VFS mount) ────────────────
// The ramdisk is FLAT: "" is the one directory holding
// every file; any deeper path is absent (a name containing '/' can't exist).

const ifilesys = @import("ifilesys");

fn fsRead(_: *anyopaque, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null; // the mount root is a directory
    return get(path);
}
fn fsList(_: *anyopaque, path: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
    if (path.len != 0) {
        return if (get(path) != null) ifilesys.Error.NotADirectory else ifilesys.Error.NotFound;
    }
    for (files.items) |f| {
        cb(cb_ctx, .{ .name = f.name, .kind = .file, .size = f.data.len });
    }
}
fn fsKind(_: *anyopaque, path: []const u8) ?ifilesys.Kind {
    if (path.len == 0) return .dir;
    return if (get(path) != null) .file else null;
}
const filesys_vtable = ifilesys.IFileSys.VTable{ .read = fsRead, .list = fsList, .kind = fsKind };

/// The store as an ifilesys.IFileSys (mounted at /ramdisk — vfs.zig).
pub fn fileSys() ifilesys.IFileSys {
    return .{ .ctx = @ptrCast(&fs_ctx), .vtable = &filesys_vtable };
}

var alloc: std.mem.Allocator = undefined;
var files: std.array_list.Managed(File) = undefined;

/// Start with an empty store. The caller seeds whatever files the system should boot
/// with — a storage driver has no business knowing what a welcome message or a 3D model
/// is, and nothing here would change if the seed list did.
pub fn init(a: std.mem.Allocator) void {
    alloc = a;
    files = std.array_list.Managed(File).init(a);
    iramdisk.instance = fs(); // anything above the driver layer reaches us through here
}

/// Create or replace a file. `data` is copied into the heap so callers may free
/// their buffer afterwards.
pub fn put(name: []const u8, data: []const u8) !void {
    const copy = try alloc.dupe(u8, data);
    for (files.items) |*f| {
        if (std.mem.eql(u8, f.name, name)) {
            alloc.free(f.data);
            f.data = copy;
            f.generation +%= 1;
            f.crc_valid = false;
            return;
        }
    }
    const name_copy = try alloc.dupe(u8, name);
    try files.append(.{ .name = name_copy, .data = copy });
}

/// Look up a file's contents by name, or null if no such file exists.
pub fn get(name: []const u8) ?[]const u8 {
    for (files.items) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.data;
    }
    return null;
}

/// All files currently in the store (backed by the live list; do not retain).
pub fn list() []const File {
    return files.items;
}

/// Free every entry's owned name/data (each `put()` dupes both onto the heap)
/// plus the list's own backing array — the symmetric teardown to init(). The
/// kernel never calls it (the ramdisk lives for the machine's lifetime); any
/// other owner of the store must.
pub fn deinit() void {
    for (files.items) |f| {
        alloc.free(f.name);
        alloc.free(f.data);
    }
    files.deinit();
}
