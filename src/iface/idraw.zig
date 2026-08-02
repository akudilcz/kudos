//! IDraw — the seam where "draw this" becomes "an RTX 4090 does something".
//!
//! Pure vtable-type module: no hardware imports, no allocation, self-contained types.
//! The kernel and the host test build both compile it. Real implementation:
//! src/drivers/gl/opengl.zig; fake: test/support/draw_sim.zig (DrawSim). Two implementations is
//! what earns a vtable here — nothing above this line has more than one.
//!
//! **This is not the OpenGL API.** That is `gles` (src/drivers/gl/es/), a pure module
//! applications import by name, in the same shape as `keymap` — the pure half of the
//! keyboard driver. `gles` calls this on their behalf; an application never sees it,
//! beyond reading `device` and handing it over.
//!
//! Why the split, rather than putting OpenGL itself here: ES 1.1 has 145 entry points, and
//! nearly every one is bookkeeping over a state vector: `glRotatef` multiplies a
//! matrix, `glEnable` sets a bit, `glMaterialfv` stores four floats. None of that is a
//! decision the hardware participates in, so a vtable entry per entry point would be
//! 145 indirections that all end in the same two places. What the hardware must
//! actually be told is smaller and blunter:
//!
//!   *here is a complete pipeline state, here is a draw.*
//!
//! Everything above that line is the specification, and it lives in the `gles` module
//! (src/drivers/gl/es/) as pure code that apps call directly. Everything below it is
//! this contract. The seam buys the thing that matters: the ES 1.1 surface kudos
//! implements — its state tables, both numeric profiles, its error cases — is
//! host-testable against DrawSim in seconds, with no GPU in the room.
//!
//! ## What this contract does NOT decide
//!
//! Legality is the specification's job, not ours. ES 1.1 forbids `SRC_COLOR` as a
//! source blend factor and rejects 32-bit indices; both appear here anyway, because
//! the silicon can do them and this contract describes the silicon. The `gles` layer
//! rejects what the spec rejects, before it ever reaches a vtable call. An
//! implementation of this contract may assume it is handed a state it can draw.
//!
//! ## The frame pipeline
//!
//! A context is one window's private frame pipeline, and every call is non-blocking —
//! fences are one-word polls, never waits, because the desktop's 60 Hz present pacing
//! runs on the same thread and must not stall. Frames are delivered GPU-side: the
//! render is chained on-card to a de-tile straight into the window's mirror (the
//! surface the compositor reads), so there is no readback and no CPU pixel copy on the
//! frame path. N contexts run concurrently and no context ever waits on another.
//!
//! `readPixels` is the one exception, and it is the specification's fault rather than
//! ours: `glReadPixels` is defined to hand the application pixels, so it must wait for
//! the GPU and copy them back. It is the only call here that blocks.

// ── numbers and handles ──────────────────────────────────────────────────────

// There is no matrix type here, which is worth saying because there was one. Matrices
// reach the shader as bytes inside `Pipeline.uniforms`, so this contract never sees one
// and never has to state a clip convention. The conventions it DOES fix are the
// framebuffer's, in `Rect` and `Dst`: y down from the top, because that is how the rows
// are stored and how the compositor reads them. GL's y-up, depth-in-[-1,1] world ends
// at `gles`, which flips rectangles and folds the depth remap into a matrix it was
// multiplying anyway.

/// A buffer of vertex or index data living in GPU memory. Handles come from
/// `bufferCreate` and stay valid until `bufferDestroy`.
pub const BufferHandle = u32;

/// A texture image plus its mip chain. Handles come from `textureCreate` and stay
/// valid until `textureDestroy`.
pub const TextureHandle = u32;

/// Texture units a single draw can sample from. ES 1.1 requires at least one and
/// most fixed-function content uses two (a base map and a light map or decal); the
/// count the specification reports to applications comes from `Limits.texture_units`,
/// not from here. This is only the array bound.
pub const MAX_UNITS: u32 = 2;

/// The render target's hard cap: a context's target is sized to the primary panel
/// (the ultrawide, the only driven monitor), so a window's whole content area always
/// fits. Callers clamp; the implementation errors rather than clipping.
pub const MAX_W: u32 = 3440;
pub const MAX_H: u32 = 1440;

/// Context-pool size: at most this many windows render 3D at once. `acquire` returns
/// null beyond it and callers show a placeholder.
pub const MAX_CTX: u32 = 8;

pub const Error = error{
    DrawOutOfResources,
    DrawBadBuffer,
    DrawBadTexture,
    DrawBadViewport,
    DrawBusy,
    DrawDeviceLost,
};

/// Where a context delivers finished frames: the identity of the window surface (its
/// pixel base — the key the present layer's mirror table uses) plus the content-area
/// origin within it. `stride_px` is in PIXELS.
pub const Dst = struct {
    win_base: u64,
    stride_px: u32,
    off_x: u32,
    off_y: u32,
};

/// A window-space rectangle, y measured DOWN from the top — the framebuffer's own
/// convention. GL measures y up from the bottom; `gles` flips at the lowering, so
/// this is unambiguous everywhere below it.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

// ── what the pipeline can be told to do ──────────────────────────────────────

/// The primitive an index or vertex run assembles into.
///
/// `line_loop` is the awkward one: it is a line strip that closes back onto its first
/// vertex, and no NVIDIA primitive does that. Implementations draw it as a strip plus
/// the closing segment.
pub const Prim = enum { points, lines, line_loop, line_strip, triangles, triangle_strip, triangle_fan };

/// Width of one index. ES 1.1 core allows only `u8` and `u16`; `u32` is reachable
/// only through the optional OES_element_index_uint extension, which is why it is the
/// `gles` layer that decides whether an application may ask for it. The hardware is
/// happy with all three.
pub const IndexType = enum { u8, u16, u32 };

/// The comparison a depth, stencil or alpha test applies. Shared because the
/// specification defines one set of eight for all three, and one silicon fact deserves
/// one spelling.
pub const CompareFunc = enum { never, less, equal, lequal, greater, notequal, gequal, always };

/// What a stencil test does to the buffer. `incr` and `decr` saturate rather than
/// wrap — ES 1.1 has no wrapping form.
pub const StencilOp = enum { keep, zero, replace, incr, decr, invert };

/// A blend factor. The specification permits a different subset on each side of the
/// blend (a source factor may not read `src_color`, a destination factor may not read
/// `dst_color`); that asymmetry is the specification's rule and `gles` enforces it, so
/// this enum is the full silicon set.
pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    src_alpha_saturate,
};

/// The bitwise operation a fragment's color undergoes against the one already in the
/// framebuffer, when logic-op mode is on. Blending and logic op are mutually
/// exclusive; logic op wins.
pub const LogicOp = enum {
    clear,
    set,
    copy,
    copy_inverted,
    noop,
    invert,
    @"and",
    nand,
    @"or",
    nor,
    xor,
    equiv,
    and_reverse,
    and_inverted,
    or_reverse,
    or_inverted,
};

pub const CullFace = enum { front, back, front_and_back };

/// Which winding, in window coordinates, counts as the front of a triangle.
pub const FrontFace = enum { cw, ccw };

/// How fog density grows with distance from the eye. Part of `ShaderKey` because each
/// mode is different arithmetic in the shader, not a different constant.
pub const FogMode = enum(u2) { off, linear, exp, exp2 };

/// How one vertex attribute's bytes are laid out in its buffer.
///
/// The specification lets an application hand over almost anything — signed bytes,
/// shorts, 16.16 fixed-point, floats, at any size and stride. Only the formats the
/// vertex-fetch hardware decodes natively appear here; `gles` converts the rest on the
/// way in, which is why `fixed` is absent: nothing fetches 16.16, so it is widened to
/// float before it reaches this contract.
pub const AttribFormat = enum {
    /// Raw integers widened to float: -128 arrives as -128.0. What a POSITION or a
    /// texture coordinate given as bytes or shorts means.
    i8x2,
    i8x3,
    i8x4,
    i16x2,
    i16x3,
    i16x4,
    f32x1,
    f32x2,
    f32x3,
    f32x4,
    /// Normalized unsigned bytes: 0..255 maps to 0.0..1.0. What `glColorPointer` feeds
    /// from.
    u8x4_unorm,
    /// Normalized signed: -128..127 maps to -1.0..1.0. What `glNormalPointer` feeds
    /// from — the specification says a normal's integer components convert as a signed
    /// normalized type, unlike a position's, which are raw coordinates.
    i8x3_snorm,
    i16x3_snorm,
};

/// A texture's pixel layout in GPU memory.
///
/// The specification's external formats are wider than this list, and deliberately so:
/// an application may hand over 4-bit-per-channel or 5-6-5 pixels, and the paletted
/// formats hand over an index plus a lookup table. All of them are expanded on the CPU
/// during upload, so what the sampler ever sees is one of these.
pub const TexFormat = enum {
    /// Four channels, blue first — the byte order the compositor's surfaces use, so an
    /// image that came from a PNG or JPEG needs no swizzle to be sampled or presented.
    bgra8,
    /// One channel, replicated to r, g and b when sampled, with alpha forced to 1.
    luminance8,
    /// One channel, sampled as alpha, with r, g and b forced to 0.
    alpha8,
    /// Two channels: luminance then alpha.
    luminance_alpha8,
};

/// What a sampler does with a coordinate outside [0, 1].
///
/// Two, not three: ES 1.1 has no mirrored repeat. The silicon does, but nothing above
/// this line can ask for it — that arrives with OES_texture_mirrored_repeat, which is
/// optional and unimplemented, and it can be added back when something needs it.
///
/// Explicitly tagged: sampler state is bit-packed into a texture object's spare word,
/// and a packed struct needs a field width it can rely on.
pub const WrapMode = enum(u2) { repeat, clamp_to_edge };

/// How a sampler filters within one mip level, and across two.
pub const Filter = enum(u1) { nearest, linear };
pub const MipFilter = enum(u2) { none, nearest, linear };

// ── the shader key ───────────────────────────────────────────────────────────

/// The axes of the fixed-function pipeline that change the shader's *instructions*
/// rather than its *data* — so each combination is a separate compiled program, picked
/// at draw time from a set built ahead of time. There is no compiler on this machine
/// and a draw must never wait for one.
///
/// 9 × 3 × 2 × 4 = **216 programs**, which is a megabyte of blobs and an exhaustive
/// set: every key this struct can express has a program, and a host test proves it, so
/// a missing variant is a red test rather than a black window.
///
/// Note what is NOT here. The texture environment — how a sampled texel combines with
/// the color that arrived — is configurable to an absurd degree: 8 RGB functions × 6
/// alpha functions × three sources and three operands on each side × two scale factors
/// is **906 million** combinations for ONE unit, and squaring that for two units puts
/// enumeration past any storage that will ever exist. So it is data, not instructions:
/// `gles` compiles it to a small bytecode in the constant buffer and the fragment
/// shader interprets it. That costs branches, but every branch reads a constant, so
/// every thread in a warp takes the same side and none of them diverge; what it really
/// costs is registers.
pub const ShaderKey = packed struct(u16) {
    /// Enabled light count, 0..8. Zero means lighting is off entirely and the vertex
    /// color passes through, which is a different program, not a loop that runs zero
    /// times.
    lights: u4,
    /// Texture units contributing to the fragment, 0..MAX_UNITS.
    units: u2,
    /// Whether back faces are lit with the back material and a flipped normal.
    two_sided: bool,
    fog: FogMode,
    /// OES_point_sprite: this draw rasterises points whose texture coordinates
    /// may be replaced by the point's own (s, t) — the fragment program reads
    /// the rasteriser's point coordinate. Only a point draw with at least one
    /// contributing unit under COORD_REPLACE sets it, and it forces `two_sided`
    /// off: a point has no back face to select.
    sprite: bool = false,
    _pad: u6 = 0,
};

// ── one draw's pipeline state ────────────────────────────────────────────────

pub const Raster = struct {
    cull: ?CullFace,
    front_face: FrontFace,
    /// Depth offset applied per fragment, scaled by the polygon's slope. Both zero
    /// disables it.
    poly_offset_factor: f32,
    poly_offset_units: f32,
    line_width: f32,
};

pub const Depth = struct {
    test_enable: bool,
    write: bool,
    func: CompareFunc,
};

pub const Stencil = struct {
    test_enable: bool,
    func: CompareFunc,
    ref: i32,
    /// Masks which bits the comparison reads.
    read_mask: u32,
    /// Masks which bits a write may touch.
    write_mask: u32,
    fail: StencilOp,
    depth_fail: StencilOp,
    depth_pass: StencilOp,
};

pub const Blend = struct {
    enable: bool,
    src: BlendFactor,
    dst: BlendFactor,
};

/// Discard a fragment whose alpha fails this comparison against `ref`.
pub const AlphaTest = struct {
    func: CompareFunc,
    ref: f32,
};

/// Fade coverage toward `value` so that partially-transparent geometry can resolve
/// against the multisample pattern instead of blending. `invert` flips which samples
/// the mask keeps.
pub const SampleCoverage = struct {
    enable: bool,
    value: f32,
    invert: bool,
};

/// One texture unit's binding for a draw: what to sample and how.
pub const Unit = struct {
    texture: TextureHandle,
    wrap_s: WrapMode,
    wrap_t: WrapMode,
    min: Filter,
    mag: Filter,
    mip: MipFilter,
};

/// The glTF material-map slots a lit draw may attach beyond the combiner units
/// (GL_KUDOS_material_maps, spec RND-005). Like AttribSlot, the slot IS the
/// semantic: each is one sampler of the physically-based fragment program, all
/// addressed by the mesh's texcoord0. A null slot means the map's neutral
/// identity — metal-rough white (fully metallic, fully rough: the glTF default),
/// normal flat +Z, occlusion white (unoccluded), emissive black — so a partial
/// binding shades correctly rather than being refused or silently ignored.
pub const MatMap = enum(u2) {
    metal_rough,
    normal,
    occlusion,
    emissive,

    pub const COUNT: usize = @typeInfo(MatMap).@"enum".fields.len;
};

/// Where one attribute's values come from.
///
/// A disabled array is not an absent attribute: the specification says every vertex
/// still has a color, a normal and texture coordinates, they are just the same for all
/// of them (whatever `glColor4f` last set). So an attribute is either a stream of
/// values or one constant value, and both are ordinary inputs to the same program.
pub const Attrib = union(enum) {
    disabled,
    constant: [4]f32,
    array: struct {
        buffer: BufferHandle,
        /// Byte offset of the first element within the buffer.
        offset: u32,
        /// Byte distance between consecutive elements. Never zero: the specification's
        /// "0 means tightly packed" shorthand is resolved by `gles` before it lowers.
        stride: u32,
        format: AttribFormat,
    },
};

/// The attributes a fixed-function vertex consumes. This is a closed set — ES 1.1 has
/// no general-purpose vertex attributes, only these six meanings — so the slot IS the
/// semantic, and each program binds them at fixed locations.
pub const AttribSlot = enum(u3) {
    position,
    normal,
    color,
    texcoord0,
    texcoord1,
    /// Per-vertex point size, from the mandatory OES_point_size_array extension.
    point_size,

    pub const COUNT: usize = @typeInfo(AttribSlot).@"enum".fields.len;
};

/// Everything about a draw except the vertices themselves.
///
/// This is a complete state, not a delta. A caller never asks "what is currently
/// bound?" and an implementation never answers — which is what lets several windows
/// interleave draws on one hardware channel without leaking state into each other. An
/// implementation may of course notice that consecutive draws share state and skip
/// re-emitting it, but only within work it is itself in the middle of recording.
pub const Pipeline = struct {
    key: ShaderKey,
    viewport: Rect,
    /// Depth range, already remapped to the hardware's [0, 1].
    depth_range: [2]f32,
    /// Null when the scissor test is off.
    scissor: ?Rect,
    raster: Raster,
    depth: Depth,
    stencil: Stencil,
    blend: Blend,
    /// Null when logic-op mode is off. Excludes blending when set.
    logic_op: ?LogicOp,
    /// Null when the alpha test is off.
    alpha_test: ?AlphaTest,
    color_mask: [4]bool,
    dither: bool,
    sample_coverage: SampleCoverage,
    /// Null in a slot the key says does not contribute.
    units: [MAX_UNITS]?Unit,
    /// glTF material maps for a physically-based lit draw
    /// (GL_KUDOS_material_maps, spec RND-005), indexed by MatMap. All null on
    /// the fixed-function path; a null slot samples that map's neutral
    /// identity, so partial bindings shade correctly.
    mat_maps: [MatMap.COUNT]?Unit,
    /// The packed uniform image this draw reads: matrices, light and material
    /// parameters, fog coefficients, and the texture-environment bytecode. Its byte
    /// layout is `uniform` below, shared by the three readers — `gles` writes it, the
    /// shaders decode it, and the software backend decodes it too — so a host test pins
    /// them against each other; a silent disagreement renders garbage rather than failing.
    uniforms: []const u8,
};

/// The byte layout of `Pipeline.uniforms` — the one place the offset of every field in
/// the packed uniform image is stated. It lives on the seam because it is a contract
/// among three parties that must agree: `gles` (which writes the image), the compiled
/// shaders (which decode it on the GPU), and `soft.zig` (which decodes it on the CPU).
///
/// Every offset is 16-byte aligned: the hardware's constant fetch wants vectors on vector
/// boundaries, and a mat3 therefore occupies three vec4s. Offsets and sizes are in bytes.
pub const uniform = struct {
    pub const OFF_MVP: usize = 0x000; // projection * modelview
    pub const OFF_MODELVIEW: usize = 0x040; // for eye-space position
    pub const OFF_NORMAL_MATRIX: usize = 0x080; // mat3, three vec4s
    pub const OFF_TEX_MATRIX: usize = 0x0B0; // [MAX_UNITS] mat4
    pub const OFF_MATERIAL: usize = 0x130; // ambient, diffuse, specular, emission, shininess
    pub const OFF_LIGHT_MODEL_AMBIENT: usize = 0x180;
    pub const OFF_FOG_COLOR: usize = 0x190;
    pub const OFF_FOG_PARAMS: usize = 0x1A0; // density, start, end, 1/(end-start)
    pub const OFF_MISC: usize = 0x1B0; // alpha_ref, point_size, coord_replace mask, 0
    pub const OFF_CLIP_PLANES: usize = 0x1C0; // [MAX_CLIP_PLANES] vec4
    pub const OFF_LIGHTS: usize = 0x220; // [MAX_LIGHTS] Light, 96 bytes each
    pub const OFF_TEXENV: usize = 0x520; // [MAX_UNITS] TexEnv, 32 bytes each

    /// One light's parameters, 96 bytes (ambient, diffuse, specular, position, spot, atten).
    pub const LIGHT_STRIDE: usize = 0x60;
    /// One texture environment, 32 bytes: a colour and four packed words.
    pub const TEXENV_STRIDE: usize = 0x20;

    /// Total size; the shaders' constant buffer must be at least this.
    pub const SIZE: usize = OFF_TEXENV + MAX_UNITS * TEXENV_STRIDE;
};

/// Which vertices to draw, and where they live.
pub const Draw = struct {
    prim: Prim,
    /// Indexed by `AttribSlot`.
    attribs: [AttribSlot.COUNT]Attrib,
    /// First vertex (non-indexed) or first index (indexed).
    first: u32,
    count: u32,
    /// Null for a sequential draw.
    index: ?struct {
        buffer: BufferHandle,
        offset: u32,
        type: IndexType,
    },
};

/// What a `clear` touches.
pub const ClearMask = packed struct {
    color: bool = false,
    depth: bool = false,
    stencil: bool = false,
};

// ── device-level resources ───────────────────────────────────────────────────

/// How a buffer is expected to be used. The hardware does not care today, but the
/// specification makes an application say, and where it says "I will rewrite this every
/// frame" there is a real placement decision to make later.
pub const Usage = enum { static, dynamic };

/// One mip level's pixels, as the sampler will store them.
pub const Level = struct {
    w: u32,
    h: u32,
    /// Tightly packed, `w * h * bytes-per-pixel(format)`, rows top-down.
    pixels: []const u8,
};

pub const TexDesc = struct {
    format: TexFormat,
    /// Level 0 first. A single level is a texture with no mip chain; a sampler asking
    /// to filter between levels of such a texture is the specification's problem to
    /// reject, not ours.
    levels: []const Level,
};

/// What this silicon can actually do.
///
/// The specification's implementation-dependent values (`glGetIntegerv` of
/// `GL_MAX_TEXTURE_SIZE` and friends) are answered from here, so `gles` never states a
/// number the device cannot honour. Each is a floor the specification sets and the
/// device is free to exceed.
pub const Limits = struct {
    /// >= 64 required; a real cap is far higher.
    max_texture_size: u32,
    /// >= 1 required.
    texture_units: u32,
    /// Multisample samples per pixel, or 1 when the target is single-sampled. The
    /// specification permits either.
    samples: u32,
    /// Bits of subpixel precision the rasterizer positions geometry with. >= 4
    /// required.
    subpixel_bits: u32,
};

/// The pixel format `glReadPixels` will accept besides the always-supported one.
///
/// The specification guarantees RGBA/UNSIGNED_BYTE always works, and requires the
/// implementation to name exactly one other pair it prefers — the one it can deliver
/// without converting. That is what OES_read_format is for.
pub const ReadFormat = enum { rgba8, bgra8 };

// ── the contract ─────────────────────────────────────────────────────────────

/// The DEVICE: resources shared by every context, plus the context pool.
pub const IDraw = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    /// How a finished frame reaches the screen. True: `endFrame` has already written the
    /// pixels into the window surface the `Dst` addresses, so the compositor shows that
    /// surface and the window must report the drawn region as damage (the software
    /// backend). False: the frame lands in a private GPU mirror the compositor samples in
    /// place, and no surface upload is needed (the 4090 backend). A window that draws
    /// through gles asks `gles.deliversInPlace` rather than assuming either.
    delivers_in_place: bool,

    pub const VTable = struct {
        /// Place `bytes` in GPU memory. `bytes` may be empty for a buffer that is
        /// sized now and filled later.
        bufferCreate: *const fn (ctx: *anyopaque, bytes: []const u8, usage: Usage) Error!BufferHandle,
        /// Overwrite part of a buffer. Must not extend it.
        bufferUpdate: *const fn (ctx: *anyopaque, h: BufferHandle, off: u32, bytes: []const u8) Error!void,
        bufferDestroy: *const fn (ctx: *anyopaque, h: BufferHandle) void,
        textureCreate: *const fn (ctx: *anyopaque, d: TexDesc) Error!TextureHandle,
        /// Overwrite a rectangle of one mip level.
        textureUpdate: *const fn (ctx: *anyopaque, h: TextureHandle, level: u32, r: Rect, px: []const u8) Error!void,
        textureDestroy: *const fn (ctx: *anyopaque, h: TextureHandle) void,
        limits: *const fn (ctx: *anyopaque) Limits,
        /// Take a context from the pool, bound to `dst` for frame delivery. Null when
        /// all MAX_CTX slots are taken.
        acquire: *const fn (ctx: *anyopaque, dst: Dst) ?IDrawCtx,
        /// Return a context to the pool (the window closed). An in-flight frame is
        /// abandoned; the slot recycles once it retires.
        release: *const fn (ctx: *anyopaque, c: IDrawCtx) void,
    };

    pub fn bufferCreate(self: IDraw, bytes: []const u8, usage: Usage) Error!BufferHandle {
        return self.vtable.bufferCreate(self.ctx, bytes, usage);
    }
    pub fn bufferUpdate(self: IDraw, h: BufferHandle, off: u32, bytes: []const u8) Error!void {
        return self.vtable.bufferUpdate(self.ctx, h, off, bytes);
    }
    pub fn bufferDestroy(self: IDraw, h: BufferHandle) void {
        self.vtable.bufferDestroy(self.ctx, h);
    }
    pub fn textureCreate(self: IDraw, d: TexDesc) Error!TextureHandle {
        return self.vtable.textureCreate(self.ctx, d);
    }
    pub fn textureUpdate(self: IDraw, h: TextureHandle, level: u32, r: Rect, px: []const u8) Error!void {
        return self.vtable.textureUpdate(self.ctx, h, level, r, px);
    }
    pub fn textureDestroy(self: IDraw, h: TextureHandle) void {
        self.vtable.textureDestroy(self.ctx, h);
    }
    pub fn limits(self: IDraw) Limits {
        return self.vtable.limits(self.ctx);
    }
    pub fn acquire(self: IDraw, dst: Dst) ?IDrawCtx {
        return self.vtable.acquire(self.ctx, dst);
    }
    pub fn release(self: IDraw, c: IDrawCtx) void {
        self.vtable.release(self.ctx, c);
    }
};

/// One window's frame pipeline. One frame in flight at a time.
pub const IDrawCtx = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Open a frame at (w, h) — both > 0, w <= MAX_W, h <= MAX_H. Callers pass
        /// their WHOLE content size, so the projection centre sits at the middle of
        /// the window's viewable area. Returns `DrawBusy` while THIS context's
        /// previous frame is still recording or in flight; callers skip and retry.
        /// Consumes a landed frame, so `frameReady` reads false again after.
        ///
        /// Note there is no clear here: in GL a clear is a command with its own state,
        /// issued whenever the application likes, and pretending otherwise would make
        /// `glClear` in the middle of a frame unexpressible.
        beginFrame: *const fn (ctx: *anyopaque, w: u32, h: u32) Error!void,
        /// Clear the enabled buffers to the given values, honouring `sc` when the
        /// scissor test is on.
        clear: *const fn (ctx: *anyopaque, m: ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?Rect) Error!void,
        draw: *const fn (ctx: *anyopaque, p: *const Pipeline, d: *const Draw) Error!void,
        /// Read back a rectangle of the frame being recorded. **The only blocking call
        /// in this contract**: it waits for the GPU, resolves multisampling, and
        /// copies to `dst`, which must hold `r.w * r.h * 4` bytes.
        readPixels: *const fn (ctx: *anyopaque, r: Rect, fmt: ReadFormat, dst: []u8) Error!void,
        /// Finish the frame: kick the render and the GPU-side de-tile into the
        /// window's mirror, and return immediately.
        endFrame: *const fn (ctx: *anyopaque) Error!void,
        /// Non-blocking poll: true once the last frame LANDED in the window's mirror,
        /// sticky until the next `beginFrame`. Callers gate damage reporting on it;
        /// there are no pixels to fetch, as the compositor reads the mirror directly.
        frameReady: *const fn (ctx: *anyopaque) bool,
        /// Abandon the current frame, wherever it got to. Never waits.
        discard: *const fn (ctx: *anyopaque) void,
    };

    pub fn beginFrame(self: IDrawCtx, w: u32, h: u32) Error!void {
        return self.vtable.beginFrame(self.ctx, w, h);
    }
    pub fn clear(self: IDrawCtx, m: ClearMask, color: [4]f32, depth: f32, stencil: u32, sc: ?Rect) Error!void {
        return self.vtable.clear(self.ctx, m, color, depth, stencil, sc);
    }
    pub fn draw(self: IDrawCtx, p: *const Pipeline, d: *const Draw) Error!void {
        return self.vtable.draw(self.ctx, p, d);
    }
    pub fn readPixels(self: IDrawCtx, r: Rect, fmt: ReadFormat, dst: []u8) Error!void {
        return self.vtable.readPixels(self.ctx, r, fmt, dst);
    }
    pub fn endFrame(self: IDrawCtx) Error!void {
        return self.vtable.endFrame(self.ctx);
    }
    pub fn frameReady(self: IDrawCtx) bool {
        return self.vtable.frameReady(self.ctx);
    }
    pub fn discard(self: IDrawCtx) void {
        self.vtable.discard(self.ctx);
    }
};

/// The live 3D device, or null when there is no GPU to draw with.
///
/// The GPU driver publishes itself here once the graphics engine is up, and clears it
/// again before tearing the engine down — so an app that renders through this can
/// never hold a handle to a dying device. Apps must re-read it every frame rather than
/// caching it, and fall back to something they can draw on the CPU when it is null (an
/// emulated boot never sets it).
///
/// This lives in `iface/` for the same reason the vtable does: the app that draws
/// through the device and the driver that provides it are in different groups and may
/// not name each other.
pub var device: ?IDraw = null;
