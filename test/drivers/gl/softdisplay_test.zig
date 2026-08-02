//! Host tests of src/drivers/gl/softdisplay.zig's publish policy — ARCH-015's
//! RUNTIME half. The layering gate holds the structural half (only this module
//! may name the `soft` backend, and nothing may reach it by path); what no gate
//! can see is the decision made at bring-up, on a build where the software
//! rasteriser IS compiled in: with a GPU coming, the desktop must not be
//! rasterised on the CPU, however headless the machine looks at that instant.

const std = @import("std");
const softdisplay = @import("testroot").gl.softdisplay;

const READY = softdisplay.Machine{ .gpu_coming = false, .scanout_ready = true };

test "a coming GPU refuses the software rasteriser outright (ARCH-015)" {
    // The moment that matters: the firmware framebuffer is adopted and usable,
    // so publishing WOULD work — and must not, because the 4090 is on its way
    // and the desktop renders there or nowhere.
    const m = softdisplay.Machine{ .gpu_coming = true, .scanout_ready = true };
    try std.testing.expectEqual(softdisplay.Decision.gpu_coming, softdisplay.decide(true, false, m));
}

test "no soft-display build reaches the rasteriser at all (ARCH-015)" {
    // Off by default: on the product image the decision is not merely negative,
    // the path does not exist. Even a machine begging for it is refused.
    const desperate = softdisplay.Machine{ .gpu_coming = false, .scanout_ready = true };
    try std.testing.expectEqual(softdisplay.Decision.not_built, softdisplay.decide(false, false, desperate));
    // ...and a coming GPU cannot make a non-soft-display build publish either.
    const m = softdisplay.Machine{ .gpu_coming = true, .scanout_ready = true };
    try std.testing.expectEqual(softdisplay.Decision.not_built, softdisplay.decide(false, false, m));
}

test "an existing draw device is never displaced" {
    // A published GPU device outranks this one; displacing it mid-life would
    // leave live contexts pointing at a backend that no longer draws.
    try std.testing.expectEqual(softdisplay.Decision.device_exists, softdisplay.decide(true, true, READY));
}

// RND-013: that path requires an adopted firmware framebuffer to deliver into.
test "without a scanout the machine stays headless rather than painting garbage" {
    const m = softdisplay.Machine{ .gpu_coming = false, .scanout_ready = false };
    try std.testing.expectEqual(softdisplay.Decision.no_scanout, softdisplay.decide(true, false, m));
}

// RND-012: a -Dsoft-display build publishes the software rasteriser as the draw
// device when no GPU is coming — the dev-build path, off by default.
test "the one case that publishes: soft-display build, no device, no GPU, a scanout" {
    try std.testing.expectEqual(softdisplay.Decision.publish, softdisplay.decide(true, false, READY));
}

test "refusals are ordered so the GPU guard outranks a missing scanout" {
    // Both refuse, but they are not interchangeable: a GPU-coming machine with
    // no scanout yet must report the GPU, or a future reader concludes the
    // rasteriser was only skipped for want of a framebuffer and "fixes" it.
    const m = softdisplay.Machine{ .gpu_coming = true, .scanout_ready = false };
    try std.testing.expectEqual(softdisplay.Decision.gpu_coming, softdisplay.decide(true, false, m));
}
