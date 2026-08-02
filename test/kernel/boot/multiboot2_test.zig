//! Host tests of src/kernel/boot/multiboot2.zig.

const std = @import("std");
const multiboot2 = @import("multiboot2");
const FramebufferTag = multiboot2.FramebufferTag;
const MmapEntry = multiboot2.MmapEntry;
const MmapIter = multiboot2.MmapIter;
const Module = multiboot2.Module;
const TAG_END = multiboot2.TAG_END;
const TAG_FRAMEBUFFER = multiboot2.TAG_FRAMEBUFFER;
const TAG_MMAP = multiboot2.TAG_MMAP;
const TAG_MODULE = multiboot2.TAG_MODULE;
const findModule = multiboot2.findModule;
const framebuffer = multiboot2.framebuffer;
const mmap = multiboot2.mmap;
const modules = multiboot2.modules;

// The parser is addressed by u64, so these tests build synthetic GRUB blobs in
// an aligned buffer and pass @intFromPtr — the exact calling convention kmain
// uses with the real pointer.

/// Test builder mirroring GRUB's layout: {total_size,reserved} header, tags
/// appended 8-byte aligned, total_size patched by finish(). Malformed-blob tests
/// then corrupt specific fields in place.
const TestBlob = struct {
    buf: [512]u8 align(8) = [_]u8{0} ** 512,
    len: usize = 8, // past the {total_size: u32, reserved: u32} header

    fn addr(self: *const TestBlob) u64 {
        return @intFromPtr(&self.buf);
    }
    fn putU32(self: *TestBlob, off: usize, v: u32) void {
        self.buf[off..][0..4].* = @bitCast(v);
    }
    fn putU64(self: *TestBlob, off: usize, v: u64) void {
        self.buf[off..][0..8].* = @bitCast(v);
    }
    /// Append a tag: header {type,size} + raw body bytes; advance 8-aligned.
    /// Returns the tag's offset (for in-place corruption by malformed tests).
    fn addTag(self: *TestBlob, tag_type: u32, body: []const u8) usize {
        const off = self.len;
        const size: u32 = @intCast(8 + body.len);
        self.putU32(off, tag_type);
        self.putU32(off + 4, size);
        @memcpy(self.buf[off + 8 ..][0..body.len], body);
        self.len += (size + 7) & ~@as(usize, 7);
        return off;
    }
    /// Append the end tag and patch total_size.
    fn finish(self: *TestBlob) void {
        _ = self.addTag(TAG_END, &.{});
        self.putU32(0, @intCast(self.len));
    }
};

/// Body of a framebuffer tag (everything after {type,size}) for a direct-RGB
/// 1024x768x32 mode at 0xFD00_0000 with BGR channel order.
fn fbBody() [30]u8 {
    var b: [30]u8 = undefined;
    b[0..8].* = @bitCast(@as(u64, 0xFD00_0000)); // addr
    b[8..12].* = @bitCast(@as(u32, 4096)); // pitch
    b[12..16].* = @bitCast(@as(u32, 1024)); // width
    b[16..20].* = @bitCast(@as(u32, 768)); // height
    b[20] = 32; // bpp
    b[21] = 1; // fb_type: direct RGB
    b[22..24].* = @bitCast(@as(u16, 0)); // reserved
    b[24] = 16; // red pos (BGR order)
    b[25] = 8; // red size
    b[26] = 8; // green pos
    b[27] = 8; // green size
    b[28] = 0; // blue pos
    b[29] = 8; // blue size
    return b;
}

/// Body of a module tag: {mod_start,mod_end} + id string + NUL.
fn moduleBody(comptime id: []const u8, start: u32, end: u32) [8 + id.len + 1]u8 {
    var b: [8 + id.len + 1]u8 = undefined;
    b[0..4].* = @bitCast(start);
    b[4..8].* = @bitCast(end);
    @memcpy(b[8..][0..id.len], id);
    b[8 + id.len] = 0;
    return b;
}

test "well-formed blob: framebuffer fields parse exactly" {
    var blob = TestBlob{};
    _ = blob.addTag(TAG_FRAMEBUFFER, &fbBody());
    blob.finish();

    const fb = framebuffer(blob.addr()) orelse return error.TestExpectedFramebuffer;
    try std.testing.expectEqual(@as(u64, 0xFD00_0000), fb.addr);
    try std.testing.expectEqual(@as(u32, 4096), fb.pitch);
    try std.testing.expectEqual(@as(u32, 1024), fb.width);
    try std.testing.expectEqual(@as(u32, 768), fb.height);
    try std.testing.expectEqual(@as(u8, 32), fb.bpp);
    try std.testing.expectEqual(@as(u8, 1), fb.fb_type);
    try std.testing.expectEqual(@as(u8, 16), fb.red_field_position);
    try std.testing.expectEqual(@as(u8, 0), fb.blue_field_position);
}

test "no framebuffer tag → null (the -vga none passthrough boot)" {
    var blob = TestBlob{};
    _ = blob.addTag(TAG_MODULE, &moduleBody("gsp", 0x1000, 0x2000));
    blob.finish();
    try std.testing.expectEqual(@as(?*const FramebufferTag, null), framebuffer(blob.addr()));
}

test "modules iterate in order and findModule matches by id" {
    var blob = TestBlob{};
    _ = blob.addTag(TAG_FRAMEBUFFER, &fbBody()); // non-module tags are skipped
    _ = blob.addTag(TAG_MODULE, &moduleBody("gsp", 0x10_0000, 0x20_0000));
    _ = blob.addTag(TAG_MODULE, &moduleBody("scrubber", 0x30_0000, 0x30_2000));
    blob.finish();

    var it = modules(blob.addr());
    const m0 = it.next() orelse return error.TestExpectedModule;
    try std.testing.expectEqualStrings("gsp", m0.id);
    try std.testing.expectEqual(@as(u64, 0x10_0000), m0.start);
    try std.testing.expectEqual(@as(u64, 0x10_0000), m0.len());
    const m1 = it.next() orelse return error.TestExpectedModule;
    try std.testing.expectEqualStrings("scrubber", m1.id);
    try std.testing.expectEqual(@as(?Module, null), it.next());

    const found = findModule(blob.addr(), "scrubber") orelse return error.TestExpectedModule;
    try std.testing.expectEqual(@as(u64, 0x30_0000), found.start);
    try std.testing.expectEqual(@as(?Module, null), findModule(blob.addr(), "absent"));
}

test "size-0 tag bails instead of spinning in place forever" {
    var blob = TestBlob{};
    const off = blob.addTag(TAG_MODULE, &moduleBody("gsp", 0x1000, 0x2000));
    blob.finish();
    blob.putU32(off + 4, 0); // corrupt: tag.size = 0 — the infinite-loop shape

    // Both walkers must terminate (returning null), not hang.
    try std.testing.expectEqual(@as(?*const FramebufferTag, null), framebuffer(blob.addr()));
    var it = modules(blob.addr());
    try std.testing.expectEqual(@as(?Module, null), it.next());
}

test "tag body declared past total_size ends the walk (truncated blob)" {
    var blob = TestBlob{};
    _ = blob.addTag(TAG_FRAMEBUFFER, &fbBody());
    blob.finish();
    blob.putU32(0, 16); // truncate: total_size now cuts into the fb tag's body

    try std.testing.expectEqual(@as(?*const FramebufferTag, null), framebuffer(blob.addr()));
}

test "blob with no end tag terminates cleanly at total_size" {
    var blob = TestBlob{};
    _ = blob.addTag(TAG_MODULE, &moduleBody("gsp", 0x1000, 0x2000));
    // No finish(): patch total_size to exactly the module tag's end, no TAG_END.
    blob.putU32(0, @intCast(blob.len));

    var it = modules(blob.addr());
    const m = it.next() orelse return error.TestExpectedModule;
    try std.testing.expectEqualStrings("gsp", m.id);
    try std.testing.expectEqual(@as(?Module, null), it.next()); // clean end, no overrun
}

test "module id missing its NUL inside the declared size → corrupt, walk ends" {
    var blob = TestBlob{};
    const off = blob.addTag(TAG_MODULE, &moduleBody("gsp", 0x1000, 0x2000));
    blob.finish();
    // Corrupt: shrink the declared size so the NUL falls OUTSIDE it. Fixed
    // fields are 16 bytes; "gsp\x00" follows; size=19 covers only "gsp".
    blob.putU32(off + 4, 19);

    var it = modules(blob.addr());
    try std.testing.expectEqual(@as(?Module, null), it.next());
}

test "mmap: entries walk by the firmware-declared stride, not @sizeOf" {
    // Firmware may append fields per entry: declare entry_size = 32 (24 + 8 pad).
    var body: [8 + 2 * 32]u8 = [_]u8{0} ** (8 + 2 * 32);
    body[0..4].* = @bitCast(@as(u32, 32)); // entry_size
    body[4..8].* = @bitCast(@as(u32, 0)); // entry_version
    // entry 0: 0..640K available
    body[8..16].* = @bitCast(@as(u64, 0));
    body[16..24].* = @bitCast(@as(u64, 640 * 1024));
    body[24..28].* = @bitCast(@as(u32, 1));
    // entry 1 at stride 32: 1M..64M available
    body[40..48].* = @bitCast(@as(u64, 0x10_0000));
    body[48..56].* = @bitCast(@as(u64, 63 * 1024 * 1024));
    body[56..60].* = @bitCast(@as(u32, 1));

    var blob = TestBlob{};
    _ = blob.addTag(TAG_MMAP, &body);
    blob.finish();

    var it = mmap(blob.addr()) orelse return error.TestExpectedMmap;
    const e0 = it.next() orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(u64, 0), e0.addr);
    try std.testing.expectEqual(@as(u64, 640 * 1024), e0.len);
    const e1 = it.next() orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(u64, 0x10_0000), e1.addr); // stride respected
    try std.testing.expectEqual(@as(?*const MmapEntry, null), it.next());
}

test "mmap: entry_size below a whole MmapEntry is rejected (0 would loop forever)" {
    for ([_]u32{ 0, 8, 23 }) |bad| {
        var body: [8 + 24]u8 = [_]u8{0} ** 32;
        body[0..4].* = @bitCast(bad);
        var blob = TestBlob{};
        _ = blob.addTag(TAG_MMAP, &body);
        blob.finish();
        try std.testing.expectEqual(@as(?MmapIter, null), mmap(blob.addr()));
    }
}

test "empty blob (header + end tag only): every query returns null" {
    var blob = TestBlob{};
    blob.finish();
    try std.testing.expectEqual(@as(?*const FramebufferTag, null), framebuffer(blob.addr()));
    try std.testing.expectEqual(@as(?MmapIter, null), mmap(blob.addr()));
    var it = modules(blob.addr());
    try std.testing.expectEqual(@as(?Module, null), it.next());
}
