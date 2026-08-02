//! Host tests of src/drivers/gl/es/limits.zig.

const std = @import("std");
const limits = @import("limits");
const MAX_CLIP_PLANES = limits.MAX_CLIP_PLANES;
const MAX_LIGHTS = limits.MAX_LIGHTS;
const MAX_MODELVIEW_STACK_DEPTH = limits.MAX_MODELVIEW_STACK_DEPTH;
const MAX_PROJECTION_STACK_DEPTH = limits.MAX_PROJECTION_STACK_DEPTH;
const MAX_TEXTURE_STACK_DEPTH = limits.MAX_TEXTURE_STACK_DEPTH;
const MAX_TEXTURE_UNITS = limits.MAX_TEXTURE_UNITS;
const deviceMeetsFloors = limits.deviceMeetsFloors;
const idraw = limits.idraw;

test "our sizes honour every floor the standard sets" {
    try std.testing.expect(MAX_LIGHTS >= 8);
    try std.testing.expect(MAX_CLIP_PLANES >= 6);
    try std.testing.expect(MAX_MODELVIEW_STACK_DEPTH >= 16);
    try std.testing.expect(MAX_PROJECTION_STACK_DEPTH >= 2);
    try std.testing.expect(MAX_TEXTURE_STACK_DEPTH >= 2);
    try std.testing.expect(MAX_TEXTURE_UNITS >= 1);
}

test "the light count fits the shader key's 4 bits" {
    try std.testing.expect(MAX_LIGHTS <= 15);
    // And the unit count fits its 2.
    try std.testing.expect(MAX_TEXTURE_UNITS <= 3);
    try std.testing.expectEqual(idraw.MAX_UNITS, MAX_TEXTURE_UNITS);
}

test "a device below the floors is rejected rather than half-supported" {
    const ok = idraw.Limits{ .max_texture_size = 8192, .texture_units = 2, .samples = 8, .subpixel_bits = 8 };
    try std.testing.expect(deviceMeetsFloors(ok));

    var small = ok;
    small.max_texture_size = 32; // below the standard's 64
    try std.testing.expect(!deviceMeetsFloors(small));

    var blunt = ok;
    blunt.subpixel_bits = 2; // below the standard's 4
    try std.testing.expect(!deviceMeetsFloors(blunt));

    var none = ok;
    none.texture_units = 0;
    try std.testing.expect(!deviceMeetsFloors(none));
}
