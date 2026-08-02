//! kgl — kudos GL, the 2D rendering library. A formal layer above OpenGL ES: the window
//! manager draws through kgl, and kgl is the only thing above `gles` that names `gles`.
//!
//! The stack is `window manager → kgl → gles → the 4090`, each layer speaking only to the
//! API of the one below. Chrome, the dock and 2D apps hold a `Painter` and call
//! `fillRoundedRect`, `disc`, `image`, `text`; none of them import `gles` or name a
//! `gles.Context`. That is the point of the layer: the UI is written against a small,
//! stable 2D vocabulary, and everything about how those shapes become triangles on a GPU —
//! the tessellation, the premultiplied blend, the texture environment — lives here, once.
//!
//! ## It batches
//!
//! A naive 2D layer issues one GPU draw per rectangle. This one accumulates every shape
//! into one growing vertex array and flushes it as a single `glDrawArrays` — breaking the
//! batch only when the bound texture must change (flat fills share a 1×1 white texture, so
//! a window body and its three traffic lights are one draw; the title text is a second).
//! A whole window's chrome is two or three draws rather than a dozen. The batch buffers
//! are allocated once at `init` and reused every frame, so steady-state drawing never
//! allocates.
//!
//! ## One pipeline
//!
//! Everything is drawn textured with a per-vertex colour under MODULATE: a flat fill
//! samples the white texel, so `white × colour = colour`; glyph coverage comes from a
//! luminance-alpha atlas, so `coverage × colour` is the glyph in its colour; an image
//! samples its own texels tinted by the colour. Colours are `0xAARRGGBB`, premultiplied
//! here because the blend is premultiplied-over (`src + dst·(1−srcA)`) — so a translucent
//! panel composites the same whether it lands on wallpaper or another window.

const std = @import("std");
const gles = @import("gles");
const geom = @import("geom.zig");
// A NAMED import, not a relative one: the packed glyph sheet (glyphcache.zig) is
// built outside this module and handed back in, so both sides must see the same
// `gltext.Glyph` type — two module instances of one file are two distinct types.
const gltext = @import("gltext");

/// Vertices held before a flush. One growing array; a shape that would overflow it forces
/// an early flush, so the cap bounds latency and memory, not what can be drawn. 4096
/// vertices is a few hundred shapes — comfortably a whole window's chrome — at 128 KiB
/// across the three arrays.
const MAX_VERTS: u32 = 4096;

/// The `image` tint that leaves the texture's own colours untouched — the pipeline
/// MODULATEs the texel by the vertex colour, and white is its identity.
pub const UNTINTED: u32 = 0xFFFFFFFF;

/// The glyph-atlas layout a caller hands to `text`. Re-exported from `gltext` so a caller
/// above this layer needs only `paint` — the 2D library is its whole vocabulary. Built
/// from the font by whatever uploads the atlas (see `uploadAtlas`).
pub const Atlas = gltext.Atlas;

/// The pixel width `text` advances for `str` — for centring and right-aligning a label
/// without the caller reaching into the text layer itself.
pub fn textWidth(atlas: Atlas, str: []const u8) f32 {
    return gltext.width(atlas, str);
}

/// Split `0xAARRGGBB` into premultiplied 0..1 components.
fn premul(c: u32) [4]f32 {
    const a = @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0;
    const r = @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0 * a;
    const g = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0 * a;
    const b = @as(f32, @floatFromInt(c & 0xFF)) / 255.0 * a;
    return .{ r, g, b, a };
}

/// A batched 2D drawing context over one `gles` context. Create it once with `init`, then
/// each frame call `begin`, issue shapes, and `end`. It owns no gles resources except the
/// 1×1 white texture; the caller owns the gles context.
pub const Painter = struct {
    g: *gles.Context = undefined,
    /// Interleaved would pack tighter, but three arrays let `gles` take three client
    /// pointers once and reuse them across every flush.
    pos: []f32, // 2 per vertex
    uv: []f32, // 2 per vertex
    col: []f32, // 4 per vertex
    n: u32 = 0, // vertices staged in the current batch
    tex: u32 = 0, // texture the staged vertices sample (0 before the first shape)
    white: u32 = 0, // 1×1 white texture; a flat fill's vertices sample this
    /// Added to every vertex position, so a caller draws a window's chrome in window-local
    /// coordinates and just moves the origin — no gles matrix change to break the batch.
    ox: f32 = 0,
    oy: f32 = 0,

    /// Allocate the batch buffers once. Freed by `deinit`.
    pub fn init(alloc: std.mem.Allocator) !Painter {
        return .{
            .pos = try alloc.alloc(f32, MAX_VERTS * 2),
            .uv = try alloc.alloc(f32, MAX_VERTS * 2),
            .col = try alloc.alloc(f32, MAX_VERTS * 4),
        };
    }

    pub fn deinit(self: *Painter, alloc: std.mem.Allocator) void {
        alloc.free(self.pos);
        alloc.free(self.uv);
        alloc.free(self.col);
    }

    /// Open a screen-space 2D frame on `g`: an orthographic projection with the origin at
    /// the top-left and y increasing downward, no depth or culling, premultiplied-alpha
    /// blending, and the vertex/texcoord/colour client arrays pointed at the batch. Call
    /// once after the gles frame's `beginFrame`, before any shape.
    pub fn begin(self: *Painter, g: *gles.Context, w: u32, h: u32) void {
        self.g = g;
        self.n = 0;
        self.tex = 0;
        self.ox = 0;
        self.oy = 0;
        if (self.white == 0) self.white = uploadWhite(g);

        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        // The context's viewport/scissor persist across whoever drew last (a window's
        // inline 3D confines them to its content rect) — 2D is whole-frame, so say so.
        gles.viewport(g, 0, 0, @intCast(w), @intCast(h));
        gles.disable(g, gles.GL_SCISSOR_TEST);
        gles.matrixMode(g, gles.GL_PROJECTION);
        gles.loadIdentity(g);
        gles.orthof(g, 0, fw, fh, 0, -1, 1); // y down: top-left origin
        gles.matrixMode(g, gles.GL_MODELVIEW);
        gles.loadIdentity(g);
        gles.disable(g, gles.GL_DEPTH_TEST);
        gles.disable(g, gles.GL_CULL_FACE);
        gles.disable(g, gles.GL_LIGHTING);
        gles.enable(g, gles.GL_BLEND);
        gles.blendFunc(g, gles.GL_ONE, gles.GL_ONE_MINUS_SRC_ALPHA); // premultiplied over
        gles.enable(g, gles.GL_TEXTURE_2D);
        // These are CLIENT arrays, and the specification makes that depend on ambient
        // state: with a buffer bound to GL_ARRAY_BUFFER, the *Pointer calls below would
        // mean "offset into that buffer" instead — and whatever bound one last (a model
        // upload on this shared context) would turn our CPU addresses into wild device
        // offsets. Unbind first; the painter's meaning must not depend on who drew
        // before it.
        gles.bindBuffer(g, gles.GL_ARRAY_BUFFER, 0);
        gles.enableClientState(g, gles.GL_VERTEX_ARRAY);
        gles.enableClientState(g, gles.GL_TEXTURE_COORD_ARRAY);
        gles.enableClientState(g, gles.GL_COLOR_ARRAY);
        gles.vertexPointer(g, 2, gles.GL_FLOAT, 0, self.pos.ptr);
        gles.texCoordPointer(g, 2, gles.GL_FLOAT, 0, self.uv.ptr);
        gles.colorPointer(g, 4, gles.GL_FLOAT, 0, self.col.ptr);
    }

    /// Finish the frame: draw whatever is still staged.
    pub fn end(self: *Painter) void {
        self.flush();
    }

    /// Move the origin subsequent shapes are drawn relative to (window-local → screen).
    pub fn setOrigin(self: *Painter, x: f32, y: f32) void {
        self.ox = x;
        self.oy = y;
    }

    /// Emit the staged vertices as one draw and empty the batch.
    fn flush(self: *Painter) void {
        if (self.n == 0) return;
        gles.bindTexture(self.g, gles.GL_TEXTURE_2D, self.tex);
        gles.drawArrays(self.g, gles.GL_TRIANGLES, 0, @intCast(self.n));
        self.n = 0;
    }

    /// Make room for `verts` more vertices sampling `tex`: flush first if the texture must
    /// change or the batch would overflow. After this, `self.n + verts <= MAX_VERTS`.
    fn prepare(self: *Painter, tex: u32, verts: u32) void {
        std.debug.assert(verts <= MAX_VERTS);
        if (self.n != 0 and (self.tex != tex or self.n + verts > MAX_VERTS)) self.flush();
        self.tex = tex;
    }

    /// Append one vertex (position offset by the origin).
    fn vert(self: *Painter, x: f32, y: f32, u: f32, v: f32, c: [4]f32) void {
        const i = self.n;
        self.pos[i * 2] = x + self.ox;
        self.pos[i * 2 + 1] = y + self.oy;
        self.uv[i * 2] = u;
        self.uv[i * 2 + 1] = v;
        self.col[i * 4] = c[0];
        self.col[i * 4 + 1] = c[1];
        self.col[i * 4 + 2] = c[2];
        self.col[i * 4 + 3] = c[3];
        self.n += 1;
    }

    /// A triangle of flat colour sampling the white texel.
    fn triFlat(self: *Painter, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, c: [4]f32) void {
        self.vert(ax, ay, 0, 0, c);
        self.vert(bx, by, 0, 0, c);
        self.vert(cx, cy, 0, 0, c);
    }

    /// A solid-colour rectangle.
    pub fn fillRect(self: *Painter, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        self.prepare(self.white, 6);
        const c = premul(color);
        self.triFlat(x, y, x + w, y, x + w, y + h, c);
        self.triFlat(x, y, x + w, y + h, x, y + h, c);
    }

    /// A solid-colour line segment of the given width — an angled quad (two
    /// triangles) displaced along the segment's normal (geom.segmentQuad).
    /// MSAA anti-aliases the angled edges on the GPU. Clock hands, plot
    /// curves, and any other non-axis-aligned stroke draw through this.
    pub fn line(self: *Painter, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, color: u32) void {
        var q: [8]f32 = undefined;
        geom.segmentQuad(&q, x0, y0, x1, y1, width);
        self.prepare(self.white, 6);
        const c = premul(color);
        // The quad is in TRIANGLE_STRIP order (TL TR BL BR): two triangles.
        self.triFlat(q[0], q[1], q[2], q[3], q[4], q[5], c);
        self.triFlat(q[2], q[3], q[6], q[7], q[4], q[5], c);
    }

    /// A 1px rectangle outline (four edge fills) — panels and gauge borders.
    pub fn rect(self: *Painter, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        if (w < 2 or h < 2) return;
        self.fillRect(x, y, w, 1, color);
        self.fillRect(x, y + h - 1, w, 1, color);
        self.fillRect(x, y + 1, 1, h - 2, color);
        self.fillRect(x + w - 1, y + 1, 1, h - 2, color);
    }

    /// A rectangle whose colour blends from `top` to `bottom` — ONE quad whose vertex
    /// colours the GPU interpolates per pixel. This is how a wallpaper gradient is
    /// band-free: any stack of constant-colour strips quantises to visible bands, but
    /// interpolation is smooth at every pixel.
    pub fn fillRectGradientV(self: *Painter, x: f32, y: f32, w: f32, h: f32, top: u32, bottom: u32) void {
        self.prepare(self.white, 6);
        const ct = premul(top);
        const cb = premul(bottom);
        self.vert(x, y, 0, 0, ct);
        self.vert(x + w, y, 0, 0, ct);
        self.vert(x + w, y + h, 0, 0, cb);
        self.vert(x, y, 0, 0, ct);
        self.vert(x + w, y + h, 0, 0, cb);
        self.vert(x, y + h, 0, 0, cb);
    }

    /// A solid-colour rounded rectangle (a tessellated fan; MSAA anti-aliases the arcs on
    /// the GPU, the software backend leaves them crisp).
    pub fn fillRoundedRect(self: *Painter, x: f32, y: f32, w: f32, h: f32, radius: f32, color: u32) void {
        var fan: [geom.roundedRectFloats(geom.CORNER_SEGS)]f32 = undefined;
        const m = geom.roundedRect(&fan, x, y, w, h, radius, geom.CORNER_SEGS);
        self.fillFan(&fan, m, color);
    }

    /// A filled disc — the traffic-light buttons and dock running-dots.
    pub fn disc(self: *Painter, cx: f32, cy: f32, r: f32, color: u32) void {
        const SEGS: u32 = 24;
        var fan: [geom.discFloats(24)]f32 = undefined;
        const m = geom.disc(&fan, cx, cy, r, SEGS);
        self.fillFan(&fan, m, color);
    }

    /// Turn a triangle-fan outline (`fan[0]` the centre, the rest the perimeter closing
    /// back on its first point) into batched triangles.
    fn fillFan(self: *Painter, fan: []const f32, m: u32, color: u32) void {
        if (m < 3) return;
        const c = premul(color);
        const tris = m - 2;
        self.prepare(self.white, tris * 3);
        const cx = fan[0];
        const cy = fan[1];
        var i: u32 = 1;
        while (i < m - 1) : (i += 1) {
            self.triFlat(cx, cy, fan[i * 2], fan[i * 2 + 1], fan[(i + 1) * 2], fan[(i + 1) * 2 + 1], c);
        }
    }

    /// An image: `tex` scaled to (w,h) and tinted by `color` (0xFFFFFFFF draws it
    /// untinted). Dock icons and any picture.
    pub fn image(self: *Painter, tex: u32, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        self.prepare(tex, 6);
        const c = premul(color);
        // uv (0,0) top-left .. (1,1) bottom-right, matching the y-down projection.
        self.vert(x, y, 0, 0, c);
        self.vert(x + w, y, 1, 0, c);
        self.vert(x + w, y + h, 1, 1, c);
        self.vert(x, y, 0, 0, c);
        self.vert(x + w, y + h, 1, 1, c);
        self.vert(x, y + h, 0, 1, c);
    }

    /// Draw `str` at (x,y) in `color`, sampling the glyph atlas `atlas_tex` (upload it once
    /// with `uploadAtlas`). Batches with any adjacent text on the same atlas.
    pub fn text(self: *Painter, atlas_tex: u32, atlas: gltext.Atlas, str: []const u8, x: f32, y: f32, color: u32) void {
        self.textScaled(atlas_tex, atlas, str, x, y, 1, color);
    }

    /// `text` with every glyph cell scaled by `scale` (the dock's icon glyphs).
    /// Glyphs stay nearest-sampled, so scaled text renders
    /// chunky rather than blurred — the monospace look at every size.
    pub fn textScaled(self: *Painter, atlas_tex: u32, atlas: gltext.Atlas, str: []const u8, x: f32, y: f32, scale: f32, color: u32) void {
        const c = premul(color);
        const cell_h = atlas.cell_h * scale;
        var pen = x;
        for (str) |ch| {
            const adv = atlas.advance(ch) * scale;
            defer pen += adv;
            if (ch < atlas.first or ch >= atlas.first + atlas.count) continue;
            self.prepare(atlas_tex, 6);
            const i: f32 = @floatFromInt(ch - atlas.first);
            const nf: f32 = @floatFromInt(atlas.count);
            const v0 = i / nf;
            const v1 = (i + 1) / nf;
            // Proportional glyphs sample the `advance/cell_w` left slice of the cell.
            const ur: f32 = if (atlas.advances != null) atlas.advance(ch) / atlas.cell_w else 1;
            const x1 = pen + adv;
            const y1 = y + cell_h;
            self.vert(pen, y, 0, v0, c);
            self.vert(x1, y, ur, v0, c);
            self.vert(x1, y1, ur, v1, c);
            self.vert(pen, y, 0, v0, c);
            self.vert(x1, y1, ur, v1, c);
            self.vert(pen, y1, 0, v1, c);
        }
    }

    /// Draw `str` from a PACKED glyph sheet (baked by glyphcache.zig), with
    /// (`x`, `baseline`) the pen point on the baseline. This is the any-size text
    /// path: the sheet holds each glyph's own ink box at the size it was baked,
    /// so the result is true outline text rather than a scaled cell — and, because
    /// every size lives in one sheet, a line mixing sizes still batches into one
    /// draw. `text`/`textScaled` remain the fixed-cell terminal path.
    pub fn glyphText(self: *Painter, sheet_tex: u32, sheet: gltext.Sheet, str: []const u8, x: f32, baseline: f32, color: u32) void {
        const c = premul(color);
        var pen = x;
        for (str) |ch| {
            const g = sheet.glyph(ch) orelse continue;
            defer pen += g.advance;
            if (g.w == 0 or g.h == 0) continue; // blank (space): advance only
            self.prepare(sheet_tex, 6);
            const x0 = pen + g.left;
            const y0 = baseline + g.top;
            const x1 = x0 + g.w;
            const y1 = y0 + g.h;
            self.vert(x0, y0, g.u0, g.v0, c);
            self.vert(x1, y0, g.u1, g.v0, c);
            self.vert(x1, y1, g.u1, g.v1, c);
            self.vert(x0, y0, g.u0, g.v0, c);
            self.vert(x1, y1, g.u1, g.v1, c);
            self.vert(x0, y1, g.u0, g.v1, c);
        }
    }
};

/// Upload the glyph atlas (a `w × h` luminance-alpha strip, both channels the glyph
/// coverage — `font.ATLAS_LA`) as the texture `Painter.text` samples. `bytes.len == w*h*2`.
/// Linear filtered, clamped. Call once at init.
///
/// Luminance-alpha, NOT alpha: under MODULATE a GL_ALPHA texture samples rgb = 0, so
/// glColor-tinted text would be black; luminance-alpha carries the coverage in rgb as well,
/// so the glyph takes the text colour (premultiplied by coverage).
pub fn uploadAtlas(g: *gles.Context, w: u32, h: u32, bytes: []const u8) u32 {
    var tex: u32 = 0;
    gles.genTextures(g, 1, @ptrCast(&tex));
    gles.bindTexture(g, gles.GL_TEXTURE_2D, tex);
    // A glyph cell is an odd number of texels wide, so a row of w·2 bytes need not be a
    // multiple of the default 4-byte unpack alignment; tell GL the rows are byte-packed or
    // it reads padding that isn't there and shears every row.
    gles.pixelStorei(g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_LUMINANCE_ALPHA, @intCast(w), @intCast(h), 0, gles.GL_LUMINANCE_ALPHA, gles.GL_UNSIGNED_BYTE, bytes.ptr);
    // NEAREST, not LINEAR: glyphs draw at exactly 1:1 (integer cell positions), where
    // linear filtering only bleeds neighbouring texels into the edges and blurs the
    // text. Crisp text is nearest-sampled text.
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, gles.GL_NEAREST);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, gles.GL_CLAMP_TO_EDGE);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, gles.GL_CLAMP_TO_EDGE);
    return tex;
}

/// Upload a `w × h` BGRA8 image (rows top-down, tightly packed — the image
/// decoders' native layout) as a texture `image` can draw — a dock icon, a
/// thumbnail, any picture. Linear filtered, clamped. Call once per image at
/// init. Uploaded via GL_BGRA_EXT (spec RND-008), so the bytes store without
/// a per-texel swap; passing genuinely-RGBA bytes here renders channel-swapped.
pub fn uploadImage(g: *gles.Context, w: u32, h: u32, rgba: []const u8) u32 {
    var tex: u32 = 0;
    gles.genTextures(g, 1, @ptrCast(&tex));
    gles.bindTexture(g, gles.GL_TEXTURE_2D, tex);
    gles.pixelStorei(g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_BGRA_EXT, @intCast(w), @intCast(h), 0, gles.GL_BGRA_EXT, gles.GL_UNSIGNED_BYTE, rgba.ptr);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_LINEAR);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, gles.GL_LINEAR);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_S, gles.GL_CLAMP_TO_EDGE);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_WRAP_T, gles.GL_CLAMP_TO_EDGE);
    return tex;
}

/// The 1×1 opaque-white texture flat fills sample so one MODULATE pipeline serves shapes,
/// text and images alike.
fn uploadWhite(g: *gles.Context) u32 {
    var tex: u32 = 0;
    gles.genTextures(g, 1, @ptrCast(&tex));
    gles.bindTexture(g, gles.GL_TEXTURE_2D, tex);
    const px = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    gles.pixelStorei(g, gles.GL_UNPACK_ALIGNMENT, 1);
    gles.texImage2D(g, gles.GL_TEXTURE_2D, 0, gles.GL_RGBA, 1, 1, 0, gles.GL_RGBA, gles.GL_UNSIGNED_BYTE, &px);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MIN_FILTER, gles.GL_NEAREST);
    gles.texParameteri(g, gles.GL_TEXTURE_2D, gles.GL_TEXTURE_MAG_FILTER, gles.GL_NEAREST);
    return tex;
}
