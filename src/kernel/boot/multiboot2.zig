//! Multiboot2 information-structure parser.
//! GRUB passes a pointer to this structure in kmain's first argument.

pub const TAG_END: u32 = 0;
pub const TAG_MODULE: u32 = 3;
pub const TAG_MMAP: u32 = 6;
pub const TAG_FRAMEBUFFER: u32 = 8;

/// Common header at the start of every tag.
const Tag = extern struct {
    type: u32,
    size: u32,
};

/// Framebuffer tag (type 8): how to reach the linear framebuffer.
pub const FramebufferTag = extern struct {
    type: u32,
    size: u32,
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
    reserved: u16,
    // color_info for direct-RGB modes (fb_type == 1): the bit position and size
    // of each channel. Real firmware varies the channel order (RGB vs BGR), so
    // the framebuffer driver must honor these instead of assuming 0x00RRGGBB.
    red_field_position: u8,
    red_mask_size: u8,
    green_field_position: u8,
    green_mask_size: u8,
    blue_field_position: u8,
    blue_mask_size: u8,
};

/// The smallest a well-formed tag can be: the common {type,size} header. A tag
/// claiming a smaller size is malformed — critically, a size of 0 makes the
/// 8-byte-rounded advance below 0, so the walk would spin in place forever.
const TAG_MIN_SIZE: u32 = @sizeOf(Tag);

/// Walk the tag list looking for `wanted`, returning a pointer to it. Bounded by
/// the structure's own `total_size` and against a malformed (too-small) tag size,
/// so a truncated or corrupt GRUB blob fails to `null` instead of reading past the
/// structure or looping forever.
fn findTag(info_addr: u64, wanted: u32) ?*const Tag {
    const base: [*]const u8 = @ptrFromInt(info_addr);
    const total = totalSize(info_addr);
    var off: usize = 8; // skip total_size (u32) + reserved (u32)
    while (off + TAG_MIN_SIZE <= total) {
        const tag: *const Tag = @ptrCast(@alignCast(base + off));
        if (tag.type == TAG_END) return null;
        if (tag.size < TAG_MIN_SIZE) return null; // malformed: bail, don't spin
        // The tag's declared BODY must fit inside the blob too — a match at the
        // end of a truncated blob would hand the caller a tag whose fields
        // (framebuffer addr/pitch, mmap entries) lie past the structure.
        if (off + tag.size > total) return null;
        if (tag.type == wanted) return tag;
        off += (tag.size + 7) & ~@as(usize, 7); // advance, 8-byte aligned
    }
    return null;
}

/// Boot module tag (type 3): a blob GRUB loaded into memory via `module2`. The
/// payload occupies physical `[mod_start, mod_end)`; `string` is the per-module
/// command-line (kudos uses it as the module id, e.g. "gsp"). Unlike the
/// framebuffer/mmap tags there can be many, so they are walked, not found-once.
pub const ModuleTag = extern struct {
    type: u32,
    size: u32,
    mod_start: u32,
    mod_end: u32,
    // followed by a null-terminated string (variable length)
};

/// A located boot module: its physical span and id string.
pub const Module = struct {
    start: u64,
    end: u64, // exclusive
    id: []const u8,

    /// Byte length of the module payload (`end` is exclusive).
    pub fn len(self: Module) u64 {
        return self.end - self.start;
    }
};

/// Iterator over every module (type-3) tag in the info structure.
pub const ModuleIter = struct {
    base: [*]const u8,
    off: usize,
    total: usize, // structure total_size — the walk's upper bound

    /// Return the next module tag, or null at the end. Bounded by `total` and
    /// against a too-small (malformed) tag size so a truncated/corrupt blob ends the
    /// walk cleanly rather than reading past the structure or looping forever.
    pub fn next(self: *ModuleIter) ?Module {
        while (self.off + TAG_MIN_SIZE <= self.total) {
            const tag: *const Tag = @ptrCast(@alignCast(self.base + self.off));
            if (tag.type == TAG_END) return null;
            if (tag.size < TAG_MIN_SIZE) return null; // malformed: bail, don't spin
            // The declared body must fit inside the blob (same rule as findTag):
            // a truncated blob must end the walk, not hand out a tag whose
            // fields lie past the structure.
            if (self.off + tag.size > self.total) return null;
            const this_off = self.off;
            self.off += (tag.size + 7) & ~@as(usize, 7);
            if (tag.type != TAG_MODULE) continue;
            // A module tag must at least hold its fixed fields
            // (size = 16 + strlen + 1).
            if (tag.size < @sizeOf(ModuleTag)) return null;
            const mt: *const ModuleTag = @ptrCast(@alignCast(self.base + this_off));
            // The id string starts after the fixed fields and must be
            // NUL-terminated WITHIN the tag's declared size — scanning past it
            // would walk out of the blob on a corrupt tag and return an id
            // spanning arbitrary memory.
            const str_ptr: [*]const u8 = self.base + this_off + @sizeOf(ModuleTag);
            const str_max: usize = tag.size - @sizeOf(ModuleTag);
            var n: usize = 0;
            while (n < str_max and str_ptr[n] != 0) n += 1;
            if (n == str_max) return null; // no NUL inside the tag: corrupt blob
            return .{ .start = mt.mod_start, .end = mt.mod_end, .id = str_ptr[0..n] };
        }
        return null; // ran off the end without a TAG_END (truncated blob)
    }
};

/// Build an iterator over the module (type-3) tags in the info structure.
pub fn modules(info_addr: u64) ModuleIter {
    return .{ .base = @ptrFromInt(info_addr), .off = 8, .total = totalSize(info_addr) };
}

/// Find the module whose id string equals `id`, or null if not loaded.
pub fn findModule(info_addr: u64, id: []const u8) ?Module {
    var it = modules(info_addr);
    while (it.next()) |m| {
        if (eql(m.id, id)) return m;
    }
    return null;
}

/// Byte-wise equality of two slices (local, so multiboot2 stays std-free).
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Locate the framebuffer tag (type 8), or null when GRUB provided no framebuffer
/// (e.g. a `-vga none` passthrough boot — see main_root.zig's headless path).
pub fn framebuffer(info_addr: u64) ?*const FramebufferTag {
    const tag = findTag(info_addr, TAG_FRAMEBUFFER) orelse return null;
    return @ptrCast(@alignCast(tag));
}

/// Total size (bytes) of the whole multiboot2 info blob (first u32 at the ptr).
pub fn totalSize(info_addr: u64) u32 {
    const p: *const u32 = @ptrFromInt(info_addr);
    return p.*;
}

/// Memory-map tag (type 6) header: fixed fields, then `size`-worth of entries
/// each `entry_size` bytes (entry_size is firmware-declared, not hardcoded).
const MmapTag = extern struct {
    type: u32,
    size: u32,
    entry_size: u32,
    entry_version: u32,
};

/// One physical memory region. `type == 1` means available RAM.
pub const MmapEntry = extern struct {
    addr: u64,
    len: u64,
    type: u32,
    reserved: u32,
};

/// Iterator over the memory-map entries of a type-6 tag. Built by `mmap`.
pub const MmapIter = struct {
    base: [*]const u8,
    end: usize, // offset (from base) one past the last entry
    entry_size: usize,
    cur: usize, // current offset from base

    /// Return the next memory-map entry, or null once the tag's entries are
    /// exhausted. Advances by the firmware-declared `entry_size` (validated in
    /// `mmap`), not @sizeOf(MmapEntry), since firmware may append trailing fields.
    pub fn next(self: *MmapIter) ?*const MmapEntry {
        if (self.cur + self.entry_size > self.end) return null;
        const e: *const MmapEntry = @ptrCast(@alignCast(self.base + self.cur));
        self.cur += self.entry_size;
        return e;
    }
};

/// Build an iterator over the memory-map (type-6) entries, or null if no mmap tag
/// is present or the firmware-declared entry_size is too small to trust (see the
/// validation below). pmm.init walks this to discover available RAM.
pub fn mmap(info_addr: u64) ?MmapIter {
    const tag = findTag(info_addr, TAG_MMAP) orelse return null;
    const mt: *const MmapTag = @ptrCast(@alignCast(tag));
    // Validate the firmware-supplied entry_size: it must be at least a whole
    // MmapEntry. An entry_size of 0 would make MmapIter.next never advance `cur`
    // (infinite loop in pmm.init); one below @sizeOf(MmapEntry) would read the
    // type/addr fields at the wrong offset and could mis-classify reserved RAM as
    // available. Fail loud (null → pmm.init's FATAL) rather than parse garbage.
    if (mt.entry_size < @sizeOf(MmapEntry)) return null;
    const base: [*]const u8 = @ptrCast(tag);
    return .{
        .base = base,
        .end = mt.size,
        .entry_size = mt.entry_size,
        .cur = @sizeOf(MmapTag), // entries follow the 16-byte tag header
    };
}
