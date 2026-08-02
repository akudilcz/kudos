//! The GL state vector — everything `glGet` can ask about, and nothing else.
//!
//! OpenGL is a state machine with a very large state and a very small set of verbs.
//! Almost every entry point in the API does one thing: it writes a field below. The
//! specification's §6.2 state tables ARE this struct, so the tables are what it is
//! checked against, field by field, including every initial value — those are
//! normative, and an application is entitled to draw correctly without setting any of
//! them.
//!
//! There is no current-context global. GL's C binding has one because C has no better
//! way to thread it, and every window would fight over it; here each context is passed
//! explicitly, and N windows each hold their own.
//!
//! Nothing in this file talks to hardware, allocates, or knows what a method stream is.
//! It is a value. `es/pipeline.zig` reads it and produces an `idraw.Pipeline`; that is
//! the only direction data flows.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §6.2 (state tables), §2.7 (current
//! vertex state), §3.7 (texture environment), §4 (per-fragment operations).

const std = @import("std");
const Allocator = std.mem.Allocator;
const idraw = @import("idraw");
const enums = @import("enums.zig");
const errors = @import("errors.zig");
const limits = @import("limits.zig");
pub const matrix = @import("matrix.zig");
const objects = @import("objects.zig");

pub const Mat4 = matrix.Mat4;

/// How a fragment's color is computed from a texel and what arrived — the state whose
/// combinatorics forced the texture environment to be interpreted rather than compiled.
pub const TexEnv = struct {
    /// GL_TEXTURE_ENV_MODE.
    mode: enum { replace, modulate, decal, blend, add, combine } = .modulate,
    color: [4]f32 = .{ 0, 0, 0, 0 },

    combine_rgb: enum { replace, modulate, add, add_signed, interpolate, subtract, dot3_rgb, dot3_rgba } = .modulate,
    combine_alpha: enum { replace, modulate, add, add_signed, interpolate, subtract } = .modulate,

    src_rgb: [3]Source = .{ .texture, .previous, .constant },
    src_alpha: [3]Source = .{ .texture, .previous, .constant },
    operand_rgb: [3]OperandRgb = .{ .src_color, .src_color, .src_alpha },
    operand_alpha: [3]OperandAlpha = .{ .src_alpha, .src_alpha, .src_alpha },

    rgb_scale: f32 = 1,
    alpha_scale: f32 = 1,

    /// OES_point_sprite COORD_REPLACE: on a point-sprite draw this unit samples
    /// the point's own (s, t) — the rasteriser's point coordinate — instead of
    /// the interpolated texture coordinate. Ignored for every other primitive.
    coord_replace: bool = false,

    pub const Source = enum { texture, constant, primary_color, previous };
    pub const OperandRgb = enum { src_color, one_minus_src_color, src_alpha, one_minus_src_alpha };
    pub const OperandAlpha = enum { src_alpha, one_minus_src_alpha };
};

/// One light. The initial values are the standard's, and they are not all the same:
/// light 0's diffuse and specular are white while every other light's are black, so a
/// program that enables lighting and light 0 and sets nothing else still sees something.
pub const Light = struct {
    ambient: [4]f32 = .{ 0, 0, 0, 1 },
    diffuse: [4]f32 = .{ 0, 0, 0, 1 },
    specular: [4]f32 = .{ 0, 0, 0, 1 },
    /// w = 0 makes it directional, w = 1 positional. In EYE coordinates: the standard
    /// transforms it by the modelview matrix *at the moment glLightfv is called*, which
    /// is a rule programs trip over constantly.
    position: [4]f32 = .{ 0, 0, 1, 0 },
    spot_direction: [3]f32 = .{ 0, 0, -1 },
    spot_exponent: f32 = 0,
    spot_cutoff: f32 = 180,
    constant_attenuation: f32 = 1,
    linear_attenuation: f32 = 0,
    quadratic_attenuation: f32 = 0,

    pub fn initial(index: u32) Light {
        var l = Light{};
        if (index == 0) {
            l.diffuse = .{ 1, 1, 1, 1 };
            l.specular = .{ 1, 1, 1, 1 };
        }
        return l;
    }
};

pub const Material = struct {
    ambient: [4]f32 = .{ 0.2, 0.2, 0.2, 1 },
    diffuse: [4]f32 = .{ 0.8, 0.8, 0.8, 1 },
    specular: [4]f32 = .{ 0, 0, 0, 1 },
    emission: [4]f32 = .{ 0, 0, 0, 1 },
    shininess: f32 = 0,
};

pub const Fog = struct {
    mode: idraw.FogMode = .exp,
    density: f32 = 1,
    start: f32 = 0,
    end: f32 = 1,
    color: [4]f32 = .{ 0, 0, 0, 0 },
};

/// One vertex array pointer, as `glVertexPointer` and its siblings set it.
///
/// `buffer` is the buffer object bound to GL_ARRAY_BUFFER *when the pointer was set* —
/// the binding is captured at that moment, not at draw time, which is one of GL's
/// sharper edges. Zero means client memory, and `ptr` is then an application pointer we
/// must copy from at draw time.
pub const ArrayPointer = struct {
    enabled: bool = false,
    size: u32 = 4,
    type: DataType = .float,
    stride: u32 = 0,
    ptr: ?[*]const u8 = null,
    buffer: u32 = 0,

    pub const DataType = enum { byte, ubyte, short, ushort, fixed, float };
};

/// The capability bits `glEnable`/`glDisable` toggle. Every one starts disabled except
/// dither, which the standard starts on.
pub const Caps = struct {
    lighting: bool = false,
    light: [limits.MAX_LIGHTS]bool = .{false} ** limits.MAX_LIGHTS,
    clip_plane: [limits.MAX_CLIP_PLANES]bool = .{false} ** limits.MAX_CLIP_PLANES,
    texture_2d: [limits.MAX_TEXTURE_UNITS]bool = .{false} ** limits.MAX_TEXTURE_UNITS,
    cull_face: bool = false,
    fog: bool = false,
    depth_test: bool = false,
    stencil_test: bool = false,
    scissor_test: bool = false,
    alpha_test: bool = false,
    blend: bool = false,
    color_logic_op: bool = false,
    dither: bool = true, // the one that starts on
    normalize: bool = false,
    rescale_normal: bool = false,
    color_material: bool = false,
    polygon_offset_fill: bool = false,
    multisample: bool = true, // starts on, per the state tables
    sample_alpha_to_coverage: bool = false,
    sample_alpha_to_one: bool = false,
    sample_coverage: bool = false,
    point_smooth: bool = false,
    line_smooth: bool = false,
    point_sprite: bool = false,
};

pub const Viewport = struct { x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 };

/// A GL context: the whole state vector, plus the device it will eventually draw
/// through.
pub const Context = struct {
    // ── the device this context lowers onto ──
    dev: idraw.IDraw,
    target: idraw.IDrawCtx,
    dev_limits: idraw.Limits,

    /// For buffer shadows and the draw path's staging. Every allocation it makes is
    /// grow-only and reused, so a steady-state frame allocates nothing — the compositor
    /// calls draw() and must not wait on a heap.
    alloc: Allocator,

    /// Where client-side and widened arrays are gathered before upload. Grown, never
    /// shrunk; `staging_buf` is its device counterpart and `staging_cap` that buffer's
    /// size, which is what makes the growth check cheap enough to do every draw.
    staging: []u8 = &.{},
    staging_buf: ?idraw.BufferHandle = null,
    staging_cap: usize = 0,

    /// The frame's write cursor into `staging_buf`. A device is allowed to DEFER every
    /// draw to one submit at the end of the frame (the hardware backend does), so two
    /// draws in one frame must never overwrite each other's staged bytes — each draw
    /// appends at this cursor and carries its offset in the draw itself. beginFrame
    /// resets it; a frame's staged data all coexists until the frame lands.
    staging_used: usize = 0,

    /// Device buffers outgrown MID-frame. They cannot be destroyed at that moment —
    /// this frame's earlier draws may still be queued against them on a deferring
    /// device — so they wait here and are destroyed at the next successful beginFrame,
    /// when the device has proven the previous frame fully landed. Sixteen slots with
    /// geometric buffer growth is unreachable (16 doublings from the floor exceeds any
    /// device heap); if it somehow fills, the draw is refused rather than corrupted.
    retired: [16]idraw.BufferHandle = undefined,
    retired_n: usize = 0,

    err: errors.Flag = .{},

    /// The frame's size, from beginFrame. GL measures y UP from the bottom and the
    /// framebuffer measures it DOWN from the top, so every rectangle that crosses the
    /// lowering needs this to flip against. Zero until a frame is open.
    frame_w: u32 = 0,
    frame_h: u32 = 0,

    // ── §2.10 coordinate transformation ──
    matrix_mode: matrix.Mode = .modelview,
    modelview: matrix.ModelviewStack = .{},
    projection: matrix.ProjectionStack = .{},
    texture_matrix: [limits.MAX_TEXTURE_UNITS]matrix.TextureStack = .{matrix.TextureStack{}} ** limits.MAX_TEXTURE_UNITS,
    viewport: Viewport = .{},
    depth_range: [2]f32 = .{ 0, 1 },
    /// Stored in EYE coordinates: the standard transforms a plane by the inverse
    /// modelview at the moment glClipPlane is called.
    clip_plane: [limits.MAX_CLIP_PLANES][4]f32 = .{.{ 0, 0, 0, 0 }} ** limits.MAX_CLIP_PLANES,

    // ── §2.7 current vertex state ──
    color: [4]f32 = .{ 1, 1, 1, 1 },
    normal: [3]f32 = .{ 0, 0, 1 },
    texcoord: [limits.MAX_TEXTURE_UNITS][4]f32 = .{.{ 0, 0, 0, 1 }} ** limits.MAX_TEXTURE_UNITS,
    point_size: f32 = 1,

    // ── §2.8 vertex arrays ──
    arrays: [idraw.AttribSlot.COUNT]ArrayPointer = .{ArrayPointer{}} ** idraw.AttribSlot.COUNT,
    active_texture: u32 = 0,
    client_active_texture: u32 = 0,
    array_buffer: u32 = 0,
    element_array_buffer: u32 = 0,

    // ── object name tables (§2.9, §3.7.13) ──
    // A name becomes an object when it is first bound, not when it is generated; the
    // table keeps that distinction, which glIsBuffer/glIsTexture exist to report.
    buffers: objects.Table = .{},
    textures: objects.Table = .{},

    // ── §2.12 lighting ──
    caps: Caps = .{},
    lights: [limits.MAX_LIGHTS]Light = blk: {
        var l: [limits.MAX_LIGHTS]Light = undefined;
        for (&l, 0..) |*x, i| x.* = Light.initial(i);
        break :blk l;
    },
    light_model_ambient: [4]f32 = .{ 0.2, 0.2, 0.2, 1 },
    light_model_two_side: bool = false,
    material_front: Material = .{},
    material_back: Material = .{},
    color_material_enabled: bool = false,
    shade_model: enum { flat, smooth } = .smooth,

    // ── §3 rasterization ──
    line_width: f32 = 1,
    cull_face: idraw.CullFace = .back,
    front_face: idraw.FrontFace = .ccw,
    polygon_offset_factor: f32 = 0,
    polygon_offset_units: f32 = 0,
    point_size_min: f32 = 0,
    point_size_max: f32 = 1,
    point_fade_threshold: f32 = 1,
    point_distance_attenuation: [3]f32 = .{ 1, 0, 0 },

    // ── §3.7 texturing ──
    texenv: [limits.MAX_TEXTURE_UNITS]TexEnv = .{TexEnv{}} ** limits.MAX_TEXTURE_UNITS,
    texture_binding: [limits.MAX_TEXTURE_UNITS]u32 = .{0} ** limits.MAX_TEXTURE_UNITS,
    /// GL_KUDOS_material_maps (RND-005): the glTF material maps bound for lit
    /// draws, texture names by idraw.MatMap slot, zero = unbound.
    mat_maps: [idraw.MatMap.COUNT]u32 = .{0} ** idraw.MatMap.COUNT,

    // ── §3.9 fog ──
    fog: Fog = .{},

    // ── §4 per-fragment operations ──
    scissor_box: Viewport = .{},
    alpha_func: idraw.CompareFunc = .always,
    alpha_ref: f32 = 0,
    stencil_func: idraw.CompareFunc = .always,
    stencil_ref: i32 = 0,
    stencil_value_mask: u32 = ~@as(u32, 0),
    stencil_writemask: u32 = ~@as(u32, 0),
    stencil_fail: idraw.StencilOp = .keep,
    stencil_zfail: idraw.StencilOp = .keep,
    stencil_zpass: idraw.StencilOp = .keep,
    depth_func: idraw.CompareFunc = .less,
    blend_src: idraw.BlendFactor = .one,
    blend_dst: idraw.BlendFactor = .zero,
    logic_op: idraw.LogicOp = .copy,
    sample_coverage_value: f32 = 1,
    sample_coverage_invert: bool = false,

    // ── §4.2 whole-framebuffer operations ──
    color_writemask: [4]bool = .{ true, true, true, true },
    depth_writemask: bool = true,
    clear_color: [4]f32 = .{ 0, 0, 0, 0 },
    clear_depth: f32 = 1,
    clear_stencil: i32 = 0,

    // ── §4.3 pixel transfer ──
    pack_alignment: u32 = 4,
    unpack_alignment: u32 = 4,

    // ── §5.2 hints ──
    perspective_correction_hint: Hint = .dont_care,
    point_smooth_hint: Hint = .dont_care,
    line_smooth_hint: Hint = .dont_care,
    fog_hint: Hint = .dont_care,
    generate_mipmap_hint: Hint = .dont_care,

    pub const Hint = enum { fastest, nicest, dont_care };

    /// Create a context over a device. Fails only if the device cannot host a
    /// conforming implementation — better to find that out here than when a texture
    /// silently refuses to bind.
    pub fn init(alloc: Allocator, dev: idraw.IDraw, target: idraw.IDrawCtx) ?Context {
        const l = dev.limits();
        if (!limits.deviceMeetsFloors(l)) return null;
        return .{ .dev = dev, .target = target, .dev_limits = l, .alloc = alloc };
    }

    /// Release everything this context owns: its staging, every buffer shadow, and the
    /// device objects the application never got round to deleting.
    pub fn deinit(self: *Context) void {
        if (self.staging.len != 0) self.alloc.free(self.staging);
        if (self.staging_buf) |h| self.dev.bufferDestroy(h);
        self.dropRetired();
        for (&self.buffers.recs) |*r| {
            if (r.shadow.len != 0) self.alloc.free(r.shadow);
            r.shadow = &.{};
        }
    }

    /// Make `staging` at least `n` bytes. Grow-only, so a frame that draws the same
    /// geometry every time allocates once and never again.
    pub fn reserveStaging(self: *Context, n: usize) !void {
        if (self.staging.len >= n) return;
        const grown = try self.alloc.realloc(self.staging, n);
        self.staging = grown;
    }

    /// The floor for the device staging buffer. Big enough that a whole desktop frame
    /// of batched 2D (tens of thousands of vertices) fits without a mid-frame regrow;
    /// growth beyond it is geometric, so regrows stay rare after the first frame.
    pub const STAGING_FLOOR: usize = 256 * 1024;

    /// Room in the device staging buffer for `need` more bytes this frame, at a
    /// 16-byte-aligned offset past everything the frame already staged. Returns the
    /// buffer and the offset to upload at; the caller uploads and then advances
    /// `staging_used` past what it wrote. Null only on allocation failure (recorded).
    ///
    /// When the buffer is too small it is RETIRED, not destroyed: a deferring device
    /// may still read it for this frame's earlier draws. The replacement starts a
    /// fresh cursor; the retiree dies at the next successful beginFrame.
    pub fn ensureStagingRoom(self: *Context, need: usize) ?struct { h: idraw.BufferHandle, base: u32 } {
        const base = std.mem.alignForward(usize, self.staging_used, 16);
        if (self.staging_buf) |h| {
            if (self.staging_cap >= base + need) return .{ .h = h, .base = @intCast(base) };
            if (self.retired_n == self.retired.len) {
                // Unreachable with geometric growth; refuse rather than corrupt.
                self.recordError(.out_of_memory);
                return null;
            }
            self.retired[self.retired_n] = h;
            self.retired_n += 1;
            self.staging_buf = null;
        }
        const newcap = @max(@max(need, 2 * self.staging_cap), STAGING_FLOOR);
        // The create seeds the buffer from a slice of its full size; grow the CPU
        // scratch to match and let the bytes past the real data be whatever they are.
        self.reserveStaging(newcap) catch {
            self.recordError(.out_of_memory);
            return null;
        };
        const nh = self.dev.bufferCreate(self.staging[0..newcap], .dynamic) catch {
            self.recordError(.out_of_memory);
            return null;
        };
        self.staging_buf = nh;
        self.staging_cap = newcap;
        self.staging_used = 0;
        return .{ .h = nh, .base = 0 };
    }

    /// Start a new frame's staging: the previous frame has landed (the device just
    /// accepted beginFrame), so its staged bytes are consumed and any buffer it
    /// outgrew can finally die.
    pub fn resetStagingFrame(self: *Context) void {
        self.staging_used = 0;
        self.dropRetired();
    }

    fn dropRetired(self: *Context) void {
        var i: usize = 0;
        while (i < self.retired_n) : (i += 1) self.dev.bufferDestroy(self.retired[i]);
        self.retired_n = 0;
    }

    pub fn recordError(self: *Context, e: errors.Error) void {
        self.err.record(e);
    }
};
