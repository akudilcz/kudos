//! Host tests of src/drivers/gl/es/texparam.zig.

const std = @import("std");
const texparam = @import("texparam");
const Sampler = texparam.Sampler;
const enums = texparam.enums;
const expect = std.testing.expect;
const mapMag = texparam.mapMag;
const mapMin = texparam.mapMin;

test "a Sampler round-trips through the object table's aux word" {
    // It is stored as bits in a u32; a widening or a lost field here would silently
    // change how every texture filters.
    const s = Sampler{ .wrap_s = .clamp_to_edge, .wrap_t = .repeat, .min_filter = .linear_mipmap_linear, .mag_filter = .nearest, .generate_mipmap = true };
    const round: Sampler = @bitCast(@as(u16, @truncate(@as(u32, @as(u16, @bitCast(s))))));
    try expect(round.wrap_s == .clamp_to_edge);
    try expect(round.wrap_t == .repeat);
    try expect(round.min_filter == .linear_mipmap_linear);
    try expect(round.mag_filter == .nearest);
    try expect(round.generate_mipmap);
}

test "the default minification filter uses mipmaps — why an un-mipmapped texture is incomplete" {
    const s = Sampler{};
    try expect(s.min_filter == .nearest_mipmap_linear);
    try expect(s.min_filter.usesMipmaps());
    // Magnification's default does not, and cannot: there is no level above 0.
    try expect(s.mag_filter == .linear);
    try expect(s.wrap_s == .repeat and s.wrap_t == .repeat);
}

test "only the non-mipmap filters skip the chain" {
    try expect(!Sampler.MinFilter.nearest.usesMipmaps());
    try expect(!Sampler.MinFilter.linear.usesMipmaps());
    for ([_]Sampler.MinFilter{ .nearest_mipmap_nearest, .linear_mipmap_nearest, .nearest_mipmap_linear, .linear_mipmap_linear }) |f|
        try expect(f.usesMipmaps());
}

test "magnification rejects the mipmap filters the standard does not allow it" {
    try expect(mapMag(enums.GL_LINEAR_MIPMAP_LINEAR) == null);
    try expect(mapMag(enums.GL_NEAREST) != null);
    try expect(mapMin(enums.GL_LINEAR_MIPMAP_LINEAR) != null);
}
