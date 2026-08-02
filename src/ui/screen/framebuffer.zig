//! Firmware framebuffer geometry, and — on an emulated boot only — the scanout
//! the software desktop draws into. kudos renders on the 4090 through the GPU
//! present path; this module adopts the firmware framebuffer's GEOMETRY
//! (width/height/bpp) from the multiboot2 tag so the desktop and WM can size
//! themselves, publishes the set-logical-size seam hook the GPU driver uses to
//! raise the desktop to the monitor's native mode, and marks the framebuffer
//! memory write-combining.
//!
//! `linearTarget` is the one exception to "no pixels here", and it writes none
//! itself: it hands out the framebuffer's address and stride so the software
//! rasteriser can deliver frames straight into it under an emulator, where
//! there is no GPU to render with (see main_root.zig's software-display bring-up,
//! gated on `-Dsoft-display`). It answers null unless the firmware mode is
//! exactly the 32-bit BGRA layout the rasteriser already produces, so a mode
//! needing channel conversion runs headless rather than painting garbage.

const buildinfo = @import("buildinfo");
const mb = @import("../../kernel/boot/multiboot2.zig");
const cpu = @import("../../kernel/cpu/cpu.zig");
const klog = @import("../../kernel/debug/klog.zig");
const iaccel = @import("iaccel"); // where the GPU publishes its acceleration hooks
const imouse = @import("imouse"); // publish the pointer coordinate space

var bpp_bytes: usize = 4; // 3 (24bpp) or 4 (32bpp) — reported by bpp(); pixels go via the GPU
// The firmware scanout, for the software-display path only. `base` is 0 until a
// linear tag is adopted, and stays 0 on a headless (`initVirtual`) boot.
var fb_base: usize = 0;
var fb_pitch_bytes: usize = 0;
var fb_bgra = false; // the 32-bit B,G,R,x channel order, needing no conversion
var fb_w: usize = 0;
var fb_h: usize = 0;
// Logical desktop size: what width()/height() report and the GPU desktop renders
// at. Defaults to the physical size; the GPU display path raises it to the
// monitor's native mode (setLogicalSize).
var logical_w: usize = 0;
var logical_h: usize = 0;
var logical_resized: bool = false;

// The largest logical desktop the system will ever present — the widest supported
// panel (the 3440x1440 ultrawide is the target; ultrawide-only display
// policy). It is the single source of truth for the MAXIMUM window size, so a window
// buffer + its GPU mirror can be allocated ONCE at this size and never realloc on a
// resize (fixed max-size window buffer): resize only changes the logical
// w/h drawn into the fixed buffer. setLogicalSize asserts it never exceeds this bound.
pub const MAX_SCREEN_W: usize = 3440;
pub const MAX_SCREEN_H: usize = 1440;

/// multiboot2 framebuffer_type for a direct-RGB LINEAR framebuffer. The only type
/// this driver can adopt (the color_info channel fields are meaningful only here).
/// Type 0 = indexed palette, type 2 = EGA text (80x25 @ 0xb8000) — GRUB's default
/// when it cannot program a graphics mode. Neither is a linear framebuffer.
const FB_TYPE_RGB: u8 = 1;

/// Adopt the firmware-provided linear framebuffer's GEOMETRY from the multiboot2
/// tag (width/height/bpp — they vary on real HW), publish the seam hooks, and mark
/// the memory write-combining. No pixels are written here; the GPU owns rendering.
pub fn init(tag: *const mb.FramebufferTag, info_addr: u64) void {
    // Fail LOUD, not with an overflow: GRUB gives a TEXT-mode tag (fb_type 2,
    // 80x25 @ 0xb8000) when it could not program a linear mode — e.g. the type-5
    // request tag is missing from boot.asm's multiboot2 header, or the firmware
    // has no linear mode. Adopting it as if linear overflows the pixel math. The
    // desktop needs a linear framebuffer's geometry; without one we run headless
    // (trace only) rather than crash. See boot/boot.asm.
    if (tag.fb_type != FB_TYPE_RGB) {
        klog.puts("fb: FATAL non-linear framebuffer tag (fb_type != 1) — GRUB gave text/indexed mode;\n");
        klog.puts("fb: running HEADLESS. Ensure boot.asm's multiboot2 framebuffer request tag is enabled.\n");
        return;
    }
    bpp_bytes = tag.bpp / 8;
    logical_w = tag.width;
    logical_h = tag.height;
    imouse.setScreen(logical_w, logical_h);
    publishHooks();

    fb_base = @intCast(tag.addr);
    fb_pitch_bytes = tag.pitch;
    fb_w = tag.width;
    fb_h = tag.height;
    // The rasteriser emits 32-bit B,G,R,x texels. Any other channel order or
    // depth would need per-pixel conversion, which the software-display path
    // does not do — `linearTarget` declines instead.
    fb_bgra = bpp_bytes == 4 and
        tag.red_field_position == 16 and
        tag.green_field_position == 8 and
        tag.blue_field_position == 0 and
        tag.pitch % 4 == 0;

    enableWriteCombine(tag, info_addr);
}

/// Offer the GPU driver the one thing it needs from the screen: "the monitor is
/// actually this big" (set-logical-size). Called through `iface/iaccel.zig`, so
/// the driver never names this module.
fn publishHooks() void {
    iaccel.compositor.set_logical_size = &setLogicalSize;
}

/// Make the framebuffer write-combining, unless available RAM
/// shares its 1 GiB page — WC on write-back RAM corrupts coherency, so in that
/// case the framebuffer is left UC (a klog warning is emitted).
fn enableWriteCombine(tag: *const mb.FramebufferTag, info_addr: u64) void {
    const span: u64 = @as(u64, tag.pitch) * @as(u64, tag.height);
    const gib_base = tag.addr & ~@as(u64, (1 << 30) - 1);
    const gib_end = gib_base + (1 << 30);

    if (mb.mmap(info_addr)) |it_const| {
        var it = it_const;
        while (it.next()) |e| {
            if (e.type != 1) continue; // available RAM only
            if (e.addr < gib_end and e.addr + e.len > gib_base) {
                klog.puts("fb: RAM shares framebuffer GiB; WC disabled (page stays UC)\n");
                return;
            }
        }
    }

    // framebufferWriteCombine logs its own outcome (WC enabled on real HW, or
    // skipped under a hypervisor) — single source of truth for the WC status.
    cpu.framebufferWriteCombine(tag.addr, span);
}

/// Framebuffer width in pixels (as reported by firmware at init).
pub fn width() usize {
    return logical_w;
}
/// Framebuffer height in pixels (as reported by firmware at init).
pub fn height() usize {
    return logical_h;
}
/// Bits per pixel of the hardware framebuffer (24 or 32); callers sizing raw
/// buffers need the real depth, which the internal count stores as bytes.
pub fn bpp() usize {
    return bpp_bytes * 8;
}

/// Where the software rasteriser may deliver desktop frames: the firmware
/// scanout's address and stride in pixels. Null unless a linear 32-bit BGRA
/// framebuffer was adopted — and always null on a build without
/// `-Dsoft-display`, so the shipping GPU image cannot reach the scanout at all.
///
/// The desktop draws the whole frame every time and the emulator's surface is
/// not double-buffered, so a frame is visible as it lands. That is honest for
/// the emulated path this serves: it exists to make kudos observable on a
/// machine with no GPU, not to meet the 60 Hz present contract (RND/PERF),
/// which remains the 4090's alone.
pub const LinearTarget = struct { base: usize, stride_px: u32, w: u32, h: u32 };

pub fn linearTarget() ?LinearTarget {
    if (!buildinfo.soft_display) return null;
    if (fb_base == 0 or !fb_bgra) return null;
    return .{
        .base = fb_base,
        .stride_px = @intCast(fb_pitch_bytes / 4),
        .w = @intCast(fb_w),
        .h = @intCast(fb_h),
    };
}

/// No firmware framebuffer tag at all (e.g. -vga none GPU passthrough): set up a
/// VIRTUAL logical desktop — the GPU present path is the only output.
pub fn initVirtual(w: usize, h: usize) void {
    logical_w = w;
    logical_h = h;
    imouse.setScreen(logical_w, logical_h);
    publishHooks();
}

/// Raise the logical desktop size (GPU display path). The desktop task picks
/// the change up via consumeLogicalResize and reallocates the compositor.
pub fn setLogicalSize(w: usize, h: usize) void {
    // The fixed max-size window buffer is sized to MAX_SCREEN_W/H, so a
    // logical size larger than that would let a maximised window exceed its buffer.
    // Loud clamp instead of silent corruption if a wider panel ever appears.
    if (w > MAX_SCREEN_W or h > MAX_SCREEN_H) {
        klog.puts("framebuffer.setLogicalSize: logical size exceeds MAX_SCREEN — clamping (grow MAX_SCREEN_W/H)\n");
    }
    logical_w = @min(w, MAX_SCREEN_W);
    logical_h = @min(h, MAX_SCREEN_H);
    imouse.setScreen(logical_w, logical_h);
    logical_resized = true;
}

/// One-shot: true once after a setLogicalSize (desktop task polls per frame).
pub fn consumeLogicalResize() bool {
    if (!logical_resized) return false;
    logical_resized = false;
    return true;
}
