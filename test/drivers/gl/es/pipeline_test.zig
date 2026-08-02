//! Host tests of src/drivers/gl/es/pipeline.zig.

const std = @import("std");
const pipeline = @import("pipeline");
const build = pipeline.build;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const flipRect = pipeline.flipRect;
const idraw = pipeline.idraw;
const state = pipeline.state;
const texparam = pipeline.texparam;

/// A Context wired to nothing (failing allocator — these tests must not
/// allocate) with a real 800x600 frame + full-frame viewport.
fn testContext() pipeline.state.Context {
    var g = pipeline.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
    g.frame_w = 800;
    g.frame_h = 600;
    g.viewport = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    return g;
}

test "y flips: a GL rectangle at the BOTTOM is a framebuffer rectangle at the TOP" {
    // GL's origin is bottom-left; the framebuffer's is top-left.
    const bottom = state.Viewport{ .x = 10, .y = 0, .w = 100, .h = 50 };
    const r = flipRect(bottom, 600);
    try expectEqual(@as(i32, 10), r.x); // x is untouched
    try expectEqual(@as(i32, 550), r.y); // 600 - (0 + 50)
    try expectEqual(@as(u32, 50), r.h);

    // A full-height viewport maps onto itself.
    const full = flipRect(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 600);
    try expectEqual(@as(i32, 0), full.y);
}

test "the flip is its own inverse" {
    const a = state.Viewport{ .x = 3, .y = 17, .w = 40, .h = 90 };
    const once = flipRect(a, 600);
    const twice = flipRect(.{ .x = once.x, .y = once.y, .w = once.w, .h = once.h }, 600);
    try expectEqual(a.y, twice.y);
}

test "depth test off means no depth WRITE either — not GL_ALWAYS" {
    var g = testContext();
    g.depth_writemask = true; // the mask says write...
    var buf: [4]u8 = undefined;
    const p = build(&g, &buf, .triangles);
    try expect(!p.depth.test_enable);
    // ...but with the test disabled the standard writes nothing. Lowering this to
    // GL_ALWAYS + write would fill the depth buffer from an unlit 2D app.
    try expect(!p.depth.write);

    g.caps.depth_test = true;
    try expect(build(&g, &buf, .triangles).depth.write);
    g.depth_writemask = false;
    try expect(!build(&g, &buf, .triangles).depth.write);
}

test "logic op excludes blending" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.caps.blend = true;
    try expect(build(&g, &buf, .triangles).blend.enable);
    try expect(build(&g, &buf, .triangles).logic_op == null);

    g.caps.color_logic_op = true; // both enabled: the standard says logic op wins
    const p = build(&g, &buf, .triangles);
    try expect(!p.blend.enable);
    try expect(p.logic_op != null);
}

test "a disabled test lowers to null rather than to a permissive setting" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.alpha_func = .greater;
    g.alpha_ref = 0.5;
    try expect(build(&g, &buf, .triangles).alpha_test == null); // disabled
    g.caps.alpha_test = true;
    const p = build(&g, &buf, .triangles);
    try expect(p.alpha_test.?.func == .greater);
    try expectEqual(@as(f32, 0.5), p.alpha_test.?.ref);
}

test "the scissor is null when disabled, and flipped when not" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.scissor_box = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try expect(build(&g, &buf, .triangles).scissor == null);
    g.caps.scissor_test = true;
    const s = build(&g, &buf, .triangles).scissor.?;
    try expectEqual(@as(i32, 590), s.y); // 600 - 10, in the framebuffer's convention
}

test "polygon offset lowers to zero when disabled, needing no separate flag" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.polygon_offset_factor = 2;
    g.polygon_offset_units = 4;
    const off = build(&g, &buf, .triangles);
    try expectEqual(@as(f32, 0), off.raster.poly_offset_factor);
    g.caps.polygon_offset_fill = true;
    try expectEqual(@as(f32, 2), build(&g, &buf, .triangles).raster.poly_offset_factor);
}

test "cull lowers to null when disabled" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.cull_face = .front;
    try expect(build(&g, &buf, .triangles).raster.cull == null);
    g.caps.cull_face = true;
    try expect(build(&g, &buf, .triangles).raster.cull.? == .front);
}

test "GL's one minification token splits into the hardware's two filters" {
    // GL_LINEAR_MIPMAP_NEAREST means: linear WITHIN a level, nearest BETWEEN levels.
    // Collapsing them would blur or alias, depending which way it was got wrong.
    const cases = [_]struct {
        gl: texparam.Sampler.MinFilter,
        min: idraw.Filter,
        mip: idraw.MipFilter,
    }{
        .{ .gl = .nearest, .min = .nearest, .mip = .none },
        .{ .gl = .linear, .min = .linear, .mip = .none },
        .{ .gl = .nearest_mipmap_nearest, .min = .nearest, .mip = .nearest },
        .{ .gl = .linear_mipmap_nearest, .min = .linear, .mip = .nearest },
        .{ .gl = .nearest_mipmap_linear, .min = .nearest, .mip = .linear },
        .{ .gl = .linear_mipmap_linear, .min = .linear, .mip = .linear },
    };
    for (cases) |c| {
        const min: idraw.Filter = switch (c.gl) {
            .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .nearest,
            .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .linear,
        };
        const mip: idraw.MipFilter = switch (c.gl) {
            .nearest, .linear => .none,
            .nearest_mipmap_nearest, .linear_mipmap_nearest => .nearest,
            .nearest_mipmap_linear, .linear_mipmap_linear => .linear,
        };
        try expect(min == c.min);
        try expect(mip == c.mip);
    }
}

test "sample coverage needs multisampling to mean anything" {
    var g = testContext();
    var buf: [4]u8 = undefined;
    g.caps.sample_coverage = true;
    g.caps.multisample = false;
    try expect(!build(&g, &buf, .triangles).sample_coverage.enable);
    g.caps.multisample = true;
    try expect(build(&g, &buf, .triangles).sample_coverage.enable);
}

test "the pipeline carries the uniform image the caller packed" {
    var g = testContext();
    const buf = [_]u8{ 1, 2, 3, 4 };
    const p = build(&g, &buf, .triangles);
    try std.testing.expectEqualSlices(u8, &buf, p.uniforms);
}
