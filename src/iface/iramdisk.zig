//! IRamdisk — the file-system contract (CLAUDE.md iface conventions).
//! Pure vtable-type module: NO hardware imports, compiled identically by the
//! kernel and host tests. Real implementation: src/drivers/storage/
//! ramdisk.zig (`ramdisk.fs()`); fake: test/support/ramdisk_sim.zig (RamdiskSim).
//!
//! Consumers: the netdebug file server (net/debug/fileserv.zig via fileproto.buildReply
//! — host-tested through this seam) and anything else that reads/writes
//! files without caring where they live.

/// The live file store, published by the driver that owns it at boot.
///
/// Apps and diagnostics that just want to read or write a file go through here rather
/// than importing the storage driver: they are in a different group, and `iface/` is
/// the only thing both groups may name. Null before the store is initialized.
pub var instance: ?IRamdisk = null;

pub const PutError = error{OutOfMemory};

/// One file's metadata + contents as the interface exposes it. `crc32` is
/// the IEEE CRC-32 of `data` for this `generation` (implementations may
/// cache it; the contract is only that it is correct).
pub const Entry = struct {
    name: []const u8,
    data: []const u8,
    generation: u32,
    crc32: u32,
};

pub const IRamdisk = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ctx: *anyopaque, name: []const u8, data: []const u8) PutError!void,
        get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
        count: *const fn (ctx: *anyopaque) usize,
        /// i < count(). Slices are valid until the next put().
        at: *const fn (ctx: *anyopaque, i: usize) Entry,
    };

    pub fn put(self: IRamdisk, name: []const u8, data: []const u8) PutError!void {
        return self.vtable.put(self.ctx, name, data);
    }
    pub fn get(self: IRamdisk, name: []const u8) ?[]const u8 {
        return self.vtable.get(self.ctx, name);
    }
    pub fn count(self: IRamdisk) usize {
        return self.vtable.count(self.ctx);
    }
    pub fn at(self: IRamdisk, i: usize) Entry {
        return self.vtable.at(self.ctx, i);
    }
};
