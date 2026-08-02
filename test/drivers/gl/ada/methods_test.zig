//! Host tests of src/drivers/gl/ada/methods.zig.

const std = @import("std");
const methods = @import("methods");
const ATTR_R32G32B32_FLOAT = methods.ATTR_R32G32B32_FLOAT;
const BEGIN = methods.BEGIN;
const BIND_GROUP_CONSTANT_BUFFER_0 = methods.BIND_GROUP_CONSTANT_BUFFER_0;
const CLEAR_SURFACE = methods.CLEAR_SURFACE;
const CT_FORMAT_A8R8G8B8 = methods.CT_FORMAT_A8R8G8B8;
const END = methods.END;
const LOAD_CONSTANT_BUFFER_OFFSET = methods.LOAD_CONSTANT_BUFFER_OFFSET;
const SET_CLEAR_SURFACE_CONTROL = methods.SET_CLEAR_SURFACE_CONTROL;
const SET_COLOR_CLEAR_VALUE_0 = methods.SET_COLOR_CLEAR_VALUE_0;
const SET_COLOR_TARGET_A_0 = methods.SET_COLOR_TARGET_A_0;
const SET_CONSTANT_BUFFER_SELECTOR_A = methods.SET_CONSTANT_BUFFER_SELECTOR_A;
const SET_DA_PRIMITIVE_RESTART_INDEX = methods.SET_DA_PRIMITIVE_RESTART_INDEX;
const SET_GLOBAL_BASE_INSTANCE_INDEX = methods.SET_GLOBAL_BASE_INSTANCE_INDEX;
const SET_GLOBAL_BASE_VERTEX_INDEX = methods.SET_GLOBAL_BASE_VERTEX_INDEX;
const SET_INDEX_BUFFER_A = methods.SET_INDEX_BUFFER_A;
const SET_INDEX_BUFFER_E = methods.SET_INDEX_BUFFER_E;
const SET_INDEX_BUFFER_SIZE_A = methods.SET_INDEX_BUFFER_SIZE_A;
const SET_INSTANCE_COUNT = methods.SET_INSTANCE_COUNT;
const SET_PIPELINE_REGISTER_COUNT_0 = methods.SET_PIPELINE_REGISTER_COUNT_0;
const SET_PIPELINE_SHADER_0 = methods.SET_PIPELINE_SHADER_0;
const SET_SCISSOR_HORIZONTAL_0 = methods.SET_SCISSOR_HORIZONTAL_0;
const SET_SURFACE_CLIP_HORIZONTAL = methods.SET_SURFACE_CLIP_HORIZONTAL;
const SET_VERTEX_ARRAY_START = methods.SET_VERTEX_ARRAY_START;
const SET_VERTEX_ATTRIBUTE_A_0 = methods.SET_VERTEX_ATTRIBUTE_A_0;
const SET_VERTEX_ID_BASE = methods.SET_VERTEX_ID_BASE;
const SET_VERTEX_STREAM_A_FORMAT_0 = methods.SET_VERTEX_STREAM_A_FORMAT_0;
const SET_VERTEX_STREAM_A_FREQUENCY_0 = methods.SET_VERTEX_STREAM_A_FREQUENCY_0;
const SET_VERTEX_STREAM_SIZE_A_0 = methods.SET_VERTEX_STREAM_SIZE_A_0;
const SET_VIEWPORT_CLIP_HORIZONTAL_0 = methods.SET_VIEWPORT_CLIP_HORIZONTAL_0;
const SET_VIEWPORT_SCALE_X_0 = methods.SET_VIEWPORT_SCALE_X_0;
const SET_ZT_A = methods.SET_ZT_A;
const SET_ZT_LAYER = methods.SET_ZT_LAYER;
const SET_ZT_SELECT = methods.SET_ZT_SELECT;
const SET_ZT_SIZE_A = methods.SET_ZT_SIZE_A;
const SET_ZT_SPARSE = methods.SET_ZT_SPARSE;
const SET_Z_COMPRESSION = methods.SET_Z_COMPRESSION;
const SLOT_VERTEX = methods.SLOT_VERTEX;
const ZT_FORMAT_ZF32 = methods.ZT_FORMAT_ZF32;
const bindCb0 = methods.bindCb0;
const clearColor = methods.clearColor;
const colorTargetPitch = methods.colorTargetPitch;
const ctxInit = methods.ctxInit;
const depthTargetBl = methods.depthTargetBl;
const drawTriangles = methods.drawTriangles;
const hdrImmd = methods.hdrImmd;
const hdrInc = methods.hdrInc;
const hdrIncOnce = methods.hdrIncOnce;
const hostpush = methods.hostpush;
const indexBufferTyped = methods.indexBufferTyped;
const loadCb = methods.loadCb;
const pipelineShader = methods.pipelineShader;
const vertexAttrib = methods.vertexAttrib;
const vertexAttribAt = methods.vertexAttribAt;
const vertexStream0 = methods.vertexStream0;
const vertexStreamAt = methods.vertexStreamAt;
const viewportFull = methods.viewportFull;

test "clearColor golden stream" {
    var buf: [64]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    clearColor(&p, 1.0, 0.5, 0.0, 1.0);
    const want = [_]u32{
        hdrImmd(SET_CLEAR_SURFACE_CONTROL, 0),
        hdrInc(SET_COLOR_CLEAR_VALUE_0, 4),
        0x3f800000, // 1.0
        0x3f000000, // 0.5
        0x00000000, // 0.0
        0x3f800000, // 1.0
        hdrInc(CLEAR_SURFACE, 1),
        0x3c,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "colorTargetPitch golden stream" {
    var buf: [64]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    colorTargetPitch(&p, 0x1_2345_6000, 1024, 768, 4096);
    const want = [_]u32{
        hdrInc(SET_COLOR_TARGET_A_0, 9),
        0x1,
        0x23456000,
        4096,
        768,
        CT_FORMAT_A8R8G8B8,
        1 << 12,
        1,
        0,
        0,
        hdrInc(SET_SURFACE_CLIP_HORIZONTAL, 2),
        1024 << 16,
        768 << 16,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "viewportFull golden stream" {
    var buf: [64]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    viewportFull(&p, 640, 480);
    const want = [_]u32{
        hdrInc(SET_VIEWPORT_SCALE_X_0, 6),
        0x43a00000, // 320.0
        0x43700000, // 240.0
        0x3f800000, // 1.0
        0x43a00000, // 320.0
        0x43700000, // 240.0
        0x00000000, // 0.0
        hdrInc(SET_VIEWPORT_CLIP_HORIZONTAL_0, 4),
        640 << 16,
        480 << 16,
        0x00000000,
        0x3f800000,
        hdrInc(SET_SCISSOR_HORIZONTAL_0, 2),
        640 << 16,
        480 << 16,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "drawTriangles golden stream" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    drawTriangles(&p, 0, 3);
    const want = [_]u32{
        hdrImmd(SET_GLOBAL_BASE_INSTANCE_INDEX, 0),
        hdrImmd(SET_GLOBAL_BASE_VERTEX_INDEX, 0),
        hdrImmd(SET_VERTEX_ID_BASE, 0),
        hdrImmd(SET_INSTANCE_COUNT, 1),
        hdrInc(BEGIN, 1),
        4,
        hdrInc(SET_VERTEX_ARRAY_START, 2),
        0,
        3,
        hdrImmd(END, 0),
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "pipelineShader golden stream" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    pipelineShader(&p, SLOT_VERTEX, 24, 0, 0x0140_0080);
    const want = [_]u32{
        hdrImmd(SET_PIPELINE_SHADER_0 + 64, 1 | (1 << 4)),
        hdrInc(SET_PIPELINE_REGISTER_COUNT_0 + 64, 4),
        24,
        0,
        0,
        0x01400080,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "vertexAttrib and vertexStream0 goldens" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    vertexAttrib(&p, 1, 12, ATTR_R32G32B32_FLOAT);
    vertexStream0(&p, 0x0150_0000, 24, 72);
    const want = [_]u32{
        hdrInc(SET_VERTEX_ATTRIBUTE_A_0 + 4, 1),
        (12 << 7) | (0x02 << 21) | (7 << 27),
        hdrInc(SET_VERTEX_STREAM_A_FORMAT_0, 3),
        24 | (1 << 12),
        0,
        0x01500000,
        hdrInc(SET_VERTEX_STREAM_A_FREQUENCY_0, 1),
        0,
        hdrInc(SET_VERTEX_STREAM_SIZE_A_0, 2),
        0,
        72,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "vertexAttribAt + vertexStreamAt goldens (per-attribute streams)" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    // Attribute at location 2 (colour), from stream 2, offset 0, R32G32B32A32_FLOAT.
    vertexAttribAt(&p, 2, 2, 0, (0x01 << 21) | (7 << 27));
    vertexStreamAt(&p, 2, 0x0170_0000, 16, 256);
    const want = [_]u32{
        hdrInc(SET_VERTEX_ATTRIBUTE_A_0 + 2 * 4, 1),
        2 | (0 << 7) | (0x01 << 21) | (7 << 27),
        hdrInc(SET_VERTEX_STREAM_A_FORMAT_0 + 2 * 16, 3),
        16 | (1 << 12),
        0,
        0x01700000,
        hdrInc(SET_VERTEX_STREAM_A_FREQUENCY_0 + 2 * 16, 1),
        0,
        hdrInc(SET_VERTEX_STREAM_SIZE_A_0 + 2 * 8, 2),
        0,
        256,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "indexBufferTyped golden (u16 indices)" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    indexBufferTyped(&p, 0x0180_0000, 96, 1); // 1 = u16
    const want = [_]u32{
        hdrInc(SET_INDEX_BUFFER_A, 2),
        0,
        0x01800000,
        hdrInc(SET_INDEX_BUFFER_SIZE_A, 2),
        0,
        96,
        hdrImmd(SET_INDEX_BUFFER_E, 1),
        hdrInc(SET_DA_PRIMITIVE_RESTART_INDEX, 1),
        0xffffffff,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "bindCb0 + loadCb goldens" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    bindCb0(&p, 0x0160_0000, 0x1000);
    loadCb(&p, 0x28, &.{ 0x11111111, 0x22222222 });
    const want = [_]u32{
        hdrInc(SET_CONSTANT_BUFFER_SELECTOR_A, 3),
        0x1000,
        0,
        0x01600000,
        hdrImmd(BIND_GROUP_CONSTANT_BUFFER_0, 1),
        hdrImmd(BIND_GROUP_CONSTANT_BUFFER_0 + 128, 1),
        hdrIncOnce(LOAD_CONSTANT_BUFFER_OFFSET, 3),
        0x28,
        0x11111111,
        0x22222222,
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "depthTargetBl golden" {
    var buf: [32]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    depthTargetBl(&p, 0x2_0000_0000, 1024, 1024, 5);
    const want = [_]u32{
        hdrInc(SET_ZT_A, 5),
        2,
        0,
        ZT_FORMAT_ZF32,
        5 << 4,
        0,
        hdrInc(SET_ZT_SIZE_A, 3),
        1024,
        1024,
        1,
        hdrImmd(SET_ZT_SELECT, 1),
        hdrImmd(SET_ZT_LAYER, 0),
        hdrImmd(SET_Z_COMPRESSION, 0),
        hdrImmd(SET_ZT_SPARSE, 0),
    };
    try std.testing.expectEqualSlices(u32, &want, buf[0 .. p.bytes() / 4]);
}

test "ctxInit emits within one page and stays in subch 0 range" {
    var buf: [1024]u32 = undefined;
    var p = hostpush.HostPush.init(@intFromPtr(&buf), buf.len * 4);
    ctxInit(&p, 0x0138_0000);
    // Sanity: non-empty, fits the GR pushbuffer page alongside RT+clear+fence.
    try std.testing.expect(p.bytes() > 100);
    try std.testing.expect(p.bytes() < 0x900);
    // Every header targets subchannel 0 with a valid SEC_OP (INC or IMMD).
    var k: usize = 0;
    while (k < p.bytes() / 4) {
        const w = buf[k];
        const secop = w >> 29;
        try std.testing.expect(secop == 1 or secop == 4);
        try std.testing.expectEqual(@as(u32, 0), (w >> 13) & 0x7);
        k += 1 + if (secop == 1) (w >> 16) & 0x1fff else 0;
    }
}
