//! FAT16/FAT32 reader tests (src/drivers/storage/fat.zig).
//! Run against REAL volumes: test/drivers/storage/fixtures/fat{16,32}.img.gz are mkfs.vfat
//! filesystems inside sfdisk MBR partition tables, populated with mtools
//! (scripts/tests/make-fat-fixtures.sh — 8.3 names, multi-slot LFNs, nested
//! directories, a 300 KiB pattern file crossing hundreds of clusters, and a
//! real .glb). The images are gunzipped into memory and served through a
//! fake IBlockDev.

const std = @import("std");
const fat = @import("fat");
const glb = @import("glb");
const iblockdev = @import("iblockdev");
const ifilesys = @import("ifilesys");

const ta = std.testing.allocator;

test {
    std.testing.refAllDecls(fat);
}

// ── the in-memory block device ───────────────────────────────────────────

const MemDev = struct {
    image: []u8,
    /// Counted, not ignored: STO-007 asks whether a mutation left the volume
    /// durable, and the only observable of that is the barrier reaching the
    /// device. `writes_since_sync` catches the other half — data written after
    /// the last barrier is data a power cut loses.
    sync_calls: usize = 0,
    writes_since_sync: usize = 0,

    fn read(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(buf[0..@intCast(len)], self.image[@intCast(off)..][0..@intCast(len)]);
    }
    fn write(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(self.image[@intCast(off)..][0..@intCast(len)], buf[0..@intCast(len)]);
        self.writes_since_sync += 1;
    }
    fn sync(ctx: *anyopaque) iblockdev.Error!void {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        self.sync_calls += 1;
        self.writes_since_sync = 0;
    }
    fn nblocks(ctx: *anyopaque) u64 {
        const self: *MemDev = @ptrCast(@alignCast(ctx));
        return self.image.len / iblockdev.SECTOR;
    }
    const vtable = iblockdev.IBlockDev.VTable{ .read = read, .write = write, .sync = sync, .nblocks = nblocks };
    fn iface(self: *MemDev) iblockdev.IBlockDev {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// A block device that fails ONE read of a chosen LBA, clobbering the caller's
/// buffer first — the shape a real flaky bulk read has (the msc data phase
/// writes into the buffer before the CSW verdict). Used to prove a failed FAT
/// read never leaves a stale, poisoned cache.
const FailDev = struct {
    image: []u8,
    poison_lba: ?u64 = null, // fail+clobber the next read whose span covers this

    fn read(ctx: *anyopaque, lba: u64, count: u32, buf: []u8) iblockdev.Error!void {
        const self: *FailDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        if (self.poison_lba) |p| {
            if (lba <= p and p < lba + count) {
                @memset(buf[0..@intCast(len)], 0xFF); // clobber before failing
                self.poison_lba = null; // one-shot
                return iblockdev.Error.BlockIoFailed;
            }
        }
        @memcpy(buf[0..@intCast(len)], self.image[@intCast(off)..][0..@intCast(len)]);
    }
    fn write(ctx: *anyopaque, lba: u64, count: u32, buf: []const u8) iblockdev.Error!void {
        const self: *FailDev = @ptrCast(@alignCast(ctx));
        const off = lba * iblockdev.SECTOR;
        const len = @as(u64, count) * iblockdev.SECTOR;
        if (off + len > self.image.len) return iblockdev.Error.BlockOutOfRange;
        @memcpy(self.image[@intCast(off)..][0..@intCast(len)], buf[0..@intCast(len)]);
    }
    fn sync(_: *anyopaque) iblockdev.Error!void {}
    fn nblocks(ctx: *anyopaque) u64 {
        const self: *FailDev = @ptrCast(@alignCast(ctx));
        return self.image.len / iblockdev.SECTOR;
    }
    const vtable = iblockdev.IBlockDev.VTable{ .read = read, .write = write, .sync = sync, .nblocks = nblocks };
    fn iface(self: *FailDev) iblockdev.IBlockDev {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn gunzip(gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var out = std.array_list.Managed(u8).init(ta);
    errdefer out.deinit();
    const window = try ta.alloc(u8, std.compress.flate.max_window_len);
    defer ta.free(window);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, window);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try dec.reader.readSliceShort(&buf);
        if (n == 0) break;
        try out.appendSlice(buf[0..n]);
    }
    return out.toOwnedSlice();
}

const Fixture = struct {
    image: []u8,
    dev: *MemDev,
    vol: *fat.Volume,

    fn open(gz: []const u8) !Fixture {
        const image = try gunzip(gz);
        errdefer ta.free(image);
        const dev = try ta.create(MemDev);
        errdefer ta.destroy(dev);
        dev.* = .{ .image = image };
        const vol = try fat.mount(ta, dev.iface());
        return .{ .image = image, .dev = dev, .vol = vol };
    }

    fn close(self: Fixture) void {
        if (self.vol.file_buf) |b| ta.free(b);
        ta.destroy(self.vol);
        ta.destroy(self.dev);
        ta.free(self.image);
    }
};

// ── directory-listing collector ──────────────────────────────────────────

const Collect = struct {
    names: [16][64]u8 = undefined,
    lens: [16]usize = undefined,
    kinds: [16]ifilesys.Kind = undefined,
    sizes: [16]usize = undefined,
    n: usize = 0,

    fn cb(ctx: ?*anyopaque, e: ifilesys.Entry) void {
        const self: *Collect = @ptrCast(@alignCast(ctx.?));
        @memcpy(self.names[self.n][0..e.name.len], e.name);
        self.lens[self.n] = e.name.len;
        self.kinds[self.n] = e.kind;
        self.sizes[self.n] = e.size;
        self.n += 1;
    }

    fn find(self: *const Collect, name: []const u8) ?usize {
        for (0..self.n) |i| {
            if (std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return i;
        }
        return null;
    }
};

/// The 300 KiB pattern file's generator (make-fat-fixtures.sh, verbatim).
fn patternByte(i: usize) u8 {
    return @truncate(i * 7 + (i >> 8) * 13);
}

// ── the shared per-volume checks (both FAT types must behave identically) ─

fn checkVolume(fx: Fixture, comptime hello: []const u8) !void {
    const fs = fx.vol.fileSys();

    // The stick is the boot medium: the volume can write, but not through this
    // seam (fat.zig) — a VFS caller is told so, and the file it aimed at is
    // still there afterwards.
    const ReadOnly = ifilesys.WriteError.ReadOnly;
    try std.testing.expectError(ReadOnly, fs.write("HELLO.TXT", "clobbered"));
    try std.testing.expectError(ReadOnly, fs.remove("HELLO.TXT"));
    try std.testing.expectError(ReadOnly, fs.mkdir("newdir"));
    try std.testing.expectError(ReadOnly, fs.rmdir("models"));
    try std.testing.expectEqualStrings(hello, fs.read("HELLO.TXT").?);

    // Root listing: 8.3 name, multi-slot LFN, lowercase LFN, directory.
    var c = Collect{};
    try fs.list("", Collect.cb, &c);
    try std.testing.expect(c.find("HELLO.TXT") != null);
    try std.testing.expect(c.find("a-much-longer-file-name.txt") != null);
    try std.testing.expect(c.find("pattern.bin") != null);
    const mi = c.find("models").?;
    try std.testing.expectEqual(ifilesys.Kind.dir, c.kinds[mi]);
    try std.testing.expectEqual(ifilesys.Kind.file, c.kinds[c.find("HELLO.TXT").?]);
    try std.testing.expectEqual(hello.len, c.sizes[c.find("HELLO.TXT").?]);

    // Whole-file reads: 8.3, LFN, and path lookup is case-insensitive.
    try std.testing.expectEqualStrings(hello, fs.read("HELLO.TXT").?);
    try std.testing.expectEqualStrings(hello, fs.read("hello.txt").?);
    try std.testing.expectEqualStrings(hello, fs.read("a-much-longer-file-name.txt").?);
    try std.testing.expectEqualStrings(hello, fs.read("A-MUCH-LONGER-FILE-NAME.TXT").?);

    // Nested directories.
    try std.testing.expectEqualStrings(hello, fs.read("models/deep/nested.txt").?);
    var md = Collect{};
    try fs.list("models", Collect.cb, &md);
    try std.testing.expect(md.find("rabbit.glb") != null);
    try std.testing.expectEqual(ifilesys.Kind.dir, md.kinds[md.find("deep").?]);

    // kind().
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("").?);
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("models/deep").?);
    try std.testing.expectEqual(ifilesys.Kind.file, fs.kind("models/rabbit.glb").?);
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("nope.txt"));
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("models/nope/x"));

    // The 300 KiB pattern file: hundreds of clusters — every byte checked.
    const pat = fs.read("pattern.bin").?;
    try std.testing.expectEqual(@as(usize, 300 * 1024), pat.len);
    for (pat, 0..) |b, i| {
        if (b != patternByte(i)) {
            std.debug.print("pattern mismatch at {d}\n", .{i});
            return error.TestUnexpectedResult;
        }
    }

    // The real model: FAT read → GLB parse end-to-end (the `show
    // /usbdisk/models/rabbit.glb` path). The single-slot buffer is live
    // only until the next read, so parse immediately.
    const rabbit = fs.read("models/rabbit.glb").?;
    const duck = @embedFile("duck_glb");
    try std.testing.expectEqualSlices(u8, duck, rabbit);
    const model = try glb.parse(ta, rabbit);
    defer model.deinit(ta);
    try std.testing.expectEqual(@as(u32, 2399), model.vert_count);

    // Error taxonomy.
    try std.testing.expectEqual(@as(?[]const u8, null), fs.read("models")); // a dir
    try std.testing.expectEqual(@as(?[]const u8, null), fs.read("missing.bin"));
    var e = Collect{};
    try std.testing.expectError(ifilesys.Error.NotADirectory, fs.list("HELLO.TXT", Collect.cb, &e));
    try std.testing.expectError(ifilesys.Error.NotFound, fs.list("nope", Collect.cb, &e));
}

// STO-003 (FAT32) and STO-005 (VFAT long names): the real mkfs.vfat volume,
// walked byte-for-byte — the multi-slot LFN must list and read on every fixture.
test "FAT32 fixture: mount, list, LFN, nested reads, chain integrity, glb end-to-end" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    try std.testing.expect(!fx.vol.is_fat16);
    try checkVolume(fx, "hello from 0c\n");
}

test "a failed FAT-sector read leaves no poisoned cache (sticky-FatCorrupt guard)" {
    // pattern.bin (300 KiB, 512-B clusters) walks several FAT sectors. Fail the
    // read of the 2nd FAT sector mid-walk, clobbering the cache buffer: a later
    // read of the FIRST sector must RE-READ, not return a cache hit on garbage.
    const image = try gunzip(@embedFile("fixtures/fat32.img.gz"));
    var dev = FailDev{ .image = image };
    const vol = try fat.mount(ta, dev.iface());
    defer {
        if (vol.file_buf) |b| ta.free(b);
        ta.destroy(vol);
        ta.free(image);
    }
    const fs = vol.fileSys();

    // Baseline: the file reads whole.
    try std.testing.expectEqual(@as(usize, 300 * 1024), fs.read("pattern.bin").?.len);

    // Poison the 2nd FAT sector's next read; the chain walk fails there. (If the
    // fixture's layout ever keeps pattern.bin inside one FAT sector this first
    // assertion fails loudly — the poison would never fire.)
    dev.poison_lba = vol.fat_lba + 1;
    try std.testing.expectEqual(@as(?[]const u8, null), fs.read("pattern.bin"));

    // The one-shot fault is spent. A re-read must succeed: fatEntry for the low
    // clusters lives in the FIRST FAT sector, whose cache entry the failed read
    // clobbered. Pre-fix (fat_sec_lba not invalidated across the read) this is a
    // cache hit on 0xFF garbage → bogus chain → null. Post-fix it re-reads.
    const again = fs.read("pattern.bin") orelse return error.CachePoisoned;
    try std.testing.expectEqual(@as(usize, 300 * 1024), again.len);
    for (again, 0..) |b, i| {
        if (b != patternByte(i)) return error.TestUnexpectedResult;
    }
}

test "LogFile: extent resolve + in-place writeAt/readAt round-trip (the boot-log path)" {
    // openLog resolves pattern.bin (300 KiB, hundreds of clusters) to a flat
    // sector-extent list; writeAt rewrites byte ranges IN PLACE and readAt reads
    // them back — the flight-recorder subset. Its own Fixture, since
    // the writes mutate the in-memory image.
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    var lf = try fx.vol.openLog("pattern.bin");
    try std.testing.expectEqual(@as(u64, 300 * 1024), lf.size);
    try std.testing.expect(lf.nruns >= 1);

    // Write a marker spanning a sector boundary (sub-sector RMW on both ends),
    // then across a cluster boundary deeper in the file, and read each back.
    const marker = "KUDOS-BOOTLOG-ROUND-TRIP-0123456789-spanning-a-sector-edge!!";
    try lf.writeAt(500, marker); // 500..~559 straddles the 512-byte sector line
    var got: [marker.len]u8 = undefined;
    try lf.readAt(500, &got);
    try std.testing.expectEqualStrings(marker, &got);

    // A second write far into the file (crosses at least one cluster run).
    const at2: u64 = 200 * 1024 + 37;
    try lf.writeAt(at2, marker);
    try lf.readAt(at2, &got);
    try std.testing.expectEqualStrings(marker, &got);

    // Bytes OUTSIDE the written ranges are untouched (verify a nearby original).
    var orig: [16]u8 = undefined;
    try lf.readAt(1000, &orig);
    for (orig, 0..) |b, i| try std.testing.expectEqual(patternByte(1000 + i), b);

    // Growing past the file end is a loud error, never a silent metadata write.
    try std.testing.expectError(fat.Error.FatCorrupt, lf.writeAt(300 * 1024 - 4, marker));
    // A missing file is FatNotFound, not a create.
    try std.testing.expectError(fat.Error.FatNotFound, fx.vol.openLog("does-not-exist.txt"));
}

// ── the general write path: create / append / delete (§4a) ────────────────

test "path canonicalization: '', '/', '/dir/' all resolve at every entry point" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();

    // "/" must be the root everywhere ('' already was) — the original create
    // test failed on list("/") returning NotFound, not on create itself.
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("/").?);
    var c1 = Collect{};
    try fs.list("/", Collect.cb, &c1);
    var c2 = Collect{};
    try fs.list("", Collect.cb, &c2);
    try std.testing.expectEqual(c2.n, c1.n);
    try std.testing.expect(c1.find("HELLO.TXT") != null);
    // Trailing slash on a directory; leading slash on a file.
    var c3 = Collect{};
    try fs.list("/models/", Collect.cb, &c3);
    try std.testing.expect(c3.find("rabbit.glb") != null);
    try std.testing.expectEqualStrings("hello from 0c\n", fs.read("/HELLO.TXT").?);
}

test "create + append + read-back: a new file the reader sees (metadata write)" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();

    // Create a brand-new 8.3 file in the root (allocates a cluster + writes a
    // dir entry) and append data crossing multiple sectors + a cluster boundary.
    var f = try fx.vol.create("/SHOT0001.PPM");
    var payload: [9000]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    try f.append(payload[0..5000]);
    try f.append(payload[5000..]); // second append continues the chain

    // kudos's OWN reader must now see it, at the exact bytes.
    try std.testing.expectEqual(ifilesys.Kind.file, fs.kind("/SHOT0001.PPM").?);
    const got = fs.read("/SHOT0001.PPM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 9000), got.len);
    try std.testing.expectEqualSlices(u8, &payload, got);

    // It shows up in a root listing with the right size.
    var col = Collect{};
    try fs.list("/", Collect.cb, &col);
    const idx = col.find("SHOT0001.PPM") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 9000), col.sizes[idx]);

    // Create + append inside a SUBDIRECTORY (the /usbdisk/shots/ use case).
    var g = try fx.vol.create("/models/CAP01.TXT");
    try g.append("in a subdir\n");
    try std.testing.expectEqualStrings("in a subdir\n", fs.read("/models/CAP01.TXT").?);

    // Re-creating the same name is FatExists (not a silent second entry).
    try std.testing.expectError(fat.Error.FatExists, fx.vol.create("/SHOT0001.PPM"));
    // A non-8.3 name is rejected loudly, never silently mangled.
    try std.testing.expectError(fat.Error.FatBadName, fx.vol.create("/this-name-is-way-too-long.ppm"));
}

test "openFile append to an EXISTING file, then delete" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();

    // HELLO.TXT exists in the fixture; append and verify the extended content.
    // (read() uses a single-slot buffer — copy out before the next read.)
    const before = fs.read("HELLO.TXT") orelse return error.TestUnexpectedResult;
    var orig: [64]u8 = undefined;
    const orig_len = before.len;
    @memcpy(orig[0..orig_len], before);

    var f = try fx.vol.openFile("/HELLO.TXT");
    try f.append("APPENDED-TAIL\n");
    const after = fs.read("HELLO.TXT") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(orig_len + 14, after.len);
    try std.testing.expectEqualSlices(u8, orig[0..orig_len], after[0..orig_len]);
    try std.testing.expectEqualStrings("APPENDED-TAIL\n", after[orig_len..]);

    // Delete a file we created; the reader must no longer find it, and its
    // clusters must be freed (a second create reuses the space without error).
    var t = try fx.vol.create("/DELME.TXT");
    try t.append("temporary\n");
    try std.testing.expectEqual(ifilesys.Kind.file, fs.kind("/DELME.TXT").?);
    try fx.vol.remove("/DELME.TXT");
    try std.testing.expectEqual(@as(?ifilesys.Kind, null), fs.kind("/DELME.TXT"));
    try std.testing.expectError(fat.Error.FatNotFound, fx.vol.remove("/DELME.TXT"));
    // The deleted slot + clusters are reusable.
    var t2 = try fx.vol.create("/DELME.TXT");
    try t2.append("recreated\n");
    try std.testing.expectEqualStrings("recreated\n", fs.read("/DELME.TXT").?);
}

test "mkdir: a new directory the reader lists into (the /usbdisk/shots case)" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();

    try fx.vol.mkdir("/shots");
    try std.testing.expectEqual(ifilesys.Kind.dir, fs.kind("/shots").?);
    // Empty at birth ('.'/'..' are skipped by the lister).
    var c0 = Collect{};
    try fs.list("/shots", Collect.cb, &c0);
    try std.testing.expectEqual(@as(usize, 0), c0.n);
    // Create + read back a file inside it — the exact usbshot flow.
    var f = try fx.vol.create("/shots/SHOT0001.PPM");
    try f.append("P6 fake ppm payload");
    try std.testing.expectEqualStrings("P6 fake ppm payload", fs.read("/shots/SHOT0001.PPM").?);
    var c1 = Collect{};
    try fs.list("/shots", Collect.cb, &c1);
    try std.testing.expect(c1.find("SHOT0001.PPM") != null);
    // mkdir over an existing name is FatExists.
    try std.testing.expectError(fat.Error.FatExists, fx.vol.mkdir("/shots"));
}

test "FSInfo free-cluster count stays fsck-clean through create/append/remove" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();

    // Count free clusters the way fsck does: scan every FAT entry.
    const scanFree = struct {
        fn f(v: *fat.Volume, img: []const u8) u32 {
            // FAT32 entries at fat_lba; volume-relative offsets into the image.
            var free: u32 = 0;
            var c: u32 = 2;
            while (c < v.n_clusters + 2) : (c += 1) {
                const off: usize = @intCast(v.fat_lba * 512 + @as(u64, c) * 4);
                const e = std.mem.readInt(u32, img[off..][0..4], .little) & 0x0FFF_FFFF;
                if (e == 0) free += 1;
            }
            return free;
        }
    }.f;
    const onDisk = struct {
        fn f(v: *fat.Volume, img: []const u8) u32 {
            const off: usize = @intCast(v.fsinfo_lba * 512 + 488);
            return std.mem.readInt(u32, img[off..][0..4], .little);
        }
    }.f;

    try std.testing.expect(fx.vol.fsinfo_lba != 0); // mkfs.vfat wrote an FSInfo

    var f = try fx.vol.create("/FSI.BIN");
    var chunk: [40 * 1024]u8 = undefined;
    @memset(&chunk, 0xAB);
    try f.append(&chunk);
    // After the append's syncMeta the ON-DISK FSInfo equals the fsck scan.
    try std.testing.expectEqual(scanFree(fx.vol, fx.image), onDisk(fx.vol, fx.image));

    try fx.vol.remove("/FSI.BIN");
    try std.testing.expectEqual(scanFree(fx.vol, fx.image), onDisk(fx.vol, fx.image));

    try fx.vol.mkdir("/FSIDIR");
    try std.testing.expectEqual(scanFree(fx.vol, fx.image), onDisk(fx.vol, fx.image));
}

test "append growth: a file spanning many freshly-allocated clusters" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();

    // Append well past one cluster in uneven chunks (forces chain extension on
    // several boundaries) and verify every byte — the screenshot-sized case.
    var f = try fx.vol.create("/BIG.BIN");
    var total: usize = 0;
    var chunk: [1777]u8 = undefined;
    while (total < 40 * 1024) {
        for (&chunk, 0..) |*b, i| b.* = patternByte(total + i);
        try f.append(&chunk);
        total += chunk.len;
    }
    const got = fs.read("/BIG.BIN") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(total, got.len);
    for (got, 0..) |b, i| {
        if (b != patternByte(i)) {
            std.debug.print("BIG.BIN mismatch at byte {d}: got {x}, want {x}\n", .{ i, b, patternByte(i) });
            return error.TestUnexpectedResult;
        }
    }
}

test "append starting exactly on a cluster boundary grows the chain (size == chain length)" {
    // Regression: a `show`-then-screenshot sweep writes a ~15 MB PPM whose running
    // size repeatedly lands EXACTLY on a cluster boundary. When the next append
    // began with size == a whole number of clusters, File.append walked to the last
    // full cluster with in_clus = 0 and re-wrote it from the start instead of
    // allocating a fresh one — so the dir size counted bytes the cluster chain did
    // not hold. fsck.vfat flagged every screenshot: "File size is N bytes, cluster
    // chain length is M bytes. Truncating file." Reading the file back walks the
    // chain, so a short chain shows up as a wrong length or wrong bytes here.
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    const fs = fx.vol.fileSys();
    const clus_bytes: usize = @as(usize, fx.vol.sec_per_clus) * 512;

    const buf = try ta.alloc(u8, clus_bytes + 1000);
    defer ta.free(buf);
    for (buf, 0..) |*b, i| b.* = patternByte(i);

    var f = try fx.vol.create("/BOUND.BIN");
    try f.append(buf[0..clus_bytes]); // fills to EXACTLY one cluster (the boundary)
    try f.append(buf[clus_bytes..]); // the buggy path: must allocate a 2nd cluster

    const got = fs.read("/BOUND.BIN") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(buf.len, got.len); // dir size backed by real clusters
    try std.testing.expectEqualSlices(u8, buf, got); // the tail is its own cluster, not an overwrite
}

test "FAT16 fixture: the same behavior on the 16-bit FAT" {
    const fx = try Fixture.open(@embedFile("fixtures/fat16.img.gz"));
    defer fx.close();
    try std.testing.expect(fx.vol.is_fat16);
    try checkVolume(fx, "hello from 06\n");
}

test "GPT fixture: the basic-data volume is selected, the FAT EFI decoy skipped" {
    // The layout mirrors the real kudos boot stick:
    // partition 1 is an EFI System partition that IS a FAT16 volume — the
    // type-GUID selection must skip it and mount the basic-data FAT32.
    const fx = try Fixture.open(@embedFile("fixtures/fatgpt.img.gz"));
    defer fx.close();
    try std.testing.expect(!fx.vol.is_fat16);
    const fs = fx.vol.fileSys();
    try std.testing.expectEqual(@as(?[]const u8, null), fs.read("EFIBOOT.TXT")); // the decoy's file
    try checkVolume(fx, "hello from gpt\n");
}

// STO-004: volumes are located via the MBR partition table — mount must
// genuinely consult it, so a corrupted table is a loud mount error.
test "mount rejects a signature-less sector 0 and a corrupt GPT header" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();

    // Corrupt the MBR signature on a copy.
    const img2 = try ta.dupe(u8, fx.image);
    defer ta.free(img2);
    img2[510] = 0;
    var dev2 = MemDev{ .image = img2 };
    try std.testing.expectError(fat.Error.FatBadMbr, fat.mount(ta, dev2.iface()));

    // A GPT whose header CRC lies must be refused, not trusted.
    const gpt = try gunzip(@embedFile("fixtures/fatgpt.img.gz"));
    defer ta.free(gpt);
    gpt[512 + 16] ^= 0xFF; // header CRC field
    var dev3 = MemDev{ .image = gpt };
    try std.testing.expectError(fat.Error.FatBadGpt, fat.mount(ta, dev3.iface()));
}

// ── durability: no write outlives its barrier (STO-007) ──────────────────────
// STO-007 asks that pending file-system writes be flushed before any reboot or
// power-off so every volume stays valid (STO-006). kudos answers it by
// CONSTRUCTION rather than by a shutdown hook: every mutating FAT operation
// ends in the volume's own durability epilogue (syncMeta → dev.sync), so there
// is never a pending write for a shutdown path to forget. These tests pin that
// property — the moment one mutation returns with data unbarriered, a power cut
// at that instant loses it, and no reboot hook can put it back.

test "every mutating operation leaves the volume durable — nothing waits for shutdown (STO-007)" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();

    // create
    fx.dev.sync_calls = 0;
    var f = try fx.vol.create("durable.txt");
    try std.testing.expect(fx.dev.sync_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), fx.dev.writes_since_sync);

    // append
    fx.dev.sync_calls = 0;
    try f.append("power could cut right here\n");
    try std.testing.expect(fx.dev.sync_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), fx.dev.writes_since_sync);

    // remove
    fx.dev.sync_calls = 0;
    try fx.vol.remove("durable.txt");
    try std.testing.expect(fx.dev.sync_calls > 0);
    try std.testing.expectEqual(@as(usize, 0), fx.dev.writes_since_sync);
}

test "a volume cut off immediately after a write still reads back what it acked (STO-007)" {
    const fx = try Fixture.open(@embedFile("fixtures/fat32.img.gz"));
    defer fx.close();
    var f = try fx.vol.create("survives.txt");
    try f.append("acked bytes\n");

    // Nothing further is done — no unmount, no flush, no shutdown hook: exactly
    // the state a power cut would freeze. Re-mount the same image and the file
    // must be there with its content, or the ack was a lie.
    var dev2 = MemDev{ .image = fx.image };
    const vol2 = try fat.mount(ta, dev2.iface());
    defer {
        if (vol2.file_buf) |b| ta.free(b);
        ta.destroy(vol2);
    }
    const fs2 = vol2.fileSys();
    try std.testing.expectEqualStrings("acked bytes\n", fs2.read("survives.txt").?);
}
