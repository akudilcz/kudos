//! GSP firmware provisioning: build a `gsp.Firmware` from the multiboot2 boot
//! modules GRUB loaded (GSP firmware provisioning). kudos has no
//! filesystem, so the signed blobs reach the kernel as `module2` entries in the
//! ISO; each is identified by its module id string (the `module2` command line).
//!
//! This is the kudos `request_firmware` equivalent. It only *locates* the blobs
//! (they are already resident in PMM-reserved RAM, src/kernel/memory/pmm.zig); it copies
//! nothing. Missing blobs are reported loudly by the caller — never substituted.
//!
//! Isolation invariant: reads `boot/multiboot2.zig` through its
//! public API; adds no GPU logic to the boot module.

const mb = @import("../../../kernel/boot/multiboot2.zig");
const gsp = @import("gsp.zig");
const log = @import("../rm/log.zig").gpu;

/// Module id strings, matching the `module2 ... "<id>"` entries scripts/build/mkiso.sh
/// stages. Single source of truth for the id contract between grub.cfg and here.
pub const MODULE_IDS = struct {
    pub const gsp_rm = "gsp_rm";
    pub const booter_load = "booter_load";
    pub const booter_unload = "booter_unload";
    pub const bootloader = "bootloader";
    pub const scrubber = "scrubber";
};

/// One module's bytes as a slice over its identity-mapped physical span, or an
/// empty slice if the module was not loaded (firmware not staged into the ISO).
fn moduleBytes(info_addr: u64, id: []const u8) []const u8 {
    const m = mb.findModule(info_addr, id) orelse return &.{};
    const ptr: [*]const u8 = @ptrFromInt(m.start);
    return ptr[0..@intCast(m.len())];
}

/// Build the firmware set from the boot modules. Logs which blobs are present so
/// a partial/absent provisioning is visible on klog. The returned set may be
/// incomplete — `gsp.Firmware.complete()` is the gate the boot path checks.
pub fn fromBootModules(info_addr: u64) gsp.Firmware {
    const fw = gsp.Firmware{
        .gsp_rm = moduleBytes(info_addr, MODULE_IDS.gsp_rm),
        .booter_load = moduleBytes(info_addr, MODULE_IDS.booter_load),
        .booter_unload = moduleBytes(info_addr, MODULE_IDS.booter_unload),
        .bootloader = moduleBytes(info_addr, MODULE_IDS.bootloader),
        .scrubber = moduleBytes(info_addr, MODULE_IDS.scrubber),
    };
    log("gpu.firmware: gsp_rm={} booter_load={} booter_unload={} bootloader={} scrubber={} bytes\n", .{
        fw.gsp_rm.len, fw.booter_load.len, fw.booter_unload.len, fw.bootloader.len, fw.scrubber.len,
    });
    return fw;
}
