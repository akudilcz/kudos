//! Host tests of src/ui/screen/geom.zig.

const std = @import("std");
const geom = @import("geom");
const CORNER_SEGS = geom.CORNER_SEGS;
fn approx(a: f32, b: f32, eps: f32) bool {
    return @abs(a - b) <= eps;
}
const disc = geom.disc;
const discFloats = geom.discFloats;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const rectStrip = geom.rectStrip;
const roundedRect = geom.roundedRect;
const roundedRectFloats = geom.roundedRectFloats;

test "rectStrip corners, in triangle-strip order" {
    var v: [8]f32 = undefined;
    rectStrip(&v, 10, 20, 100, 50);
    try expectEqual(@as(f32, 10), v[0]); // TL x
    try expectEqual(@as(f32, 20), v[1]); // TL y
    try expectEqual(@as(f32, 110), v[2]); // TR x
    try expectEqual(@as(f32, 70), v[7]); // BR y
}

test "roundedRect vertex count matches the buffer sizer" {
    var buf: [256]f32 = undefined;
    const count = roundedRect(&buf, 0, 0, 100, 60, 12, CORNER_SEGS);
    try expectEqual(@as(u32, @intCast(roundedRectFloats(CORNER_SEGS) / 2)), count);
}

test "roundedRect perimeter stays within the rectangle and hugs the corner radius" {
    var buf: [256]f32 = undefined;
    const x = 0.0;
    const y = 0.0;
    const w = 100.0;
    const h = 60.0;
    const r = 12.0;
    const count = roundedRect(&buf, x, y, w, h, r, CORNER_SEGS);
    // Every vertex is inside the rect bounds (centre + perimeter).
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const px = buf[i * 2];
        const py = buf[i * 2 + 1];
        try expect(px >= x - 0.01 and px <= x + w + 0.01);
        try expect(py >= y - 0.01 and py <= y + h + 0.01);
    }
    // The very first perimeter point is the start of the top-right arc at angle
    // -90°: directly above the top-right arc centre, i.e. (x+w-r, y).
    try expect(approx(buf[2], x + w - r, 0.05)); // skip the centre (index 0,1)
    try expect(approx(buf[3], y, 0.05));
}

test "roundedRect clamps a radius larger than half the short side" {
    var buf: [256]f32 = undefined;
    // r=40 on a 60-tall rect clamps to 30; no vertex may leave the box.
    const count = roundedRect(&buf, 0, 0, 100, 60, 40, CORNER_SEGS);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        try expect(buf[i * 2 + 1] >= -0.01 and buf[i * 2 + 1] <= 60.01);
    }
}

test "disc perimeter points lie on the circle" {
    var buf: [128]f32 = undefined;
    const cx = 50.0;
    const cy = 50.0;
    const r = 8.0;
    const count = disc(&buf, cx, cy, r, 24);
    try expectEqual(@as(u32, @intCast(discFloats(24) / 2)), count);
    // Centre first.
    try expect(approx(buf[0], cx, 0.001) and approx(buf[1], cy, 0.001));
    // Each perimeter point is radius r from the centre.
    var i: u32 = 1;
    while (i < count) : (i += 1) {
        const dx = buf[i * 2] - cx;
        const dy = buf[i * 2 + 1] - cy;
        try expect(approx(@sqrt(dx * dx + dy * dy), r, 0.001));
    }
}

test "segmentQuad: corners sit width/2 off the endpoints along the normal" {
    var q: [8]f32 = undefined;
    // A horizontal segment: the normal is vertical (y grows DOWN in screen
    // space, so +normal on a rightward segment points down), and the quad is
    // the axis-aligned rectangle from (10, 18) to (30, 22).
    geom.segmentQuad(&q, 10, 20, 30, 20, 4);
    try expect(approx(q[0], 10, 0.001) and approx(q[1], 22, 0.001)); // start +n
    try expect(approx(q[2], 30, 0.001) and approx(q[3], 22, 0.001)); // end   +n
    try expect(approx(q[4], 10, 0.001) and approx(q[5], 18, 0.001)); // start -n
    try expect(approx(q[6], 30, 0.001) and approx(q[7], 18, 0.001)); // end   -n
}

test "segmentQuad: a diagonal keeps every corner width/2 from the axis" {
    var q: [8]f32 = undefined;
    const w = 6.0;
    geom.segmentQuad(&q, 0, 0, 10, 10, w);
    // Each corner must be exactly w/2 from its own endpoint, displaced
    // PERPENDICULAR to the segment (dot with the direction ≈ 0) — distance
    // alone would accept a sheared quad.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const ex: f32 = if (i % 2 == 0) 0 else 10; // even corners: start; odd: end
        const dx = q[i * 2] - ex;
        const dy = q[i * 2 + 1] - ex;
        try expect(approx(@sqrt(dx * dx + dy * dy), w / 2.0, 0.001));
        try expect(approx(dx * 10 + dy * 10, 0, 0.01)); // ⊥ to direction (10,10)
    }
}

test "segmentQuad: zero length degenerates instead of dividing by zero" {
    var q: [8]f32 = undefined;
    geom.segmentQuad(&q, 5, 5, 5, 5, 4);
    for (q) |v| try expect(approx(v, 5, 0.001));
}
