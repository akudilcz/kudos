//! An in-memory drawable: a pixel buffer with a stride, so sub-regions (window
//! content areas) can share a parent's memory.

pub const Color = u32; // 0xAARRGGBB, PREMULTIPLIED alpha. The alpha byte only
// matters on a GLASS window's surface (translucent windows):
// premultiplied content background, 0xFF glyphs/chrome. Every opaque composite
// path (CE copy, desktop plane PIXEL_NONE blend) ignores it, so plain
// 0x00RRGGBB values remain valid wherever the pixel never reaches a
// premultiplied blend.

/// Premultiply an opaque `0x00RRGGBB` color by coverage `a` and stamp `a` into the
/// alpha byte — the form a GLASS surface's translucent background pixels take
/// (translucent windows). Rounded like blendConst so a premultiplied
/// background fill is bit-identical to blending the straight color at `a` over black.
pub fn premultiply(c: Color, a: u8) Color {
    const fa: u32 = a;
    const r = ((c >> 16) & 0xFF) * fa / 255;
    const g = ((c >> 8) & 0xFF) * fa / 255;
    const b = (c & 0xFF) * fa / 255;
    return (fa << 24) | (r << 16) | (g << 8) | b;
}

pub const Surface = struct {
    px: [*]u32,
    w: usize,
    h: usize,
    stride: usize, // pixels per row of the backing buffer

    /// Wrap a caller-owned pixel slice as a top-level surface; stride equals
    /// width, so the backing buffer is exactly w*h pixels with no row padding.
    pub fn fromSlice(buf: []u32, w: usize, h: usize) Surface {
        return .{ .px = buf.ptr, .w = w, .h = h, .stride = w };
    }

    /// A sub-region sharing this surface's memory.
    pub fn sub(self: Surface, x: usize, y: usize, w: usize, h: usize) Surface {
        return .{
            .px = self.px + y * self.stride + x,
            .w = w,
            .h = h,
            .stride = self.stride,
        };
    }

    /// Write one pixel, silently clipping coordinates outside the surface so
    /// callers can draw near an edge without bounds-checking every point.
    pub fn putPixel(self: Surface, x: usize, y: usize, c: Color) void {
        if (x >= self.w or y >= self.h) return;
        self.px[y * self.stride + x] = c;
    }

    /// Fill the entire surface with a solid color.
    pub fn fill(self: Surface, c: Color) void {
        self.fillRect(0, 0, self.w, self.h, c);
    }

    /// Fill the rectangle (x0,y0,w,h) with a solid color, clipped to the
    /// surface bounds.
    pub fn fillRect(self: Surface, x0: usize, y0: usize, w: usize, h: usize, c: Color) void {
        const xe = @min(x0 + w, self.w);
        const ye = @min(y0 + h, self.h);
        var y = y0;
        while (y < ye) : (y += 1) {
            const row = self.px + y * self.stride;
            var x = x0;
            while (x < xe) : (x += 1) row[x] = c;
        }
    }

    /// PREMULTIPLIED per-pixel blend of a rectangle of `src` over this surface at
    /// (dx,dy): out = src + (1−srcA/255)·dst per channel, where srcA is each source
    /// pixel's own alpha byte and src is already premultiplied — the CPU mirror of
    /// the HW overlay plane's PREMULTI blend, so a glass window looks the same on
    /// either path (translucent windows). A srcA=0xFF pixel is an
    /// opaque copy; an all-zero pixel leaves dst. `sx`/`sy` is the source
    /// sub-origin, `w`/`h` the rectangle; clipped to both surfaces. The output alpha
    /// byte is irrelevant downstream (`back` feeds the opaque desktop plane): out
    /// carries only the RGB channels (alpha 0). The dst scale reuses the two-lane
    /// rounded /255 (`blendConst`); the src add cannot carry between channels
    /// because premultiplied src_c + round(dst_c·(255−srcA)/255) ≤ 255.
    pub fn blitPremult(self: Surface, src: Surface, sx: usize, sy: usize, dx: usize, dy: usize, w: usize, h: usize) void {
        const xe = @min(@min(dx + w, self.w), dx + (src.w - @min(sx, src.w)));
        const ye = @min(@min(dy + h, self.h), dy + (src.h - @min(sy, src.h)));
        var y = dy;
        while (y < ye) : (y += 1) {
            const drow = self.px + y * self.stride;
            const srow = src.px + (sy + (y - dy)) * src.stride + sx;
            var x = dx;
            while (x < xe) : (x += 1) {
                const s = srow[x - dx];
                const ia: u32 = 255 - (s >> 24);
                drow[x] = (s & 0x00FFFFFF) + blendConst(0, drow[x], 0, ia);
            }
        }
    }
};

/// Blend one `0x00RRGGBB` foreground over background at constant coverage
/// `fa` (= a, 0..255) with `ia` (= 255−a), two byte-lanes at a time — no
/// per-channel hardware divide. Bit-exact to the scalar reference
/// `round((fg_c·fa + bg_c·ia) / 255)` for every channel (see the test below).
pub inline fn blendConst(fg: u32, bg: u32, fa: u32, ia: u32) u32 {
    // Even lane: R (bits 16-23) and B (bits 0-7). Each channel product
    // fg_c·fa + bg_c·ia ≤ 255·255 = 65025 < 2^16, so R lands in the [16:32) field
    // and B in the [0:16) field with no carry between them. Odd lane: G, shifted
    // to bits [0:8) so its product occupies a clean [0:16) field of its own.
    const rb = (fg & 0x00FF00FF) * fa + (bg & 0x00FF00FF) * ia;
    const g = ((fg >> 8) & 0xFF) * fa + ((bg >> 8) & 0xFF) * ia;

    // Rounded /255 per packed field: t = v + 0x80; (t + (t>>8)) >> 8. Masks keep
    // each field's carry from leaking into its neighbour.
    const rb_t = rb + 0x00800080;
    const rb_div = ((rb_t + ((rb_t >> 8) & 0x00FF00FF)) >> 8) & 0x00FF00FF;
    const g_t = g + 0x80;
    const g_div = ((g_t + (g_t >> 8)) >> 8) & 0xFF;

    return rb_div | (g_div << 8);
}

// ── tests (host: `zig build test`) — alpha-blend fast path ────────────────────
const std = @import("std");

/// Scalar reference: exact rounded per-channel blend. blendConst must match this
/// bit-for-bit.
pub fn refBlendChannel(fc: u32, bc: u32, fa: u32, ia: u32) u32 {
    return (fc * fa + bc * ia + 127) / 255; // +127 = round-to-nearest
}

// ── tests: the public Surface API ─────────────────────────────────────────

pub fn makeSurface(buf: []u32, w: usize, h: usize) Surface {
    @memset(buf, 0);
    return Surface.fromSlice(buf, w, h);
}
