//! IFileSys — the contract a mounted store implements for the VFS
//! (vfs.zig owns the namespace docs). Pure vtable-type module: no
//! hardware/freestanding imports, so the kernel and the host tests compile
//! the same instance. Real implementations: the ramdisk (flat) and, once
//! USB mass storage lands, the FAT volume. Fakes live with the host tests.
//!
//! Paths given to a store are MOUNT-RELATIVE with no leading '/': "" names
//! the mount root, "models/rabbit.glb" a nested entry. The VFS owns all
//! normalization; stores never see ".", "..", or doubled separators.

pub const Kind = enum { file, dir };

pub const Entry = struct {
    name: []const u8, // entry name only (no path); valid only during the callback
    kind: Kind,
    size: usize, // bytes for files; 0 for directories
};

pub const Error = error{
    NotFound, // the path names nothing
    NotADirectory, // list() of a file
    IoFailed, // the store's medium failed (FAT: transport/corruption — the
    // volume records the specific cause; the ramdisk never returns this)
};

/// One directory entry per call; `ctx` is the caller's closure state.
pub const ListFn = *const fn (ctx: ?*anyopaque, entry: Entry) void;

pub const IFileSys = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whole-file read; null when `path` is not an existing file.
        read: *const fn (ctx: *anyopaque, path: []const u8) ?[]const u8,
        /// Enumerate one directory's entries through `cb`.
        list: *const fn (ctx: *anyopaque, path: []const u8, cb: ListFn, cb_ctx: ?*anyopaque) Error!void,
        /// What `path` names, or null when absent ("" is always .dir).
        kind: *const fn (ctx: *anyopaque, path: []const u8) ?Kind,
    };

    pub fn read(self: IFileSys, path: []const u8) ?[]const u8 {
        return self.vtable.read(self.ctx, path);
    }
    pub fn list(self: IFileSys, path: []const u8, cb: ListFn, cb_ctx: ?*anyopaque) Error!void {
        return self.vtable.list(self.ctx, path, cb, cb_ctx);
    }
    pub fn kind(self: IFileSys, path: []const u8) ?Kind {
        return self.vtable.kind(self.ctx, path);
    }
};
