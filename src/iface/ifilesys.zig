//! IFileSys — the contract a mounted store implements for the VFS
//! (vfs.zig owns the namespace docs). Pure vtable-type module: no
//! hardware/freestanding imports, so the kernel and the host tests compile
//! the same instance. Real implementations: the ramdisk (flat) and, once
//! USB mass storage lands, the FAT volume. Fakes live with the host tests.
//!
//! Paths given to a store are MOUNT-RELATIVE with no leading '/': "" names
//! the mount root, "models/rabbit.glb" a nested entry. The VFS owns all
//! normalization; stores never see ".", "..", or doubled separators.
//!
//! The contract covers reading AND mutation. A store that accepts no mutation
//! is not a smaller contract — it answers `error.ReadOnly` (see `read_only`
//! below), so a caller learns why rather than finding a missing capability.

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

/// Why a mutation was refused. Every case is distinct so a caller can say which
/// invariant failed rather than "write failed" — the agent acts on these.
pub const WriteError = error{
    NotFound, // the path, or a directory along it, names nothing
    NotADirectory, // a component of the path names a file
    IsADirectory, // write/remove aimed at a directory
    Exists, // mkdir onto a name already taken
    NotEmpty, // rmdir of a directory that still holds entries
    ReadOnly, // this store does not accept mutation at all
    NoSpace, // the store is full
    IoFailed, // the store's medium failed
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
        /// Create or replace the file at `path` with a COPY of `data`, so the
        /// caller may reuse its buffer as soon as the call returns.
        write: *const fn (ctx: *anyopaque, path: []const u8, data: []const u8) WriteError!void,
        /// Delete the file at `path`.
        remove: *const fn (ctx: *anyopaque, path: []const u8) WriteError!void,
        /// Create the directory `path`.
        mkdir: *const fn (ctx: *anyopaque, path: []const u8) WriteError!void,
        /// Delete the directory `path`, which must hold no entries.
        rmdir: *const fn (ctx: *anyopaque, path: []const u8) WriteError!void,
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
    pub fn write(self: IFileSys, path: []const u8, data: []const u8) WriteError!void {
        return self.vtable.write(self.ctx, path, data);
    }
    pub fn remove(self: IFileSys, path: []const u8) WriteError!void {
        return self.vtable.remove(self.ctx, path);
    }
    pub fn mkdir(self: IFileSys, path: []const u8) WriteError!void {
        return self.vtable.mkdir(self.ctx, path);
    }
    pub fn rmdir(self: IFileSys, path: []const u8) WriteError!void {
        return self.vtable.rmdir(self.ctx, path);
    }
};

/// A store that accepts no mutation fills its four write slots with these, so
/// "read-only" is one stated decision rather than four hand-written refusals.
pub const read_only = struct {
    pub fn write(_: *anyopaque, _: []const u8, _: []const u8) WriteError!void {
        return WriteError.ReadOnly;
    }
    pub fn remove(_: *anyopaque, _: []const u8) WriteError!void {
        return WriteError.ReadOnly;
    }
    pub fn mkdir(_: *anyopaque, _: []const u8) WriteError!void {
        return WriteError.ReadOnly;
    }
    pub fn rmdir(_: *anyopaque, _: []const u8) WriteError!void {
        return WriteError.ReadOnly;
    }
};
