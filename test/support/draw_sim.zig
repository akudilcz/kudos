//! DrawSim — the IDraw fake.
//!
//! The real device needs an RTX 4090 and a booted graphics engine. This does not, which
//! is the point: the OpenGL ES 1.1 state machine above the contract is pure code, and
//! its state tables, both numeric profiles, and the specification errors it raises can
//! all be exercised against this fake on the host, in seconds, with
//! no GPU in the room. The hardware then only has to answer one question: does the
//! method stream this lowering produces actually draw?
//!
//! There are no pixels here, and there are none in the real device either on the frame
//! path — finished frames are delivered GPU-side into the window's mirror. So the fake
//! records CALLS, and models the two things that are genuinely stateful:
//!
//!   * **The frame pipeline.** begin -> draw -> end -> ready (sticky) -> next begin
//!     consumes. `ready_after` models the pipelined fence: frameReady stays false for
//!     that many polls after each endFrame, so an app's not-ready-yet path gets
//!     exercised instead of being assumed.
//!
//!   * **Object lifetime.** Handles are allocated, freed, and REUSED. A handle used
//!     after its destroy is an error here, which is the whole reason to model it: the
//!     specification lets an application delete a texture that is still bound, and the
//!     rule for what happens next is subtle enough to be worth failing loudly about.
//!
//! Where the fake is deliberately stricter than the contract requires, it says so at
//! the check. Where it is looser, that is a bug in the fake.

const std = @import("std");
const idraw = @import("idraw");

/// Fake-only ceilings. The real device's limits come from VRAM; these exist so a test
/// can exhaust the pool without allocating anything, and are tunable per test.
pub const SIM_MAX_BUFFERS: u32 = 64;
pub const SIM_MAX_TEXTURES: u32 = 64;

/// What the fake claims when asked. Mirrors the floors the specification sets,
/// with room above them, so a test that asserts
/// `glGetIntegerv(GL_MAX_TEXTURE_SIZE)` is asserting against a plausible device.
pub const SIM_LIMITS = idraw.Limits{
    .max_texture_size = 8192,
    .texture_units = idraw.MAX_UNITS,
    .samples = 8,
    .subpixel_bits = 8,
};

fn bytesPerPixel(f: idraw.TexFormat) usize {
    return switch (f) {
        .bgra8 => 4,
        .luminance_alpha8 => 2,
        .luminance8, .alpha8 => 1,
    };
}

const Buffer = struct {
    alive: bool = false,
    len: usize = 0,
    usage: idraw.Usage = .static,
};

const Texture = struct {
    alive: bool = false,
    format: idraw.TexFormat = .bgra8,
    w: u32 = 0,
    h: u32 = 0,
    levels: u32 = 0,

    /// Dimensions of mip level `l`, halving and never reaching zero — the standard's
    /// chain, restated once here so the fake can check an update against the right
    /// rectangle.
    fn levelSize(self: Texture, l: u32) struct { w: u32, h: u32 } {
        return .{
            .w = @max(1, self.w >> @intCast(l)),
            .h = @max(1, self.h >> @intCast(l)),
        };
    }
};

pub const CtxSim = struct {
    in_use: bool = false,
    dst: idraw.Dst = undefined,
    recording: bool = false,
    in_flight: bool = false,
    landed: bool = false,

    frames_begun: u32 = 0,
    frames_ended: u32 = 0,
    draws: u32 = 0,
    clears: u32 = 0,
    discards: u32 = 0,
    reads: u32 = 0,

    last_w: u32 = 0,
    last_h: u32 = 0,
    /// The last draw, recorded whole. A Pipeline holds a `uniforms` slice pointing at
    /// the caller's memory; tests keep it alive, which is the normal shape of a test.
    last_pipeline: ?idraw.Pipeline = null,
    last_draw: ?idraw.Draw = null,
    last_clear_mask: idraw.ClearMask = .{},
    last_clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    last_clear_depth: f32 = 0,
    last_clear_stencil: u32 = 0,

    /// frameReady stays false this many polls after each endFrame before the frame
    /// "lands" — exercises the app's not-ready-yet path.
    ready_after: u32 = 0,
    ready_polls: u32 = 0,

    dev: *DrawSim = undefined,

    pub fn iface(self: *CtxSim) idraw.IDrawCtx {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = idraw.IDrawCtx.VTable{
        .beginFrame = beginFrame,
        .clear = clear,
        .draw = draw,
        .readPixels = readPixels,
        .endFrame = endFrame,
        .frameReady = frameReady,
        .discard = discard,
    };

    fn cast(ctx: *anyopaque) *CtxSim {
        return @ptrCast(@alignCast(ctx));
    }

    fn beginFrame(ctx: *anyopaque, w: u32, h: u32) idraw.Error!void {
        const self = cast(ctx);
        if (w == 0 or h == 0 or w > idraw.MAX_W or h > idraw.MAX_H)
            return idraw.Error.DrawBadViewport;
        // One frame in flight PER CONTEXT — never a device-wide interlock.
        if (self.recording or self.in_flight) return idraw.Error.DrawBusy;
        self.recording = true;
        self.landed = false; // consuming the previous frame
        self.frames_begun += 1;
        self.last_w = w;
        self.last_h = h;
    }

    fn clear(ctx: *anyopaque, m: idraw.ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?idraw.Rect) idraw.Error!void {
        _ = sc;
        const self = cast(ctx);
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        self.clears += 1;
        self.last_clear_mask = m;
        self.last_clear_color = color;
        self.last_clear_depth = depth;
        self.last_clear_stencil = stencil;
    }

    fn draw(ctx: *anyopaque, p: *const idraw.Pipeline, d: *const idraw.Draw) idraw.Error!void {
        const self = cast(ctx);
        if (!self.recording) return idraw.Error.DrawDeviceLost;

        // Every buffer this draw names must still be alive. The specification permits
        // deleting a bound object, so the layer above is required to have unbound it;
        // this is where that mistake surfaces instead of becoming a GPU fault.
        for (d.attribs) |a| switch (a) {
            .array => |arr| if (!self.dev.bufferAlive(arr.buffer)) return idraw.Error.DrawBadBuffer,
            .disabled, .constant => {},
        };
        if (d.index) |ix| if (!self.dev.bufferAlive(ix.buffer)) return idraw.Error.DrawBadBuffer;

        // Likewise every texture the key says contributes.
        for (p.units[0..], 0..) |maybe_unit, i| {
            if (maybe_unit) |u| {
                if (i >= p.key.units) return idraw.Error.DrawBadTexture; // key disagrees with bindings
                if (!self.dev.textureAlive(u.texture)) return idraw.Error.DrawBadTexture;
            } else if (i < p.key.units) return idraw.Error.DrawBadTexture;
        }

        if (p.key.lights > 8) return idraw.Error.DrawBadViewport; // the key cannot express it; belt and braces
        self.draws += 1;
        self.last_pipeline = p.*;
        self.last_draw = d.*;
    }

    fn readPixels(ctx: *anyopaque, r: idraw.Rect, fmt: idraw.ReadFormat, dst: []u8) idraw.Error!void {
        const self = cast(ctx);
        if (!self.recording) return idraw.Error.DrawDeviceLost;
        const need = @as(usize, r.w) * @as(usize, r.h) * 4;
        if (dst.len < need) return idraw.Error.DrawBadViewport;
        // No pixels exist, so hand back something deterministic and format-dependent:
        // a test can then prove the ES layer honoured the requested channel order
        // rather than passing bytes through unread.
        const tag: u8 = switch (fmt) {
            .rgba8 => 0xA0,
            .bgra8 => 0xB0,
        };
        @memset(dst[0..need], tag);
        self.reads += 1;
    }

    fn endFrame(ctx: *anyopaque) idraw.Error!void {
        const self = cast(ctx);
        if (!self.recording) return idraw.Error.DrawDeviceLost; // no beginFrame
        self.recording = false;
        self.frames_ended += 1;
        self.in_flight = true;
        self.ready_polls = 0;
    }

    fn frameReady(ctx: *anyopaque) bool {
        const self = cast(ctx);
        if (self.in_flight) {
            if (self.ready_polls < self.ready_after) {
                self.ready_polls += 1;
                return false;
            }
            self.in_flight = false;
            self.landed = true; // the frame "reached the mirror"
        }
        return self.landed; // sticky until the next beginFrame
    }

    fn discard(ctx: *anyopaque) void {
        const self = cast(ctx);
        self.recording = false;
        self.in_flight = false;
        self.landed = false;
        self.discards += 1;
    }
};

pub const DrawSim = struct {
    buffers: [SIM_MAX_BUFFERS]Buffer = .{Buffer{}} ** SIM_MAX_BUFFERS,
    textures: [SIM_MAX_TEXTURES]Texture = .{Texture{}} ** SIM_MAX_TEXTURES,

    /// Effective pool sizes for tests (<= the SIM_MAX_* ceilings).
    max_buffers: u32 = SIM_MAX_BUFFERS,
    max_textures: u32 = SIM_MAX_TEXTURES,
    max_ctx: u32 = idraw.MAX_CTX,

    limits_val: idraw.Limits = SIM_LIMITS,

    pool: [idraw.MAX_CTX]CtxSim = .{CtxSim{}} ** idraw.MAX_CTX,
    acquires: u32 = 0,
    releases: u32 = 0,
    buffers_created: u32 = 0,
    buffers_destroyed: u32 = 0,
    textures_created: u32 = 0,
    textures_destroyed: u32 = 0,

    pub fn iface(self: *DrawSim) idraw.IDraw {
        // Records calls without producing pixels; delivery is moot, so say mirror.
        return .{ .ctx = self, .vtable = &vtable, .delivers_in_place = false };
    }

    const vtable = idraw.IDraw.VTable{
        .bufferCreate = bufferCreate,
        .bufferUpdate = bufferUpdate,
        .bufferDestroy = bufferDestroy,
        .textureCreate = textureCreate,
        .textureUpdate = textureUpdate,
        .textureDestroy = textureDestroy,
        .limits = limits,
        .acquire = acquire,
        .release = release,
    };

    fn cast(ctx: *anyopaque) *DrawSim {
        return @ptrCast(@alignCast(ctx));
    }

    // Handles are 1-based so that zero is never a valid one: the specification uses 0
    // to mean "no object bound", and a fake that let 0 work would hide the layer above
    // failing to notice.
    fn bufferAlive(self: *DrawSim, h: idraw.BufferHandle) bool {
        return h >= 1 and h <= self.max_buffers and self.buffers[h - 1].alive;
    }
    fn textureAlive(self: *DrawSim, h: idraw.TextureHandle) bool {
        return h >= 1 and h <= self.max_textures and self.textures[h - 1].alive;
    }

    fn bufferCreate(ctx: *anyopaque, bytes: []const u8, usage: idraw.Usage) idraw.Error!idraw.BufferHandle {
        const self = cast(ctx);
        for (self.buffers[0..self.max_buffers], 0..) |*b, i| {
            if (b.alive) continue;
            b.* = .{ .alive = true, .len = bytes.len, .usage = usage };
            self.buffers_created += 1;
            return @intCast(i + 1);
        }
        return idraw.Error.DrawOutOfResources;
    }

    fn bufferUpdate(ctx: *anyopaque, h: idraw.BufferHandle, off: u32, bytes: []const u8) idraw.Error!void {
        const self = cast(ctx);
        if (!self.bufferAlive(h)) return idraw.Error.DrawBadBuffer;
        // An update may not grow the buffer: the contract says so, and a device that
        // silently reallocated would move an address the GPU already holds.
        if (@as(usize, off) + bytes.len > self.buffers[h - 1].len) return idraw.Error.DrawBadBuffer;
    }

    fn bufferDestroy(ctx: *anyopaque, h: idraw.BufferHandle) void {
        const self = cast(ctx);
        if (!self.bufferAlive(h)) return; // destroying a dead handle is a no-op, not a fault
        self.buffers[h - 1].alive = false;
        self.buffers_destroyed += 1;
    }

    fn textureCreate(ctx: *anyopaque, d: idraw.TexDesc) idraw.Error!idraw.TextureHandle {
        const self = cast(ctx);
        if (d.levels.len == 0) return idraw.Error.DrawBadTexture;
        const base = d.levels[0];
        if (base.w == 0 or base.h == 0) return idraw.Error.DrawBadTexture;
        if (base.w > self.limits_val.max_texture_size or base.h > self.limits_val.max_texture_size)
            return idraw.Error.DrawBadTexture;

        // Every level must be the right size for its place in the chain, and carry
        // exactly its pixels. A short slice here is a buffer overrun on real hardware.
        const bpp = bytesPerPixel(d.format);
        for (d.levels, 0..) |lv, l| {
            const want_w = @max(1, base.w >> @intCast(l));
            const want_h = @max(1, base.h >> @intCast(l));
            if (lv.w != want_w or lv.h != want_h) return idraw.Error.DrawBadTexture;
            if (lv.pixels.len != @as(usize, lv.w) * lv.h * bpp) return idraw.Error.DrawBadTexture;
        }

        for (self.textures[0..self.max_textures], 0..) |*t, i| {
            if (t.alive) continue;
            t.* = .{
                .alive = true,
                .format = d.format,
                .w = base.w,
                .h = base.h,
                .levels = @intCast(d.levels.len),
            };
            self.textures_created += 1;
            return @intCast(i + 1);
        }
        return idraw.Error.DrawOutOfResources;
    }

    fn textureUpdate(ctx: *anyopaque, h: idraw.TextureHandle, level: u32, r: idraw.Rect, px: []const u8) idraw.Error!void {
        const self = cast(ctx);
        if (!self.textureAlive(h)) return idraw.Error.DrawBadTexture;
        const t = self.textures[h - 1];
        if (level >= t.levels) return idraw.Error.DrawBadTexture;
        const size = t.levelSize(level);
        if (r.x < 0 or r.y < 0) return idraw.Error.DrawBadTexture;
        const x: u32 = @intCast(r.x);
        const y: u32 = @intCast(r.y);
        if (x + r.w > size.w or y + r.h > size.h) return idraw.Error.DrawBadTexture;
        if (px.len != @as(usize, r.w) * r.h * bytesPerPixel(t.format)) return idraw.Error.DrawBadTexture;
    }

    fn textureDestroy(ctx: *anyopaque, h: idraw.TextureHandle) void {
        const self = cast(ctx);
        if (!self.textureAlive(h)) return;
        self.textures[h - 1].alive = false;
        self.textures_destroyed += 1;
    }

    fn limits(ctx: *anyopaque) idraw.Limits {
        return cast(ctx).limits_val;
    }

    fn acquire(ctx: *anyopaque, dst: idraw.Dst) ?idraw.IDrawCtx {
        const self = cast(ctx);
        var i: u32 = 0;
        while (i < self.max_ctx) : (i += 1) {
            const c = &self.pool[i];
            if (c.in_use) continue;
            c.* = .{ .in_use = true, .dst = dst, .dev = self };
            self.acquires += 1;
            return c.iface();
        }
        return null; // pool exhausted
    }

    fn release(ctx: *anyopaque, c: idraw.IDrawCtx) void {
        const self = cast(ctx);
        const sim: *CtxSim = @ptrCast(@alignCast(c.ctx));
        sim.in_use = false;
        self.releases += 1;
    }
};

// ── contract tests ───────────────────────────────────────────────────────────

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const DST = idraw.Dst{ .win_base = 0x1000, .stride_px = 640, .off_x = 1, .off_y = 23 };

/// A minimal drawable state: no lights, no textures, no fog — the simplest thing the
/// key can express, so a test about frame lifecycle is not also a test about lighting.
fn plainPipeline() idraw.Pipeline {
    return .{
        .key = .{ .lights = 0, .units = 0, .two_sided = false, .fog = .off },
        .viewport = .{ .x = 0, .y = 0, .w = 64, .h = 32 },
        .depth_range = .{ 0, 1 },
        .scissor = null,
        .raster = .{ .cull = null, .front_face = .ccw, .poly_offset_factor = 0, .poly_offset_units = 0, .line_width = 1 },
        .depth = .{ .test_enable = true, .write = true, .func = .less },
        .stencil = .{ .test_enable = false, .func = .always, .ref = 0, .read_mask = ~@as(u32, 0), .write_mask = ~@as(u32, 0), .fail = .keep, .depth_fail = .keep, .depth_pass = .keep },
        .blend = .{ .enable = false, .src = .one, .dst = .zero },
        .logic_op = null,
        .alpha_test = null,
        .color_mask = .{ true, true, true, true },
        .dither = true,
        .sample_coverage = .{ .enable = false, .value = 1, .invert = false },
        .units = .{null} ** idraw.MAX_UNITS,
        .mat_maps = .{null} ** idraw.MatMap.COUNT,
        .uniforms = &.{},
    };
}

fn arrayDraw(vb: idraw.BufferHandle, count: u32) idraw.Draw {
    var attribs = [_]idraw.Attrib{.disabled} ** idraw.AttribSlot.COUNT;
    attribs[@intFromEnum(idraw.AttribSlot.position)] = .{ .array = .{
        .buffer = vb,
        .offset = 0,
        .stride = 12,
        .format = .f32x3,
    } };
    attribs[@intFromEnum(idraw.AttribSlot.color)] = .{ .constant = .{ 1, 1, 1, 1 } };
    return .{ .prim = .triangles, .attribs = attribs, .first = 0, .count = count, .index = null };
}

test "full frame cycle: begin → clear → draw → end → ready (sticky) → next begin consumes" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const vb = try dev.bufferCreate(&([_]u8{0} ** 36), .static);
    const c = dev.acquire(DST).?;
    const p = plainPipeline();
    const d = arrayDraw(vb, 3);

    try expect(!c.frameReady()); // nothing in flight
    try c.beginFrame(64, 32);
    try c.clear(.{ .color = true, .depth = true }, .{ 0, 0, 0, 1 }, 1.0, 0, null);
    try c.draw(&p, &d);
    try c.endFrame();
    try expect(c.frameReady()); // landed
    try expect(c.frameReady()); // sticky — the app polls it more than once
    try c.beginFrame(64, 32); // consumes
    try expect(!c.frameReady());
    try c.endFrame();
}

test "pipelined not-ready gating (ready_after)" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const c = dev.acquire(DST).?;
    const cs: *CtxSim = @ptrCast(@alignCast(c.ctx));
    cs.ready_after = 2;
    try c.beginFrame(8, 8);
    try c.endFrame();
    try expect(!c.frameReady()); // poll 1
    try expect(!c.frameReady()); // poll 2
    try expect(c.frameReady()); // fences "retired" — the frame is in the mirror
}

test "contexts are independent: one window in flight never blocks another" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const a = dev.acquire(DST).?;
    const b = dev.acquire(DST).?;
    const as: *CtxSim = @ptrCast(@alignCast(a.ctx));
    as.ready_after = 1000; // A's frame stays in flight "forever"
    try a.beginFrame(8, 8);
    try a.endFrame();
    try expect(!a.frameReady());
    // B's pipeline is untouched by A's in-flight frame — the second-teapot regression:
    // with a single shared slot this returned DrawBusy.
    try b.beginFrame(8, 8);
    try b.endFrame();
    try expect(b.frameReady());
    // A itself IS busy until its own frame retires.
    try expectError(idraw.Error.DrawBusy, a.beginFrame(8, 8));
}

test "pool exhaustion and recycle" {
    var sim = DrawSim{ .max_ctx = 2 };
    const dev = sim.iface();
    const a = dev.acquire(DST).?;
    const b = dev.acquire(DST).?;
    try expect(dev.acquire(DST) == null); // exhausted → the app draws a placeholder
    dev.release(a);
    const c2 = dev.acquire(DST).?; // slot recycled
    _ = b;
    _ = c2;
    try expectEqual(@as(u32, 3), sim.acquires);
}

test "discard frees the context's pipeline" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const c = dev.acquire(DST).?;
    try c.beginFrame(8, 8);
    try c.endFrame();
    c.discard(); // the owner's window closed mid-flight
    try c.beginFrame(8, 8); // pipeline recovered
    try c.endFrame();
    try expect(c.frameReady());
}

test "viewport validation" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const c = dev.acquire(DST).?;
    try expectError(idraw.Error.DrawBadViewport, c.beginFrame(0, 8));
    try expectError(idraw.Error.DrawBadViewport, c.beginFrame(idraw.MAX_W + 1, 8));
    try expectError(idraw.Error.DrawBadViewport, c.beginFrame(8, idraw.MAX_H + 1));
}

test "a command outside begin/end is refused rather than silently dropped" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const c = dev.acquire(DST).?;
    const p = plainPipeline();
    const d = arrayDraw(1, 3);
    try expectError(idraw.Error.DrawDeviceLost, c.clear(.{ .color = true }, .{ 0, 0, 0, 1 }, 1, 0, null));
    try expectError(idraw.Error.DrawDeviceLost, c.draw(&p, &d));
    try expectError(idraw.Error.DrawDeviceLost, c.endFrame());
}

test "buffers: create → update → destroy → handle reuse" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const a = try dev.bufferCreate(&([_]u8{0} ** 64), .static);
    try expectEqual(@as(idraw.BufferHandle, 1), a); // 1-based: zero means "no object"
    try dev.bufferUpdate(a, 0, &([_]u8{1} ** 64));
    try dev.bufferUpdate(a, 60, &([_]u8{1} ** 4)); // exactly to the end
    // An update may not grow it.
    try expectError(idraw.Error.DrawBadBuffer, dev.bufferUpdate(a, 61, &([_]u8{1} ** 4)));
    try expectError(idraw.Error.DrawBadBuffer, dev.bufferUpdate(a, 0, &([_]u8{1} ** 65)));

    dev.bufferDestroy(a);
    try expectError(idraw.Error.DrawBadBuffer, dev.bufferUpdate(a, 0, &([_]u8{1} ** 4)));
    dev.bufferDestroy(a); // destroying twice is a no-op, not a fault
    // The slot comes back.
    const b = try dev.bufferCreate(&([_]u8{0} ** 8), .dynamic);
    try expectEqual(a, b);
    try expectEqual(@as(u32, 1), sim.buffers_destroyed);
}

test "drawing from a destroyed buffer is caught here, not on the GPU" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const vb = try dev.bufferCreate(&([_]u8{0} ** 36), .static);
    const c = dev.acquire(DST).?;
    const p = plainPipeline();
    const d = arrayDraw(vb, 3);
    try c.beginFrame(64, 32);
    try c.draw(&p, &d); // fine
    dev.bufferDestroy(vb);
    try expectError(idraw.Error.DrawBadBuffer, c.draw(&p, &d));
    // A handle that never existed is refused the same way, including zero.
    try expectError(idraw.Error.DrawBadBuffer, c.draw(&p, &arrayDraw(0, 3)));
    try expectError(idraw.Error.DrawBadBuffer, c.draw(&p, &arrayDraw(999, 3)));
}

test "an index buffer's lifetime is checked too" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const vb = try dev.bufferCreate(&([_]u8{0} ** 36), .static);
    const ib = try dev.bufferCreate(&([_]u8{0} ** 6), .static);
    const c = dev.acquire(DST).?;
    const p = plainPipeline();
    var d = arrayDraw(vb, 3);
    d.index = .{ .buffer = ib, .offset = 0, .type = .u16 };
    try c.beginFrame(64, 32);
    try c.draw(&p, &d);
    dev.bufferDestroy(ib);
    try expectError(idraw.Error.DrawBadBuffer, c.draw(&p, &d));
}

test "textures: the mip chain must be the right shape and carry its pixels" {
    var sim = DrawSim{};
    const dev = sim.iface();
    // 4x4 BGRA8, three levels: 4x4, 2x2, 1x1.
    const l0 = [_]u8{0} ** (4 * 4 * 4);
    const l1 = [_]u8{0} ** (2 * 2 * 4);
    const l2 = [_]u8{0} ** (1 * 1 * 4);
    const t = try dev.textureCreate(.{ .format = .bgra8, .levels = &.{
        .{ .w = 4, .h = 4, .pixels = &l0 },
        .{ .w = 2, .h = 2, .pixels = &l1 },
        .{ .w = 1, .h = 1, .pixels = &l2 },
    } });
    try expectEqual(@as(idraw.TextureHandle, 1), t);

    // A level of the wrong size for its place in the chain.
    try expectError(idraw.Error.DrawBadTexture, dev.textureCreate(.{ .format = .bgra8, .levels = &.{
        .{ .w = 4, .h = 4, .pixels = &l0 },
        .{ .w = 3, .h = 3, .pixels = &l1 },
    } }));
    // A level whose pixels are short — an overrun on real hardware.
    try expectError(idraw.Error.DrawBadTexture, dev.textureCreate(.{ .format = .bgra8, .levels = &.{
        .{ .w = 4, .h = 4, .pixels = l0[0 .. l0.len - 1] },
    } }));
    // No levels at all, and a zero dimension.
    try expectError(idraw.Error.DrawBadTexture, dev.textureCreate(.{ .format = .bgra8, .levels = &.{} }));
    try expectError(idraw.Error.DrawBadTexture, dev.textureCreate(.{ .format = .bgra8, .levels = &.{
        .{ .w = 0, .h = 4, .pixels = &.{} },
    } }));
}

test "texture formats carry different bytes per pixel" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const one = [_]u8{0} ** (2 * 2 * 1);
    const two = [_]u8{0} ** (2 * 2 * 2);
    _ = try dev.textureCreate(.{ .format = .luminance8, .levels = &.{.{ .w = 2, .h = 2, .pixels = &one }} });
    _ = try dev.textureCreate(.{ .format = .alpha8, .levels = &.{.{ .w = 2, .h = 2, .pixels = &one }} });
    _ = try dev.textureCreate(.{ .format = .luminance_alpha8, .levels = &.{.{ .w = 2, .h = 2, .pixels = &two }} });
    // luminance8 is one byte per pixel, so a four-byte-per-pixel slice is wrong.
    try expectError(idraw.Error.DrawBadTexture, dev.textureCreate(.{ .format = .luminance8, .levels = &.{
        .{ .w = 2, .h = 2, .pixels = &two },
    } }));
}

test "textureUpdate stays inside the level it names" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const l0 = [_]u8{0} ** (4 * 4 * 4);
    const l1 = [_]u8{0} ** (2 * 2 * 4);
    const t = try dev.textureCreate(.{ .format = .bgra8, .levels = &.{
        .{ .w = 4, .h = 4, .pixels = &l0 },
        .{ .w = 2, .h = 2, .pixels = &l1 },
    } });
    const px = [_]u8{0} ** (2 * 2 * 4);
    try dev.textureUpdate(t, 0, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, &px);
    // Level 1 is 2x2, so the same rectangle at (1,1) runs off it.
    try expectError(idraw.Error.DrawBadTexture, dev.textureUpdate(t, 1, .{ .x = 1, .y = 1, .w = 2, .h = 2 }, &px));
    try dev.textureUpdate(t, 1, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px);
    // A level that does not exist.
    try expectError(idraw.Error.DrawBadTexture, dev.textureUpdate(t, 2, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, px[0..4]));
    // Pixels that do not match the rectangle.
    try expectError(idraw.Error.DrawBadTexture, dev.textureUpdate(t, 0, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, px[0..4]));
    dev.textureDestroy(t);
    try expectError(idraw.Error.DrawBadTexture, dev.textureUpdate(t, 0, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, &px));
}

test "the shader key must agree with the bindings it is drawn with" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const vb = try dev.bufferCreate(&([_]u8{0} ** 36), .static);
    const l0 = [_]u8{0} ** 4;
    const t = try dev.textureCreate(.{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} });
    const c = dev.acquire(DST).?;
    const d = arrayDraw(vb, 3);
    try c.beginFrame(64, 32);

    const unit = idraw.Unit{ .texture = t, .wrap_s = .repeat, .wrap_t = .repeat, .min = .linear, .mag = .linear, .mip = .none };

    // Key says one unit contributes, and one is bound: fine.
    var p = plainPipeline();
    p.key.units = 1;
    p.units[0] = unit;
    try c.draw(&p, &d);

    // Key says one unit, nothing bound.
    var p2 = plainPipeline();
    p2.key.units = 1;
    try expectError(idraw.Error.DrawBadTexture, c.draw(&p2, &d));

    // A unit bound the key does not account for.
    var p3 = plainPipeline();
    p3.key.units = 0;
    p3.units[0] = unit;
    try expectError(idraw.Error.DrawBadTexture, c.draw(&p3, &d));

    // A destroyed texture.
    var p4 = plainPipeline();
    p4.key.units = 1;
    p4.units[0] = unit;
    dev.textureDestroy(t);
    try expectError(idraw.Error.DrawBadTexture, c.draw(&p4, &d));
}

test "resource pools are loud when exhausted" {
    var sim = DrawSim{ .max_buffers = 2, .max_textures = 1 };
    const dev = sim.iface();
    _ = try dev.bufferCreate(&.{}, .static);
    _ = try dev.bufferCreate(&.{}, .static);
    try expectError(idraw.Error.DrawOutOfResources, dev.bufferCreate(&.{}, .static));
    const l0 = [_]u8{0} ** 4;
    const desc = idraw.TexDesc{ .format = .bgra8, .levels = &.{.{ .w = 1, .h = 1, .pixels = &l0 }} };
    _ = try dev.textureCreate(desc);
    try expectError(idraw.Error.DrawOutOfResources, dev.textureCreate(desc));
}

test "limits come from the device, so glGet never states what it cannot honour" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const l = dev.limits();
    // The floors the specification sets.
    try expect(l.max_texture_size >= 64);
    try expect(l.texture_units >= 1);
    try expect(l.subpixel_bits >= 4);
    try expect(l.samples >= 1);
}

test "readPixels needs room and reports the format it delivered" {
    var sim = DrawSim{};
    const dev = sim.iface();
    const c = dev.acquire(DST).?;
    var buf: [2 * 2 * 4]u8 = undefined;
    const r = idraw.Rect{ .x = 0, .y = 0, .w = 2, .h = 2 };
    try expectError(idraw.Error.DrawDeviceLost, c.readPixels(r, .rgba8, &buf)); // outside a frame
    try c.beginFrame(64, 32);
    try c.readPixels(r, .rgba8, &buf);
    try expectEqual(@as(u8, 0xA0), buf[0]);
    try c.readPixels(r, .bgra8, &buf);
    try expectEqual(@as(u8, 0xB0), buf[0]);
    // Too small a destination is refused rather than overrun.
    try expectError(idraw.Error.DrawBadViewport, c.readPixels(r, .rgba8, buf[0..8]));
    try expectEqual(@as(u32, 2), @as(*CtxSim, @ptrCast(@alignCast(c.ctx))).reads);
}
