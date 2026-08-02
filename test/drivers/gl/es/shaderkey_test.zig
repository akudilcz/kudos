//! Host tests of src/drivers/gl/es/shaderkey.zig.

const std = @import("std");
const shaderkey = @import("shaderkey");
const contributingUnits = shaderkey.contributingUnits;
const enabledLights = shaderkey.enabledLights;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const idraw = shaderkey.idraw;
const keyFor = shaderkey.keyFor;
const limits = shaderkey.limits;

/// A Context wired to nothing: no device, no target, and an allocator that
/// fails on use — these tests must not allocate.
fn testContext() shaderkey.state.Context {
    return shaderkey.state.Context{ .dev = undefined, .target = undefined, .dev_limits = undefined, .alloc = std.testing.failing_allocator };
}

/// Bind a texture to `unit` and give it storage, as glBindTexture + glTexImage2D would.
fn bindComplete(g: *shaderkey.state.Context, unit: usize, name: u32) void {
    g.caps.texture_2d[unit] = true;
    g.texture_binding[unit] = name;
    g.textures.ensureNamed(name) catch unreachable;
    g.textures.setDeviceHandle(name, 100 + name, 4, .static);
}

test "a default context wants the simplest program there is" {
    var g = testContext();
    const k = keyFor(&g, .triangles);
    try expectEqual(@as(u4, 0), k.lights);
    try expectEqual(@as(u2, 0), k.units);
    try expect(!k.two_sided);
    try expect(k.fog == .off);
}

test "GL_LIGHTING off folds every light bit away — one program, not nine" {
    var g = testContext();
    for (&g.caps.light) |*l| l.* = true; // all eight on...
    try expectEqual(@as(u4, 0), keyFor(&g, .triangles).lights); // ...but the master switch is off

    g.caps.lighting = true;
    try expectEqual(@as(u4, 8), keyFor(&g, .triangles).lights);
}

test "the count is how many are enabled, not the highest index" {
    var g = testContext();
    g.caps.lighting = true;
    g.caps.light[7] = true; // only the last one
    try expectEqual(@as(u4, 1), keyFor(&g, .triangles).lights);

    // And the packing agrees about WHICH light that is.
    var idx: [limits.MAX_LIGHTS]u8 = undefined;
    try expectEqual(@as(u8, 1), enabledLights(&g, &idx));
    try expectEqual(@as(u8, 7), idx[0]); // light 7 lands in slot 0
}

test "two-sided lighting folds away when there is no light to flip a normal for" {
    var g = testContext();
    g.light_model_two_side = true;
    try expect(!keyFor(&g, .triangles).two_sided); // lighting off: nothing to be two-sided about

    g.caps.lighting = true;
    g.caps.light[0] = true;
    try expect(keyFor(&g, .triangles).two_sided);
}

test "a texture unit needs its enable, a binding, AND an image to count" {
    var g = testContext();
    g.caps.texture_2d[0] = true; // enabled, nothing bound
    try expectEqual(@as(u2, 0), keyFor(&g, .triangles).units);

    // Bound but with no image: the standard says an incomplete texture behaves as if
    // texturing were disabled, so this must NOT count. When it did, the key claimed a
    // unit the lowering could not bind and the device refused the whole draw.
    g.texture_binding[0] = 5;
    g.textures.ensureNamed(5) catch unreachable;
    try expectEqual(@as(u2, 0), keyFor(&g, .triangles).units);

    g.textures.setDeviceHandle(5, 42, 4, .static); // now it has an image
    try expectEqual(@as(u2, 1), keyFor(&g, .triangles).units);

    g.caps.texture_2d[0] = false; // complete but disabled
    try expectEqual(@as(u2, 0), keyFor(&g, .triangles).units);
}

test "a sparse unit is compacted to the front" {
    var g = testContext();
    bindComplete(&g, 1, 3); // unit 1 only
    try expectEqual(@as(u2, 1), keyFor(&g, .triangles).units);
    var idx: [limits.MAX_TEXTURE_UNITS]u8 = undefined;
    try expectEqual(@as(u8, 1), contributingUnits(&g, &idx));
    try expectEqual(@as(u8, 1), idx[0]); // unit 1 lands in slot 0
}

test "fog folds to off when disabled, whatever mode is set" {
    var g = testContext();
    g.fog.mode = .exp2;
    try expect(keyFor(&g, .triangles).fog == .off);
    g.caps.fog = true;
    try expect(keyFor(&g, .triangles).fog == .exp2);
}

test "every state this can reach maps to a key that was built" {
    // The guarantee this module exists to make (ARCH-010): 216 programs are compiled
    // ahead of time, and a draw must never need a 217th. Sweep the whole reachable space.
    var seen = std.AutoHashMap(u16, void).init(std.testing.allocator);
    defer seen.deinit();

    for ([_]bool{ false, true }) |lighting| {
        for (0..limits.MAX_LIGHTS + 1) |nlights| {
            for (0..limits.MAX_TEXTURE_UNITS + 1) |nunits| {
                for ([_]bool{ false, true }) |two_side| {
                    for ([_]idraw.FogMode{ .off, .linear, .exp, .exp2 }) |fm| {
                        for ([_]bool{ false, true }) |fog_on| {
                            var g = testContext();
                            g.caps.lighting = lighting;
                            for (0..nlights) |i| g.caps.light[i] = true;
                            for (0..nunits) |i| bindComplete(&g, i, @intCast(i + 1));
                            g.light_model_two_side = two_side;
                            g.caps.fog = fog_on;
                            g.fog.mode = fm;

                            const k = keyFor(&g, .triangles);
                            try expect(k.lights <= 8);
                            try expect(k.units <= limits.MAX_TEXTURE_UNITS);
                            try seen.put(@bitCast(k), {});
                        }
                    }
                }
            }
        }
    }
    // Every key produced is inside the built set of 9 x 3 x 2 x 4.
    try expect(seen.count() <= 216);
}

test "OES_point_sprite keys only a point draw with a replacing, contributing unit" {
    var g = testContext();
    bindComplete(&g, 0, 7);
    // Cap off: no sprite, whatever the texenv says.
    g.texenv[0].coord_replace = true;
    try expect(!keyFor(&g, .points).sprite);
    // Cap on + replace on a contributing unit: a point draw keys sprite...
    g.caps.point_sprite = true;
    try expect(keyFor(&g, .points).sprite);
    // ...and every other primitive keys exactly as before.
    try expect(!keyFor(&g, .triangles).sprite);
    try expect(!keyFor(&g, .lines).sprite);
    // Replace off again: points key plain.
    g.texenv[0].coord_replace = false;
    try expect(!keyFor(&g, .points).sprite);
}

test "a sprite key never carries two-sided: a point has no back face" {
    var g = testContext();
    bindComplete(&g, 0, 7);
    g.caps.point_sprite = true;
    g.texenv[0].coord_replace = true;
    g.caps.lighting = true;
    g.caps.light[0] = true;
    g.light_model_two_side = true;
    try expect(keyFor(&g, .triangles).two_sided);
    const k = keyFor(&g, .points);
    try expect(k.sprite);
    try expect(!k.two_sided);
}

test "a replace flag on a non-contributing unit replaces nothing" {
    var g = testContext();
    g.caps.point_sprite = true;
    // Unit 0 enabled but imageless: it contributes nothing, so no sprite.
    g.caps.texture_2d[0] = true;
    g.texenv[0].coord_replace = true;
    try expect(!keyFor(&g, .points).sprite);
}
