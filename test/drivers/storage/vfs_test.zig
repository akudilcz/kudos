//! Host tests of src/drivers/storage/vfs.zig.

const std = @import("std");
const vfs = @import("vfs");
const MAX_PATH = vfs.MAX_PATH;
const ifilesys = vfs.ifilesys;
const kind = vfs.kind;
const list = vfs.list;
const mount = vfs.mount;
const read = vfs.read;
const unmountAllForTest = vfs.unmountAllForTest;

/// One fake store: two files, plus a "models" directory holding one. Its four
/// mutation entries record what reached them rather than doing anything —
/// routing is what the VFS owns, and a store's own rules are the store's tests.
const FakeFs = struct {
    var last_op: []const u8 = "";
    var last_path: [MAX_PATH]u8 = undefined;
    var last_path_len: usize = 0;
    var last_data: []const u8 = "";

    fn record(op: []const u8, path: []const u8, data: []const u8) void {
        last_op = op;
        @memcpy(last_path[0..path.len], path);
        last_path_len = path.len;
        last_data = data;
    }
    fn lastPath() []const u8 {
        return last_path[0..last_path_len];
    }
    fn write_(_: *anyopaque, p: []const u8, data: []const u8) ifilesys.WriteError!void {
        record("write", p, data);
    }
    fn remove_(_: *anyopaque, p: []const u8) ifilesys.WriteError!void {
        record("remove", p, "");
    }
    fn mkdir_(_: *anyopaque, p: []const u8) ifilesys.WriteError!void {
        record("mkdir", p, "");
    }
    fn rmdir_(_: *anyopaque, p: []const u8) ifilesys.WriteError!void {
        record("rmdir", p, "");
    }

    fn read_(_: *anyopaque, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "a.txt")) return "AA";
        if (std.mem.eql(u8, path, "models/r.glb")) return "GLB!";
        return null;
    }
    fn list_(_: *anyopaque, path: []const u8, cb: ifilesys.ListFn, ctx: ?*anyopaque) ifilesys.Error!void {
        if (path.len == 0) {
            cb(ctx, .{ .name = "a.txt", .kind = .file, .size = 2 });
            cb(ctx, .{ .name = "models", .kind = .dir, .size = 0 });
            return;
        }
        if (std.mem.eql(u8, path, "models")) {
            cb(ctx, .{ .name = "r.glb", .kind = .file, .size = 4 });
            return;
        }
        if (read_(undefined, path) != null) return ifilesys.Error.NotADirectory;
        return ifilesys.Error.NotFound;
    }
    fn kind_(_: *anyopaque, path: []const u8) ?ifilesys.Kind {
        if (path.len == 0 or std.mem.eql(u8, path, "models")) return .dir;
        if (read_(undefined, path) != null) return .file;
        return null;
    }
    const vtable = ifilesys.IFileSys.VTable{
        .read = read_,
        .list = list_,
        .kind = kind_,
        .write = write_,
        .remove = remove_,
        .mkdir = mkdir_,
        .rmdir = rmdir_,
    };
    var ctx_byte: u8 = 0;
    fn iface() ifilesys.IFileSys {
        return .{ .ctx = &ctx_byte, .vtable = &vtable };
    }
};

/// normalize() against a static scratch buffer — the shape every test call uses.
fn norm(cwd: []const u8, arg: []const u8) ?[]const u8 {
    const S = struct {
        var buf: [MAX_PATH]u8 = undefined;
    };
    return vfs.normalize(cwd, arg, &S.buf);
}

test "normalize: absolute, relative, dot, dotdot, clamping, overflow" {
    const eq = std.testing.expectEqualStrings;
    try eq("/", norm("/", "/").?);
    try eq("/ramdisk", norm("/", "ramdisk").?);
    try eq("/ramdisk", norm("/", "/ramdisk/").?);
    try eq("/ramdisk/a.txt", norm("/ramdisk", "a.txt").?);
    try eq("/ramdisk/a.txt", norm("/", "//ramdisk//./a.txt").?);
    try eq("/", norm("/ramdisk", "..").?);
    try eq("/", norm("/", "../../..").?); // clamped at the root
    try eq("/usbdisk", norm("/ramdisk", "../usbdisk").?);
    try eq("/ramdisk", norm("/ramdisk", ".").?);
    try eq("/ramdisk/b", norm("/ramdisk/a", "../b").?);
    // Overflow: a component pushing past MAX_PATH is refused, not truncated.
    const long = "x" ** MAX_PATH;
    try std.testing.expectEqual(@as(?[]const u8, null), norm("/", long));
}

test "routing: read/kind/list over mounts; unknown mounts and roots" {
    unmountAllForTest();
    mount("ramdisk", FakeFs.iface());

    try std.testing.expectEqualStrings("AA", read("/ramdisk/a.txt").?);
    try std.testing.expectEqualStrings("GLB!", read("/ramdisk/models/r.glb").?);
    try std.testing.expectEqual(@as(?[]const u8, null), read("/ramdisk/missing"));
    try std.testing.expectEqual(@as(?[]const u8, null), read("/ramdisk")); // a dir
    try std.testing.expectEqual(@as(?[]const u8, null), read("/nope/x"));
    try std.testing.expectEqual(@as(?[]const u8, null), read("/"));

    try std.testing.expectEqual(ifilesys.Kind.dir, kind("/").?);
    try std.testing.expectEqual(ifilesys.Kind.dir, kind("/ramdisk").?);
    try std.testing.expectEqual(ifilesys.Kind.dir, kind("/ramdisk/models").?);
    try std.testing.expectEqual(ifilesys.Kind.file, kind("/ramdisk/a.txt").?);
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), kind("/ramdisk/zz"));
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), kind("/zz"));

    const Collect = struct {
        var names: [8][32]u8 = undefined;
        var lens: [8]usize = undefined;
        var kinds: [8]ifilesys.Kind = undefined;
        var n: usize = 0;
        fn cb(_: ?*anyopaque, e: ifilesys.Entry) void {
            @memcpy(names[n][0..e.name.len], e.name);
            lens[n] = e.name.len;
            kinds[n] = e.kind;
            n += 1;
        }
    };
    Collect.n = 0;
    try list("/", Collect.cb, null);
    try std.testing.expectEqual(@as(usize, 1), Collect.n);
    try std.testing.expectEqualStrings("ramdisk", Collect.names[0][0..Collect.lens[0]]);
    try std.testing.expectEqual(ifilesys.Kind.dir, Collect.kinds[0]);

    Collect.n = 0;
    try list("/ramdisk", Collect.cb, null);
    try std.testing.expectEqual(@as(usize, 2), Collect.n);

    Collect.n = 0;
    try list("/ramdisk/models", Collect.cb, null);
    try std.testing.expectEqual(@as(usize, 1), Collect.n);
    try std.testing.expectEqualStrings("r.glb", Collect.names[0][0..Collect.lens[0]]);

    try std.testing.expectError(ifilesys.Error.NotADirectory, list("/ramdisk/a.txt", Collect.cb, null));
    try std.testing.expectError(ifilesys.Error.NotFound, list("/ramdisk/zz", Collect.cb, null));
    try std.testing.expectError(ifilesys.Error.NotFound, list("/zz", Collect.cb, null));
}

test "routing: every mutation reaches its mount with the mount-relative path (STO-008)" {
    unmountAllForTest();
    mount("ramdisk", FakeFs.iface());
    const eq = std.testing.expectEqualStrings;

    try vfs.write("/ramdisk/notes/todo.txt", "buy milk");
    try eq("write", FakeFs.last_op);
    try eq("notes/todo.txt", FakeFs.lastPath());
    try eq("buy milk", FakeFs.last_data);

    try vfs.remove("/ramdisk/a.txt");
    try eq("remove", FakeFs.last_op);
    try eq("a.txt", FakeFs.lastPath());

    try vfs.mkdir("/ramdisk/notes");
    try eq("mkdir", FakeFs.last_op);
    try eq("notes", FakeFs.lastPath());

    try vfs.rmdir("/ramdisk/notes");
    try eq("rmdir", FakeFs.last_op);
    try eq("notes", FakeFs.lastPath());
}

test "routing: the namespace's own shape is not a caller's to change (STO-010)" {
    unmountAllForTest();
    mount("ramdisk", FakeFs.iface());
    const expectError = std.testing.expectError;
    const ReadOnly = ifilesys.WriteError.ReadOnly;

    // The root holds exactly the mounts, so nothing may be made or unmade there.
    try expectError(ReadOnly, vfs.write("/x.txt", "hi"));
    try expectError(ReadOnly, vfs.mkdir("/newmount"));
    try expectError(ReadOnly, vfs.remove("/ramdisk"));
    try expectError(ReadOnly, vfs.rmdir("/ramdisk")); // unmounting is not a delete
    try expectError(ReadOnly, vfs.write("/ramdisk", "hi"));

    // An unknown mount is absent, not read-only: the two need different fixes.
    try expectError(ifilesys.WriteError.NotFound, vfs.write("/nope/x.txt", "hi"));
    try expectError(ifilesys.WriteError.NotFound, vfs.rmdir("/nope/dir"));
}
