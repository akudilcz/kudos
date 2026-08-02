//! Host tests of src/drivers/gl/es/state.zig.

const std = @import("std");
const state = @import("state");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const matrix = state.matrix;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() state.Context {
    return state.Context{
        .dev = undefined,
        .target = undefined,
        .dev_limits = undefined,
        .alloc = std.testing.failing_allocator,
    };
}

test "the initial state is the standard's, not zeroes" {
    // §6.2's initial values are normative: a program that sets nothing must still draw.
    const s = testContext();
    try expectEqual([4]f32{ 1, 1, 1, 1 }, s.color); // white, not transparent black
    try expectEqual([3]f32{ 0, 0, 1 }, s.normal); // +Z
    try expectEqual(@as(f32, 1), s.point_size);
    try expectEqual(@as(f32, 1), s.line_width);
    try expectEqual(matrix.Mode.modelview, s.matrix_mode);
    try expectEqual([2]f32{ 0, 1 }, s.depth_range);
    try expectEqual(@as(f32, 1), s.clear_depth);
    try expectEqual(@as(u32, 4), s.pack_alignment);
    try expectEqual(@as(u32, 4), s.unpack_alignment);
}

test "dither starts enabled — the one capability that does" {
    const s = testContext();
    try expect(s.caps.dither);
    try expect(!s.caps.lighting);
    try expect(!s.caps.depth_test);
    try expect(!s.caps.blend);
    try expect(!s.caps.cull_face);
    for (s.caps.light) |on| try expect(!on);
}

test "light 0 starts white and the rest start black" {
    const s = testContext();
    // Otherwise enabling lighting + light 0 and setting nothing would render black,
    // which is the first thing a program does.
    try expectEqual([4]f32{ 1, 1, 1, 1 }, s.lights[0].diffuse);
    try expectEqual([4]f32{ 1, 1, 1, 1 }, s.lights[0].specular);
    for (s.lights[1..]) |l| {
        try expectEqual([4]f32{ 0, 0, 0, 1 }, l.diffuse);
        try expectEqual([4]f32{ 0, 0, 0, 1 }, l.specular);
    }
    // Every light's ambient starts black, including light 0.
    for (s.lights) |l| try expectEqual([4]f32{ 0, 0, 0, 1 }, l.ambient);
    // And every light starts directional, pointing down +Z.
    for (s.lights) |l| try expectEqual([4]f32{ 0, 0, 1, 0 }, l.position);
}

test "material and light-model defaults are the standard's" {
    const s = testContext();
    try expectEqual([4]f32{ 0.2, 0.2, 0.2, 1 }, s.material_front.ambient);
    try expectEqual([4]f32{ 0.8, 0.8, 0.8, 1 }, s.material_front.diffuse);
    try expectEqual(@as(f32, 0), s.material_front.shininess);
    try expectEqual([4]f32{ 0.2, 0.2, 0.2, 1 }, s.light_model_ambient);
    try expect(!s.light_model_two_side);
}

test "the texture environment starts at MODULATE, not REPLACE" {
    const s = testContext();
    for (s.texenv) |e| {
        try expect(e.mode == .modulate);
        try expect(e.combine_rgb == .modulate);
        try expectEqual(@as(f32, 1), e.rgb_scale);
    }
}

test "fog starts EXP with density 1" {
    const s = testContext();
    try expect(s.fog.mode == .exp);
    try expectEqual(@as(f32, 1), s.fog.density);
    try expectEqual(@as(f32, 0), s.fog.start);
    try expectEqual(@as(f32, 1), s.fog.end);
}

test "blending starts ONE/ZERO and depth starts LESS" {
    const s = testContext();
    try expect(s.blend_src == .one);
    try expect(s.blend_dst == .zero);
    try expect(s.depth_func == .less);
    try expect(s.alpha_func == .always);
    try expect(s.stencil_func == .always);
    try expect(s.logic_op == .copy);
    try expect(s.depth_writemask);
    try expectEqual([4]bool{ true, true, true, true }, s.color_writemask);
}

test "every array starts disabled — a draw with no glEnableClientState draws nothing" {
    const s = testContext();
    for (s.arrays) |a| {
        try expect(!a.enabled);
        try expect(a.buffer == 0);
        try expect(a.ptr == null);
    }
    try expectEqual(@as(u32, 0), s.array_buffer);
    try expectEqual(@as(u32, 0), s.element_array_buffer);
}
