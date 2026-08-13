//! VBIOS access + minimal parse for FWSEC extraction (nouveau
//! nvkm/subdev/bios/). The signed FWSEC ucode that sets up the FRTS region in
//! WPR2 (a precondition for the GSP booter) lives in the GPU VBIOS, not the
//! firmware package — so we must read and parse the VBIOS.
//!
//! Read method (Ada): the GPU has decompressed the VBIOS into VRAM; nouveau
//! reads it through the BAR0 PRAMIN window (shadowramin.c):
//!   image addr = rd32(0x820c04) (GA100+); must be enabled + in-vram
//!   addr = (addr & 0xffffff00) << 8
//!   save rd32(0x001700); wr32(0x001700, addr>>16); read via rd32(0x700000+i)
//!
//! Parse path: ROM -> BIT table ('0xb8 BIT') -> 'p' entry -> PMU table -> entry
//! type 0x85 (FWSEC) -> falcon ucode desc. Cross-checked vs bios/bit.c, pmu.c.
//!
//! Isolation invariant: reads the BAR0 mmio.Mapping; adds nothing to other
//! modules. The VBIOS bytes are copied into a kudos heap buffer.

const mmio = @import("../rm/mmio.zig");
const log = @import("../rm/log.zig").gpu;
const heap = @import("../../../kernel/memory/heap.zig");
const pci = @import("../../pci/pci.zig");

pub const Error = error{
    VbiosImageDisabled,
    VbiosNotInVram,
    VbiosBadSignature,
    VbiosAlloc,
    VbiosNoBit,
    VbiosNoPmu,
    VbiosNoFwsec,
    VbiosIfrBad,
};

// PROM (PCI-ROM mirror) read method — works on a cold card (nouveau shadowrom.c).
const PROM_BASE: u64 = 0x300000; // BAR0 mirror of the PCI expansion ROM
const PCI_CFG_ROM_SHADOW: u8 = 0x50; // PCI cfg reg; bit0 = ROM shadow enable
const IFR_FIXED0_NVGI: u32 = 0x4947564e; // "NVGI" IFR header signature
const ROM_DIR_RFRD: u32 = 0x44524652; // "RFRD" ROM directory id

/// A read VBIOS image (owned heap buffer of raw bytes).
///
/// NVIDIA data-table pointers (BIT/PMU/...) use a relocated address space: an
/// offset past the legacy image (image0_size) is rebased into the first NVIDIA-
/// extension (type-0xe0) image (imaged_addr). nouveau's nvbios_addr applies this
/// to every read; we mirror it in xlat() so rd8/16/32 take the *pointer-space*
/// offset and resolve to the right byte in the concatenated buffer.
pub const Vbios = struct {
    data: []u8,
    bit_offset: u32, // offset of the BIT header (the 0xb8 byte), pointer-space
    image0_size: u32 = 0, // size of the legacy image (image[0])
    imaged_addr: u32 = 0, // base of the first type-0xe0 image

    /// nvbios_addr: rebase a pointer-space offset into the raw buffer.
    fn xlat(self: Vbios, off: u32) u32 {
        if (off >= self.image0_size and self.imaged_addr != 0)
            return off - self.image0_size + self.imaged_addr;
        return off;
    }

    /// True when `n` bytes at pointer-space offset `off` lie inside the buffer —
    /// the parse-step bounds guard (a corrupt table pointer must be caught by the
    /// caller and fail loudly, not read OOB / panic).
    pub fn inBounds(self: Vbios, off: u32, n: u32) bool {
        const a: u64 = self.xlat(off);
        return a + n <= self.data.len;
    }

    /// Read a byte at pointer-space offset `off` (relocated via xlat).
    pub fn rd8(self: Vbios, off: u32) u8 {
        return self.data[self.xlat(off)];
    }
    /// Read a little-endian u16 at pointer-space offset `off` (relocated via xlat).
    pub fn rd16(self: Vbios, off: u32) u16 {
        const a = self.xlat(off);
        return @as(u16, self.data[a]) | (@as(u16, self.data[a + 1]) << 8);
    }
    /// Read a little-endian u32 at pointer-space offset `off` (relocated via xlat).
    pub fn rd32(self: Vbios, off: u32) u32 {
        const a = self.xlat(off);
        return @as(u32, self.data[a]) | (@as(u32, self.data[a + 1]) << 8) |
            (@as(u32, self.data[a + 2]) << 16) | (@as(u32, self.data[a + 3]) << 24);
    }
};

/// Read a dword from the PROM mirror at BAR0+0x300000+off.
fn promRd(regs: mmio.Mapping, off: u32) u32 {
    return regs.read32(PROM_BASE + off);
}

/// Find the PCI ROM image's byte offset within the PROM mirror, parsing the IFR
/// header if present (nouveau nvbios_prom_init). Returns the offset where the
/// 0x55aa PCI ROM image begins.
fn promImageOffset(regs: mmio.Mapping) Error!u32 {
    const fixed0 = promRd(regs, 0);
    if (fixed0 != IFR_FIXED0_NVGI) return 0; // no IFR: image at offset 0

    const fixed1 = promRd(regs, 4);
    const version: u8 = @truncate(fixed1 >> 8);
    var rom_off: u32 = 0;
    switch (version) {
        1, 2 => {
            const data_size = (fixed1 >> 16) & 0x7fff;
            rom_off = promRd(regs, data_size + 4);
        },
        3 => {
            const fixed2 = promRd(regs, 8);
            const data_size = fixed2 & 0x000fffff;
            const dir_off = promRd(regs, data_size) + 4096;
            if (promRd(regs, dir_off) != ROM_DIR_RFRD) return error.VbiosIfrBad;
            rom_off = promRd(regs, dir_off + 8);
        },
        else => return error.VbiosIfrBad,
    }
    if (rom_off >= 0x00100000) return error.VbiosIfrBad;
    if ((promRd(regs, rom_off) & 0xffff) != 0xaa55) return error.VbiosIfrBad;
    return rom_off;
}

/// Read the VBIOS via the PROM mirror (works on a cold card). `regs` is BAR0,
/// `dev` is the GPU PCI device (to toggle the ROM shadow), `len` is how many
/// bytes to copy from the image start.
pub fn read(regs: mmio.Mapping, dev: pci.Device, len: u32) Error!Vbios {
    // Disable the PCI ROM shadow so the PROM is readable (cfg 0x50 bit0 = 0).
    const shadow = dev.read32(PCI_CFG_ROM_SHADOW);
    dev.write32(PCI_CFG_ROM_SHADOW, shadow & ~@as(u32, 1));
    defer dev.write32(PCI_CFG_ROM_SHADOW, shadow | 1); // restore on the way out

    const rom_off = try promImageOffset(regs);

    const a = heap.allocator();
    const buf = a.alloc(u8, len) catch return error.VbiosAlloc;
    var i: u32 = 0;
    while (i < len) : (i += 4) {
        const w = promRd(regs, rom_off + i);
        buf[i] = @truncate(w);
        buf[i + 1] = @truncate(w >> 8);
        buf[i + 2] = @truncate(w >> 16);
        buf[i + 3] = @truncate(w >> 24);
    }

    if (!(buf[0] == 0x55 and buf[1] == 0xaa)) {
        log("gpu.vbios: bad ROM sig 0x{x:0>2}{x:0>2} at rom_off=0x{x}\n", .{ buf[1], buf[0], rom_off });
        a.free(buf);
        return error.VbiosBadSignature;
    }

    var vb = Vbios{ .data = buf, .bit_offset = 0 };
    // Compute the pointer-space relocation (image0_size + first 0xe0 image base)
    // by walking the RAW concatenated images (no translation yet).
    setRelocation(&vb);
    vb.bit_offset = findBit(vb) catch {
        a.free(buf);
        return error.VbiosNoBit;
    };
    log("gpu.vbios: PROM read {} KiB (rom_off=0x{x}), sig ok, BIT @0x{x}, image0_size=0x{x} imaged_addr=0x{x}\n", .{ len >> 10, rom_off, vb.bit_offset, vb.image0_size, vb.imaged_addr });
    return vb;
}

/// Raw little-endian u16 read at RAW buffer offset `o` (NO pointer-space
/// translation) — for walking the concatenated image chain before the
/// relocation parameters are known.
fn raw16(vb: *const Vbios, o: u32) u16 {
    return @as(u16, vb.data[o]) | (@as(u16, vb.data[o + 1]) << 8);
}
/// Raw little-endian u32 read at RAW buffer offset `o` (NO pointer-space
/// translation); see raw16.
fn raw32(vb: *const Vbios, o: u32) u32 {
    return @as(u32, vb.data[o]) | (@as(u32, vb.data[o + 1]) << 8) |
        (@as(u32, vb.data[o + 2]) << 16) | (@as(u32, vb.data[o + 3]) << 24);
}

/// Set image0_size + imaged_addr (nouveau base.c): image0_size = size of the
/// first image; imaged_addr = base of the first type-0xe0 image. Walks raw.
fn setRelocation(vb: *Vbios) void {
    var base: u32 = 0;
    var idx: u32 = 0;
    while (idx < 16) : (idx += 1) {
        if (base + 0x1a >= vb.data.len) return;
        const sig = raw16(vb, base);
        if (sig != 0xaa55 and sig != 0xbb77 and sig != 0x4e56) return;
        const pcir = base + raw16(vb, base + 0x18);
        if (pcir + 0x16 >= vb.data.len) return;
        const psig = raw32(vb, pcir);
        if (psig != 0x52494350 and psig != 0x53494752 and psig != 0x5344504e) return;
        var size = @as(u32, raw16(vb, pcir + 0x10)) * 512;
        const itype = vb.data[pcir + 0x14];
        const npde = (pcir + raw16(vb, pcir + 0x0a) + 0x0f) & ~@as(u32, 0x0f);
        if (npde + 0x0a < vb.data.len and raw32(vb, npde) == 0x4544504e)
            size = @as(u32, raw16(vb, npde + 0x08)) * 512;
        if (idx == 0) vb.image0_size = size;
        if (itype == 0xe0 and vb.imaged_addr == 0) {
            vb.imaged_addr = base;
            return; // first 0xe0 image found (nouveau breaks here)
        }
        if (size == 0) return;
        base += size;
    }
}

/// Find the BIT table. nouveau scans for the 5-byte signature "\xff\xb8BIT" and
/// sets bit_offset to the \xff byte (base.c nvbios_findstr); the entry count/
/// stride are read relative to that, so we must return the \xff offset, not 0xb8.
fn findBit(vb: Vbios) Error!u32 {
    var o: u32 = 0;
    while (o + 5 < vb.data.len) : (o += 1) {
        if (vb.data[o] == 0xff and vb.data[o + 1] == 0xb8 and vb.data[o + 2] == 'B' and
            vb.data[o + 3] == 'I' and vb.data[o + 4] == 'T') return o;
    }
    return error.VbiosNoBit;
}

/// A BIT table entry (bios/bit.c).
pub const BitEntry = struct { version: u8, length: u16, offset: u16 };

/// Look up a BIT entry by id (e.g. 'p'). bit_offset+9 = entry stride,
/// +10 = entry count, +12 = first entry; entry: id,ver,len(u16),off(u16).
pub fn bitEntry(vb: Vbios, id: u8) ?BitEntry {
    if (!vb.inBounds(vb.bit_offset, 12)) {
        log("gpu.vbios: BIT header @0x{x} outside buffer\n", .{vb.bit_offset});
        return null;
    }
    const count = vb.rd8(vb.bit_offset + 10);
    const stride = vb.rd8(vb.bit_offset + 9);
    var entry = vb.bit_offset + 12;
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        if (!vb.inBounds(entry, @max(6, @as(u32, stride)))) {
            log("gpu.vbios: BIT entry[{}] @0x{x} outside buffer\n", .{ n, entry });
            return null;
        }
        if (vb.rd8(entry) == id) {
            return .{
                .version = vb.rd8(entry + 1),
                .length = vb.rd16(entry + 2),
                .offset = vb.rd16(entry + 4),
            };
        }
        entry += stride;
    }
    return null;
}

/// A located FWSEC ucode descriptor within the VBIOS (the type-0x85 PMU entry's
/// data pointer; the caller parses the version-specific desc there).
pub const FwsecLoc = struct {
    desc_offset: u32, // offset of the falcon ucode desc in the VBIOS
};

/// Find the FWSEC ucode (PMU table entry type 0x85). nouveau pmu.c:
///   'p' bit entry (v2) -> rd32(off) = PMU table; tbl[1]=hdr, tbl[2]=len,
///   tbl[3]=cnt; each entry: [0]=type, [2..6]=data offset.
pub fn findFwsec(vb: Vbios) Error!FwsecLoc {
    // Diagnostic: dump BIT header + entry ids so we can see the table on HW.
    log("gpu.vbios: BIT cnt={} stride={}\n", .{ vb.rd8(vb.bit_offset + 10), vb.rd8(vb.bit_offset + 9) });
    const p = bitEntry(vb, 'p') orelse {
        log("gpu.vbios: no 'p' BIT entry\n", .{});
        return error.VbiosNoPmu;
    };
    log("gpu.vbios: 'p' entry ver={} len={} off=0x{x}\n", .{ p.version, p.length, p.offset });
    if (p.version != 2) return error.VbiosNoPmu;
    if (!vb.inBounds(p.offset, 4)) return error.VbiosNoPmu;
    const pmu = vb.rd32(p.offset);
    log("gpu.vbios: PMU tbl ptr=0x{x}\n", .{pmu});
    if (pmu == 0 or !vb.inBounds(pmu, 4)) return error.VbiosNoPmu;
    const hdr = vb.rd8(pmu + 1);
    const len = vb.rd8(pmu + 2);
    const cnt = vb.rd8(pmu + 3);
    log("gpu.vbios: PMU tbl hdr={} len={} cnt={}\n", .{ hdr, len, cnt });
    var idx: u32 = 0;
    while (idx < cnt) : (idx += 1) {
        const ent = pmu + hdr + idx * len;
        if (!vb.inBounds(ent, @max(6, @as(u32, len)))) {
            log("gpu.vbios: PMU entry[{}] @0x{x} outside buffer\n", .{ idx, ent });
            return error.VbiosNoFwsec;
        }
        const etype = vb.rd8(ent);
        const edata = vb.rd32(ent + 2);
        if (etype == 0x85) {
            log("gpu.vbios: FWSEC (type 0x85) desc @0x{x}\n", .{edata});
            return .{ .desc_offset = edata };
        }
    }
    return error.VbiosNoFwsec;
}
