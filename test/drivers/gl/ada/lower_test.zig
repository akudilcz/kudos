//! Host tests of src/drivers/gl/ada/lower.zig.

const std = @import("std");
const lower = @import("lower");
const attribFormat = lower.attribFormat;
const blendIsPremultOver = lower.blendIsPremultOver;
const compareFunc = lower.compareFunc;
const cullFace = lower.cullFace;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const frontFace = lower.frontFace;
const indexSize = lower.indexSize;
const primBegin = lower.primBegin;

test "comparison functions are the OGL 0x200 block, in spec order" {
    try expectEqual(@as(u32, 0x200), compareFunc(.never));
    try expectEqual(@as(u32, 0x201), compareFunc(.less));
    try expectEqual(@as(u32, 0x202), compareFunc(.equal));
    try expectEqual(@as(u32, 0x203), compareFunc(.lequal));
    try expectEqual(@as(u32, 0x204), compareFunc(.greater));
    try expectEqual(@as(u32, 0x205), compareFunc(.notequal));
    try expectEqual(@as(u32, 0x206), compareFunc(.gequal));
    try expectEqual(@as(u32, 0x207), compareFunc(.always));
}

test "index widths are 0/1/2 for u8/u16/u32" {
    try expectEqual(@as(u32, 0), indexSize(.u8));
    try expectEqual(@as(u32, 1), indexSize(.u16));
    try expectEqual(@as(u32, 2), indexSize(.u32));
}

test "grounded primitives carry their BEGIN opcode; the rest refuse" {
    try expectEqual(@as(?u32, 0), primBegin(.points));
    try expectEqual(@as(?u32, 1), primBegin(.lines));
    try expectEqual(@as(?u32, 4), primBegin(.triangles));
    try expectEqual(@as(?u32, 5), primBegin(.triangle_strip));
    // Not yet grounded — must be null, never a plausible-looking 2/3/6.
    try expect(primBegin(.line_loop) == null);
    try expect(primBegin(.line_strip) == null);
    try expect(primBegin(.triangle_fan) == null);
}

test "grounded attribute formats match methods.zig's ATTR_* composites" {
    // The two the old fixed path hard-coded, now derived — they must agree, or a draw
    // through opengl.zig would fetch vertices differently than the mesh path did.
    try expectEqual(@as(?u32, (0x02 << 21) | (7 << 27)), attribFormat(.f32x3)); // ATTR_R32G32B32_FLOAT
    try expectEqual(@as(?u32, (0x04 << 21) | (7 << 27)), attribFormat(.f32x2)); // ATTR_R32G32_FLOAT
    try expectEqual(@as(?u32, (0x12 << 21) | (7 << 27)), attribFormat(.f32x1));
    try expectEqual(@as(?u32, (0x01 << 21) | (7 << 27)), attribFormat(.f32x4));
    try expectEqual(@as(?u32, (0x0A << 21) | (2 << 27)), attribFormat(.u8x4_unorm));
    // Byte/short formats are not grounded.
    try expect(attribFormat(.i8x3) == null);
    try expect(attribFormat(.i16x3) == null);
    try expect(attribFormat(.i8x3_snorm) == null);
}

test "front face and the one grounded cull face" {
    try expectEqual(@as(u32, 0x900), frontFace(.cw));
    try expectEqual(@as(u32, 0x901), frontFace(.ccw));
    try expectEqual(@as(?u32, 0x405), cullFace(.back));
    try expect(cullFace(.front) == null);
    try expect(cullFace(.front_and_back) == null);
}

test "premultiplied-over blend is recognised; others are not" {
    try expect(blendIsPremultOver(.{ .enable = true, .src = .one, .dst = .one_minus_src_alpha }));
    // Disabled is not the premult state even with matching factors.
    try expect(!blendIsPremultOver(.{ .enable = false, .src = .one, .dst = .one_minus_src_alpha }));
    // A different equation is not it.
    try expect(!blendIsPremultOver(.{ .enable = true, .src = .src_alpha, .dst = .one_minus_src_alpha }));
}
