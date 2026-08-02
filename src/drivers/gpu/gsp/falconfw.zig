//! NVIDIA falcon firmware container parsing — the booter/bootloader images are
//! wrapped in NVIDIA's signed "HS" (heavy-secure) container. This mirrors
//! nouveau's nvfw container headers (include/nvfw/fw.h, hs.h) and the ga102
//! booter ctor (gsp/ga102.c ga102_gsp_booter_ctor) that reads them.
//!
//! Parse only for now (the load/boot DMA is the next step): given a signed
//! falcon image, locate the code/data segments + signature so they can be DMAed
//! into the falcon. Verifiable on HW: the booter image magic is 0x10de.

const log = @import("../base/log.zig").gpu;

/// `struct nvfw_bin_hdr` (nvfw/fw.h). bin_magic for NVIDIA images is 0x10de.
pub const BinHdr = extern struct {
    bin_magic: u32, // 0x10de
    bin_ver: u32,
    bin_size: u32,
    header_offset: u32, // -> nvfw_hs_header_v2
    data_offset: u32, // -> ucode image (code+data)
    data_size: u32,
};

/// `struct nvfw_hs_header_v2` (nvfw/hs.h) — the heavy-secure header that locates
/// the production signature, the patch site, and the load header.
pub const HsHeaderV2 = extern struct {
    sig_prod_offset: u32,
    sig_prod_size: u32,
    patch_loc: u32,
    patch_sig: u32,
    meta_data_offset: u32,
    meta_data_size: u32,
    num_sig: u32,
    header_offset: u32, // -> nvfw_hs_load_header_v2
    header_size: u32,
};

/// `struct nvfw_hs_load_header_v2` (nvfw/hs.h), without the trailing app[] VLA;
/// the first app entry follows immediately and gives IMEM offset/size.
pub const HsLoadHeaderV2 = extern struct {
    os_code_offset: u32,
    os_code_size: u32,
    os_data_offset: u32,
    os_data_size: u32,
    num_apps: u32,
    // app[num_apps] follows: { offset, size, data_offset, data_size }
};

pub const App = extern struct {
    offset: u32,
    size: u32,
    data_offset: u32,
    data_size: u32,
};

pub const Error = error{ FalconFwBadMagic, FalconFwTruncated };

const BIN_MAGIC: u32 = 0x10de;

/// Typed pointer to a `T` at byte offset `off` in the image, bounds-checked
/// against the blob length (fails FalconFwTruncated rather than reading OOB).
fn at(comptime T: type, image: []const u8, off: u32) Error!*const T {
    if (@as(u64, off) + @sizeOf(T) > image.len) return error.FalconFwTruncated;
    return @ptrCast(@alignCast(image.ptr + off));
}

/// Parsed view of a signed falcon image: the segments + signature the loader
/// needs (mirrors what ga102_gsp_booter_ctor extracts).
pub const FalconImage = struct {
    bin: *const BinHdr,
    hs: *const HsHeaderV2,
    load: *const HsLoadHeaderV2,
    app0: *const App,
    /// fuse version / engine / ucode ids from the HS meta (3 u32s).
    fuse_ver: u32,
    engine_id: u32,
    ucode_id: u32,
    // Signature patch parameters (ga102_gsp_booter_ctor: these three HS header
    // fields are *offsets to* dword values in the blob, dereferenced here).
    patch_loc: u32, // dst offset in the image where the chosen sig is written
    patch_sig: u32, // added to sig_prod_offset to locate the signature array
    num_sig: u32, // number of production signatures
};

/// Read a u32 from the image at `off` (little-endian, native).
fn rd32(image: []const u8, off: u32) u32 {
    const p: *const u32 = @ptrCast(@alignCast(image.ptr + off));
    return p.*;
}

/// Parse a signed falcon firmware image. Logs the key fields (verifiable on HW
/// against the known booter layout). Fails loudly on a bad magic / truncation.
pub fn parse(name: []const u8, image: []const u8) Error!FalconImage {
    const bin = try at(BinHdr, image, 0);
    if (bin.bin_magic != BIN_MAGIC) {
        log("gpu.falconfw: {s}: bad magic 0x{x} (want 0x10de)\n", .{ name, bin.bin_magic });
        return error.FalconFwBadMagic;
    }
    const hs = try at(HsHeaderV2, image, bin.header_offset);
    const load = try at(HsLoadHeaderV2, image, hs.header_offset);
    const app0 = try at(App, image, hs.header_offset + @sizeOf(HsLoadHeaderV2));
    const meta: [*]const u32 = @ptrCast(@alignCast(image.ptr + hs.meta_data_offset));

    log("gpu.falconfw: {s}: ver={} size={} data@0x{x} sig@0x{x} apps={} app0[off=0x{x} size=0x{x}]\n", .{
        name, bin.bin_ver, bin.bin_size, bin.data_offset, hs.sig_prod_offset, load.num_apps, app0.offset, app0.size,
    });
    // patch_loc/patch_sig/num_sig are HS-header offsets *to* dword values.
    const patch_loc = rd32(image, hs.patch_loc);
    const patch_sig = rd32(image, hs.patch_sig);
    const num_sig = rd32(image, hs.num_sig);

    return .{
        .bin = bin,
        .hs = hs,
        .load = load,
        .app0 = app0,
        .fuse_ver = meta[0],
        .engine_id = meta[1],
        .ucode_id = meta[2],
        .patch_loc = patch_loc,
        .patch_sig = patch_sig,
        .num_sig = num_sig,
    };
}
