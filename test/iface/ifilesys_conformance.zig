//! IFileSys contract conformance (spec R69): one shared vector suite that
//! every implementation of iface/ifilesys.zig must pass. Here the real ramdisk
//! store (drivers/storage/ramdisk.zig fileSys) and a purpose-built in-test
//! fake are seeded with the same flat file set and run through `verify`, which
//! exercises read/list/kind and the mount-root convention ("" is always .dir).
//! The FAT volume implementation has its own contents-specific suite
//! (fat_test.zig) against real mkfs.vfat images.
//!
//! The contract has two halves, and so does this file: every store answers the
//! read half, and each one answers the MUTATION half in one of exactly two
//! ways — it accepts mutation (`verifyWritable`) or it refuses all of it with
//! error.ReadOnly (`verifyReadOnly`). A store that did neither would be a third
//! kind of thing the callers have no case for.

const std = @import("std");
const ifilesys = @import("ifilesys");
const ramdisk = @import("testroot").storage.ramdisk;

const File = struct { name: []const u8, data: []const u8 };
const FILES = [_]File{
    .{ .name = "one.txt", .data = "first" },
    .{ .name = "two.dat", .data = "second-file" },
    .{ .name = "z", .data = "" },
};

/// The shared conformance vectors over a flat store holding FILES.
fn verify(fs: ifilesys.IFileSys) !void {
    // The mount root is always a directory; an absent path is null.
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("") orelse return error.RootNotDir);
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("nope.txt"));

    // Each file: kind .file, read returns the exact bytes.
    for (FILES) |f| {
        try std.testing.expectEqual(ifilesys.Kind.file, fs.kind(f.name) orelse return error.MissingKind);
        const got = fs.read(f.name) orelse return error.MissingRead;
        try std.testing.expectEqualStrings(f.data, got);
    }
    // read of a non-file is null.
    try std.testing.expectEqual(@as(?[]const u8, null), fs.read("nope.txt"));

    // list("") enumerates exactly FILES (order-independent), files typed .file
    // with the right size.
    var seen = [_]bool{false} ** FILES.len;
    const Collector = struct {
        files: *const [FILES.len]File,
        seen: *[FILES.len]bool,
        fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            for (self.files, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, e.name)) {
                    self.seen[i] = true;
                    // File entries carry their byte size.
                    if (e.kind == .file) std.debug.assert(e.size == f.data.len);
                }
            }
        }
    };
    var col = Collector{ .files = &FILES, .seen = &seen };
    try fs.list("", Collector.cb, &col);
    for (seen) |s| try std.testing.expect(s);

    // list of a file is NotADirectory.
    try std.testing.expectError(ifilesys.Error.NotADirectory, fs.list("one.txt", Collector.cb, &col));
}

/// The vectors every store that ACCEPTS mutation must satisfy, run against an
/// empty store. What a directory IS stays the store's own business (the ramdisk
/// implies one from a name; a FAT volume has real ones) — asserted here is only
/// what the contract states: what each call does, and which refusal each broken
/// precondition earns.
fn verifyWritable(fs: ifilesys.IFileSys) !void {
    const expectError = std.testing.expectError;

    // write creates, and replaces without leaving the old contents behind.
    try fs.write("a.txt", "one");
    try std.testing.expectEqualStrings("one", fs.read("a.txt").?);
    try fs.write("a.txt", "two");
    try std.testing.expectEqualStrings("two", fs.read("a.txt").?);

    // remove deletes it, and says so when there is nothing to delete.
    try fs.remove("a.txt");
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("a.txt"));
    try expectError(ifilesys.WriteError.NotFound, fs.remove("a.txt"));

    // mkdir creates a directory that exists while empty; a taken name is Exists.
    try fs.mkdir("d");
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("d").?);
    try expectError(ifilesys.WriteError.Exists, fs.mkdir("d"));
    try fs.rmdir("d");
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("d"));
    try expectError(ifilesys.WriteError.NotFound, fs.rmdir("d"));

    // A directory holding something is not silently emptied, and is not a file.
    try fs.write("d/inner.txt", "x");
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("d").?);
    try expectError(ifilesys.WriteError.NotEmpty, fs.rmdir("d"));
    try expectError(ifilesys.WriteError.IsADirectory, fs.write("d", "x"));
    try expectError(ifilesys.WriteError.IsADirectory, fs.remove("d"));

    // …and nothing may be put under a FILE, which has nothing under it.
    try expectError(ifilesys.WriteError.NotADirectory, fs.write("d/inner.txt/x", "x"));
    try expectError(ifilesys.WriteError.NotADirectory, fs.mkdir("d/inner.txt/x"));
    try fs.remove("d/inner.txt");
}

/// The vectors a store that accepts NO mutation must satisfy: every call is
/// refused as read-only — not ignored, and not reported as something absent.
fn verifyReadOnly(fs: ifilesys.IFileSys) !void {
    const ReadOnly = ifilesys.WriteError.ReadOnly;
    try std.testing.expectError(ReadOnly, fs.write("one.txt", "changed"));
    try std.testing.expectError(ReadOnly, fs.remove("one.txt"));
    try std.testing.expectError(ReadOnly, fs.mkdir("newdir"));
    try std.testing.expectError(ReadOnly, fs.rmdir("newdir"));
    // Refused means unchanged: the file it was told to overwrite still reads as it was.
    try std.testing.expectEqualStrings(FILES[0].data, fs.read(FILES[0].name).?);
}

test "IFileSys conformance: the REAL ramdisk fileSys" {
    ramdisk.init(std.testing.allocator);
    defer ramdisk.deinit();
    for (FILES) |f| try ramdisk.put(f.name, f.data);
    try verify(ramdisk.fileSys());
}

test "IFileSys conformance: the REAL ramdisk fileSys accepts mutation" {
    ramdisk.init(std.testing.allocator);
    defer ramdisk.deinit();
    try verifyWritable(ramdisk.fileSys());
}

test "IFileSys conformance: an in-memory FAKE" {
    var fake = FakeFs{};
    for (FILES) |f| fake.add(f.name, f.data);
    try verify(fake.fs());
}

test "IFileSys conformance: a read-only store refuses every mutation (STO-010)" {
    var fake = FakeFs{};
    for (FILES) |f| fake.add(f.name, f.data);
    try verifyReadOnly(fake.fs());
}

/// A minimal flat IFileSys over a fixed table — the fake half of the contract.
const FakeFs = struct {
    names: [16][]const u8 = undefined,
    datas: [16][]const u8 = undefined,
    n: usize = 0,

    fn add(self: *FakeFs, name: []const u8, data: []const u8) void {
        self.names[self.n] = name;
        self.datas[self.n] = data;
        self.n += 1;
    }

    fn read_(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        for (0..self.n) |i| if (std.mem.eql(u8, self.names[i], path)) return self.datas[i];
        return null;
    }
    fn kind_(ctx: *anyopaque, path: []const u8) ?ifilesys.Kind {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        if (path.len == 0) return .dir;
        for (0..self.n) |i| if (std.mem.eql(u8, self.names[i], path)) return .file;
        return null;
    }
    fn list_(ctx: *anyopaque, path: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        if (path.len != 0) return ifilesys.Error.NotADirectory; // only the root is a dir
        for (0..self.n) |i| cb(cb_ctx, .{ .name = self.names[i], .kind = .file, .size = self.datas[i].len });
    }

    // The read-only half of the contract, in the one form it takes.
    const vtable = ifilesys.IFileSys.VTable{
        .read = read_,
        .list = list_,
        .kind = kind_,
        .write = ifilesys.read_only.write,
        .remove = ifilesys.read_only.remove,
        .mkdir = ifilesys.read_only.mkdir,
        .rmdir = ifilesys.read_only.rmdir,
    };
    fn fs(self: *FakeFs) ifilesys.IFileSys {
        return .{ .ctx = self, .vtable = &vtable };
    }
};
