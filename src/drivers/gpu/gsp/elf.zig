//! Minimal ELF64 section finder — the GSP-RM firmware blob is an ELF whose
//! `.fwimage` section is the actual firmware (radix3 target) and whose
//! `.fwsignature_ad10x` section is the signature the booter checks (nouveau
//! r535_gsp_elf_section). We only need: given a blob + section name, return the
//! section's [offset,size) within the blob.

const log = @import("../rm/log.zig").gpu;

pub const Error = error{ ElfBadMagic, ElfSectionNotFound, ElfOutOfBounds };

/// Read a little-endian u16 from the blob at byte offset `o`.
fn rd16(d: []const u8, o: usize) u16 {
    return @as(u16, d[o]) | (@as(u16, d[o + 1]) << 8);
}
/// Read a little-endian u32 from the blob at byte offset `o`.
fn rd32(d: []const u8, o: usize) u32 {
    return @as(u32, d[o]) | (@as(u32, d[o + 1]) << 8) | (@as(u32, d[o + 2]) << 16) | (@as(u32, d[o + 3]) << 24);
}
/// Read a little-endian u64 from the blob at byte offset `o`.
fn rd64(d: []const u8, o: usize) u64 {
    return @as(u64, rd32(d, o)) | (@as(u64, rd32(d, o + 4)) << 32);
}

pub const Section = struct { data: []const u8 };

/// Find an ELF64 section by name. elf64_hdr: e_shoff@0x28(u64), e_shentsize@0x3a
/// (u16), e_shnum@0x3c(u16), e_shstrndx@0x3e(u16). elf64_shdr: sh_name@0(u32),
/// sh_offset@0x18(u64), sh_size@0x20(u64); entry stride = e_shentsize.
pub fn section(img: []const u8, name: []const u8) Error!Section {
    if (img.len < 64 or !(img[0] == 0x7f and img[1] == 'E' and img[2] == 'L' and img[3] == 'F'))
        return error.ElfBadMagic;
    const shoff = rd64(img, 0x28);
    const shentsize = rd16(img, 0x3a);
    const shnum = rd16(img, 0x3c);
    const shstrndx = rd16(img, 0x3e);

    // Bounds: every section header, and the string-table header, must lie inside
    // the blob (a truncated/corrupt blob must fail loudly, not read OOB).
    if (shentsize < 0x40 or shstrndx >= shnum or
        shoff + @as(u64, shnum) * shentsize > img.len)
    {
        log("gpu.elf: bad section headers shoff=0x{x} shentsize={} shnum={} shstrndx={} len={}\n", .{ shoff, shentsize, shnum, shstrndx, img.len });
        return error.ElfOutOfBounds;
    }

    // String table section -> its sh_offset gives the names base.
    const strsh = shoff + @as(u64, shstrndx) * shentsize;
    const names_off = rd64(img, @intCast(strsh + 0x18));
    if (names_off >= img.len) {
        log("gpu.elf: string table offset 0x{x} outside blob (len={})\n", .{ names_off, img.len });
        return error.ElfOutOfBounds;
    }

    var i: u16 = 0;
    while (i < shnum) : (i += 1) {
        const sh = shoff + @as(u64, i) * shentsize;
        const sh_name = rd32(img, @intCast(sh));
        const nm_start: usize = @intCast(names_off + sh_name);
        // The name (plus its terminator) must fit in the blob.
        if (nm_start + name.len + 1 > img.len) continue;
        // Compare the null-terminated name at names_off+sh_name to `name`.
        var k: usize = 0;
        while (k < name.len and img[nm_start + k] == name[k]) k += 1;
        if (k == name.len and img[nm_start + k] == 0) {
            const off = rd64(img, @intCast(sh + 0x18));
            const size = rd64(img, @intCast(sh + 0x20));
            if (off > img.len or size > img.len - off) {
                log("gpu.elf: section '{s}' [0x{x}..+0x{x}) outside blob (len={})\n", .{ name, off, size, img.len });
                return error.ElfOutOfBounds;
            }
            return .{ .data = img[@intCast(off)..@intCast(off + size)] };
        }
    }
    log("gpu.elf: section '{s}' not found ({} sections)\n", .{ name, shnum });
    return error.ElfSectionNotFound;
}
