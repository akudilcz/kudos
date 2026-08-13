//! Scanout screenshot into the ramdisk: CE-copies the visible head-0 planes
//! into sysmem, composites them the way the display engine does, encodes a
//! FULL-RESOLUTION PNG natively (pngenc, spec R33/R69 — ~10x smaller than
//! the raw pixels) and puts it at ramdisk "screenshot.png" — the netdebug
//! mirror pulls it to the
//! host reliably. This replaced the lossy SCRN base64 streaming over the netdebug
//! broadcast. With VFIO passthrough the frame exists solely in the 4090's VRAM
//! (QEMU's VNC shows nothing, -vga none), so this is the only host-visible
//! render evidence.
//!
//! WHAT THE MONITOR SHOWS IS TWO PLANES. The display engine blends the desktop
//! plane (head surface) with the overlay plane (the topmost glass window — the
//! terminal) at scanout, DEPTH=254 over 255, PREMULTI.
//! Copying the head surface alone yields a desktop with NO terminal. So we take
//! present.captureView() — the LIVE scanout VA (the triple-buffer ring rotates;
//! gmmu.VA_VRAM is only ring[0]) plus the armed overlay front buffer and rect —
//! and re-run the same premultiplied blend on the CPU via Surface.blitPremult
//! (the one premultiplied-alpha implementation in the tree).

const std = @import("std");
const log = @import("rm/log.zig").gpu;
const gsp = @import("gsp/gsp.zig");
const fifo = @import("engines/fifo.zig");
const gmmu = @import("engines/gmmu.zig");
const shim = @import("rm/shim.zig");
const ce = @import("engines/ce.zig");
const present = @import("present/present.zig");
const surface = @import("surface");
const ramdisk = @import("../storage/ramdisk.zig");
const usbshot = @import("usbshot.zig");
const pngenc = @import("rm/pngenc.zig");
const heap = @import("../../kernel/memory/heap.zig");
const tsc = @import("../../kernel/cpu/tsc.zig");

/// Dedicated staging VA — must NOT sit inside VA_SYSMEM/VA_WSYSMEM (the
/// present layer bump-allocates window surfaces there; observed
/// GmmuAlreadyMapped in stage6) nor the GR windows. 0xD000_0000 is above the
/// GRCTX window (ends 0xC000_0000) and below the 4 GiB ceiling. The stage
/// holds BOTH planes back to back: [0]=head copy, [1]=overlay copy.
const VA_STAGE: u64 = 0xd000_0000;

/// Both buffers are allocated once, sized by the FIRST dump's dimensions
/// (every call site captures head 0 at native dims, so first-call sizing is
/// exact). A later dump needing more fails loudly with ScreenshotCapacity —
/// never a silent partial capture or an overflow.
var stage_phys: u64 = 0;
var stage_cap: u64 = 0; // bytes mapped at VA_STAGE (both planes)
pub const Error = error{ ScreenshotAlloc, ScreenshotCapacity, ScreenshotNoPresent } || fifo.Error;

/// Capture what head 0 is scanning out — BOTH display planes, composited the
/// way the display engine composites them — at full resolution into ramdisk
/// "screenshot.png". This is the desktop capture (netdebug SHOT + auto-shot);
/// it requires the GPU present path to be up.
pub fn dump(g: gsp.Gsp, f: *fifo.Fifo) Error!void {
    const view = present.captureView() orelse return error.ScreenshotNoPresent;
    try capture(g, f, view);
}

fn capture(g: gsp.Gsp, f: *fifo.Fifo, view: present.CaptureView) Error!void {
    const t_start = tsc.rdtsc();
    const w = view.w;
    const h = view.h;
    const pitch = view.pitch;

    // One plane's worth of bytes; the stage holds two (head, then overlay).
    const plane_bytes: u64 = @as(u64, pitch) * h;
    const stage_bytes: u64 = plane_bytes * 2;
    if (stage_cap == 0) {
        const pages: u32 = @intCast((stage_bytes + 0xfff) / 0x1000);
        stage_phys = shim.allocPagesPhys(pages) orelse return error.ScreenshotAlloc;
        try f.mmu.mapSysmem(VA_STAGE, stage_phys, @as(u64, pages) * 0x1000);
        stage_cap = @as(u64, pages) * 0x1000;
    }
    if (stage_bytes > stage_cap) return error.ScreenshotCapacity;

    // CE: the LIVE scanout plane -> stage[0]; the armed overlay's FRONT buffer
    // -> stage[1]. One batch, one fence: both land before the CPU reads them.
    const ov_stage_va = VA_STAGE + plane_bytes;
    const ov_stage_phys = stage_phys + plane_bytes;
    var p = f.begin();
    const fence = f.nextFence();
    ce.copyPitch(&p, VA_STAGE, pitch, view.head_va, pitch, w * 4, h, gmmu.VA_SEM, 0);
    if (view.overlay) |ov| {
        // The overlay's content sits at plane-local (0,0) sized ov.w x ov.h.
        ce.copyPitch(&p, ov_stage_va, pitch, ov.va, pitch, @as(u32, ov.w) * 4, ov.h, gmmu.VA_SEM, fence);
    } else {
        // The fence must ride a real CE op: re-copy one page of the head plane.
        ce.copyPitch(&p, VA_STAGE, pitch, view.head_va, pitch, 4, 1, gmmu.VA_SEM, fence);
    }
    _ = try f.submitWait(g, &p, fence);

    // The CE DMA-wrote both staging planes; invalidate before the CPU reads.
    invalidatePlane(stage_phys, pitch, h, w * 4);
    if (view.overlay) |ov| invalidatePlane(ov_stage_phys, pitch, ov.h, @as(u32, ov.w) * 4);

    // Composite exactly as the display engine does: overlay PREMULTI over the
    // desktop plane, at the armed on-head rect, source origin (0,0).
    const head_surf = surface.Surface{
        .px = @ptrFromInt(stage_phys),
        .w = w,
        .h = h,
        .stride = pitch / 4,
    };
    if (view.overlay) |ov| {
        const ov_surf = surface.Surface{
            .px = @ptrFromInt(ov_stage_phys),
            .w = ov.w,
            .h = ov.h,
            .stride = pitch / 4,
        };
        head_surf.blitPremult(ov_surf, 0, 0, ov.x, ov.y, ov.w, ov.h);
    }

    // Encode the composited pixels as PNG (natively, R33) and hand it to the
    // ramdisk (the netdebug mirror pulls it from there). The staged plane IS
    // the encoder's input: pngenc reads w pixels per pitch/4-stride row.
    const t_captured = tsc.rdtsc();
    const px_all: [*]const u32 = @ptrFromInt(stage_phys);
    const png_bytes = pngenc.encode(heap.allocator(), w, h, px_all[0 .. @as(usize, head_surf.stride) * h], head_surf.stride) catch {
        log("gpu.screenshot: PNG encode failed (heap?)\n", .{});
        return;
    };
    defer heap.allocator().free(png_bytes);
    ramdisk.fs().put("screenshot.png", png_bytes) catch {
        log("gpu.screenshot: ramdisk put failed (heap?)\n", .{});
        return;
    };
    const t_done = tsc.rdtsc();
    const hz = tsc.hz();
    const cap_ms: u64 = if (hz != 0) (t_captured - t_start) * 1000 / hz else 0;
    const enc_ms: u64 = if (hz != 0) (t_done - t_captured) * 1000 / hz else 0;
    const planes: u8 = if (view.overlay != null) 2 else 1;
    // capture_ms is the R65 evidence: pixels are safely off the scanout in
    // well under a second; the encode happens after the capture instant.
    log("gpu.screenshot: screenshot.png saved ({} bytes, {}x{}, {} plane(s), capture_ms={} encode_ms={}) — pull it with the netdebug MCP, or scripts/debug/netdebug.py shot\n", .{ png_bytes.len, w, h, planes, cap_ms, enc_ms });
    // Additionally persist to the physical stick (/usbdisk/shots/SHOTnnnn.PNG)
    // when a stick is mounted — the harness reads it after the run instead of
    // pulling megabytes over UDP. usbshot logs its own record with the filename.
    _ = usbshot.save(png_bytes);
}

/// Invalidate the cache lines the CE DMA-wrote for `rows` rows of `row_bytes`
/// at `pitch` stride, so the CPU reads the fresh pixels.
fn invalidatePlane(base: u64, pitch: u32, rows: u32, row_bytes: u32) void {
    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        const row = base + @as(u64, y) * pitch;
        var o: u64 = 0;
        while (o < row_bytes) : (o += 64) shim.invalidateLine(row + o);
    }
}
