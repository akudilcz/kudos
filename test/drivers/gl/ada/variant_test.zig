//! Host tests of src/drivers/gl/ada/variant.zig.

const std = @import("std");
const variant = @import("variant");
const BLOB_COUNT = variant.BLOB_COUNT;
const COUNT = variant.COUNT;
const FRAGMENT_COUNT = variant.FRAGMENT_COUNT;
const NAME_CAP = variant.NAME_CAP;
const VERTEX_COUNT = variant.VERTEX_COUNT;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const fragmentName = variant.fragmentName;
const idraw = variant.idraw;
const manifest = variant.manifest;
const reachable = variant.reachable;
const vertexName = variant.vertexName;

/// Collect the distinct names one namer produces over the whole reachable key space.
fn distinctNames(namer: fn (idraw.ShaderKey, *[NAME_CAP]u8) []const u8) !usize {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| std.testing.allocator.free(k.*);
        seen.deinit();
    }
    for (0..9) |l| for (0..idraw.MAX_UNITS + 1) |u| for ([_]bool{ false, true }) |ts|
        for ([_]idraw.FogMode{ .off, .linear, .exp, .exp2 }) |fog| for ([_]bool{ false, true }) |spr| {
            const k = idraw.ShaderKey{ .lights = @intCast(l), .units = @intCast(u), .two_sided = ts, .fog = fog, .sprite = spr };
            if (!reachable(k)) continue;
            var buf: [NAME_CAP]u8 = undefined;
            const name = namer(k, &buf);
            if (!seen.contains(name)) try seen.put(try std.testing.allocator.dupe(u8, name), {});
        };
    return seen.count();
}

/// Does the offline build actually contain a program by this name, for this stage?
fn inManifest(name: []const u8, stage: manifest.Stage) bool {
    for (manifest.shaders) |s| {
        if (s.stage == stage and std.mem.eql(u8, s.name, name)) return true;
    }
    return false;
}

test "the key space is exactly what the struct's fields multiply out to" {
    // 9 light counts x 3 unit counts x 2 two-sided x 4 fog modes, plus the sprite
    // keys: 9 lights x 2 unit counts (a sprite needs a unit) x 4 fog modes, never
    // two-sided (a point has no back face).
    try expectEqual(@as(usize, 288), COUNT);
    var n: usize = 0;
    for (0..9) |l| for (0..idraw.MAX_UNITS + 1) |u| for ([_]bool{ false, true }) |ts|
        for ([_]idraw.FogMode{ .off, .linear, .exp, .exp2 }) |fog| for ([_]bool{ false, true }) |spr| {
            const k = idraw.ShaderKey{ .lights = @intCast(l), .units = @intCast(u), .two_sided = ts, .fog = fog, .sprite = spr };
            if (reachable(k)) n += 1;
        };
    try expectEqual(COUNT, n);
}

test "names are what the scheme says, for the corners of the space" {
    var buf: [NAME_CAP]u8 = undefined;
    try expectEqualStrings("v_l0_u0", vertexName(.{ .lights = 0, .units = 0, .two_sided = false, .fog = .off }, &buf));
    try expectEqualStrings("f_u0_off", fragmentName(.{ .lights = 0, .units = 0, .two_sided = false, .fog = .off }, &buf));
    try expectEqualStrings("v_l8_u2_2s", vertexName(.{ .lights = 8, .units = 2, .two_sided = true, .fog = .exp2 }, &buf));
    try expectEqualStrings("f_u2_2s_exp2", fragmentName(.{ .lights = 8, .units = 2, .two_sided = true, .fog = .exp2 }, &buf));
    try expectEqualStrings("f_u1_lin", fragmentName(.{ .lights = 2, .units = 1, .two_sided = false, .fog = .linear }, &buf));
    // The sprite corners: the suffix lands after fog, and the vertex stage never
    // sees the bit (coordinate replacement happens where sampling does).
    try expectEqualStrings("f_u1_off_spr", fragmentName(.{ .lights = 0, .units = 1, .two_sided = false, .fog = .off, .sprite = true }, &buf));
    try expectEqualStrings("f_u2_exp2_spr", fragmentName(.{ .lights = 8, .units = 2, .two_sided = false, .fog = .exp2, .sprite = true }, &buf));
    try expectEqualStrings("v_l8_u2", vertexName(.{ .lights = 8, .units = 2, .two_sided = false, .fog = .exp2, .sprite = true }, &buf));
}

test "the vertex program is fog-blind, so fog cannot change its name" {
    var a: [NAME_CAP]u8 = undefined;
    var b: [NAME_CAP]u8 = undefined;
    const k1 = idraw.ShaderKey{ .lights = 3, .units = 1, .two_sided = false, .fog = .off };
    const k2 = idraw.ShaderKey{ .lights = 3, .units = 1, .two_sided = false, .fog = .exp2 };
    try expectEqualStrings(vertexName(k1, &a), vertexName(k2, &b));
    // But it does change the fragment's.
    try expect(!std.mem.eql(u8, fragmentName(k1, &a), fragmentName(k2, &b)));
}

test "the vertex program is sprite-blind, so the sprite bit cannot change its name" {
    var a: [NAME_CAP]u8 = undefined;
    var b: [NAME_CAP]u8 = undefined;
    const plain = idraw.ShaderKey{ .lights = 3, .units = 1, .two_sided = false, .fog = .off };
    const spr = idraw.ShaderKey{ .lights = 3, .units = 1, .two_sided = false, .fog = .off, .sprite = true };
    try expectEqualStrings(vertexName(plain, &a), vertexName(spr, &b));
    // But it does change the fragment's — that is where the replacement happens.
    try expect(!std.mem.eql(u8, fragmentName(plain, &a), fragmentName(spr, &b)));
}

test "every name fits the cap the factory allocates for it" {
    var buf: [NAME_CAP]u8 = undefined;
    var longest: usize = 0;
    for (0..9) |l| for (0..idraw.MAX_UNITS + 1) |u| for ([_]bool{ false, true }) |ts|
        for ([_]idraw.FogMode{ .off, .linear, .exp, .exp2 }) |fog| for ([_]bool{ false, true }) |spr| {
            const k = idraw.ShaderKey{ .lights = @intCast(l), .units = @intCast(u), .two_sided = ts, .fog = fog, .sprite = spr };
            if (!reachable(k)) continue;
            longest = @max(longest, fragmentName(k, &buf).len);
            longest = @max(longest, vertexName(k, &buf).len);
        };
    try expect(longest <= NAME_CAP);
}

test "the fragment program is light-blind, so the light count cannot change its name" {
    var a: [NAME_CAP]u8 = undefined;
    var b: [NAME_CAP]u8 = undefined;
    // ES 1.1 lights per vertex, so these two keys MUST share a fragment program: by the
    // time a fragment exists there is one interpolated colour and no trace of how many
    // lights made it. Giving them separate blobs would be 192 wasted compilations of
    // identical code.
    const k1 = idraw.ShaderKey{ .lights = 0, .units = 1, .two_sided = false, .fog = .exp };
    const k2 = idraw.ShaderKey{ .lights = 8, .units = 1, .two_sided = false, .fog = .exp };
    try expectEqualStrings(fragmentName(k1, &a), fragmentName(k2, &b));
    // But it does change the vertex program's.
    try expect(!std.mem.eql(u8, vertexName(k1, &a), vertexName(k2, &b)));
}

test "the 288 keys resolve to 54 vertex and 32 fragment programs" {
    // Each stage names only what it can see, so neither count is 288 and they do not
    // multiply back to it — a key picks one of each. 86 blobs, not 576.
    try expectEqual(VERTEX_COUNT, try distinctNames(vertexName));
    try expectEqual(@as(usize, 54), try distinctNames(vertexName));
    try expectEqual(FRAGMENT_COUNT, try distinctNames(fragmentName));
    try expectEqual(@as(usize, 32), try distinctNames(fragmentName));
    try expectEqual(@as(usize, 86), BLOB_COUNT);
}

test "no vertex name can ever collide with a fragment name" {
    // They share one flat manifest, so the two namespaces must not meet. The v_/f_
    // prefixes are what keep them apart, and this is the test that says so.
    var buf: [NAME_CAP]u8 = undefined;
    const k = idraw.ShaderKey{ .lights = 1, .units = 1, .two_sided = false, .fog = .off };
    try expect(vertexName(k, &buf)[0] == 'v');
    try expect(fragmentName(k, &buf)[0] == 'f');
}

test "every one of the 288 keys resolves to a program that exists" {
    // THE test this file exists for (ARCH-010: no drawable state may need a program
    // that was not built). A key whose blob was never compiled has no
    // fallback and no recovery — the draw simply does not happen — so the miss is
    // caught here, on a laptop, rather than as a black window on lemon.
    //
    // It also binds the two halves of the naming rule together: this side computes the
    // name, and the manifest is what scripts/shaders/build.sh's loop actually emitted.
    // If those two ever disagree, this goes red rather than silent.
    for (0..9) |l| for (0..idraw.MAX_UNITS + 1) |u| for ([_]bool{ false, true }) |ts|
        for ([_]idraw.FogMode{ .off, .linear, .exp, .exp2 }) |fog| for ([_]bool{ false, true }) |spr| {
            var buf: [NAME_CAP]u8 = undefined;
            const k = idraw.ShaderKey{ .lights = @intCast(l), .units = @intCast(u), .two_sided = ts, .fog = fog, .sprite = spr };
            if (!reachable(k)) continue;
            if (!inManifest(vertexName(k, &buf), .vertex)) {
                std.debug.print("no vertex program '{s}'\n", .{vertexName(k, &buf)});
                return error.MissingVertexVariant;
            }
            if (!inManifest(fragmentName(k, &buf), .fragment)) {
                std.debug.print("no fragment program '{s}'\n", .{fragmentName(k, &buf)});
                return error.MissingFragmentVariant;
            }
        };
}

test "the factory built every variant and no key is unreachable from it" {
    // The other direction (ARCH-008: the generated manifest IS the offline-compiled,
    // embedded program set): a blob nothing can ask for is dead weight in a 1 MiB VA
    // window. Counting both ways is what makes the set exactly right rather than merely
    // sufficient.
    var v: usize = 0;
    var f: usize = 0;
    for (manifest.shaders) |s| {
        if (std.mem.startsWith(u8, s.name, "v_l")) v += 1;
        if (std.mem.startsWith(u8, s.name, "f_u")) f += 1;
    }
    try expectEqual(VERTEX_COUNT, v);
    try expectEqual(FRAGMENT_COUNT, f);
}

test "a key the pipeline cannot reach is refused rather than indexed" {
    try expect(reachable(.{ .lights = 8, .units = 2, .two_sided = true, .fog = .exp2 }));
    try expect(reachable(.{ .lights = 0, .units = 0, .two_sided = false, .fog = .off }));
    // The struct's four bits can hold 9..15; the pipeline can never produce them.
    try expect(!reachable(.{ .lights = 9, .units = 0, .two_sided = false, .fog = .off }));
    try expect(!reachable(.{ .lights = 15, .units = 0, .two_sided = false, .fog = .off }));
    // MAX_UNITS is 2, and the field holds 3.
    try expect(!reachable(.{ .lights = 0, .units = 3, .two_sided = false, .fog = .off }));
    // A sprite key needs a unit to replace and never has a back face —
    // es/shaderkey.zig keys point draws exactly that way.
    try expect(reachable(.{ .lights = 0, .units = 1, .two_sided = false, .fog = .off, .sprite = true }));
    try expect(!reachable(.{ .lights = 0, .units = 0, .two_sided = false, .fog = .off, .sprite = true }));
    try expect(!reachable(.{ .lights = 1, .units = 1, .two_sided = true, .fog = .off, .sprite = true }));
}
