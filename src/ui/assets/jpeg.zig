//! JPEG (JFIF) decoder — PURE module (std only), host-tested
//! (test/ui/assets/jpeg_test.zig). Sibling of png.zig: decodes the embedded base-color
//! textures GLB models carry into the BGRA8 layout the kGL texture unit samples
//! (tex.zig ticPitchBgra8 — byte order B,G,R,A =
//! little-endian 0xAARRGGBB, straight/opaque alpha) — the SAME output layout as
//! png.zig, so a decoded JPEG drops into the identical texture path.
//!
//! Grounded in libjpeg-turbo 2.1.5. Supported subset:
//!   - 8-bit precision, Huffman coding.
//!   - Baseline / extended sequential (SOF0/SOF1) AND progressive (SOF2), the
//!     latter with spectral selection + successive approximation across scans.
//!   - YCbCr (3-component) with 1x1 / 2x1 / 2x2 chroma subsampling, and
//!     grayscale (1-component).
//!   - Restart intervals (DRI / RSTn).
//! Everything else is a DISTINCT loud error, never a silently-wrong texture:
//! arithmetic coding (SOF9/10/DAC), lossless/differential (SOF3/5/6/7/…),
//! 12/16-bit precision, and CMYK/YCCK (4-component).
//!
//! Memory: the coefficient store (per-component i16 block grids) and the output
//! image are heap-allocated via an arena; the only sizable stack frame is the
//! IDCT's [64]i32 workspace — safe on the kernel boot stack, which has no room
//! for a large decoder buffer.

const std = @import("std");

pub const Error = error{
    JpegBadMarker, // missing SOI/EOI, marker where none expected
    JpegTruncated, // a segment/scan runs off the end of the buffer
    JpegBadHuffmanTable, // malformed DHT (bad counts / over-full code tree / undefined ref)
    JpegBadQuantTable, // malformed DQT / referenced-but-undefined quant table
    JpegBadScan, // illegal Ss/Se/Ah/Al, unknown scan component, bad sampling factor
    JpegArithmetic, // arithmetic coding (SOF9/SOF10/DAC) — not implemented
    JpegUnsupportedMode, // lossless / differential SOF
    JpegUnsupportedPrecision, // precision != 8 (12/16-bit)
    JpegUnsupportedComponents, // component count not in {1, 3} (CMYK/YCCK)
    JpegTooLarge, // dimension beyond MAX_DIM
    JpegCorrupt, // entropy stream inconsistent (bad Huffman code, etc.)
} || std.mem.Allocator.Error;

/// Shared axis bound with png.zig (texture-unit sanity; 8192² × 4 = 256 MiB).
pub const MAX_DIM: u32 = 8192;

/// Decoded texture image — the SAME nominal type png.zig returns (byte-identical
/// {w,h,bgra,deinit}), re-exported so a caller can decode a base-color texture
/// through either codec and keep ONE type at the use site (modelcache.zig's
/// `switch (tex_mime)` yields one Image). One owner, one type.
pub const Image = @import("png.zig").Image;

// ── constants (jidctint.c) ───────────────────────────────────────────────────
const DCTSIZE = 8;
const DCTSIZE2 = 64;

/// zig-zag → natural (row-major) index map (jutils.c jpeg_natural_order). The
/// 16 trailing 63s guard against corrupt streams pushing k past 63 (jdhuff.c
/// L613 relies on this).
const natural_order = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63, 63,
};

// ── marker codes (jdmarker.c) ────────────────────────────────────────────────
/// Every JPEG marker is MARKER_PREFIX then the code byte; a stream opens with
/// MARKER_PREFIX, M_SOI. Public so a caller that sniffs a byte stream's format
/// checks the one authoritative pair.
pub const MARKER_PREFIX = 0xff;
const M_SOF0 = 0xc0;
const M_SOF1 = 0xc1;
const M_SOF2 = 0xc2;
const M_SOF3 = 0xc3;
const M_DHT = 0xc4;
const M_SOF9 = 0xc9;
const M_SOF10 = 0xca;
const M_DAC = 0xcc;
const M_RST0 = 0xd0;
const M_RST7 = 0xd7;
pub const M_SOI = 0xd8;
const M_EOI = 0xd9;
const M_SOS = 0xda;
const M_DQT = 0xdb;
const M_DRI = 0xdd;
const M_APP0 = 0xe0;
const M_APP15 = 0xef;
const M_COM = 0xfe;

const MAX_COMPS = 4; // parsed count is 1 or 3; array sized for safety

// ── Huffman derived table (jdhuff.c jpeg_make_d_derived_tbl, Figures C.1/C.2/F.15)
const HuffTable = struct {
    // maxcode[l] = largest code of length l (or -1 if none); index 1..16, plus
    // a length-17 sentinel that forces the decode loop to terminate on garbage.
    maxcode: [18]i32,
    // valoffset[l] = (huffval index of first length-l symbol) - (first length-l code).
    valoffset: [18]i32,
    huffval: [256]u8,
    defined: bool,

    fn build(bits: *const [17]u8, huffval: *const [256]u8) Error!HuffTable {
        var t: HuffTable = .{ .maxcode = undefined, .valoffset = undefined, .huffval = huffval.*, .defined = true };

        // Figure C.1: huffsize[] in code-length order.
        var huffsize: [257]u8 = undefined;
        var p: usize = 0;
        var l: usize = 1;
        while (l <= 16) : (l += 1) {
            const n = bits[l];
            if (p + n > 256) return Error.JpegBadHuffmanTable;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                huffsize[p] = @intCast(l);
                p += 1;
            }
        }
        huffsize[p] = 0;

        // Figure C.2: canonical codes; validate the tree is legal.
        var huffcode: [257]u32 = undefined;
        var code: u32 = 0;
        var si: u8 = huffsize[0];
        p = 0;
        while (huffsize[p] != 0) {
            while (huffsize[p] == si) {
                huffcode[p] = code;
                p += 1;
                code += 1;
            }
            // code must still fit in si bits (no all-ones code).
            if (code >= (@as(u32, 1) << @intCast(si))) return Error.JpegBadHuffmanTable;
            code <<= 1;
            si += 1;
        }

        // Figure F.15: maxcode / valoffset.
        p = 0;
        l = 1;
        while (l <= 16) : (l += 1) {
            if (bits[l] != 0) {
                t.valoffset[l] = @as(i32, @intCast(p)) - @as(i32, @intCast(huffcode[p]));
                p += bits[l];
                t.maxcode[l] = @intCast(huffcode[p - 1]);
            } else {
                t.maxcode[l] = -1;
            }
        }
        t.valoffset[17] = 0;
        t.maxcode[17] = 0xFFFFF; // sentinel
        return t;
    }
};

// ── bit reader over the entropy-coded segment (jdhuff.c jpeg_fill_bit_buffer) ─
// Feeds the Huffman/receive-extend decoders. Handles FF00 byte-stuffing and
// stops at a real marker (leaving it in `marker`). Out-of-data returns zero bits
// (libjpeg's insufficient_data behavior) so a slightly-short scan still yields a
// full image rather than crashing.
const BitReader = struct {
    data: []const u8,
    pos: usize,
    bitbuf: u32,
    bitcnt: u5, // bits currently buffered (0..24)
    marker: ?u8, // a marker byte encountered while filling (scan boundary)

    fn init(data: []const u8, pos: usize) BitReader {
        return .{ .data = data, .pos = pos, .bitbuf = 0, .bitcnt = 0, .marker = null };
    }

    /// Ensure at least `n` (<= 16) bits are buffered.
    fn fill(self: *BitReader, n: u5) void {
        while (self.bitcnt < n) {
            if (self.marker != null or self.pos >= self.data.len) {
                // Out of data: stuff zero bits (jdhuff.c L369-371).
                self.bitbuf <<= 8;
                self.bitcnt += 8;
                continue;
            }
            var c = self.data[self.pos];
            self.pos += 1;
            if (c == 0xFF) {
                // Skip padding FFs, then examine the next byte.
                var nb: u8 = 0;
                while (self.pos < self.data.len) {
                    nb = self.data[self.pos];
                    self.pos += 1;
                    if (nb != 0xFF) break;
                }
                if (nb == 0) {
                    c = 0xFF; // FF00 → literal FF data byte
                } else {
                    // Real marker terminates the entropy data. Record it and
                    // rewind so the scan loop can read it.
                    self.marker = nb;
                    self.pos -= 2; // back to the FF
                    self.bitbuf <<= 8;
                    self.bitcnt += 8;
                    continue;
                }
            }
            self.bitbuf = (self.bitbuf << 8) | c;
            self.bitcnt += 8;
        }
    }

    /// Read `n` bits (n <= 16), MSB first.
    fn getBits(self: *BitReader, n: u5) u32 {
        if (n == 0) return 0;
        self.fill(n);
        self.bitcnt -= n;
        return (self.bitbuf >> self.bitcnt) & ((@as(u32, 1) << n) - 1);
    }

    fn getBit(self: *BitReader) u32 {
        return self.getBits(1);
    }

    /// Decode one Huffman symbol (jpeg_huff_decode, Figure F.16).
    fn decodeHuff(self: *BitReader, t: *const HuffTable) Error!u8 {
        var code: i32 = 0;
        var l: usize = 1;
        while (l <= 16) : (l += 1) {
            code = (code << 1) | @as(i32, @intCast(self.getBit()));
            if (code <= t.maxcode[l]) {
                const idx = code + t.valoffset[l];
                if (idx < 0 or idx > 255) return Error.JpegCorrupt;
                return t.huffval[@intCast(idx)];
            }
        }
        return Error.JpegCorrupt; // ran past length 16 without a match
    }

    /// Discard buffered bits up to the next byte boundary and skip the RSTn
    /// marker at a restart interval (jdhuff.c process_restart).
    fn resetToRestart(self: *BitReader) Error!void {
        self.bitbuf = 0;
        self.bitcnt = 0;
        // Consume the RSTn marker (FF D0..D7). It may already be sitting at pos.
        if (self.marker) |m| {
            if (m >= M_RST0 and m <= M_RST7) {
                self.pos += 2; // skip FF Dn
                self.marker = null;
                return;
            }
            return Error.JpegBadMarker;
        }
        // Not yet seen: scan forward to it.
        while (self.pos + 1 < self.data.len) {
            if (self.data[self.pos] == 0xFF) {
                const m = self.data[self.pos + 1];
                if (m >= M_RST0 and m <= M_RST7) {
                    self.pos += 2;
                    return;
                }
                if (m != 0xFF and m != 0) return Error.JpegBadMarker;
            }
            self.pos += 1;
        }
        return Error.JpegTruncated;
    }
};

/// Receive-and-extend (jdhuff.c HUFF_EXTEND, T.81 Figure F.12).
inline fn extend(v: u32, s: u5) i32 {
    const x: i32 = @intCast(v);
    if (s == 0) return 0;
    // if the top bit is 0 the value is negative: v - (1<<s) + 1
    if (x < (@as(i32, 1) << (s - 1))) return x - (@as(i32, 1) << s) + 1;
    return x;
}

// ── per-component info ───────────────────────────────────────────────────────
const Component = struct {
    id: u8,
    h: u8, // horizontal sampling factor
    v: u8, // vertical sampling factor
    quant: u8, // quant table selector
    dc_tbl: u8, // DC Huffman selector (set per scan)
    ac_tbl: u8, // AC Huffman selector (set per scan)
    // block grid dimensions (in 8x8 blocks), padded to the MCU grid.
    bw: u32, // blocks wide
    bh: u32, // blocks high
    coeffs: []i16, // bw*bh*64 coefficient store (natural order), heap
    pred: i32, // running DC predictor
    eobrun: u32, // progressive EOB run remaining (AC scans)
};

const Decoder = struct {
    a: std.mem.Allocator,
    bytes: []const u8,
    pos: usize,

    width: u32,
    height: u32,
    progressive: bool,
    ncomp: u8,
    comps: [MAX_COMPS]Component,
    hmax: u8,
    vmax: u8,
    mcus_x: u32,
    mcus_y: u32,
    restart_interval: u32,

    quant: [4][64]u16, // natural order
    quant_def: [4]bool,
    dc_huff: [4]HuffTable,
    ac_huff: [4]HuffTable,

    fn u16be(self: *Decoder) Error!u16 {
        if (self.pos + 2 > self.bytes.len) return Error.JpegTruncated;
        const v = std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }
    fn byte(self: *Decoder) Error!u8 {
        if (self.pos >= self.bytes.len) return Error.JpegTruncated;
        const v = self.bytes[self.pos];
        self.pos += 1;
        return v;
    }
};

pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    // Scratch arena holds every intermediate (coefficient store, component
    // sample planes); only the final BGRA image comes from `a`.
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var d: Decoder = undefined;
    d.a = arena;
    d.bytes = bytes;
    d.pos = 0;
    d.progressive = false;
    d.restart_interval = 0;
    d.ncomp = 0;
    for (&d.quant_def) |*x| x.* = false;
    for (&d.dc_huff) |*t| t.defined = false;
    for (&d.ac_huff) |*t| t.defined = false;

    // SOI must come first (jdmarker.c first_marker).
    if (bytes.len < 2 or bytes[0] != MARKER_PREFIX or bytes[1] != M_SOI) return Error.JpegBadMarker;
    d.pos = 2;

    var seen_sof = false;

    // Marker loop (jdmarker.c read_markers), extended to run each scan inline.
    while (d.pos + 1 < bytes.len) {
        // Find the next marker (skip fill/non-FF, though a well-formed header
        // has markers back-to-back).
        if (bytes[d.pos] != 0xFF) {
            d.pos += 1;
            continue;
        }
        var m = bytes[d.pos + 1];
        d.pos += 2;
        while (m == 0xFF) { // padding FFs
            if (d.pos >= bytes.len) return Error.JpegTruncated;
            m = bytes[d.pos];
            d.pos += 1;
        }

        switch (m) {
            M_SOF0, M_SOF1, M_SOF2 => {
                if (seen_sof) return Error.JpegBadMarker;
                try parseSof(&d, m == M_SOF2);
                seen_sof = true;
            },
            M_SOF3, 0xc5, 0xc6, 0xc7, 0xcd, 0xce, 0xcf => return Error.JpegUnsupportedMode,
            M_SOF9, M_SOF10, 0xcb, M_DAC => return Error.JpegArithmetic,
            M_DHT => try parseDht(&d),
            M_DQT => try parseDqt(&d),
            M_DRI => {
                const len = try d.u16be();
                if (len != 4) return Error.JpegBadMarker;
                d.restart_interval = try d.u16be();
            },
            M_SOS => {
                if (!seen_sof) return Error.JpegBadScan;
                try decodeScan(&d);
                // decodeScan leaves d.pos at the marker that ended the scan.
                continue;
            },
            M_EOI => break, // EOI: end of image (a stream may also end at its last scan)
            M_APP0...M_APP15, M_COM => {
                const len = try d.u16be();
                if (len < 2) return Error.JpegBadMarker;
                if (d.pos + (len - 2) > bytes.len) return Error.JpegTruncated;
                d.pos += len - 2;
            },
            M_RST0...M_RST7, 0x01 => {}, // stray standalone marker between segments — ignore
            else => {
                // Unknown variable-length marker: skip by its length.
                const len = try d.u16be();
                if (len < 2) return Error.JpegBadMarker;
                if (d.pos + (len - 2) > bytes.len) return Error.JpegTruncated;
                d.pos += len - 2;
            },
        }
    }

    if (!seen_sof) return Error.JpegBadMarker;
    return finish(&d, a);
}

fn parseSof(d: *Decoder, progressive: bool) Error!void {
    const len = try d.u16be();
    const precision = try d.byte();
    if (precision != 8) return Error.JpegUnsupportedPrecision;
    d.height = try d.u16be();
    d.width = try d.u16be();
    d.ncomp = try d.byte();
    if (d.height == 0 or d.width == 0) return Error.JpegBadMarker;
    if (d.width > MAX_DIM or d.height > MAX_DIM) return Error.JpegTooLarge;
    if (d.ncomp != 1 and d.ncomp != 3) return Error.JpegUnsupportedComponents;
    if (len != 8 + @as(u16, d.ncomp) * 3) return Error.JpegBadMarker;
    d.progressive = progressive;

    d.hmax = 1;
    d.vmax = 1;
    var ci: usize = 0;
    while (ci < d.ncomp) : (ci += 1) {
        var c = &d.comps[ci];
        c.id = try d.byte();
        const hv = try d.byte();
        c.h = (hv >> 4) & 0xF;
        c.v = hv & 0xF;
        c.quant = try d.byte();
        if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4) return Error.JpegBadScan;
        if (c.quant >= 4) return Error.JpegBadQuantTable;
        c.pred = 0;
        c.eobrun = 0;
        if (c.h > d.hmax) d.hmax = c.h;
        if (c.v > d.vmax) d.vmax = c.v;
    }

    d.mcus_x = (d.width + @as(u32, d.hmax) * 8 - 1) / (@as(u32, d.hmax) * 8);
    d.mcus_y = (d.height + @as(u32, d.vmax) * 8 - 1) / (@as(u32, d.vmax) * 8);

    // Each component's block grid is padded to the MCU grid: bw = mcus_x * h.
    // (Non-interleaved scans iterate exactly this padded grid, §6.)
    ci = 0;
    while (ci < d.ncomp) : (ci += 1) {
        var c = &d.comps[ci];
        c.bw = d.mcus_x * c.h;
        c.bh = d.mcus_y * c.v;
        const n = @as(usize, c.bw) * c.bh * 64;
        c.coeffs = try d.a.alloc(i16, n);
        @memset(c.coeffs, 0);
    }
}

fn parseDqt(d: *Decoder) Error!void {
    var len = try d.u16be();
    if (len < 2) return Error.JpegBadMarker;
    len -= 2;
    while (len > 0) {
        const pq_tq = try d.byte();
        len -= 1;
        const pq = pq_tq >> 4;
        const tq = pq_tq & 0xF;
        if (tq >= 4) return Error.JpegBadQuantTable;
        if (pq != 0) return Error.JpegUnsupportedPrecision; // 16-bit tables
        if (len < 64) return Error.JpegBadQuantTable;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            // Stored zig-zag; de-zig-zag to natural order (jdmarker.c L539).
            d.quant[tq][natural_order[i]] = try d.byte();
        }
        d.quant_def[tq] = true;
        len -= 64;
    }
}

fn parseDht(d: *Decoder) Error!void {
    var len = try d.u16be();
    if (len < 2) return Error.JpegBadMarker;
    len -= 2;
    while (len > 16) {
        const tc_th = try d.byte();
        len -= 1;
        const tc = tc_th >> 4; // 0 DC, 1 AC
        const th = tc_th & 0xF;
        if (th >= 4 or tc >= 2) return Error.JpegBadHuffmanTable;

        var bits: [17]u8 = .{0} ** 17;
        var count: usize = 0;
        var i: usize = 1;
        while (i <= 16) : (i += 1) {
            bits[i] = try d.byte();
            count += bits[i];
        }
        len -= 16;
        if (count > 256 or count > len) return Error.JpegBadHuffmanTable;

        var huffval: [256]u8 = .{0} ** 256;
        i = 0;
        while (i < count) : (i += 1) huffval[i] = try d.byte();
        len -= @intCast(count);

        const t = try HuffTable.build(&bits, &huffval);
        if (tc == 0) d.dc_huff[th] = t else d.ac_huff[th] = t;
    }
    if (len != 0) return Error.JpegBadMarker;
}

// ── scan decode ──────────────────────────────────────────────────────────────
fn decodeScan(d: *Decoder) Error!void {
    const len = try d.u16be();
    const ns = try d.byte();
    if (ns < 1 or ns > d.ncomp) return Error.JpegBadScan;
    if (len != 6 + @as(u16, ns) * 2) return Error.JpegBadScan;

    // Map the ns scan components to their SOF component indices, in scan order.
    var scan_comp: [MAX_COMPS]usize = undefined;
    var si: usize = 0;
    while (si < ns) : (si += 1) {
        const cs = try d.byte();
        const td_ta = try d.byte();
        // locate the SOF component with this id
        var found: ?usize = null;
        var k: usize = 0;
        while (k < d.ncomp) : (k += 1) {
            if (d.comps[k].id == cs) {
                found = k;
                break;
            }
        }
        const ci = found orelse return Error.JpegBadScan;
        d.comps[ci].dc_tbl = (td_ta >> 4) & 0xF;
        d.comps[ci].ac_tbl = td_ta & 0xF;
        if (d.comps[ci].dc_tbl >= 4 or d.comps[ci].ac_tbl >= 4) return Error.JpegBadScan;
        scan_comp[si] = ci;
    }

    const ss = try d.byte();
    const se = try d.byte();
    const ah_al = try d.byte();
    const ah: u5 = @intCast((ah_al >> 4) & 0xF);
    const al: u5 = @intCast(ah_al & 0xF);

    if (!d.progressive) {
        if (ss != 0 or se != 63 or ah != 0 or al != 0) return Error.JpegBadScan;
    } else {
        // Validate progression (jdphuff.c start_pass_phuff_decoder L91-119).
        if (ss == 0) {
            if (se != 0) return Error.JpegBadScan; // DC band: Se must be 0
        } else {
            if (ss > se or se >= 64) return Error.JpegBadScan;
            if (ns != 1) return Error.JpegBadScan; // AC scans are single-component
        }
        if (ah != 0 and al != ah - 1) return Error.JpegBadScan;
        if (al > 13) return Error.JpegBadScan;
    }

    var br = BitReader.init(d.bytes, d.pos);

    // Reset DC predictors and EOB runs at scan start.
    var i: usize = 0;
    while (i < d.ncomp) : (i += 1) {
        d.comps[i].pred = 0;
        d.comps[i].eobrun = 0;
    }
    // EOBRUN is per-scan progressive state, tracked on the (single) AC comp.

    var restarts_to_go: u32 = d.restart_interval;

    if (ns == 1) {
        // Non-interleaved: MCU = one block, iterate the component's own padded
        // block grid (§6). Used by grayscale and every progressive AC scan, and
        // by single-component progressive DC scans.
        const ci = scan_comp[0];
        const c = &d.comps[ci];
        // For a subsampled single-component scan, the meaningful block extent is
        // ceil(compW/8) × ceil(compH/8), which can be smaller than the padded
        // bw×bh; libjpeg iterates the padded grid but pads coefficients to zero.
        const comp_bw = (d.width * c.h + @as(u32, d.hmax) * 8 - 1) / (@as(u32, d.hmax) * 8);
        const comp_bh = (d.height * c.v + @as(u32, d.vmax) * 8 - 1) / (@as(u32, d.vmax) * 8);
        var by: u32 = 0;
        while (by < comp_bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < comp_bw) : (bx += 1) {
                if (d.restart_interval != 0 and restarts_to_go == 0) {
                    try br.resetToRestart();
                    c.pred = 0;
                    c.eobrun = 0;
                    restarts_to_go = d.restart_interval;
                }
                const block = c.coeffs[(@as(usize, by) * c.bw + bx) * 64 ..][0..64];
                try decodeBlock(d, &br, c, block, ss, se, ah, al);
                if (d.restart_interval != 0) restarts_to_go -= 1;
            }
        }
    } else {
        // Interleaved: iterate the MCU grid; each MCU emits h·v blocks per
        // component in raster order (§5, §6).
        var my: u32 = 0;
        while (my < d.mcus_y) : (my += 1) {
            var mx: u32 = 0;
            while (mx < d.mcus_x) : (mx += 1) {
                if (d.restart_interval != 0 and restarts_to_go == 0) {
                    try br.resetToRestart();
                    var r: usize = 0;
                    while (r < d.ncomp) : (r += 1) {
                        d.comps[r].pred = 0;
                        d.comps[r].eobrun = 0;
                    }
                    restarts_to_go = d.restart_interval;
                }
                si = 0;
                while (si < ns) : (si += 1) {
                    const ci = scan_comp[si];
                    const c = &d.comps[ci];
                    var v: u32 = 0;
                    while (v < c.v) : (v += 1) {
                        var h: u32 = 0;
                        while (h < c.h) : (h += 1) {
                            const bx = mx * c.h + h;
                            const by = my * c.v + v;
                            const block = c.coeffs[(@as(usize, by) * c.bw + bx) * 64 ..][0..64];
                            try decodeBlock(d, &br, c, block, ss, se, ah, al);
                        }
                    }
                }
                if (d.restart_interval != 0) restarts_to_go -= 1;
            }
        }
    }

    // Advance the decoder past the entropy data to the terminating marker.
    // br.marker is set once a real marker was hit; otherwise walk from br.pos.
    d.pos = br.pos;
    if (br.marker == null) {
        // Skip any trailing entropy bytes / fill to the next marker.
        while (d.pos + 1 < d.bytes.len) {
            if (d.bytes[d.pos] == 0xFF and d.bytes[d.pos + 1] != 0 and d.bytes[d.pos + 1] != 0xFF) break;
            d.pos += 1;
        }
    }
}

/// Decode one 8×8 block into `block` (natural order). Dispatches sequential vs
/// the four progressive routines (§7).
fn decodeBlock(d: *Decoder, br: *BitReader, c: *Component, block: []i16, ss: u8, se: u8, ah: u5, al: u5) Error!void {
    if (!d.progressive) {
        return decodeBlockBaseline(d, br, c, block);
    }
    if (ss == 0) {
        if (ah == 0) return decodeBlockDcFirst(d, br, c, block, al);
        return decodeBlockDcRefine(br, block, al);
    }
    if (ah == 0) return decodeBlockAcFirst(d, br, c, block, ss, se, al);
    return decodeBlockAcRefine(d, br, c, block, ss, se, al);
}

/// Baseline sequential block (jdhuff.c decode_mcu_slow L549).
fn decodeBlockBaseline(d: *Decoder, br: *BitReader, c: *Component, block: []i16) Error!void {
    if (!d.dc_huff[c.dc_tbl].defined or !d.ac_huff[c.ac_tbl].defined) return Error.JpegBadHuffmanTable;
    const dctbl = &d.dc_huff[c.dc_tbl];
    const actbl = &d.ac_huff[c.ac_tbl];

    // DC coefficient difference (F.2.2.1).
    const s = try br.decodeHuff(dctbl);
    var diff: i32 = 0;
    if (s != 0) {
        if (s > 15) return Error.JpegCorrupt;
        const bits = br.getBits(@intCast(s));
        diff = extend(bits, @intCast(s));
    }
    c.pred += diff;
    block[0] = @intCast(clampCoef(c.pred));

    // AC coefficients (F.2.2.2), skipping zero runs.
    var k: usize = 1;
    while (k < 64) {
        const rs = try br.decodeHuff(actbl);
        const r = rs >> 4;
        const sz = rs & 15;
        if (sz != 0) {
            k += r;
            if (k >= 64) break;
            const bits = br.getBits(@intCast(sz));
            block[natural_order[k]] = @intCast(clampCoef(extend(bits, @intCast(sz))));
            k += 1;
        } else {
            if (r != 15) break; // EOB
            k += 16; // ZRL
        }
    }
}

/// Progressive DC first pass (jdphuff.c decode_mcu_DC_first L287).
fn decodeBlockDcFirst(d: *Decoder, br: *BitReader, c: *Component, block: []i16, al: u5) Error!void {
    if (!d.dc_huff[c.dc_tbl].defined) return Error.JpegBadHuffmanTable;
    const s = try br.decodeHuff(&d.dc_huff[c.dc_tbl]);
    var diff: i32 = 0;
    if (s != 0) {
        if (s > 15) return Error.JpegCorrupt;
        diff = extend(br.getBits(@intCast(s)), @intCast(s));
    }
    c.pred += diff;
    block[0] = @intCast(clampCoef(c.pred << al));
}

/// Progressive DC refinement (jdphuff.c decode_mcu_DC_refine L449).
fn decodeBlockDcRefine(br: *BitReader, block: []i16, al: u5) Error!void {
    if (br.getBit() != 0) block[0] |= (@as(i16, 1) << @as(u4, @intCast(al)));
}

/// Progressive AC first pass (jdphuff.c decode_mcu_AC_first L363).
fn decodeBlockAcFirst(d: *Decoder, br: *BitReader, c: *Component, block: []i16, ss: u8, se: u8, al: u5) Error!void {
    if (c.eobrun > 0) {
        c.eobrun -= 1;
        return;
    }
    if (!d.ac_huff[c.ac_tbl].defined) return Error.JpegBadHuffmanTable;
    const actbl = &d.ac_huff[c.ac_tbl];
    var k: usize = ss;
    while (k <= se) {
        const rs = try br.decodeHuff(actbl);
        const r = rs >> 4;
        const sz = rs & 15;
        if (sz != 0) {
            k += r;
            if (k > se) break;
            const val = extend(br.getBits(@intCast(sz)), @intCast(sz));
            block[natural_order[k]] = @intCast(clampCoef(val << al));
            k += 1;
        } else {
            if (r != 15) {
                // EOB run: 2^r + r extra bits (jdphuff.c L415-423).
                var eob: u32 = @as(u32, 1) << @intCast(r);
                if (r != 0) eob += br.getBits(@intCast(r));
                c.eobrun = eob - 1; // this band consumed now
                break;
            }
            k += 16; // ZRL
        }
    }
}

/// Progressive AC refinement (jdphuff.c decode_mcu_AC_refine L499) — the subtle
/// one. `p1`/`m1` are the ±correction in the bit position being coded; already-
/// nonzero coefficients passed over receive a correction bit, new ones become
/// ±p1.
fn decodeBlockAcRefine(d: *Decoder, br: *BitReader, c: *Component, block: []i16, ss: u8, se: u8, al: u5) Error!void {
    if (!d.ac_huff[c.ac_tbl].defined) return Error.JpegBadHuffmanTable;
    const actbl = &d.ac_huff[c.ac_tbl];
    const shift: u4 = @intCast(al);
    const p1: i16 = @as(i16, 1) << shift; // +1 in the coded bit position
    const m1: i16 = @as(i16, -1) << shift; // -1 in the coded bit position (arith shift keeps upper bits)

    var k: usize = ss;
    if (c.eobrun == 0) {
        while (k <= se) {
            const rs = try br.decodeHuff(actbl);
            var r: i32 = @intCast(rs >> 4);
            const sz = rs & 15;
            var newval: i16 = 0;
            if (sz != 0) {
                // size should always be 1 for a refinement's new coefficient.
                newval = if (br.getBit() != 0) p1 else m1;
            } else {
                if (r != 15) {
                    // EOB run begins.
                    var eob: u32 = @as(u32, 1) << @intCast(r);
                    if (r != 0) eob += br.getBits(@intCast(r));
                    c.eobrun = eob;
                    break; // handled by the EOB phase below
                }
                // r == 15: ZRL, skip 16 zero coefficients (correction bits still
                // applied to nonzeros passed over). newval stays 0.
            }

            // Advance over already-nonzero coeffs (append correction bit) and r
            // still-zero coeffs (jdphuff.c L574-591).
            while (k <= se) {
                const pos = natural_order[k];
                if (block[pos] != 0) {
                    if (br.getBit() != 0 and (block[pos] & p1) == 0) {
                        if (block[pos] >= 0) block[pos] += p1 else block[pos] += m1;
                    }
                } else {
                    if (r == 0) break; // reached target zero coefficient
                    r -= 1;
                }
                k += 1;
            }
            if (newval != 0 and k <= se) {
                block[natural_order[k]] = newval;
            }
            k += 1;
        }
    }

    if (c.eobrun > 0) {
        // EOB phase: append a correction bit to every remaining nonzero coeff.
        while (k <= se) : (k += 1) {
            const pos = natural_order[k];
            if (block[pos] != 0) {
                if (br.getBit() != 0 and (block[pos] & p1) == 0) {
                    if (block[pos] >= 0) block[pos] += p1 else block[pos] += m1;
                }
            }
        }
        c.eobrun -= 1;
    }
}

inline fn clampCoef(v: i32) i32 {
    // Coefficients live in i16; clamp so a corrupt stream can't wrap.
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return v;
}

// ── finish: dequant + IDCT + upsample + color → BGRA ─────────────────────────
fn finish(d: *Decoder, out_alloc: std.mem.Allocator) Error!Image {
    // Decode every component's blocks into a full-resolution (padded) sample
    // plane of u8. Padded plane size = bw*8 × bh*8.
    var planes: [MAX_COMPS][]u8 = undefined;
    var plane_w: [MAX_COMPS]u32 = undefined;
    var plane_h: [MAX_COMPS]u32 = undefined;

    var ci: usize = 0;
    while (ci < d.ncomp) : (ci += 1) {
        const c = &d.comps[ci];
        if (!d.quant_def[c.quant]) return Error.JpegBadQuantTable;
        const pw = c.bw * 8;
        const ph = c.bh * 8;
        const plane = try d.a.alloc(u8, @as(usize, pw) * ph);
        var by: u32 = 0;
        var ws: [64]i32 = undefined;
        while (by < c.bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < c.bw) : (bx += 1) {
                const block = c.coeffs[(@as(usize, by) * c.bw + bx) * 64 ..][0..64];
                idctBlock(block, &d.quant[c.quant], &ws);
                // Scatter the 8×8 result into the plane.
                var yy: usize = 0;
                while (yy < 8) : (yy += 1) {
                    const row = (@as(usize, by) * 8 + yy) * pw + @as(usize, bx) * 8;
                    var xx: usize = 0;
                    while (xx < 8) : (xx += 1) {
                        plane[row + xx] = @intCast(ws[yy * 8 + xx]);
                    }
                }
            }
        }
        planes[ci] = plane;
        plane_w[ci] = pw;
        plane_h[ci] = ph;
    }

    const w = d.width;
    const h = d.height;
    const out = try out_alloc.alloc(u8, @as(usize, w) * h * 4);
    errdefer out_alloc.free(out);

    if (d.ncomp == 1) {
        // Grayscale: replicate luma to B,G,R (jdcolext.c gray_rgb_convert).
        const yp = planes[0];
        const pw = plane_w[0];
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const g = yp[@as(usize, y) * pw + x];
                const o = (@as(usize, y) * w + x) * 4;
                out[o] = g;
                out[o + 1] = g;
                out[o + 2] = g;
                out[o + 3] = 255;
            }
        }
    } else {
        // YCbCr → BGRA. Chroma is box-upsampled by the component ratio (§9):
        // component sample for image pixel (x,y) is plane[(y*Vi/Vmax), (x*Hi/Hmax)].
        const yc = &d.comps[0];
        const cbc = &d.comps[1];
        const crc = &d.comps[2];
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const yy = sampleAt(planes[0], plane_w[0], x, y, yc.h, yc.v, d.hmax, d.vmax);
                const cb = sampleAt(planes[1], plane_w[1], x, y, cbc.h, cbc.v, d.hmax, d.vmax);
                const cr = sampleAt(planes[2], plane_w[2], x, y, crc.h, crc.v, d.hmax, d.vmax);
                const o = (@as(usize, y) * w + x) * 4;
                yccToBgra(yy, cb, cr, out[o..][0..4]);
            }
        }
    }

    return .{ .w = w, .h = h, .bgra = out };
}

/// Box-upsampled component sample for image pixel (x,y): map through the
/// component's sampling ratio (replicating upsample, §9).
inline fn sampleAt(plane: []const u8, pw: u32, x: u32, y: u32, ch: u8, cv: u8, hmax: u8, vmax: u8) u8 {
    const cx = (@as(u64, x) * ch) / hmax;
    const cy = (@as(u64, y) * cv) / vmax;
    return plane[@intCast(cy * pw + cx)];
}

/// YCbCr → RGB, fixed-point CCIR-601 (jdcolor.c build_ycc_rgb_table +
/// ycc_rgb_convert_internal). Writes B,G,R,A (kGL layout).
inline fn yccToBgra(y: u8, cb: u8, cr: u8, dst: []u8) void {
    const SCALEBITS = 16;
    const ONE_HALF = @as(i32, 1) << (SCALEBITS - 1);
    // FIX(x) = round(x * 2^16); constants match jdcolor.c.
    const cr_r: i32 = 91881; // FIX(1.40200)
    const cb_b: i32 = 116130; // FIX(1.77200)
    const cr_g: i32 = -46802; // -FIX(0.71414)
    const cb_g: i32 = -22554; // -FIX(0.34414)

    const yi: i32 = y;
    const cbx: i32 = @as(i32, cb) - 128;
    const crx: i32 = @as(i32, cr) - 128;

    const r = yi + ((cr_r * crx + ONE_HALF) >> SCALEBITS);
    const g = yi + ((cb_g * cbx + cr_g * crx + ONE_HALF) >> SCALEBITS);
    const b = yi + ((cb_b * cbx + ONE_HALF) >> SCALEBITS);

    dst[0] = clampU8(b);
    dst[1] = clampU8(g);
    dst[2] = clampU8(r);
    dst[3] = 255;
}

inline fn clampU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

// ── integer IDCT (the LLM algorithm, as libjpeg's jpeg_idct_islow implements it) ──
// Loeffler-Ligtenberg-Moschytz, at the published 13-bit fixed-point scaling, so
// this decoder's output agrees bit-for-bit with the libjpeg-turbo goldens.
// `block` is dequantized in-flight (coef × quant, both natural order); output is
// 8×8 samples centered at 128 and clamped to [0,255] into `ws`.
const CONST_BITS = 13;
const PASS1_BITS = 2;
const FIX_0_298631336 = 2446;
const FIX_0_390180644 = 3196;
const FIX_0_541196100 = 4433;
const FIX_0_765366865 = 6270;
const FIX_0_899976223 = 7373;
const FIX_1_175875602 = 9633;
const FIX_1_501321110 = 12299;
const FIX_1_847759065 = 15137;
const FIX_1_961570560 = 16069;
const FIX_2_053119869 = 16819;
const FIX_2_562915447 = 20995;
const FIX_3_072711026 = 25172;

inline fn descale(x: i64, comptime n: u6) i32 {
    return @intCast((x + (@as(i64, 1) << (n - 1))) >> n);
}

fn idctBlock(block: []const i16, quant: *const [64]u16, ws: *[64]i32) void {
    var work: [64]i32 = undefined;

    // Pass 1: columns.
    var ctr: usize = 0;
    while (ctr < 8) : (ctr += 1) {
        const c = ctr;
        // AC-all-zero column short-circuit.
        if (block[c + 8] == 0 and block[c + 16] == 0 and block[c + 24] == 0 and
            block[c + 32] == 0 and block[c + 40] == 0 and block[c + 48] == 0 and
            block[c + 56] == 0)
        {
            const dc = deq(block, quant, c) << PASS1_BITS;
            var i: usize = 0;
            while (i < 8) : (i += 1) work[c + i * 8] = dc;
            continue;
        }

        var z2 = deq(block, quant, c + 16);
        var z3 = deq(block, quant, c + 48);
        var z1 = (z2 + z3) * FIX_0_541196100;
        var tmp2 = z1 + z3 * (-FIX_1_847759065);
        var tmp3 = z1 + z2 * FIX_0_765366865;

        z2 = deq(block, quant, c + 0);
        z3 = deq(block, quant, c + 32);
        var tmp0 = (z2 + z3) << CONST_BITS;
        var tmp1 = (z2 - z3) << CONST_BITS;
        const tmp10 = tmp0 + tmp3;
        const tmp13 = tmp0 - tmp3;
        const tmp11 = tmp1 + tmp2;
        const tmp12 = tmp1 - tmp2;

        tmp0 = deq(block, quant, c + 56);
        tmp1 = deq(block, quant, c + 40);
        tmp2 = deq(block, quant, c + 24);
        tmp3 = deq(block, quant, c + 8);
        z1 = tmp0 + tmp3;
        z2 = tmp1 + tmp2;
        z3 = tmp0 + tmp2;
        var z4 = tmp1 + tmp3;
        const z5 = (z3 + z4) * FIX_1_175875602;
        tmp0 = tmp0 * FIX_0_298631336;
        tmp1 = tmp1 * FIX_2_053119869;
        tmp2 = tmp2 * FIX_3_072711026;
        tmp3 = tmp3 * FIX_1_501321110;
        z1 = z1 * (-FIX_0_899976223);
        z2 = z2 * (-FIX_2_562915447);
        z3 = z3 * (-FIX_1_961570560);
        z4 = z4 * (-FIX_0_390180644);
        z3 += z5;
        z4 += z5;
        tmp0 += z1 + z3;
        tmp1 += z2 + z4;
        tmp2 += z2 + z3;
        tmp3 += z1 + z4;

        work[c + 0] = descale(@as(i64, tmp10) + tmp3, CONST_BITS - PASS1_BITS);
        work[c + 56] = descale(@as(i64, tmp10) - tmp3, CONST_BITS - PASS1_BITS);
        work[c + 8] = descale(@as(i64, tmp11) + tmp2, CONST_BITS - PASS1_BITS);
        work[c + 48] = descale(@as(i64, tmp11) - tmp2, CONST_BITS - PASS1_BITS);
        work[c + 16] = descale(@as(i64, tmp12) + tmp1, CONST_BITS - PASS1_BITS);
        work[c + 40] = descale(@as(i64, tmp12) - tmp1, CONST_BITS - PASS1_BITS);
        work[c + 24] = descale(@as(i64, tmp13) + tmp0, CONST_BITS - PASS1_BITS);
        work[c + 32] = descale(@as(i64, tmp13) - tmp0, CONST_BITS - PASS1_BITS);
    }

    // Pass 2: rows. Output centered at 128 and clamped.
    var r: usize = 0;
    while (r < 8) : (r += 1) {
        const base = r * 8;
        if (work[base + 1] == 0 and work[base + 2] == 0 and work[base + 3] == 0 and
            work[base + 4] == 0 and work[base + 5] == 0 and work[base + 6] == 0 and
            work[base + 7] == 0)
        {
            const dc = rangeClamp(descale(@as(i64, work[base]), PASS1_BITS + 3));
            var i: usize = 0;
            while (i < 8) : (i += 1) ws[base + i] = dc;
            continue;
        }

        var z2: i32 = work[base + 2];
        var z3: i32 = work[base + 6];
        var z1 = (z2 + z3) * FIX_0_541196100;
        var tmp2 = z1 + z3 * (-FIX_1_847759065);
        var tmp3 = z1 + z2 * FIX_0_765366865;
        var tmp0 = (work[base] + work[base + 4]) << CONST_BITS;
        var tmp1 = (work[base] - work[base + 4]) << CONST_BITS;
        const tmp10 = tmp0 + tmp3;
        const tmp13 = tmp0 - tmp3;
        const tmp11 = tmp1 + tmp2;
        const tmp12 = tmp1 - tmp2;

        tmp0 = work[base + 7];
        tmp1 = work[base + 5];
        tmp2 = work[base + 3];
        tmp3 = work[base + 1];
        z1 = tmp0 + tmp3;
        z2 = tmp1 + tmp2;
        z3 = tmp0 + tmp2;
        var z4 = tmp1 + tmp3;
        const z5 = (z3 + z4) * FIX_1_175875602;
        tmp0 = tmp0 * FIX_0_298631336;
        tmp1 = tmp1 * FIX_2_053119869;
        tmp2 = tmp2 * FIX_3_072711026;
        tmp3 = tmp3 * FIX_1_501321110;
        z1 = z1 * (-FIX_0_899976223);
        z2 = z2 * (-FIX_2_562915447);
        z3 = z3 * (-FIX_1_961570560);
        z4 = z4 * (-FIX_0_390180644);
        z3 += z5;
        z4 += z5;
        tmp0 += z1 + z3;
        tmp1 += z2 + z4;
        tmp2 += z2 + z3;
        tmp3 += z1 + z4;

        ws[base + 0] = rangeClamp(descale(@as(i64, tmp10) + tmp3, CONST_BITS + PASS1_BITS + 3));
        ws[base + 7] = rangeClamp(descale(@as(i64, tmp10) - tmp3, CONST_BITS + PASS1_BITS + 3));
        ws[base + 1] = rangeClamp(descale(@as(i64, tmp11) + tmp2, CONST_BITS + PASS1_BITS + 3));
        ws[base + 6] = rangeClamp(descale(@as(i64, tmp11) - tmp2, CONST_BITS + PASS1_BITS + 3));
        ws[base + 2] = rangeClamp(descale(@as(i64, tmp12) + tmp1, CONST_BITS + PASS1_BITS + 3));
        ws[base + 5] = rangeClamp(descale(@as(i64, tmp12) - tmp1, CONST_BITS + PASS1_BITS + 3));
        ws[base + 3] = rangeClamp(descale(@as(i64, tmp13) + tmp0, CONST_BITS + PASS1_BITS + 3));
        ws[base + 4] = rangeClamp(descale(@as(i64, tmp13) - tmp0, CONST_BITS + PASS1_BITS + 3));
    }
}

/// Dequantize coefficient at natural-order index i (coef × quant).
inline fn deq(block: []const i16, quant: *const [64]u16, i: usize) i32 {
    return @as(i32, block[i]) * @as(i32, quant[i]);
}

/// IDCT output centering + clamp: reference indexes range_limit at CENTERJSAMPLE
/// (jidctint.c / jdmaster.c prepare_range_limit_table), i.e. clamp(v+128,0,255).
inline fn rangeClamp(v: i32) i32 {
    const c = v + 128;
    if (c < 0) return 0;
    if (c > 255) return 255;
    return c;
}
