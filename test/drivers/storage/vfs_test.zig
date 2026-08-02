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

/// One flat fake store: two files, plus a "models" directory holding one.
const FakeFs = struct {
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
    const vtable = ifilesys.IFileSys.VTable{ .read = read_, .list = list_, .kind = kind_ };
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
