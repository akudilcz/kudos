//! FAT16/FAT32 volume reader (spec STO-003) — PURE module (std + the
//! iblockdev/ifilesys ifaces only), host-tested against real mkfs.vfat images
//! (test/drivers/storage/fat_test.zig; fixtures built by scripts/tests/make-fat-fixtures.sh).
//! Wire format grounded in Linux msdos_fs.h / fs/fat.
//!
//! This is /usbdisk's filesystem: mount() scans the MBR for the first
//! FAT-type partition (GPT and FAT12 are distinct loud errors), validates
//! the BPB (512-byte sectors only), and serves the `ifilesys.IFileSys`
//! contract — case-insensitive path lookup, directory listing with VFAT
//! long names, whole-file reads via the cluster chain.
//!
//! Writes are NARROW and metadata-free: `openLog(path)` resolves ONE
//! pre-existing file's cluster chain to a flat sector-extent list, and
//! `LogFile.writeAt` rewrites byte ranges inside it in place (the sole writer
//! is the boot-log ring, bootlog.zig). It never allocates clusters, grows a
//! file, or touches FAT/dir metadata — a narrow in-place write subset chosen
//! so an interrupted write can damage the one pre-sized file's data rather
//! than allocation metadata.
//!
//! Whole-file reads use a SINGLE-SLOT buffer per volume: read(path) frees
//! the previous file's bytes — a returned slice is valid only until the
//! next read on this volume. Both consumers copy immediately (the model
//! viewer into VRAM, `cat` into the terminal), and the one-slot policy
//! bounds memory at one file (≤ MAX_FILE_BYTES, loud error beyond).
//!
//! ifilesys can only say NotFound/NotADirectory/IoFailed and read() only
//! null — so every specific failure is BOTH recorded in `last_error` and said
//! on the ilog seam (null sink on the host): a filesystem that goes quiet
//! about why a read failed is undiagnosable from outside.

const std = @import("std");
const iblockdev = @import("iblockdev");
const ifilesys = @import("ifilesys");
const ilog = @import("ilog");

pub const Error = error{
    FatBadMbr, // no 0x55AA / unreadable sector 0
    FatBadGpt, // protective MBR but the GPT header/CRCs are invalid
    FatNoPartition, // no FAT volume found anywhere on the device
    FatBadBpb, // BPB fields inconsistent
    FatUnsupportedSectorSize, // != 512
    Fat12Unsupported, // < 4085 clusters
    FatCorrupt, // FAT chain cycle / out-of-range cluster / bad dir
    FatFileTooLarge, // > MAX_FILE_BYTES
    FatNotFound, // openLog/remove: the named file does not exist
    FatNoSpace, // no free cluster / no free directory slot
    FatBadName, // create: not a valid 8.3 name (kudos writes 8.3 only)
    FatExists, // create: the name already exists
} || iblockdev.Error || std.mem.Allocator.Error;

/// Whole-file read cap: far above any model/text yet small against RAM.
pub const MAX_FILE_BYTES: usize = 64 * 1024 * 1024;

const SECTOR = iblockdev.SECTOR;
const ATTR_VOLUME: u8 = 0x08;
const ATTR_DIR: u8 = 0x10;
const ATTR_LFN: u8 = 0x0F;
const DELETED: u8 = 0xE5;
const MAX_NAME: usize = 255; // FAT_LFN_LEN

pub const Volume = struct {
    a: std.mem.Allocator,
    dev: iblockdev.IBlockDev,
    is_fat16: bool,
    sec_per_clus: u32,
    fat_lba: u64, // absolute LBA of FAT[0]
    fats: u32, // number of FAT copies (write all to keep them consistent)
    fat_len: u64, // sectors per FAT copy (spacing between copies)
    root_lba: u64, // FAT16 fixed root region
    root_secs: u32,
    root_cluster: u32, // FAT32 root chain start
    data_lba: u64, // absolute LBA of cluster 2
    n_clusters: u32,
    // FAT32 FSInfo free-cluster tracking: kudos maintains the count the
    // way Linux does, so a host fsck after kudos writes stays clean. 0 lba =
    // no FSInfo (FAT16 / missing / bad signature); FSINFO_UNKNOWN count =
    // stored value was invalid (kudos then leaves the sector alone).
    fsinfo_lba: u64,
    free_clusters: u32,
    // One-sector FAT cache: chain walks hit the same sector repeatedly.
    fat_sec: [SECTOR]u8,
    fat_sec_lba: u64, // ~0 = empty
    // The single-slot whole-file buffer (see file header).
    file_buf: ?[]u8,
    /// The specific failure behind the last null/IoFailed answer — the
    /// mount owner logs it (this module is pure and cannot).
    last_error: ?Error,

    // ── FAT chain ────────────────────────────────────────────────────

    /// FAT entry for `cluster` (already masked).
    fn fatEntry(self: *Volume, cluster: u32) Error!u32 {
        const off: u64 = @as(u64, cluster) * @as(u64, if (self.is_fat16) 2 else 4);
        const lba = self.fat_lba + off / SECTOR;
        if (lba != self.fat_sec_lba) {
            // Invalidate BEFORE the read: the device read clobbers fat_sec as it
            // goes, so a failed read leaves the buffer holding garbage. Setting
            // fat_sec_lba only on success means a later fatEntry for this LBA
            // re-reads instead of returning a cache hit on that garbage (a sticky
            // FatCorrupt that needed no device IO — the flaky-stick death spiral).
            self.fat_sec_lba = ~@as(u64, 0);
            try self.dev.read(lba, 1, &self.fat_sec);
            self.fat_sec_lba = lba;
        }
        const at: usize = @intCast(off % SECTOR);
        return if (self.is_fat16)
            std.mem.readInt(u16, self.fat_sec[at..][0..2], .little)
        else
            std.mem.readInt(u32, self.fat_sec[at..][0..4], .little) & 0x0FFF_FFFF;
    }

    // ── FAT / directory WRITE primitives ─────────────────────────────
    // The general read/write filesystem: cluster allocation, dir-entry create,
    // append, delete. Only in the writable data partition. 8.3 names only.

    const EOC_MARK: u32 = 0x0FFF_FFFF; // masked; write per-width in setFatEntry
    const FSINFO_UNKNOWN: u32 = 0xFFFF_FFFF;

    /// Persist the in-RAM free-cluster count into the FSInfo sector (FAT32),
    /// then SYNCHRONIZE CACHE. The single durability epilogue for every
    /// metadata write (create/append/remove/mkdir) — keeping FSInfo current is
    /// what keeps a host `fsck.vfat` clean after kudos writes.
    fn syncMeta(self: *Volume) Error!void {
        if (self.fsinfo_lba != 0 and self.free_clusters != FSINFO_UNKNOWN) {
            var fi: [SECTOR]u8 = undefined;
            try self.dev.read(self.fsinfo_lba, 1, &fi);
            std.mem.writeInt(u32, fi[488..492], self.free_clusters, .little);
            try self.dev.write(self.fsinfo_lba, 1, &fi);
        }
        try self.dev.sync();
    }

    /// Write FAT entry `cluster` = `value` (masked) into ALL FAT copies, keeping
    /// them consistent (like Linux). Preserves the top 4 reserved bits on FAT32.
    /// Invalidates the read cache so a later fatEntry re-reads.
    fn setFatEntry(self: *Volume, cluster: u32, value: u32) Error!void {
        const width: u64 = if (self.is_fat16) 2 else 4;
        const off: u64 = @as(u64, cluster) * width;
        var copy: u32 = 0;
        var sec: [SECTOR]u8 = undefined;
        while (copy < self.fats) : (copy += 1) {
            const lba = self.fat_lba + copy * self.fat_len + off / SECTOR;
            try self.dev.read(lba, 1, &sec);
            const at: usize = @intCast(off % SECTOR);
            if (self.is_fat16) {
                std.mem.writeInt(u16, sec[at..][0..2], @intCast(value & 0xFFFF), .little);
            } else {
                const prev = std.mem.readInt(u32, sec[at..][0..4], .little);
                const merged = (prev & 0xF000_0000) | (value & 0x0FFF_FFFF);
                std.mem.writeInt(u32, sec[at..][0..4], merged, .little);
            }
            try self.dev.write(lba, 1, &sec);
        }
        self.fat_sec_lba = ~@as(u64, 0); // invalidate the read cache
    }

    /// Allocate one free cluster (scan the FAT for the first `0` ≥ 2), mark it
    /// EOC, and return it. FatNoSpace when the volume is full.
    fn allocCluster(self: *Volume) Error!u32 {
        var c: u32 = 2;
        while (c < self.n_clusters + 2) : (c += 1) {
            if ((try self.fatEntry(c)) == 0) {
                try self.setFatEntry(c, EOC_MARK);
                if (self.free_clusters != FSINFO_UNKNOWN) self.free_clusters -= 1;
                return c;
            }
        }
        return Error.FatNoSpace;
    }

    /// Zero every sector of a data cluster (a fresh directory cluster must not
    /// read stale bytes as entries; a data cluster stays clean past EOF).
    fn zeroCluster(self: *Volume, cluster: u32) Error!void {
        var zero: [SECTOR]u8 = [_]u8{0} ** SECTOR;
        const lba = self.clusterLba(cluster);
        var s: u32 = 0;
        while (s < self.sec_per_clus) : (s += 1) try self.dev.write(lba + s, 1, &zero);
    }

    fn isEoc(self: *const Volume, v: u32) bool {
        return v >= (if (self.is_fat16) @as(u32, 0xFFF8) else 0x0FFF_FFF8);
    }

    fn clusterLba(self: *const Volume, cluster: u32) u64 {
        return self.data_lba + @as(u64, cluster - 2) * self.sec_per_clus;
    }

    fn validCluster(self: *const Volume, c: u32) bool {
        return c >= 2 and c - 2 < self.n_clusters;
    }

    // ── directory iteration ──────────────────────────────────────────

    /// Where a directory's entries live: the FAT16 fixed root region or a
    /// cluster chain.
    const DirLoc = union(enum) {
        region: struct { lba: u64, secs: u32 }, // FAT16 root
        chain: u32, // start cluster
    };

    fn rootLoc(self: *const Volume) DirLoc {
        return if (self.is_fat16)
            .{ .region = .{ .lba = self.root_lba, .secs = self.root_secs } }
        else
            .{ .chain = self.root_cluster };
    }

    /// One assembled directory entry (name valid only during iteration).
    const DirEntry = struct {
        name: []const u8, // LFN or decoded 8.3
        attr: u8,
        start_cluster: u32,
        size: u32,
    };

    /// Iterate a directory, assembling VFAT long names. Sector-at-a-time;
    /// `visit` returns true to stop (found).
    fn walkDir(self: *Volume, loc: DirLoc, ctx: anytype, comptime visit: fn (@TypeOf(ctx), DirEntry) bool) Error!bool {
        var lfn_buf: [MAX_NAME]u8 = undefined;
        var lfn_len: usize = 0;
        var lfn_next_seq: u8 = 0; // expected next slot id (counting down); 0 = none
        var lfn_checksum: u8 = 0;
        var lfn_ok = false;

        var sec: [SECTOR]u8 = undefined;
        var cluster: u32 = 0;
        var region_lba: u64 = 0;
        var region_left: u32 = 0;
        var chain_steps: u32 = 0;
        switch (loc) {
            .region => |r| {
                region_lba = r.lba;
                region_left = r.secs;
            },
            .chain => |c| {
                if (!self.validCluster(c)) return Error.FatCorrupt;
                cluster = c;
            },
        }

        while (true) {
            // Next sector run of this directory.
            var run_lba: u64 = 0;
            var run_secs: u32 = 0;
            switch (loc) {
                .region => {
                    if (region_left == 0) return false;
                    run_lba = region_lba;
                    run_secs = 1;
                    region_lba += 1;
                    region_left -= 1;
                },
                .chain => {
                    if (cluster == 0) return false; // chain ended
                    run_lba = self.clusterLba(cluster);
                    run_secs = self.sec_per_clus;
                    const next = try self.fatEntry(cluster);
                    chain_steps += 1;
                    if (chain_steps > self.n_clusters) return Error.FatCorrupt; // cycle
                    cluster = if (self.isEoc(next)) 0 else blk: {
                        if (!self.validCluster(next)) return Error.FatCorrupt;
                        break :blk next;
                    };
                },
            }

            var s: u32 = 0;
            while (s < run_secs) : (s += 1) {
                try self.dev.read(run_lba + s, 1, &sec);
                var e: usize = 0;
                while (e < SECTOR) : (e += 32) {
                    const ent = sec[e..][0..32];
                    if (ent[0] == 0) return false; // end of directory
                    if (ent[0] == DELETED) {
                        lfn_next_seq = 0;
                        lfn_ok = false;
                        continue;
                    }
                    if (ent[11] == ATTR_LFN) {
                        self.collectLfnSlot(ent, &lfn_buf, &lfn_len, &lfn_next_seq, &lfn_checksum, &lfn_ok);
                        continue;
                    }
                    if (ent[11] & ATTR_VOLUME != 0) { // volume label
                        lfn_next_seq = 0;
                        lfn_ok = false;
                        continue;
                    }
                    // A real entry: pick the LFN if it is complete and its
                    // checksum ties to this 8.3 record, else decode 8.3.
                    var short_buf: [13]u8 = undefined;
                    var name: []const u8 = undefined;
                    if (lfn_ok and lfn_next_seq == 0 and lfn_checksum == shortChecksum(ent[0..11])) {
                        name = lfn_buf[0..lfn_len];
                    } else {
                        name = decode83(ent, &short_buf);
                    }
                    lfn_next_seq = 0;
                    lfn_ok = false;
                    if (name.len == 0) continue; // "." / ".." dot entries
                    const de = DirEntry{
                        .name = name,
                        .attr = ent[11],
                        .start_cluster = (@as(u32, std.mem.readInt(u16, ent[20..22], .little)) << 16) |
                            std.mem.readInt(u16, ent[26..28], .little),
                        .size = std.mem.readInt(u32, ent[28..32], .little),
                    };
                    if (visit(ctx, de)) return true;
                }
            }
        }
    }

    /// Accumulate one LFN slot (they precede the 8.3 entry in reverse
    /// order). Non-ASCII characters invalidate the LFN — the entry falls
    /// back to its 8.3 name.
    fn collectLfnSlot(self: *Volume, ent: *const [32]u8, buf: *[MAX_NAME]u8, len: *usize, next_seq: *u8, checksum: *u8, ok: *bool) void {
        _ = self;
        const id = ent[0];
        const seq: u8 = id & 0x1F;
        if (seq == 0 or seq > 20) {
            ok.* = false;
            next_seq.* = 0;
            return;
        }
        if (id & 0x40 != 0) {
            // Last-logical slot arrives first on disk: (re)start assembly.
            checksum.* = ent[13];
            len.* = 0;
            ok.* = true;
        } else if (!ok.* or seq != next_seq.* or ent[13] != checksum.*) {
            ok.* = false;
            next_seq.* = 0;
            return;
        }
        next_seq.* = seq - 1;

        // 13 UCS-2 chars at fixed offsets: 1..10, 14..25, 28..31.
        const base: usize = (@as(usize, seq) - 1) * 13;
        if (base + 13 > MAX_NAME) {
            ok.* = false;
            return;
        }
        const offs = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        var n: usize = 0;
        for (offs, 0..) |off, i| {
            const u = std.mem.readInt(u16, ent[off..][0..2], .little);
            if (u == 0) break; // terminator; rest is 0xFFFF padding
            if (u > 0x7F) { // non-ASCII name: unsupported, fall back to 8.3
                ok.* = false;
                return;
            }
            buf[base + i] = @intCast(u);
            n = i + 1;
        }
        if (id & 0x40 != 0) len.* = base + n else if (n != 13) {
            ok.* = false; // only the last-logical slot may be partial
        }
    }

    // ── the ifilesys.IFileSys surface ────────────────────────────────

    /// Case-insensitive path lookup (VFAT semantics). Returns the entry,
    /// null for the root itself.
    fn lookup(self: *Volume, path: []const u8) Error!?DirEntry {
        var loc = self.rootLoc();
        var found: DirEntry = undefined;
        var it = std.mem.splitScalar(u8, path, '/');
        var have: bool = false;
        while (it.next()) |comp| {
            if (comp.len == 0) continue;
            const Ctx = struct {
                want: []const u8,
                out: *DirEntry,
                name_buf: [MAX_NAME]u8 = undefined,
            };
            var ctx = Ctx{ .want = comp, .out = &found };
            const hit = try self.walkDir(loc, &ctx, struct {
                fn visit(c: *Ctx, de: DirEntry) bool {
                    if (!std.ascii.eqlIgnoreCase(c.want, de.name)) return false;
                    // `de.name` points into walkDir's stack — copy it out.
                    @memcpy(c.name_buf[0..de.name.len], de.name);
                    c.out.* = de;
                    c.out.name = c.name_buf[0..de.name.len];
                    return true;
                }
            }.visit);
            if (!hit) return null;
            have = true;
            if (it.peek() != null and it.peek().?.len > 0) {
                // More components: this one must be a directory.
                if (found.attr & ATTR_DIR == 0) return null;
                if (!self.validCluster(found.start_cluster)) return Error.FatCorrupt;
                loc = .{ .chain = found.start_cluster };
            }
        }
        return if (have) found else null;
    }

    /// Record + say a specific failure. Absence (lookup miss) is a normal
    /// result and stays quiet; an ERROR never does.
    fn fail(self: *Volume, op: []const u8, path: []const u8, e: Error) void {
        self.last_error = e;
        ilog.puts("fat: ");
        ilog.puts(op);
        ilog.puts(" '");
        ilog.puts(path);
        ilog.puts("' failed: ");
        ilog.puts(@errorName(e));
        ilog.puts("\n");
    }

    fn vtKind(ctx_p: *anyopaque, path: []const u8) ?ifilesys.Kind {
        const self: *Volume = @ptrCast(@alignCast(ctx_p));
        const p = canon(path);
        if (p.len == 0) return .dir;
        const de = self.lookup(p) catch |e| {
            self.fail("kind", path, e);
            return null;
        } orelse return null;
        return if (de.attr & ATTR_DIR != 0) .dir else .file;
    }

    fn vtRead(ctx_p: *anyopaque, path: []const u8) ?[]const u8 {
        const self: *Volume = @ptrCast(@alignCast(ctx_p));
        return self.readFile(path) catch |e| {
            self.fail("read", path, e);
            return null;
        };
    }

    fn readFile(self: *Volume, path: []const u8) Error!?[]const u8 {
        const p = canon(path);
        if (p.len == 0) return null;
        const de = (try self.lookup(p)) orelse return null;
        if (de.attr & ATTR_DIR != 0) return null;
        if (de.size > MAX_FILE_BYTES) return Error.FatFileTooLarge;

        // Single-slot buffer: replace the previous file (file header).
        if (self.file_buf) |old| self.a.free(old);
        self.file_buf = null;
        const clus_bytes: usize = @as(usize, self.sec_per_clus) * SECTOR;
        const padded = std.mem.alignForward(usize, @max(de.size, 1), clus_bytes);
        const buf = try self.a.alloc(u8, padded);
        errdefer self.a.free(buf);

        var cluster = de.start_cluster;
        var at: usize = 0;
        var steps: u32 = 0;
        while (at < de.size) {
            if (!self.validCluster(cluster)) return Error.FatCorrupt;
            try self.dev.read(self.clusterLba(cluster), self.sec_per_clus, buf[at..][0..clus_bytes]);
            at += clus_bytes;
            steps += 1;
            if (steps > self.n_clusters) return Error.FatCorrupt; // cycle
            const next = try self.fatEntry(cluster);
            if (self.isEoc(next)) break;
            cluster = next;
        }
        if (at < de.size) return Error.FatCorrupt; // chain shorter than size
        self.file_buf = buf;
        return buf[0..de.size];
    }

    // ── flight-recorder write: in-place data-cluster rewrites of ONE file ──
    // The ONLY write path in kudos. It resolves a pre-existing file's cluster
    // chain to a flat sector-extent list ONCE (openLog), then rewrites byte
    // ranges inside it (writeAt) via IBlockDev.write — which SYNCHRONIZE-CACHEs
    // each flush. It NEVER allocates clusters, grows the file, or touches
    // FAT/dir metadata: the file must already exist at its full size
    // (host-seeded). Crash blast radius is one sector of log text, never
    // filesystem structure.

    pub const LogFile = struct {
        vol: *Volume,
        size: u64, // the file's byte length (fixed; the ring lives inside it)
        // Flat run list: each run is a contiguous sector span on the medium.
        // A FAT chain is usually near-contiguous, so a handful of runs covers a
        // multi-MB file; capped, with a loud error if a file is too fragmented.
        runs: [MAX_RUNS]Run,
        nruns: usize,
        total_secs: u64,

        const MAX_RUNS = 64;
        const Run = struct { lba: u64, secs: u64 };

        /// Absolute medium LBA + intra-sector offset for a byte position in the
        /// file, walking the run list. Null if `pos` is past the file.
        fn locate(self: *const LogFile, pos: u64) ?struct { lba: u64, off: usize } {
            var sec = pos / SECTOR;
            const off: usize = @intCast(pos % SECTOR);
            for (self.runs[0..self.nruns]) |r| {
                if (sec < r.secs) return .{ .lba = r.lba + sec, .off = off };
                sec -= r.secs;
            }
            return null;
        }

        /// Overwrite `bytes` at absolute byte offset `at` within the file.
        /// Read-modify-write per sector (the log rarely writes sector-aligned),
        /// each via IBlockDev.write (WRITE(10)+SYNCHRONIZE CACHE = durable).
        /// Errors loudly rather than wrapping or spilling past the file end.
        pub fn writeAt(self: *LogFile, at: u64, bytes: []const u8) Error!void {
            if (at + bytes.len > self.size) return Error.FatCorrupt; // never grow
            var sector_buf: [SECTOR]u8 = undefined;
            var done: usize = 0;
            while (done < bytes.len) {
                const loc = self.locate(at + done) orelse return Error.FatCorrupt;
                const n = @min(SECTOR - loc.off, bytes.len - done);
                if (n == SECTOR) {
                    self.vol.dev.write(loc.lba, 1, bytes[done..][0..SECTOR]) catch return Error.BlockIoFailed;
                } else {
                    self.vol.dev.read(loc.lba, 1, &sector_buf) catch return Error.BlockIoFailed;
                    @memcpy(sector_buf[loc.off..][0..n], bytes[done..][0..n]);
                    self.vol.dev.write(loc.lba, 1, &sector_buf) catch return Error.BlockIoFailed;
                }
                done += n;
            }
        }

        /// SYNCHRONIZE CACHE the underlying device — commit all prior writeAt
        /// calls to non-volatile medium. The boot-log ring calls this only on
        /// flushNow (panic), so steady writes stay cheap (device cache).
        pub fn sync(self: *LogFile) Error!void {
            try self.vol.dev.sync();
        }

        /// Read `bytes.len` bytes from offset `at` (for the ring header on boot).
        pub fn readAt(self: *LogFile, at: u64, out: []u8) Error!void {
            if (at + out.len > self.size) return Error.FatCorrupt;
            var sector_buf: [SECTOR]u8 = undefined;
            var done: usize = 0;
            while (done < out.len) {
                const loc = self.locate(at + done) orelse return Error.FatCorrupt;
                const n = @min(SECTOR - loc.off, out.len - done);
                self.vol.dev.read(loc.lba, 1, &sector_buf) catch return Error.BlockIoFailed;
                @memcpy(out[done..][0..n], sector_buf[loc.off..][0..n]);
                done += n;
            }
        }
    };

    /// Open a pre-existing file for in-place writes: resolve its cluster chain
    /// to a flat sector-extent list. The file must exist; too-fragmented (more
    /// than LogFile.MAX_RUNS runs) is a loud error, not a silent truncation.
    /// Coalesces consecutive clusters into one run so a normal file is ~1 run.
    pub fn openLog(self: *Volume, path: []const u8) Error!LogFile {
        const de = (try self.lookup(path)) orelse return Error.FatNotFound;
        if (de.attr & ATTR_DIR != 0) return Error.FatCorrupt;
        var lf = LogFile{ .vol = self, .size = de.size, .runs = undefined, .nruns = 0, .total_secs = 0 };
        var cluster = de.start_cluster;
        var steps: u32 = 0;
        while (true) {
            if (!self.validCluster(cluster)) return Error.FatCorrupt;
            const lba = self.clusterLba(cluster);
            // Extend the last run if this cluster is physically contiguous.
            if (lf.nruns > 0 and lf.runs[lf.nruns - 1].lba + lf.runs[lf.nruns - 1].secs == lba) {
                lf.runs[lf.nruns - 1].secs += self.sec_per_clus;
            } else {
                if (lf.nruns == LogFile.MAX_RUNS) return Error.FatFileTooLarge; // too fragmented
                lf.runs[lf.nruns] = .{ .lba = lba, .secs = self.sec_per_clus };
                lf.nruns += 1;
            }
            lf.total_secs += self.sec_per_clus;
            steps += 1;
            if (steps > self.n_clusters) return Error.FatCorrupt; // cycle
            const next = try self.fatEntry(cluster);
            if (self.isEoc(next)) break;
            cluster = next;
        }
        if (lf.total_secs * SECTOR < de.size) return Error.FatCorrupt; // chain shorter than size
        return lf;
    }

    fn vtList(ctx_p: *anyopaque, path: []const u8, cb: ifilesys.ListFn, cb_ctx: ?*anyopaque) ifilesys.Error!void {
        const self: *Volume = @ptrCast(@alignCast(ctx_p));
        const p = canon(path);
        var loc = self.rootLoc();
        if (p.len != 0) {
            const de = self.lookup(p) catch |e| {
                self.fail("list", path, e);
                return ifilesys.Error.IoFailed;
            } orelse return ifilesys.Error.NotFound;
            if (de.attr & ATTR_DIR == 0) return ifilesys.Error.NotADirectory;
            if (!self.validCluster(de.start_cluster)) {
                self.fail("list", path, Error.FatCorrupt);
                return ifilesys.Error.IoFailed;
            }
            loc = .{ .chain = de.start_cluster };
        }
        const Ctx = struct { cb: ifilesys.ListFn, cb_ctx: ?*anyopaque };
        var c = Ctx{ .cb = cb, .cb_ctx = cb_ctx };
        _ = self.walkDir(loc, &c, struct {
            fn visit(cc: *Ctx, de: DirEntry) bool {
                cc.cb(cc.cb_ctx, .{
                    .name = de.name,
                    .kind = if (de.attr & ATTR_DIR != 0) .dir else .file,
                    .size = de.size,
                });
                return false; // enumerate everything
            }
        }.visit) catch |e| {
            self.fail("list", path, e);
            return ifilesys.Error.IoFailed;
        };
    }

    // ── public create / append / delete ──────────────────────────────

    /// Encode a path's basename to an 11-byte 8.3 name (space-padded, upper).
    /// FatBadName if it is not valid 8.3 (base > 8, ext > 3, illegal chars) —
    /// kudos writes 8.3 only, never synthesises an LFN.
    fn name83(path: []const u8, out: *[11]u8) Error!void {
        const base = basenameOf(path);
        @memset(out, ' ');
        var i: usize = 0; // index into base
        var o: usize = 0; // 0..8 name, then ext
        // Base (up to the last dot).
        const dot = std.mem.lastIndexOfScalar(u8, base, '.');
        const base_end = dot orelse base.len;
        while (i < base_end) : (i += 1) {
            if (o >= 8) return Error.FatBadName;
            out[o] = upper83(base[i]) orelse return Error.FatBadName;
            o += 1;
        }
        if (o == 0) return Error.FatBadName; // empty name
        if (dot) |d| {
            var e: usize = 0;
            var j = d + 1;
            while (j < base.len) : (j += 1) {
                if (e >= 3) return Error.FatBadName;
                out[8 + e] = upper83(base[j]) orelse return Error.FatBadName;
                e += 1;
            }
        }
    }

    /// One directory-slot cursor: the absolute LBA + byte offset of a 32-byte
    /// entry, plus enough state to advance (region or chain).
    const SlotCursor = struct {
        loc: DirLoc,
        // current position
        cluster: u32 = 0,
        region_lba: u64 = 0,
        region_left: u32 = 0,
        sec_in_clus: u32 = 0,
        ent_in_sec: u32 = 0,
        started: bool = false,
    };

    /// The directory a path lives in (its parent), as a DirLoc. Only the root
    /// and its immediate subdirectories are supported for WRITE (the screenshot
    /// use writes /shots/*, one level); a deeper parent is FatNotFound.
    fn parentLoc(self: *Volume, path: []const u8) Error!DirLoc {
        const dir = dirnameOf(path);
        if (dir.len == 0) return self.rootLoc();
        const de = (try self.lookup(dir)) orelse return Error.FatNotFound;
        if (de.attr & ATTR_DIR == 0) return Error.FatCorrupt;
        if (!self.validCluster(de.start_cluster)) return Error.FatCorrupt;
        return .{ .chain = de.start_cluster };
    }

    /// Find a free 32-byte directory slot in `loc` (name[0] == 0x00 end, or 0xE5
    /// deleted), returning its absolute LBA + offset. Extends a chained
    /// directory by one cluster if it fills. FatNoSpace if a fixed FAT16 root
    /// fills. Also errors FatExists if `want83` is already present.
    fn findFreeSlot(self: *Volume, loc: DirLoc, want83: *const [11]u8) Error!struct { lba: u64, off: usize } {
        var sec: [SECTOR]u8 = undefined;
        var cluster: u32 = 0;
        var region_lba: u64 = 0;
        var region_left: u32 = 0;
        var chain_steps: u32 = 0;
        switch (loc) {
            .region => |r| {
                region_lba = r.lba;
                region_left = r.secs;
            },
            .chain => |c| cluster = c,
        }
        while (true) {
            var run_lba: u64 = 0;
            var run_secs: u32 = 0;
            var last_chain: u32 = 0;
            switch (loc) {
                .region => {
                    if (region_left == 0) return Error.FatNoSpace; // fixed root full
                    run_lba = region_lba;
                    run_secs = 1;
                    region_lba += 1;
                    region_left -= 1;
                },
                .chain => {
                    if (cluster == 0) return Error.FatNoSpace;
                    if (!self.validCluster(cluster)) return Error.FatCorrupt;
                    run_lba = self.clusterLba(cluster);
                    run_secs = self.sec_per_clus;
                    last_chain = cluster;
                    const next = try self.fatEntry(cluster);
                    chain_steps += 1;
                    if (chain_steps > self.n_clusters) return Error.FatCorrupt;
                    cluster = if (self.isEoc(next)) 0 else next;
                },
            }
            var s: u32 = 0;
            while (s < run_secs) : (s += 1) {
                try self.dev.read(run_lba + s, 1, &sec);
                var e: usize = 0;
                while (e < SECTOR) : (e += 32) {
                    const c0 = sec[e];
                    if (c0 == 0 or c0 == DELETED) {
                        return .{ .lba = run_lba + s, .off = e };
                    }
                    // Collision check: an existing 8.3 entry (not LFN/volume).
                    if (sec[e + 11] != ATTR_LFN and sec[e + 11] & ATTR_VOLUME == 0) {
                        if (std.mem.eql(u8, sec[e .. e + 11], want83)) return Error.FatExists;
                    }
                }
            }
            // Chain exhausted without a slot: grow the directory by one cluster.
            if (loc == .chain and cluster == 0) {
                const nc = try self.allocCluster();
                try self.zeroCluster(nc);
                try self.setFatEntry(last_chain, nc);
                cluster = nc;
            }
        }
    }

    /// Create an empty file at `path` (8.3 name) with one allocated cluster, and
    /// return an fat-backed handle for appending. FatExists if it already
    /// exists. Only the writable data partition; parent must be root or a
    /// one-level subdirectory.
    pub fn create(self: *Volume, path: []const u8) Error!File {
        const p = canon(path);
        var n83: [11]u8 = undefined;
        try name83(p, &n83);
        const loc = try self.parentLoc(p);
        const slot = try self.findFreeSlot(loc, &n83);
        const first = try self.allocCluster();
        try self.zeroCluster(first);
        // If we consumed a 0x00 (end) slot and the next entry in the sector is
        // present, we must leave a fresh end marker; findFreeSlot returns the
        // FIRST free, and writing a real entry there is fine because the reader
        // stops at the NEXT 0x00 — which the zeroed remainder / next slot holds.
        var sec: [SECTOR]u8 = undefined;
        try self.dev.read(slot.lba, 1, &sec);
        writeDirEntry(sec[slot.off..][0..32], &n83, first, 0);
        try self.dev.write(slot.lba, 1, &sec);
        try self.syncMeta();
        return .{ .vol = self, .dir_lba = slot.lba, .dir_off = slot.off, .first = first, .size = 0 };
    }

    /// Create a directory at `path` (8.3 name): one zeroed cluster holding the
    /// mandatory '.' and '..' entries, plus an ATTR_DIR entry in the parent.
    /// FatExists if present. '..' start cluster is the parent's first cluster
    /// (0 for the root, per the FAT spec).
    pub fn mkdir(self: *Volume, path: []const u8) Error!void {
        const p = canon(path);
        var n83: [11]u8 = undefined;
        try name83(p, &n83);
        const loc = try self.parentLoc(p);
        const slot = try self.findFreeSlot(loc, &n83);
        const clus = try self.allocCluster();
        try self.zeroCluster(clus);
        // '.' and '..' in the new directory's first sector.
        var first: [SECTOR]u8 = [_]u8{0} ** SECTOR;
        const dot = ".          ".*;
        const dotdot = "..         ".*;
        const parent_clus: u32 = switch (loc) {
            .region => 0, // FAT16 fixed root
            .chain => |c| if (!self.is_fat16 and c == self.root_cluster) 0 else c,
        };
        writeDirEntry(first[0..32], &dot, clus, 0);
        first[11] = ATTR_DIR;
        writeDirEntry(first[32..64], &dotdot, parent_clus, 0);
        first[32 + 11] = ATTR_DIR;
        try self.dev.write(self.clusterLba(clus), 1, &first);
        // The parent's entry for the new directory.
        var sec: [SECTOR]u8 = undefined;
        try self.dev.read(slot.lba, 1, &sec);
        writeDirEntry(sec[slot.off..][0..32], &n83, clus, 0);
        sec[slot.off + 11] = ATTR_DIR;
        try self.dev.write(slot.lba, 1, &sec);
        try self.syncMeta();
    }

    /// A writable file handle (from create or openFile): its dir-entry location
    /// (to update size) + chain head + current size. Append writes whole data,
    /// extends the chain, and rewrites the size LAST (crash order).
    pub const File = struct {
        vol: *Volume,
        dir_lba: u64,
        dir_off: usize,
        first: u32,
        size: u64,

        /// Append `bytes` at the end of the file. Extends the cluster chain as
        /// needed; rewrites the dir-entry size last. Syncs on return.
        pub fn append(self: *File, bytes: []const u8) Error!void {
            const v = self.vol;
            const clus_bytes: u64 = @as(u64, v.sec_per_clus) * SECTOR;
            // Walk to the cluster + offset holding the current end.
            var cluster = self.first;
            var remaining_to_end = self.size;
            while (remaining_to_end >= clus_bytes) {
                const nxt = try v.fatEntry(cluster);
                if (v.isEoc(nxt)) {
                    // The file ends exactly on THIS (the last) cluster's boundary.
                    // Stop here WITHOUT subtracting: remaining_to_end stays ==
                    // clus_bytes, so in_clus == clus_bytes below and the write loop
                    // allocates a FRESH cluster for the appended bytes. Subtracting
                    // to 0 set in_clus = 0, which re-wrote the last full cluster from
                    // its start and never grew the chain — the dir size then counted
                    // bytes the cluster chain did not hold (size > chain length; fsck
                    // "cluster chain length is N bytes / Truncating file").
                    break;
                }
                cluster = nxt;
                remaining_to_end -= clus_bytes;
            }
            var in_clus: u64 = remaining_to_end; // byte offset within `cluster`
            var src = bytes;
            var sbuf: [SECTOR]u8 = undefined;
            while (src.len > 0) {
                if (in_clus == clus_bytes) {
                    // Need the next cluster; allocate + link if at EOC.
                    var nxt = try v.fatEntry(cluster);
                    if (v.isEoc(nxt)) {
                        const nc = try v.allocCluster();
                        try v.setFatEntry(cluster, nc);
                        nxt = nc;
                    }
                    cluster = nxt;
                    in_clus = 0;
                }
                const sec_idx: u32 = @intCast(in_clus / SECTOR);
                const sec_off: usize = @intCast(in_clus % SECTOR);
                const lba = v.clusterLba(cluster) + sec_idx;
                var n: usize = undefined;
                if (sec_off == 0 and src.len >= SECTOR) {
                    // Bulk fast path: every remaining whole sector of this
                    // cluster in ONE multi-sector write (a 15 MB screenshot is
                    // ~500 BOT commands at 32 KiB clusters, not ~30k).
                    const secs_left: usize = @as(usize, v.sec_per_clus) - sec_idx;
                    const secs = @min(secs_left, src.len / SECTOR);
                    n = secs * SECTOR;
                    try v.dev.write(lba, @intCast(secs), src[0..n]);
                } else {
                    // Ragged edge (partial sector): read-modify-write one sector.
                    n = @min(SECTOR - sec_off, src.len);
                    try v.dev.read(lba, 1, &sbuf);
                    @memcpy(sbuf[sec_off..][0..n], src[0..n]);
                    try v.dev.write(lba, 1, &sbuf);
                }
                src = src[n..];
                in_clus += n;
                self.size += n;
            }
            // Size LAST (crash safety: data+FAT first, then the size).
            try self.writeSize();
            try v.syncMeta();
        }

        fn writeSize(self: *File) Error!void {
            var sec: [SECTOR]u8 = undefined;
            try self.vol.dev.read(self.dir_lba, 1, &sec);
            std.mem.writeInt(u32, sec[self.dir_off + 28 ..][0..4], @intCast(self.size), .little);
            try self.vol.dev.write(self.dir_lba, 1, &sec);
        }
    };

    /// Open an existing file for appending. FatNotFound if absent.
    pub fn openFile(self: *Volume, path: []const u8) Error!File {
        const p = canon(path);
        const loc = try self.parentLoc(p);
        var n83: [11]u8 = undefined;
        try name83(p, &n83);
        const found = try self.findEntry(loc, &n83) orelse return Error.FatNotFound;
        return .{ .vol = self, .dir_lba = found.lba, .dir_off = found.off, .first = found.cluster, .size = found.size };
    }

    /// Delete a file: free its cluster chain, then mark its dir entry deleted
    /// (0xE5). FatNotFound if absent. Frees-then-marks so a crash leaves at most
    /// an orphaned chain (fsck-recoverable), never a live entry with freed data.
    pub fn remove(self: *Volume, path: []const u8) Error!void {
        const p = canon(path);
        const loc = try self.parentLoc(p);
        var n83: [11]u8 = undefined;
        try name83(p, &n83);
        const found = try self.findEntry(loc, &n83) orelse return Error.FatNotFound;
        // Free the chain.
        var cluster = found.cluster;
        var steps: u32 = 0;
        while (self.validCluster(cluster)) {
            const next = try self.fatEntry(cluster);
            try self.setFatEntry(cluster, 0); // free
            if (self.free_clusters != FSINFO_UNKNOWN) self.free_clusters += 1;
            steps += 1;
            if (steps > self.n_clusters) break;
            if (self.isEoc(next)) break;
            cluster = next;
        }
        // Mark the entry deleted.
        var sec: [SECTOR]u8 = undefined;
        try self.dev.read(found.lba, 1, &sec);
        sec[found.off] = DELETED;
        try self.dev.write(found.lba, 1, &sec);
        try self.syncMeta();
    }

    /// Find a plain 8.3 entry by its packed name in `loc`; returns its dir-entry
    /// location + start cluster + size. Null if absent.
    fn findEntry(self: *Volume, loc: DirLoc, want83: *const [11]u8) Error!?struct { lba: u64, off: usize, cluster: u32, size: u32 } {
        var sec: [SECTOR]u8 = undefined;
        var cluster: u32 = 0;
        var region_lba: u64 = 0;
        var region_left: u32 = 0;
        var chain_steps: u32 = 0;
        switch (loc) {
            .region => |r| {
                region_lba = r.lba;
                region_left = r.secs;
            },
            .chain => |c| cluster = c,
        }
        while (true) {
            var run_lba: u64 = 0;
            var run_secs: u32 = 0;
            switch (loc) {
                .region => {
                    if (region_left == 0) return null;
                    run_lba = region_lba;
                    run_secs = 1;
                    region_lba += 1;
                    region_left -= 1;
                },
                .chain => {
                    if (cluster == 0) return null;
                    if (!self.validCluster(cluster)) return Error.FatCorrupt;
                    run_lba = self.clusterLba(cluster);
                    run_secs = self.sec_per_clus;
                    const next = try self.fatEntry(cluster);
                    chain_steps += 1;
                    if (chain_steps > self.n_clusters) return Error.FatCorrupt;
                    cluster = if (self.isEoc(next)) 0 else next;
                },
            }
            var s: u32 = 0;
            while (s < run_secs) : (s += 1) {
                try self.dev.read(run_lba + s, 1, &sec);
                var e: usize = 0;
                while (e < SECTOR) : (e += 32) {
                    if (sec[e] == 0) return null; // end of directory
                    if (sec[e] == DELETED or sec[e + 11] == ATTR_LFN or sec[e + 11] & ATTR_VOLUME != 0) continue;
                    if (std.mem.eql(u8, sec[e .. e + 11], want83)) {
                        const hi = std.mem.readInt(u16, sec[e + 20 ..][0..2], .little);
                        const lo = std.mem.readInt(u16, sec[e + 26 ..][0..2], .little);
                        return .{
                            .lba = run_lba + s,
                            .off = e,
                            .cluster = (@as(u32, hi) << 16) | lo,
                            .size = std.mem.readInt(u32, sec[e + 28 ..][0..4], .little),
                        };
                    }
                }
            }
        }
    }

    const filesys_vtable = ifilesys.IFileSys.VTable{ .read = vtRead, .list = vtList, .kind = vtKind };

    /// The volume as an ifilesys.IFileSys (mounted at /usbdisk).
    pub fn fileSys(self: *Volume) ifilesys.IFileSys {
        return .{ .ctx = self, .vtable = &filesys_vtable };
    }
};

/// Decode an 8.3 name ("FOO     GLB" → "foo.glb" per the lcase flags).
/// Returns "" for the "." / ".." dot entries (callers skip those).
/// Canonicalize a volume-relative path: strip leading/trailing '/' so "", "/",
/// "/models/" and "models" all name the same thing at EVERY public entry point
/// (read/kind/list/create/openFile/remove). Embedded empty components ("a//b")
/// are skipped by lookup's component walk. One normalization, one place.
fn canon(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

/// The basename (after the last '/') of a normalized absolute path.
fn basenameOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[i + 1 ..];
}

/// The directory part (before the last '/'), volume-relative; "" for the root.
fn dirnameOf(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..i];
}

/// Uppercase an 8.3 name character; null if it is not a legal 8.3 char (so the
/// name is rejected rather than silently mangled). Allows A-Z, 0-9, and the
/// common punctuation FAT permits; '.' is handled by the caller (separator).
fn upper83(c: u8) ?u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if ((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) return c;
    return switch (c) {
        '_', '-', '~', '!', '#', '$', '%', '&', '(', ')', '@', '^', '{', '}' => c,
        else => null,
    };
}

/// Write a fresh 8.3 directory entry into `ent`: name, attr=archive, start
/// cluster (hi/lo), size. Timestamps left zero (kudos has no wall clock).
fn writeDirEntry(ent: *[32]u8, name83: *const [11]u8, first_cluster: u32, size: u32) void {
    @memset(ent, 0);
    @memcpy(ent[0..11], name83);
    ent[11] = 0x20; // ATTR_ARCHIVE
    std.mem.writeInt(u16, ent[20..22], @intCast((first_cluster >> 16) & 0xFFFF), .little); // starthi
    std.mem.writeInt(u16, ent[26..28], @intCast(first_cluster & 0xFFFF), .little); // start
    std.mem.writeInt(u32, ent[28..32], size, .little);
}

fn decode83(ent: *const [32]u8, out: *[13]u8) []const u8 {
    if (ent[0] == '.') return ""; // "." and ".." only ever start with '.'
    const lcase = ent[12];
    var n: usize = 0;
    var base_len: usize = 8;
    while (base_len > 0 and ent[base_len - 1] == ' ') base_len -= 1;
    for (ent[0..base_len]) |ch| {
        var c = if (ch == 0x05) DELETED else ch; // 0x05 stores a real 0xE5
        if (lcase & 0x08 != 0) c = std.ascii.toLower(c);
        out[n] = c;
        n += 1;
    }
    var ext_len: usize = 3;
    while (ext_len > 0 and ent[8 + ext_len - 1] == ' ') ext_len -= 1;
    if (ext_len > 0) {
        out[n] = '.';
        n += 1;
        for (ent[8 .. 8 + ext_len]) |ch| {
            out[n] = if (lcase & 0x10 != 0) std.ascii.toLower(ch) else ch;
            n += 1;
        }
    }
    return out[0..n];
}

/// The 8.3-alias checksum LFN slots carry.
fn shortChecksum(name: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (name) |c| sum = std.math.rotr(u8, sum, 1) +% c;
    return sum;
}

/// Mount the FAT data volume of `dev`: MBR first-FAT-type partition, GPT
/// basic-data probe, or a table-less super-floppy BPB at LBA 0.
pub fn mount(a: std.mem.Allocator, dev: iblockdev.IBlockDev) Error!*Volume {
    var sec: [SECTOR]u8 = undefined;
    try dev.read(0, 1, &sec);
    if (sec[510] != 0x55 or sec[511] != 0xAA) return Error.FatBadMbr;

    var vol_lba: u64 = 0;
    var found = false;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const e = sec[446 + i * 16 ..][0..16];
        const ptype = e[4];
        if (ptype == 0xEE) return mountGpt(a, dev);
        const is_fat = ptype == 0x0B or ptype == 0x0C or ptype == 0x06 or ptype == 0x0E or ptype == 0x04;
        if (is_fat and !found) {
            vol_lba = std.mem.readInt(u32, e[8..12], .little);
            found = true;
        }
    }
    // No table entry: sector 0 may itself be a BPB (super-floppy stick).
    // parseBpb validates it either way; a non-BPB fails loudly there.

    return parseBpb(a, dev, vol_lba, found);
}

/// The on-disk (mixed-endian) GUID of "Microsoft basic data" — the type the
/// kudos data partition carries. The boot stick's EFI System partition is
/// ALSO FAT, so selection goes by this type, not by "first FAT thing".
const GUID_BASIC_DATA = [16]u8{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 };

/// GPT: verify the header + entry-array CRCs (like Linux), then probe every
/// basic-data entry in order with the strict BPB parse — the first that
/// validates as FAT16/32 is the data volume.
fn mountGpt(a: std.mem.Allocator, dev: iblockdev.IBlockDev) Error!*Volume {
    var hdr: [SECTOR]u8 = undefined;
    try dev.read(1, 1, &hdr);
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return Error.FatBadGpt;
    const hdr_size = std.mem.readInt(u32, hdr[12..16], .little);
    if (hdr_size < 92 or hdr_size > SECTOR) return Error.FatBadGpt;
    const hdr_crc = std.mem.readInt(u32, hdr[16..20], .little);
    var crc = std.hash.Crc32.init();
    crc.update(hdr[0..16]);
    crc.update(&.{ 0, 0, 0, 0 }); // the CRC field itself counts as zero
    crc.update(hdr[20..hdr_size]);
    if (crc.final() != hdr_crc) return Error.FatBadGpt;

    const entries_lba = std.mem.readInt(u64, hdr[72..80], .little);
    const nparts = std.mem.readInt(u32, hdr[80..84], .little);
    const esize = std.mem.readInt(u32, hdr[84..88], .little);
    const entries_crc = std.mem.readInt(u32, hdr[88..92], .little);
    if (esize != 128 or nparts == 0 or nparts > 256) return Error.FatBadGpt;

    // One pass for the array CRC, collecting basic-data candidates.
    var cand: [8]u64 = undefined;
    var ncand: usize = 0;
    var ecrc = std.hash.Crc32.init();
    var sec: [SECTOR]u8 = undefined;
    const total_secs = (nparts * esize + SECTOR - 1) / SECTOR;
    var s: u32 = 0;
    var seen: u32 = 0;
    while (s < total_secs) : (s += 1) {
        try dev.read(entries_lba + s, 1, &sec);
        var off: usize = 0;
        while (off < SECTOR and seen < nparts) : (off += esize) {
            ecrc.update(sec[off..][0..esize]);
            const entry = sec[off..][0..128];
            if (std.mem.eql(u8, entry[0..16], &GUID_BASIC_DATA) and ncand < cand.len) {
                cand[ncand] = std.mem.readInt(u64, entry[32..40], .little);
                ncand += 1;
            }
            seen += 1;
        }
    }
    if (ecrc.final() != entries_crc) return Error.FatBadGpt;

    for (cand[0..ncand]) |lba| {
        // The hybrid boot layout carries tiny non-FAT basic-data crumbs;
        // the strict BPB parse rejects those and selects the data volume.
        return parseBpb(a, dev, lba, true) catch continue;
    }
    return Error.FatNoPartition;
}

fn parseBpb(a: std.mem.Allocator, dev: iblockdev.IBlockDev, vol_lba: u64, from_table: bool) Error!*Volume {
    var sec: [SECTOR]u8 = undefined;
    try dev.read(vol_lba, 1, &sec);
    if (sec[510] != 0x55 or sec[511] != 0xAA) {
        return if (from_table) Error.FatBadBpb else Error.FatNoPartition;
    }
    const sector_size = std.mem.readInt(u16, sec[11..13], .little);
    if (sector_size != SECTOR) {
        return if (from_table) Error.FatUnsupportedSectorSize else Error.FatNoPartition;
    }
    const spc: u32 = sec[13];
    if (spc == 0 or spc > 128 or !std.math.isPowerOfTwo(spc)) return Error.FatBadBpb;
    const reserved = std.mem.readInt(u16, sec[14..16], .little);
    const fats: u32 = sec[16];
    if (reserved == 0 or fats == 0) return Error.FatBadBpb;
    const dir_entries: u32 = std.mem.readInt(u16, sec[17..19], .little);
    const sectors16: u32 = std.mem.readInt(u16, sec[19..21], .little);
    const total32 = std.mem.readInt(u32, sec[32..36], .little);
    const total: u64 = if (sectors16 != 0) sectors16 else total32;
    const fat_len16: u32 = std.mem.readInt(u16, sec[22..24], .little);
    const fat_len: u64 = if (fat_len16 != 0) fat_len16 else std.mem.readInt(u32, sec[36..40], .little);
    if (total == 0 or fat_len == 0) return Error.FatBadBpb;

    const fat_lba = vol_lba + reserved;
    const root_lba = fat_lba + fats * fat_len;
    const root_secs: u32 = @intCast((dir_entries * 32 + SECTOR - 1) / SECTOR);
    const data_lba = root_lba + root_secs;
    if (data_lba - vol_lba >= total) return Error.FatBadBpb;
    const n_clusters: u64 = (total - (data_lba - vol_lba)) / spc;

    // Type by cluster count ALONE.
    if (n_clusters < 0xFF5) return Error.Fat12Unsupported;
    const is_fat16 = n_clusters < 0xFFF5;
    const root_cluster = std.mem.readInt(u32, sec[44..48], .little);
    if (is_fat16 and dir_entries == 0) return Error.FatBadBpb;
    if (!is_fat16 and root_cluster < 2) return Error.FatBadBpb;

    // FAT32 FSInfo sector (BPB offset 48): carries the free-cluster count that
    // Linux (and fsck.vfat) maintain — kudos's allocator must keep it current
    // or every host fsck flags "free cluster summary wrong" after a write.
    var fsinfo_lba: u64 = 0;
    var free_clusters: u32 = Volume.FSINFO_UNKNOWN;
    if (!is_fat16) {
        const fsinfo_sec = std.mem.readInt(u16, sec[48..50], .little);
        if (fsinfo_sec != 0 and fsinfo_sec != 0xFFFF) {
            var fi: [SECTOR]u8 = undefined;
            try dev.read(vol_lba + fsinfo_sec, 1, &fi);
            if (std.mem.eql(u8, fi[0..4], "RRaA") and std.mem.eql(u8, fi[484..488], "rrAa")) {
                fsinfo_lba = vol_lba + fsinfo_sec;
                const stored = std.mem.readInt(u32, fi[488..492], .little);
                if (stored <= n_clusters) free_clusters = stored;
            }
        }
    }

    const v = try a.create(Volume);
    v.* = .{
        .a = a,
        .dev = dev,
        .is_fat16 = is_fat16,
        .sec_per_clus = spc,
        .fat_lba = fat_lba,
        .fats = fats,
        .fat_len = fat_len,
        .root_lba = root_lba,
        .root_secs = root_secs,
        .root_cluster = if (is_fat16) 0 else root_cluster,
        .data_lba = data_lba,
        .n_clusters = @intCast(n_clusters),
        .fsinfo_lba = fsinfo_lba,
        .free_clusters = free_clusters,
        .fat_sec = undefined,
        .fat_sec_lba = std.math.maxInt(u64),
        .file_buf = null,
        .last_error = null,
    };
    return v;
}
