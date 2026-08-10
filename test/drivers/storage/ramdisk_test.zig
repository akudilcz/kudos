//! Host tests of src/drivers/storage/ramdisk.zig (reached through the storage_root module-root shim).

const std = @import("std");
const ramdisk = @import("testroot").storage.ramdisk;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const get = ramdisk.get;
const init = ramdisk.init;
const iramdisk = ramdisk.iramdisk;
const list = ramdisk.list;
const put = ramdisk.put;
const testing = std.testing;

/// Fresh empty store on the test allocator, so each test starts clean.
fn testReset() void {
    init(std.testing.allocator);
}

/// The module's own symmetric teardown (frees every duped name/data + the list).
fn testDeinit() void {
    ramdisk.deinit();
}

test {
    std.testing.refAllDecls(ramdisk);
}

test "get() on an empty store returns null" {
    testReset();
    defer testDeinit();
    try expect(get("missing.txt") == null);
}

// STO-001: the ramdisk is the in-memory file store; ownership and replace
// semantics below are its contract.
test "put() then get() round-trips the data, and the caller's buffer can be freed after" {
    testReset();
    defer testDeinit();
    const buf = try testing.allocator.dupe(u8, "hello world");
    try put("greeting.txt", buf);
    testing.allocator.free(buf); // put() must have copied; this must not corrupt the store
    const got = get("greeting.txt").?;
    try expectEqualStrings("hello world", got);
}

test "put() with an existing name REPLACES the contents, does not duplicate the entry" {
    testReset();
    defer testDeinit();
    try put("a.txt", "first");
    try put("a.txt", "second"); // same name: replace, not append
    try expectEqualStrings("second", get("a.txt").?);
    try expectEqual(@as(usize, 1), list().len); // still exactly one entry, not two
}

test "list() reflects insertion order and count across multiple distinct files" {
    testReset();
    defer testDeinit();
    try put("a.txt", "1");
    try put("b.txt", "2");
    try put("c.txt", "3");
    const l = list();
    try expectEqual(@as(usize, 3), l.len);
    try expectEqualStrings("a.txt", l[0].name);
    try expectEqualStrings("b.txt", l[1].name);
    try expectEqualStrings("c.txt", l[2].name);
}

// ── the tree the ifilesys seam presents (the /ramdisk mount) ─────────────────
// STO-001: names carry the hierarchy — a directory exists exactly while
// something lives under it, or while `mkdir` remembers it.

const ifilesys = ramdisk.ifilesys;
const Kind = ifilesys.Kind;
const WriteError = ifilesys.WriteError;

fn fsys() ifilesys.IFileSys {
    return ramdisk.fileSys();
}

/// Collects one directory listing so a test can assert names, kinds and order.
const Listing = struct {
    var names: [8][32]u8 = undefined;
    var lens: [8]usize = undefined;
    var kinds: [8]Kind = undefined;
    var sizes: [8]usize = undefined;
    var n: usize = 0;

    fn cb(_: ?*anyopaque, e: ifilesys.Entry) void {
        @memcpy(names[n][0..e.name.len], e.name);
        lens[n] = e.name.len;
        kinds[n] = e.kind;
        sizes[n] = e.size;
        n += 1;
    }
    fn of(path: []const u8) !void {
        n = 0;
        try fsys().list(path, cb, null);
    }
    fn name(i: usize) []const u8 {
        return names[i][0..lens[i]];
    }
};

test "a name with '/' in it makes every directory above it exist (STO-009)" {
    testReset();
    defer testDeinit();
    try fsys().write("notes/2026/plan.txt", "ship it");

    try expectEqual(Kind.dir, fsys().kind("").?); // the mount root
    try expectEqual(Kind.dir, fsys().kind("notes").?);
    try expectEqual(Kind.dir, fsys().kind("notes/2026").?);
    try expectEqual(Kind.file, fsys().kind("notes/2026/plan.txt").?);
    try expectEqualStrings("ship it", fsys().read("notes/2026/plan.txt").?);
    // Directories are not files, and a partial name is not a prefix match.
    try expect(fsys().read("notes") == null);
    try expect(fsys().kind("not") == null);
}

test "list() names each subdirectory once, however many entries live under it" {
    testReset();
    defer testDeinit();
    try fsys().write("motd.txt", "hi");
    try fsys().write("notes/a.txt", "1");
    try fsys().write("notes/b.txt", "22");
    try fsys().write("notes/deep/c.txt", "333");

    try Listing.of("");
    try expectEqual(@as(usize, 2), Listing.n); // motd.txt and notes — not four files
    try expectEqualStrings("motd.txt", Listing.name(0));
    try expectEqual(Kind.file, Listing.kinds[0]);
    try expectEqual(@as(usize, 2), Listing.sizes[0]);
    try expectEqualStrings("notes", Listing.name(1));
    try expectEqual(Kind.dir, Listing.kinds[1]);

    try Listing.of("notes");
    try expectEqual(@as(usize, 3), Listing.n);
    try expectEqualStrings("a.txt", Listing.name(0));
    try expectEqualStrings("b.txt", Listing.name(1));
    try expectEqualStrings("deep", Listing.name(2));
    try expectEqual(Kind.dir, Listing.kinds[2]);

    try std.testing.expectError(ifilesys.Error.NotADirectory, Listing.of("motd.txt"));
    try std.testing.expectError(ifilesys.Error.NotFound, Listing.of("nope"));
}

test "mkdir() makes a directory that exists while holding nothing, and rmdir() unmakes it (STO-009)" {
    testReset();
    defer testDeinit();
    try fsys().mkdir("empty");

    try expectEqual(Kind.dir, fsys().kind("empty").?);
    try Listing.of("empty");
    try expectEqual(@as(usize, 0), Listing.n);
    try Listing.of("");
    try expectEqual(@as(usize, 1), Listing.n);
    try expectEqualStrings("empty", Listing.name(0));
    try expectEqual(Kind.dir, Listing.kinds[0]);
    // It is a directory, not a file: the flat store still holds nothing.
    try expectEqual(@as(usize, 0), list().len);

    try fsys().rmdir("empty");
    try expect(fsys().kind("empty") == null);
}

test "a directory that still holds something cannot be unmade, and its name cannot be reused" {
    testReset();
    defer testDeinit();
    try fsys().mkdir("notes");
    try fsys().write("notes/a.txt", "1");

    try std.testing.expectError(WriteError.NotEmpty, fsys().rmdir("notes"));
    try std.testing.expectError(WriteError.Exists, fsys().mkdir("notes"));
    try std.testing.expectError(WriteError.Exists, fsys().mkdir("notes/a.txt"));
    try std.testing.expectError(WriteError.IsADirectory, fsys().write("notes", "x"));
    try std.testing.expectError(WriteError.IsADirectory, fsys().remove("notes"));

    // Emptied, it is still there — `mkdir` remembered it independently of what
    // was written under it, so removing the file does not remove the directory.
    try fsys().remove("notes/a.txt");
    try expectEqual(Kind.dir, fsys().kind("notes").?);
    try fsys().rmdir("notes");
    try expect(fsys().kind("notes") == null);
}

test "an implied directory stops existing when the last entry under it goes" {
    testReset();
    defer testDeinit();
    try fsys().write("notes/a.txt", "1");
    try expectEqual(Kind.dir, fsys().kind("notes").?);

    try fsys().remove("notes/a.txt");
    try expect(fsys().kind("notes") == null); // nothing implies it any more
    try expectEqual(@as(usize, 0), list().len);
}

test "remove() deletes one file and leaves the rest in their order (STO-008)" {
    testReset();
    defer testDeinit();
    try fsys().write("a.txt", "1");
    try fsys().write("b.txt", "2");
    try fsys().write("c.txt", "3");

    try fsys().remove("b.txt");
    const l = list();
    try expectEqual(@as(usize, 2), l.len);
    try expectEqualStrings("a.txt", l[0].name);
    try expectEqualStrings("c.txt", l[1].name);
    try std.testing.expectError(WriteError.NotFound, fsys().remove("b.txt"));
    try std.testing.expectError(WriteError.NotFound, fsys().rmdir("b.txt"));
}

test "nothing may be created under a FILE, and the mount root is nobody's to delete" {
    testReset();
    defer testDeinit();
    try fsys().write("motd.txt", "hi");

    // "motd.txt/notes" would be stored but unreachable through the tree.
    try std.testing.expectError(WriteError.NotADirectory, fsys().write("motd.txt/notes.txt", "x"));
    try std.testing.expectError(WriteError.NotADirectory, fsys().mkdir("motd.txt/notes"));
    try std.testing.expectError(WriteError.NotADirectory, fsys().rmdir("motd.txt"));
    try std.testing.expectError(WriteError.ReadOnly, fsys().rmdir(""));
    try expectEqual(@as(usize, 1), list().len);
}

test "write() replaces a file's contents without a second entry, and copies the caller's bytes (STO-008)" {
    testReset();
    defer testDeinit();
    const buf = try testing.allocator.dupe(u8, "first");
    try fsys().write("a.txt", buf);
    testing.allocator.free(buf); // the store must have copied

    try fsys().write("a.txt", "second");
    try expectEqualStrings("second", fsys().read("a.txt").?);
    try expectEqual(@as(usize, 1), list().len);
}

test "init() yields an EMPTY store and publishes it through the iramdisk seam" {
    iramdisk.instance = null;
    init(testing.allocator); // the actual boot-time entry point, not a re-implementation
    defer testDeinit();

    // The driver seeds nothing. Which files a system boots with is the caller's
    // decision (src/main_root.zig `seedRamdisk`), so a store that arrives pre-populated
    // would mean the driver had grown a policy it has no business holding.
    try expectEqual(@as(usize, 0), list().len);

    // Everything above the driver layer reaches the store through this, so init that
    // forgot to publish would leave the shell and the file server with no file system
    // at all while the driver itself looked perfectly healthy.
    try expect(iramdisk.instance != null);
    try expectEqual(@as(usize, 0), iramdisk.instance.?.count());
}

test "putStatic() BORROWS its bytes: no copy, never freed, and replaceable (STO-008)" {
    testReset();
    defer testDeinit();

    // A baked guest image is hundreds of megabytes of .rodata; the store must
    // publish it without copying it. `const` data here stands in for that: the
    // test allocator would trip on any attempt to free or resize it, and the
    // pointer identity is what proves nothing was duplicated.
    const baked = "BORROWED-BYTES";
    try ramdisk.putStatic("virt/demo/bzImage", baked);
    const got = get("virt/demo/bzImage").?;
    try expect(got.ptr == baked.ptr);

    // It is an ordinary file in every other way: it lists, and it can be
    // replaced by a real write — which must take a heap copy and leave the
    // borrowed bytes alone.
    try expectEqual(@as(usize, 1), list().len);
    try put("virt/demo/bzImage", "over");
    const after = get("virt/demo/bzImage").?;
    try expect(after.ptr != baked.ptr);
    try expectEqualStrings("over", after);

    // And a borrowed file can be removed without freeing what it pointed at.
    try ramdisk.putStatic("virt/demo/initramfs.cpio.gz", baked);
    try ramdisk.fileSys().remove("virt/demo/initramfs.cpio.gz");
    try expect(get("virt/demo/initramfs.cpio.gz") == null);
}
