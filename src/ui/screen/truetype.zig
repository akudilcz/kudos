//! TrueType outline parsing and antialiased rasterisation at any pixel size.
//!
//! kudos ships one typeface as its original TrueType file (src/ui/assets/) rather
//! than only as fixed-size baked atlases, so text can be drawn at whatever size a
//! surface asks for: this module turns a glyph's outline into an 8-bit coverage
//! bitmap for a requested pixel height. Everything here is a pure function of the
//! font bytes — no allocation, no IO, no device — so the whole rasteriser is
//! host-tested. The caller supplies every buffer, which is also what keeps the
//! renderer's rule that nothing allocates on a hot path: glyph bitmaps are baked
//! into an atlas once (see glyphcache.zig) and drawn from there every frame.
//!
//! Scope: the `glyf` outline flavour of TrueType — quadratic B-splines, simple and
//! composite glyphs, `cmap` formats 4 and 12. PostScript (CFF/OTF) outlines are a
//! different curve type and are rejected at parse time rather than mis-drawn.
//!
//! Terms, expanded on first use: `sfnt` is the container format all TrueType files
//! use; `em` is the design square a glyph is drawn on; `units per em` is that
//! square's resolution in font units; a `glyph index` (gid) is the font's internal
//! numbering, which `cmap` maps Unicode code points onto.

const std = @import("std");

pub const Error = error{
    /// Not an sfnt container, or a flavour this rasteriser does not draw.
    BadFormat,
    /// A table the rasteriser needs is absent or truncated.
    BadTable,
    /// The outline needs more points, edges or nesting than the fixed budgets allow.
    TooComplex,
    /// The destination bitmap is smaller than the glyph's pixel box.
    BufferTooSmall,
};

/// Fixed budgets. A glyph outline that exceeds them is reported, never truncated
/// silently. Roboto Mono's densest glyph uses 96 points; the ceiling is generous
/// so a future typeface does not have to change the contract.
pub const MAX_POINTS: usize = 512;
pub const MAX_CONTOURS: usize = 64;
pub const MAX_EDGES: usize = 1024;
/// Composite glyphs may reference composites; two levels covers every real font.
pub const MAX_COMPONENT_DEPTH: u8 = 4;
/// Widest glyph the scanline filler will draw, in pixels — the coverage
/// accumulator is one row of this, sized once on the stack.
pub const MAX_GLYPH_WIDTH: usize = 1024;
/// Vertical sub-samples per pixel row. Coverage is exact horizontally and
/// sampled vertically, so 4 sub-rows already puts the error below one 8-bit step
/// on the near-horizontal edges that show it worst.
pub const SUB_SAMPLES: usize = 4;

/// A glyph's placement, in whole pixels, relative to the text origin (pen point on
/// the baseline). `left`/`top` are the bitmap's top-left corner: x grows right,
/// y grows DOWN, matching the framebuffer and the atlas.
pub const Metrics = struct {
    /// Bitmap width in pixels (0 for a blank glyph such as space).
    width: u32,
    /// Bitmap height in pixels (0 for a blank glyph).
    height: u32,
    /// Pixels from the pen point to the bitmap's left edge (may be negative).
    left: i32,
    /// Pixels from the baseline UP to the bitmap's top edge, negated: a glyph that
    /// rises 12 px above the baseline has top = -12, so `y + top` is the row to
    /// draw at when y is the baseline.
    top: i32,
    /// Pen advance for this glyph, in pixels.
    advance: f32,
};

/// Vertical metrics of the face, in pixels, for a given pixel height.
pub const LineMetrics = struct {
    /// Baseline to the highest ascender, positive upwards.
    ascent: f32,
    /// Baseline to the lowest descender, positive downwards.
    descent: f32,
    /// Baseline to baseline for consecutive lines.
    line_height: f32,
};

const Box = struct { x_min: i16, y_min: i16, x_max: i16, y_max: i16 };

const Point = struct { x: f32, y: f32, on_curve: bool };
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i2 };

/// Where one sub-scanline crosses an edge, and which way that edge is wound.
const Crossing = struct {
    x: f32,
    dir: i2,

    fn lessThan(_: void, a: Crossing, b: Crossing) bool {
        return a.x < b.x;
    }
};

/// A parsed font: table slices plus the handful of header fields the rasteriser
/// needs. Holds a reference to the caller's bytes and copies nothing.
pub const Font = struct {
    bytes: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    long_loca: bool,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    num_h_metrics: u16,
    loca: []const u8,
    glyf: []const u8,
    hmtx: []const u8,
    cmap_sub: []const u8,

    /// Parse the sfnt table directory and the head/maxp/hhea headers.
    pub fn parse(bytes: []const u8) Error!Font {
        if (bytes.len < 12) return Error.BadFormat;
        const tag = readU32(bytes, 0) catch return Error.BadFormat;
        // 0x00010000 = TrueType outlines; 'true' = the legacy Apple spelling of the
        // same thing. 'OTTO' is a PostScript-outline font: a different curve type.
        if (tag != 0x00010000 and tag != 0x74727565) return Error.BadFormat;

        const num_tables = try readU16(bytes, 4);
        var head: []const u8 = &.{};
        var maxp: []const u8 = &.{};
        var hhea: []const u8 = &.{};
        var loca: []const u8 = &.{};
        var glyf: []const u8 = &.{};
        var hmtx: []const u8 = &.{};
        var cmap: []const u8 = &.{};

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const rec = 12 + 16 * i;
            if (rec + 16 > bytes.len) return Error.BadTable;
            const off = try readU32(bytes, rec + 8);
            const len = try readU32(bytes, rec + 12);
            if (off > bytes.len or off + len > bytes.len) return Error.BadTable;
            const slice = bytes[off .. off + len];
            const name = bytes[rec .. rec + 4];
            if (std.mem.eql(u8, name, "head")) head = slice;
            if (std.mem.eql(u8, name, "maxp")) maxp = slice;
            if (std.mem.eql(u8, name, "hhea")) hhea = slice;
            if (std.mem.eql(u8, name, "loca")) loca = slice;
            if (std.mem.eql(u8, name, "glyf")) glyf = slice;
            if (std.mem.eql(u8, name, "hmtx")) hmtx = slice;
            if (std.mem.eql(u8, name, "cmap")) cmap = slice;
            if (std.mem.eql(u8, name, "CFF ")) return Error.BadFormat;
        }
        if (head.len < 54 or maxp.len < 6 or hhea.len < 36) return Error.BadTable;
        if (loca.len == 0 or glyf.len == 0 or hmtx.len == 0 or cmap.len == 0) return Error.BadTable;

        const units_per_em = try readU16(head, 18);
        if (units_per_em == 0) return Error.BadTable;
        const loc_fmt = try readI16(head, 50);
        const num_glyphs = try readU16(maxp, 4);

        return .{
            .bytes = bytes,
            .units_per_em = units_per_em,
            .num_glyphs = num_glyphs,
            .long_loca = loc_fmt == 1,
            .ascent = try readI16(hhea, 4),
            .descent = try readI16(hhea, 6),
            .line_gap = try readI16(hhea, 8),
            .num_h_metrics = try readU16(hhea, 34),
            .loca = loca,
            .glyf = glyf,
            .hmtx = hmtx,
            .cmap_sub = try selectCmap(cmap),
        };
    }

    /// Font units to pixels for a requested EM size in pixels: the size a
    /// typographer means by "14 px Roboto Mono", i.e. the em square's height.
    pub fn scaleForEmSize(self: Font, px: f32) f32 {
        return px / @as(f32, @floatFromInt(self.units_per_em));
    }

    /// Vertical metrics at a given em size in pixels.
    pub fn lineMetrics(self: Font, px: f32) LineMetrics {
        const s = self.scaleForEmSize(px);
        const asc = @as(f32, @floatFromInt(self.ascent)) * s;
        const desc = -@as(f32, @floatFromInt(self.descent)) * s;
        const gap = @as(f32, @floatFromInt(self.line_gap)) * s;
        return .{ .ascent = asc, .descent = desc, .line_height = asc + desc + gap };
    }

    /// The glyph index a Unicode code point maps to; 0 (.notdef) when unmapped.
    pub fn glyphIndex(self: Font, cp: u21) u16 {
        return cmapLookup(self.cmap_sub, cp) catch 0;
    }

    /// Horizontal advance for a glyph, in font units.
    pub fn advanceUnits(self: Font, gid: u16) u16 {
        if (self.num_h_metrics == 0) return 0;
        const idx = if (gid < self.num_h_metrics) gid else self.num_h_metrics - 1;
        return readU16(self.hmtx, 4 * @as(usize, idx)) catch 0;
    }

    /// Horizontal advance for a glyph, in pixels at the given em size.
    pub fn advancePx(self: Font, gid: u16, px: f32) f32 {
        return @as(f32, @floatFromInt(self.advanceUnits(gid))) * self.scaleForEmSize(px);
    }

    /// Byte range of a glyph's outline record inside `glyf`, or null when the
    /// glyph is blank (space: loca[i] == loca[i+1]).
    fn glyphRange(self: Font, gid: u16) Error!?struct { start: usize, end: usize } {
        if (gid >= self.num_glyphs) return Error.BadTable;
        const i: usize = gid;
        var start: usize = undefined;
        var end: usize = undefined;
        if (self.long_loca) {
            start = try readU32(self.loca, 4 * i);
            end = try readU32(self.loca, 4 * i + 4);
        } else {
            start = 2 * @as(usize, try readU16(self.loca, 2 * i));
            end = 2 * @as(usize, try readU16(self.loca, 2 * i + 2));
        }
        if (end <= start) return null;
        if (end > self.glyf.len) return Error.BadTable;
        return .{ .start = start, .end = end };
    }

    /// Metrics only — the pixel box a glyph would occupy, without drawing it.
    /// `rasterize` reports the same numbers; this is for callers that need to
    /// measure or pack before they have a bitmap to draw into.
    pub fn measure(self: Font, gid: u16, px: f32) Error!Metrics {
        var pts: [MAX_POINTS]Point = undefined;
        var ends: [MAX_CONTOURS]usize = undefined;
        const scale = self.scaleForEmSize(px);
        const n = try loadOutline(self, gid, scale, 0, 0, &pts, &ends, 0, 0);
        return metricsOf(pts[0..n.points], self.advancePx(gid, px));
    }

    /// Draw a glyph into `dst` as 8-bit coverage, one byte per pixel, rows of
    /// `stride` bytes. The bitmap is exactly the glyph's ink box: the caller
    /// places it with the returned metrics. `dst` is written only inside that box
    /// and is expected to be cleared by the caller (an atlas clears once).
    pub fn rasterize(self: Font, gid: u16, px: f32, dst: []u8, stride: usize) Error!Metrics {
        var pts: [MAX_POINTS]Point = undefined;
        var ends: [MAX_CONTOURS]usize = undefined;
        const scale = self.scaleForEmSize(px);
        const loaded = try loadOutline(self, gid, scale, 0, 0, &pts, &ends, 0, 0);
        const m = metricsOf(pts[0..loaded.points], self.advancePx(gid, px));
        if (m.width == 0 or m.height == 0) return m;
        if (dst.len < (m.height - 1) * stride + m.width) return Error.BufferTooSmall;

        // Shift the outline so the ink box starts at (0,0) in bitmap space, with y
        // growing down — the outline arrives in font orientation (y up).
        var edges: [MAX_EDGES]Edge = undefined;
        const n_edges = try buildEdges(
            pts[0..loaded.points],
            ends[0..loaded.contours],
            @floatFromInt(m.left),
            @floatFromInt(m.top),
            &edges,
        );
        fillEdges(edges[0..n_edges], dst, m.width, m.height, stride);
        return m;
    }
};

/// Ink box of an outline, in whole pixels, plus the advance.
fn metricsOf(pts: []const Point, advance: f32) Metrics {
    if (pts.len == 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0, .advance = advance };
    var min_x: f32 = pts[0].x;
    var max_x: f32 = pts[0].x;
    var min_y: f32 = pts[0].y;
    var max_y: f32 = pts[0].y;
    for (pts[1..]) |p| {
        min_x = @min(min_x, p.x);
        max_x = @max(max_x, p.x);
        min_y = @min(min_y, p.y);
        max_y = @max(max_y, p.y);
    }
    const x0: i32 = @intFromFloat(@floor(min_x));
    const y1: i32 = @intFromFloat(@ceil(max_y));
    const x1: i32 = @intFromFloat(@ceil(max_x));
    const y0: i32 = @intFromFloat(@floor(min_y));
    const w = x1 - x0;
    const h = y1 - y0;
    if (w <= 0 or h <= 0) return .{ .width = 0, .height = 0, .left = 0, .top = 0, .advance = advance };
    return .{
        .width = @intCast(w),
        .height = @intCast(h),
        .left = x0,
        // Font space has y up; the bitmap's top edge is the outline's max y, and
        // `top` is measured downwards from the baseline, hence the negation.
        .top = -y1,
        .advance = advance,
    };
}

const Loaded = struct { points: usize, contours: usize };

/// Decode one glyph's points into `pts` (already scaled to pixels, y still up),
/// following composite references. `dx`/`dy` are the pixel offset a parent
/// composite places this component at.
fn loadOutline(
    self: Font,
    gid: u16,
    scale: f32,
    dx: f32,
    dy: f32,
    pts: *[MAX_POINTS]Point,
    ends: *[MAX_CONTOURS]usize,
    base_points: usize,
    depth: u8,
) Error!Loaded {
    if (depth > MAX_COMPONENT_DEPTH) return Error.TooComplex;
    const r = (try self.glyphRange(gid)) orelse return .{ .points = base_points, .contours = 0 };
    const g = self.glyf[r.start..r.end];
    if (g.len < 10) return Error.BadTable;
    const n_contours = try readI16(g, 0);
    if (n_contours >= 0) {
        return loadSimple(g, @intCast(n_contours), scale, dx, dy, pts, ends, base_points);
    }
    return loadComposite(self, g, scale, dx, dy, pts, ends, base_points, depth);
}

fn loadSimple(
    g: []const u8,
    n_contours: usize,
    scale: f32,
    dx: f32,
    dy: f32,
    pts: *[MAX_POINTS]Point,
    ends: *[MAX_CONTOURS]usize,
    base_points: usize,
) Error!Loaded {
    if (n_contours > MAX_CONTOURS) return Error.TooComplex;
    var off: usize = 10;
    var n_points: usize = 0;
    var c: usize = 0;
    while (c < n_contours) : (c += 1) {
        const end_pt = try readU16(g, off + 2 * c);
        n_points = @as(usize, end_pt) + 1;
        ends[c] = base_points + n_points;
    }
    off += 2 * n_contours;
    if (base_points + n_points > MAX_POINTS) return Error.TooComplex;

    const instr_len = try readU16(g, off);
    off += 2 + instr_len;

    // Flags are run-length encoded: bit 3 means "the next byte is a repeat count".
    var flags: [MAX_POINTS]u8 = undefined;
    var i: usize = 0;
    while (i < n_points) {
        if (off >= g.len) return Error.BadTable;
        const f = g[off];
        off += 1;
        flags[i] = f;
        i += 1;
        if (f & 0x08 != 0) {
            if (off >= g.len) return Error.BadTable;
            var rep = g[off];
            off += 1;
            while (rep > 0 and i < n_points) : (rep -= 1) {
                flags[i] = f;
                i += 1;
            }
        }
    }

    // Coordinates are deltas, in one of three widths selected per axis by flags.
    var x: i32 = 0;
    i = 0;
    while (i < n_points) : (i += 1) {
        const f = flags[i];
        if (f & 0x02 != 0) {
            if (off >= g.len) return Error.BadTable;
            const d: i32 = g[off];
            off += 1;
            x += if (f & 0x10 != 0) d else -d;
        } else if (f & 0x10 == 0) {
            x += try readI16(g, off);
            off += 2;
        }
        pts[base_points + i] = .{
            .x = @as(f32, @floatFromInt(x)) * scale + dx,
            .y = 0,
            .on_curve = f & 0x01 != 0,
        };
    }
    var y: i32 = 0;
    i = 0;
    while (i < n_points) : (i += 1) {
        const f = flags[i];
        if (f & 0x04 != 0) {
            if (off >= g.len) return Error.BadTable;
            const d: i32 = g[off];
            off += 1;
            y += if (f & 0x20 != 0) d else -d;
        } else if (f & 0x20 == 0) {
            y += try readI16(g, off);
            off += 2;
        }
        pts[base_points + i].y = @as(f32, @floatFromInt(y)) * scale + dy;
    }
    return .{ .points = base_points + n_points, .contours = n_contours };
}

fn loadComposite(
    self: Font,
    g: []const u8,
    scale: f32,
    dx: f32,
    dy: f32,
    pts: *[MAX_POINTS]Point,
    ends: *[MAX_CONTOURS]usize,
    base_points: usize,
    depth: u8,
) Error!Loaded {
    var off: usize = 10;
    var points = base_points;
    var contours: usize = 0;
    while (true) {
        const flags = try readU16(g, off);
        const sub_gid = try readU16(g, off + 2);
        off += 4;
        var arg1: i32 = undefined;
        var arg2: i32 = undefined;
        if (flags & 0x0001 != 0) { // ARG_1_AND_2_ARE_WORDS
            arg1 = try readI16(g, off);
            arg2 = try readI16(g, off + 2);
            off += 4;
        } else {
            if (off + 2 > g.len) return Error.BadTable;
            arg1 = @as(i8, @bitCast(g[off]));
            arg2 = @as(i8, @bitCast(g[off + 1]));
            off += 2;
        }
        // Only offset placement is honoured; a component scale is rare in text
        // faces and silently mis-drawing one would be worse than skipping it.
        if (flags & 0x0008 != 0) off += 2 // WE_HAVE_A_SCALE
        else if (flags & 0x0040 != 0) off += 4 // X_AND_Y_SCALE
        else if (flags & 0x0080 != 0) off += 8; // TWO_BY_TWO

        const ox: f32 = if (flags & 0x0002 != 0) @as(f32, @floatFromInt(arg1)) * scale else 0;
        const oy: f32 = if (flags & 0x0002 != 0) @as(f32, @floatFromInt(arg2)) * scale else 0;

        var sub_ends: [MAX_CONTOURS]usize = undefined;
        const sub = try loadOutline(self, sub_gid, scale, dx + ox, dy + oy, pts, &sub_ends, points, depth + 1);
        var k: usize = 0;
        while (k < sub.contours) : (k += 1) {
            if (contours >= MAX_CONTOURS) return Error.TooComplex;
            ends[contours] = sub_ends[k];
            contours += 1;
        }
        points = sub.points;
        if (flags & 0x0020 == 0) break; // MORE_COMPONENTS
    }
    return .{ .points = points, .contours = contours };
}

/// Flatten every contour's quadratic segments into edges, in bitmap space
/// (origin at the ink box's top-left, y growing down).
fn buildEdges(pts: []const Point, ends: []const usize, left: f32, top: f32, out: *[MAX_EDGES]Edge) Error!usize {
    var n: usize = 0;
    var start: usize = 0;
    for (ends) |end| {
        if (end <= start or end > pts.len) {
            start = end;
            continue;
        }
        const c = pts[start..end];
        // A contour may begin on an off-curve point; the implied start is then the
        // midpoint between the last and first points.
        var cursor = if (c[0].on_curve) toBitmap(c[0], left, top) else blk: {
            const last = c[c.len - 1];
            const first = c[0];
            break :blk if (last.on_curve)
                toBitmap(last, left, top)
            else
                mid(toBitmap(last, left, top), toBitmap(first, left, top));
        };
        const first_point = cursor;

        var i: usize = if (c[0].on_curve) 1 else 0;
        var control: ?Vec = null;
        while (i <= c.len) : (i += 1) {
            const p = if (i == c.len) first_point else toBitmap(c[i % c.len], left, top);
            const on = if (i == c.len) true else c[i % c.len].on_curve;
            if (on) {
                if (control) |ctl| {
                    n = try emitQuad(out, n, cursor, ctl, p);
                    control = null;
                } else {
                    n = try emitLine(out, n, cursor, p);
                }
                cursor = p;
            } else {
                if (control) |ctl| {
                    // Two consecutive off-curve points imply an on-curve midpoint.
                    const implied = mid(ctl, p);
                    n = try emitQuad(out, n, cursor, ctl, implied);
                    cursor = implied;
                }
                control = p;
            }
        }
        if (control) |ctl| n = try emitQuad(out, n, cursor, ctl, first_point);
        start = end;
    }
    return n;
}

const Vec = struct { x: f32, y: f32 };

fn toBitmap(p: Point, left: f32, top: f32) Vec {
    // Font space has y up and the ink box's top edge at -top; the bitmap has y down.
    return .{ .x = p.x - left, .y = -p.y - top };
}

fn mid(a: Vec, b: Vec) Vec {
    return .{ .x = (a.x + b.x) * 0.5, .y = (a.y + b.y) * 0.5 };
}

fn emitLine(out: *[MAX_EDGES]Edge, n: usize, a: Vec, b: Vec) Error!usize {
    if (a.y == b.y) return n; // horizontal edges never cross a scanline
    if (n >= MAX_EDGES) return Error.TooComplex;
    out[n] = if (a.y < b.y)
        .{ .x0 = a.x, .y0 = a.y, .x1 = b.x, .y1 = b.y, .dir = 1 }
    else
        .{ .x0 = b.x, .y0 = b.y, .x1 = a.x, .y1 = a.y, .dir = -1 };
    return n + 1;
}

/// Flatten a quadratic Bézier into line segments. The step count follows the
/// control polygon's size in pixels, so small text costs few segments and large
/// text stays smooth.
fn emitQuad(out: *[MAX_EDGES]Edge, n_in: usize, a: Vec, c: Vec, b: Vec) Error!usize {
    const dev = @abs(a.x - 2 * c.x + b.x) + @abs(a.y - 2 * c.y + b.y);
    var steps: usize = @intFromFloat(@sqrt(dev * 2.0) + 1.0);
    if (steps > 32) steps = 32;
    var n = n_in;
    var prev = a;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const u = 1 - t;
        const p: Vec = .{
            .x = u * u * a.x + 2 * u * t * c.x + t * t * b.x,
            .y = u * u * a.y + 2 * u * t * c.y + t * t * b.y,
        };
        n = try emitLine(out, n, prev, p);
        prev = p;
    }
    return n;
}

/// Scanline fill with the nonzero winding rule: SUB_SAMPLES sub-rows per pixel
/// row, exact horizontal coverage within each sub-row.
fn fillEdges(edges: []const Edge, dst: []u8, w: u32, h: u32, stride: usize) void {
    var row: u32 = 0;
    var cov: [MAX_GLYPH_WIDTH]f32 = undefined; // one accumulator per pixel column
    var xs: [MAX_EDGES]Crossing = undefined;
    while (row < h) : (row += 1) {
        const cols = @min(@as(usize, w), cov.len);
        @memset(cov[0..cols], 0);

        var s: usize = 0;
        while (s < SUB_SAMPLES) : (s += 1) {
            const y = @as(f32, @floatFromInt(row)) +
                (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(SUB_SAMPLES));

            // Crossings of this sub-scanline, with winding direction.
            var n: usize = 0;
            for (edges) |e| {
                if (y < e.y0 or y >= e.y1) continue;
                if (n == MAX_EDGES) break;
                const t = (y - e.y0) / (e.y1 - e.y0);
                xs[n] = .{ .x = e.x0 + t * (e.x1 - e.x0), .dir = e.dir };
                n += 1;
            }
            if (n == 0) continue;
            std.mem.sort(Crossing, xs[0..n], {}, Crossing.lessThan);

            // Nonzero winding: ink runs from where the count leaves zero to where
            // it returns to zero.
            var winding: i32 = 0;
            var span_start: f32 = 0;
            for (xs[0..n]) |c| {
                const before = winding;
                winding += c.dir;
                if (before == 0 and winding != 0) span_start = c.x;
                if (before != 0 and winding == 0) addSpan(cov[0..cols], span_start, c.x);
            }
        }

        const inv: f32 = 1.0 / @as(f32, @floatFromInt(SUB_SAMPLES));
        var x: usize = 0;
        while (x < cols) : (x += 1) {
            const a = cov[x] * inv;
            const v: f32 = if (a <= 0) 0 else if (a >= 1) 255 else a * 255.0 + 0.5;
            dst[@as(usize, row) * stride + x] = @intFromFloat(v);
        }
    }
}

/// Accumulate one horizontal span's exact per-pixel coverage.
fn addSpan(cov: []f32, x_start: f32, x_end: f32) void {
    if (x_end <= x_start) return;
    const lo = @max(x_start, 0);
    const hi = @min(x_end, @as(f32, @floatFromInt(cov.len)));
    if (hi <= lo) return;
    var px: usize = @intFromFloat(@floor(lo));
    const last: usize = @min(@as(usize, @intFromFloat(@ceil(hi))), cov.len);
    while (px < last) : (px += 1) {
        const l = @max(lo, @as(f32, @floatFromInt(px)));
        const r = @min(hi, @as(f32, @floatFromInt(px + 1)));
        if (r > l) cov[px] += r - l;
    }
}

// ── cmap ────────────────────────────────────────────────────────────────────────

/// Pick the best Unicode subtable: a full-repertoire format 12 if present,
/// otherwise the Basic-Multilingual-Plane format 4 every font carries.
fn selectCmap(cmap: []const u8) Error![]const u8 {
    const n = try readU16(cmap, 2);
    var best: ?[]const u8 = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 4 + 8 * i;
        const platform = try readU16(cmap, rec);
        const encoding = try readU16(cmap, rec + 2);
        const off = try readU32(cmap, rec + 4);
        if (off >= cmap.len) return Error.BadTable;
        const sub = cmap[off..];
        const format = try readU16(sub, 0);
        const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
        if (!unicode) continue;
        if (format == 12) return sub;
        if (format == 4 and best == null) best = sub;
    }
    return best orelse Error.BadTable;
}

fn cmapLookup(sub: []const u8, cp: u21) Error!u16 {
    return switch (try readU16(sub, 0)) {
        4 => cmapFormat4(sub, cp),
        12 => cmapFormat12(sub, cp),
        else => Error.BadTable,
    };
}

fn cmapFormat4(sub: []const u8, cp: u21) Error!u16 {
    if (cp > 0xFFFF) return 0;
    const c: u16 = @intCast(cp);
    const seg_x2 = try readU16(sub, 6);
    const segs = seg_x2 / 2;
    const ends = 14;
    const starts = ends + seg_x2 + 2;
    const deltas = starts + seg_x2;
    const ranges = deltas + seg_x2;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        if (try readU16(sub, ends + 2 * i) < c) continue;
        if (try readU16(sub, starts + 2 * i) > c) return 0;
        const delta = try readU16(sub, deltas + 2 * i);
        const range_off = try readU16(sub, ranges + 2 * i);
        if (range_off == 0) return c +% delta;
        const seg_start = try readU16(sub, starts + 2 * i);
        const idx = ranges + 2 * i + range_off + 2 * @as(usize, c - seg_start);
        const g = try readU16(sub, idx);
        return if (g == 0) 0 else g +% delta;
    }
    return 0;
}

fn cmapFormat12(sub: []const u8, cp: u21) Error!u16 {
    const n_groups = try readU32(sub, 12);
    var i: usize = 0;
    while (i < n_groups) : (i += 1) {
        const rec = 16 + 12 * i;
        const start = try readU32(sub, rec);
        const end = try readU32(sub, rec + 4);
        const gid = try readU32(sub, rec + 8);
        if (cp < start) return 0;
        if (cp <= end) return @intCast(gid + (cp - start));
    }
    return 0;
}

// ── big-endian readers, bounds-checked ──────────────────────────────────────────

fn readU16(b: []const u8, off: usize) Error!u16 {
    if (off + 2 > b.len) return Error.BadTable;
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn readI16(b: []const u8, off: usize) Error!i16 {
    return @bitCast(try readU16(b, off));
}

fn readU32(b: []const u8, off: usize) Error!u32 {
    if (off + 4 > b.len) return Error.BadTable;
    return std.mem.readInt(u32, b[off..][0..4], .big);
}
