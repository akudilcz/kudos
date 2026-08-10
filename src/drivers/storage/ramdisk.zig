//! In-RAM file store: a name -> bytes map in the heap.
//! Seeded with files embedded into the kernel. No disk, no persistence.
//!
//! A name may contain '/', and that is the whole of the directory model: a
//! DIRECTORY EXISTS IF SOMETHING LIVES UNDER IT, or if it was created empty
//! (`mkdir`). "notes/2026/plan.txt" therefore makes "notes" and "notes/2026"
//! directories the moment it is written, and they stop existing when the last
//! entry under them goes. Implying directories rather than storing them keeps
//! the store one list — the flat `iramdisk` seam (put/get/count/at, which the
//! netdebug file mirror walks) sees exactly the files, unchanged, while the
//! `ifilesys` seam below presents the same names as a tree.

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
    /// Whether `data` is BORROWED — bytes that live in the kernel image rather
    /// than on the heap (see `putStatic`). Borrowed bytes are never freed and
    /// never resized; everything else about the file is ordinary.
    static: bool = false,
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
// The same names the flat seam above stores, presented as a tree: a '/' in a
// name is a directory boundary (see the file header), and `empty_dirs` holds
// the directories `mkdir` made that nothing lives under yet.

/// Re-exported so a caller reached through this module (the host tests) shares
/// this module's single `ifilesys` instance — its `Kind` must be the same type.
pub const ifilesys = @import("ifilesys");

/// True when `name` lives UNDER directory `dir` — strictly below it, so a name
/// equal to `dir` is not under it. The root ("") holds everything.
fn under(name: []const u8, dir: []const u8) bool {
    if (dir.len == 0) return true;
    return name.len > dir.len and name[dir.len] == '/' and std.mem.startsWith(u8, name, dir);
}

/// The one component of `name` that `dir` holds directly, and whether `name`
/// continues below it (which makes that component a directory). `name` must be
/// under `dir`.
fn childOf(name: []const u8, dir: []const u8) struct { name: []const u8, nested: bool } {
    const rest = if (dir.len == 0) name else name[dir.len + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    return .{ .name = if (slash) |i| rest[0..i] else rest, .nested = slash != null };
}

// Every name the tree knows: the files, then the empty directories. One index
// space so a walk can dedupe children across both lists without allocating.
fn entryCount() usize {
    return files.items.len + empty_dirs.items.len;
}
fn entryName(i: usize) []const u8 {
    return if (i < files.items.len) files.items[i].name else empty_dirs.items[i - files.items.len];
}
fn entryIsFile(i: usize) bool {
    return i < files.items.len;
}

/// What `path` names, as the tree sees it — the shared answer behind `fsKind`
/// and every mutation's precondition.
fn kindOf(path: []const u8) ?ifilesys.Kind {
    if (path.len == 0) return .dir; // the mount root
    if (get(path) != null) return .file;
    var i: usize = 0;
    while (i < entryCount()) : (i += 1) {
        const n = entryName(i);
        if (under(n, path) or (!entryIsFile(i) and std.mem.eql(u8, n, path))) return .dir;
    }
    return null;
}

/// Whether an entry BEFORE `i` already named this child of `dir` — the
/// no-allocation dedupe that lists a subdirectory once however many entries
/// live under it.
fn alreadyListed(i: usize, dir: []const u8, name: []const u8) bool {
    var j: usize = 0;
    while (j < i) : (j += 1) {
        const n = entryName(j);
        if (under(n, dir) and std.mem.eql(u8, childOf(n, dir).name, name)) return true;
    }
    return false;
}

/// Every directory along `path` must BE a directory: a name under a file
/// ("motd.txt/notes") would be stored but unreachable through the tree, so it
/// is refused at the seam that owns the tree rather than created and lost.
fn parentsAreDirs(path: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, i, '/')) |s| : (i = s + 1) {
        if (get(path[0..s]) != null) return false;
    }
    return true;
}

fn fsRead(_: *anyopaque, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null; // the mount root is a directory
    return get(path);
}
fn fsList(_: *anyopaque, path: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
    switch (kindOf(path) orelse return ifilesys.Error.NotFound) {
        .file => return ifilesys.Error.NotADirectory,
        .dir => {},
    }
    var i: usize = 0;
    while (i < entryCount()) : (i += 1) {
        const n = entryName(i);
        if (!under(n, path)) continue;
        const child = childOf(n, path);
        if (alreadyListed(i, path, child.name)) continue;
        // A name that continues below this component describes a directory, and
        // so does an `empty_dirs` entry; only a file named directly here is one.
        const is_dir = child.nested or !entryIsFile(i);
        cb(cb_ctx, .{
            .name = child.name,
            .kind = if (is_dir) .dir else .file,
            .size = if (is_dir) 0 else files.items[i].data.len,
        });
    }
}
fn fsKind(_: *anyopaque, path: []const u8) ?ifilesys.Kind {
    return kindOf(path);
}
fn fsWrite(_: *anyopaque, path: []const u8, data: []const u8) ifilesys.WriteError!void {
    if (kindOf(path) == .dir) return ifilesys.WriteError.IsADirectory;
    if (!parentsAreDirs(path)) return ifilesys.WriteError.NotADirectory;
    put(path, data) catch return ifilesys.WriteError.NoSpace;
}
fn fsRemove(_: *anyopaque, path: []const u8) ifilesys.WriteError!void {
    for (files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, path)) continue;
        alloc.free(f.name);
        if (!f.static) alloc.free(f.data); // borrowed bytes are the image's, not the heap's
        _ = files.orderedRemove(i); // insertion order IS the listing order
        return;
    }
    // No file by that name: either it is a directory, or nothing is there.
    if (kindOf(path) != null) return ifilesys.WriteError.IsADirectory;
    return ifilesys.WriteError.NotFound;
}
fn fsMkdir(_: *anyopaque, path: []const u8) ifilesys.WriteError!void {
    if (kindOf(path) != null) return ifilesys.WriteError.Exists;
    if (!parentsAreDirs(path)) return ifilesys.WriteError.NotADirectory;
    const copy = alloc.dupe(u8, path) catch return ifilesys.WriteError.NoSpace;
    empty_dirs.append(copy) catch {
        alloc.free(copy);
        return ifilesys.WriteError.NoSpace;
    };
}
fn fsRmdir(_: *anyopaque, path: []const u8) ifilesys.WriteError!void {
    if (path.len == 0) return ifilesys.WriteError.ReadOnly; // the mount root is not ours to delete
    switch (kindOf(path) orelse return ifilesys.WriteError.NotFound) {
        .file => return ifilesys.WriteError.NotADirectory,
        .dir => {},
    }
    var i: usize = 0;
    while (i < entryCount()) : (i += 1) {
        if (under(entryName(i), path)) return ifilesys.WriteError.NotEmpty;
    }
    // It exists and holds nothing, so it is one `mkdir` created: drop it and
    // the directory stops existing, because nothing implies it any more.
    for (empty_dirs.items, 0..) |d, j| {
        if (!std.mem.eql(u8, d, path)) continue;
        alloc.free(d);
        _ = empty_dirs.orderedRemove(j);
        return;
    }
    return ifilesys.WriteError.NotFound;
}
const filesys_vtable = ifilesys.IFileSys.VTable{
    .read = fsRead,
    .list = fsList,
    .kind = fsKind,
    .write = fsWrite,
    .remove = fsRemove,
    .mkdir = fsMkdir,
    .rmdir = fsRmdir,
};

/// The store as an ifilesys.IFileSys (mounted at /ramdisk — vfs.zig).
pub fn fileSys() ifilesys.IFileSys {
    return .{ .ctx = @ptrCast(&fs_ctx), .vtable = &filesys_vtable };
}

var alloc: std.mem.Allocator = undefined;
var files: std.array_list.Managed(File) = undefined;
/// Directories `mkdir` created that hold nothing yet — the only directories the
/// store has to remember, since every other one is implied by a file's name.
var empty_dirs: std.array_list.Managed([]const u8) = undefined;

/// Start with an empty store. The caller seeds whatever files the system should boot
/// with — a storage driver has no business knowing what a welcome message or a 3D model
/// is, and nothing here would change if the seed list did.
pub fn init(a: std.mem.Allocator) void {
    alloc = a;
    files = std.array_list.Managed(File).init(a);
    empty_dirs = std.array_list.Managed([]const u8).init(a);
    iramdisk.instance = fs(); // anything above the driver layer reaches us through here
}

/// Create or replace a file. `data` is copied into the heap so callers may free
/// their buffer afterwards.
pub fn put(name: []const u8, data: []const u8) !void {
    const copy = try alloc.dupe(u8, data);
    for (files.items) |*f| {
        if (std.mem.eql(u8, f.name, name)) {
            // Borrowed bytes belong to the kernel image, not the heap: replacing
            // such a file is allowed, freeing what it pointed at is not.
            if (!f.static) alloc.free(f.data);
            f.static = false;
            f.data = copy;
            f.generation +%= 1;
            f.crc_valid = false;
            return;
        }
    }
    const name_copy = try alloc.dupe(u8, name);
    try files.append(.{ .name = name_copy, .data = copy });
}

/// Create a file whose contents are BORROWED, not copied: bytes that live for
/// the machine's lifetime because they live in the kernel image itself
/// (@embedFile). The guest images a build bakes in are hundreds of megabytes,
/// and copying them onto the heap to make them visible here would cost that
/// memory twice for one set of bytes nobody will ever modify.
///
/// `data` must outlive the store. A later `put` to the same name replaces the
/// file with an ordinary heap copy and leaves the borrowed bytes alone.
pub fn putStatic(name: []const u8, data: []const u8) !void {
    for (files.items) |*f| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        if (!f.static) alloc.free(f.data);
        f.static = true;
        f.data = data;
        f.generation +%= 1;
        f.crc_valid = false;
        return;
    }
    const name_copy = try alloc.dupe(u8, name);
    try files.append(.{ .name = name_copy, .data = data, .static = true });
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

/// Free every entry's owned name/data (each `put()` dupes both onto the heap),
/// every remembered empty directory, plus both lists' own backing arrays — the
/// symmetric teardown to init(). The
/// kernel never calls it (the ramdisk lives for the machine's lifetime); any
/// other owner of the store must.
pub fn deinit() void {
    for (files.items) |f| {
        alloc.free(f.name);
        if (!f.static) alloc.free(f.data); // borrowed bytes were never ours
    }
    files.deinit();
    for (empty_dirs.items) |d| alloc.free(d);
    empty_dirs.deinit();
}
