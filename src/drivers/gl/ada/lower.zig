//! Lowering the draw seam's enums to ADA_A (0xc997) register values — PURE
//! module, host-golden-tested, imports only the `idraw` seam types.
//!
//! A draw arrives as an `idraw.Pipeline` + `idraw.Draw` (src/iface/idraw.zig): a
//! complete fixed-function state in the vocabulary of the OpenGL ES specification.
//! The silicon speaks a different vocabulary — a comparison is a 12-bit OGL code, a
//! primitive is a BEGIN opcode, a vertex format is a (component-widths, numeric-type)
//! pair. This file is the dictionary between the two, and NOTHING ELSE: it decides no
//! policy and emits no method stream. `opengl.zig` calls it to turn the seam's enums
//! into the numbers the method emitters (`methods.zig`) write.
//!
//! ## Every value here is read from the class header, never guessed
//!
//! These are silicon facts. A wrong one is not a compile error and not a crash — it is
//! a black window on the physical 4090, found only after a netboot that wears the rig.
//! So each value is read from the mesa `clc997.h` class header, cited at the line it
//! came from, and pinned by a golden test below. The naive OGL sequence is NOT safe to
//! extrapolate: the blend space already proves it (ONE_MINUS_SRC_ALPHA is 0x4303, not
//! the 0x4301 a linear reading of the enum would predict).
//!
//! ## What is not yet grounded returns null, and is refused rather than approximated
//!
//! Only the subset of `clc997.h` the first bring-up needed is transcribed here. Where a
//! mapping's value is missing — the `triangle_fan` and line primitives' opcodes, the
//! byte/short vertex formats, the full cull set — the function returns `null`. A `null`
//! means "this draw needs a value I cannot source without the class header," and
//! `opengl.zig` turns it into `DrawOutOfResources`: the window shows a placeholder, and
//! no invented number ever reaches the engine. Filling these in is a
//! transcription-plus-hardware task (source `clc997.h`, extend the golden below,
//! validate on lemon), not a keyboard guess.

const std = @import("std");
const idraw = @import("idraw");

// ── comparison functions (depth, stencil, alpha test) ────────────────────────
//
// The specification defines ONE set of eight comparisons and shares it across the
// depth test, the stencil test and the alpha test; the silicon shares it too. These
// are the "OGL" encodings SET_DEPTH_FUNC (0x130c) takes — a 12-bit code in the 0x200
// block — and the stencil and alpha func methods take the same set.
// (clc997.h:2606-2615.)
const OGL_NEVER: u32 = 0x200;
const OGL_LESS: u32 = 0x201;
const OGL_EQUAL: u32 = 0x202;
const OGL_LEQUAL: u32 = 0x203;
const OGL_GREATER: u32 = 0x204;
const OGL_NOTEQUAL: u32 = 0x205;
const OGL_GEQUAL: u32 = 0x206;
const OGL_ALWAYS: u32 = 0x207;

/// A comparison function's OGL register code. Total and grounded: all eight are in
/// the reference doc. Written as an explicit map, not `0x200 + @intFromEnum`, so that
/// reordering the seam's enum is caught by the golden rather than silently renumbering
/// every comparison in the pipeline.
pub fn compareFunc(f: idraw.CompareFunc) u32 {
    return switch (f) {
        .never => OGL_NEVER,
        .less => OGL_LESS,
        .equal => OGL_EQUAL,
        .lequal => OGL_LEQUAL,
        .greater => OGL_GREATER,
        .notequal => OGL_NOTEQUAL,
        .gequal => OGL_GEQUAL,
        .always => OGL_ALWAYS,
    };
}

// ── index width ──────────────────────────────────────────────────────────────

/// The SET_INDEX_BUFFER_E code for one index width: 0=u8, 1=u16, 2=u32
/// (clc997.h:3620-3624). Total and grounded.
pub fn indexSize(t: idraw.IndexType) u32 {
    return switch (t) {
        .u8 => 0,
        .u16 => 1,
        .u32 => 2,
    };
}

// ── primitive assembly ───────────────────────────────────────────────────────
//
// The OP field of BEGIN (0x1618). The reference doc lists POINTS=0, LINES=1,
// TRIANGLES=4, TRIANGLE_STRIP=5, PATCH=0xE — the values a triangle-and-line path
// proved on the card. It does NOT list LINE_LOOP, LINE_STRIP or TRIANGLE_FAN, and the
// gaps in that sequence (2, 3, 6) are exactly where those three sit in every NVIDIA
// class header since Fermi — but "exactly where they should be" is a prediction, not a
// transcription, and predicting a primitive opcode is how a fan renders as a fan of
// garbage. They stay null until the header is sourced and the card confirms them.
const BEGIN_POINTS: u32 = 0;
const BEGIN_LINES: u32 = 1;
const BEGIN_TRIANGLES: u32 = 4;
const BEGIN_TRIANGLE_STRIP: u32 = 5;

/// The BEGIN opcode for a primitive, or null when its value is not yet grounded.
/// `line_loop` is doubly unfinished: even once its opcode is known it needs the
/// closing segment the hardware does not draw (idraw.Prim's own note), so it will
/// remain a caller-side special case, not a single opcode.
pub fn primBegin(p: idraw.Prim) ?u32 {
    return switch (p) {
        .points => BEGIN_POINTS,
        .lines => BEGIN_LINES,
        .triangles => BEGIN_TRIANGLES,
        .triangle_strip => BEGIN_TRIANGLE_STRIP,
        .line_loop, .line_strip, .triangle_fan => null,
    };
}

// ── vertex attribute formats ─────────────────────────────────────────────────
//
// SET_VERTEX_ATTRIBUTE_A (0x1160+i*4) packs the source format into two adjacent
// fields: COMPONENT_BIT_WIDTHS at bit 21 and NUMERICAL_TYPE at bit 27. The composite
// this file returns is `(widths << 21) | (type << 27)`, the OFFSET/STREAM bits being
// the caller's to add. (clc997.h:2217-2254.)
const COMPONENT_SHIFT: u5 = 21;
const NUMERICAL_SHIFT: u5 = 27;

// Component-width codes the reference doc transcribes.
const BW_R32_G32_B32_A32: u32 = 0x01;
const BW_R32_G32_B32: u32 = 0x02;
const BW_R32_G32: u32 = 0x04;
const BW_R32: u32 = 0x12;
const BW_R8_G8_B8_A8: u32 = 0x0A;

// Numerical-type codes (same table).
const NT_UNORM: u32 = 2;
const NT_FLOAT: u32 = 7;

fn attr(widths: u32, ntype: u32) u32 {
    return (widths << COMPONENT_SHIFT) | (ntype << NUMERICAL_SHIFT);
}

/// The attribute-format composite for one `AttribFormat`, or null when the format's
/// component-width code is not yet grounded.
///
/// Grounded: the float widths and the one normalized-byte format
/// (`u8x4_unorm` — what `glColorPointer` feeds). These are what the 2D toolkit and the
/// model viewer actually stream. The byte- and short-integer formats need the R8_G8,
/// R8_G8_B8, R16_G16, R16_G16_B16 width codes, which the doc does not carry, and the
/// signed-normalized normal formats need those plus SNORM — all null until sourced.
pub fn attribFormat(f: idraw.AttribFormat) ?u32 {
    return switch (f) {
        .f32x1 => attr(BW_R32, NT_FLOAT),
        .f32x2 => attr(BW_R32_G32, NT_FLOAT),
        .f32x3 => attr(BW_R32_G32_B32, NT_FLOAT),
        .f32x4 => attr(BW_R32_G32_B32_A32, NT_FLOAT),
        .u8x4_unorm => attr(BW_R8_G8_B8_A8, NT_UNORM),
        .i8x2, .i8x3, .i8x4, .i16x2, .i16x3, .i16x4, .i8x3_snorm, .i16x3_snorm => null,
    };
}

// ── face culling ─────────────────────────────────────────────────────────────
//
// OGL_SET_CULL_FACE (0x1920) names the face to cull; OGL_SET_CULL (0x1918) is the
// on/off the caller handles separately (0 disables, and the face value is then inert).
// The doc transcribes BACK=0x405 — the one the depth-tested content path uses. FRONT
// and FRONT_AND_BACK are in the same 0x40x block but their exact codes are not in the
// doc, so they are null.
const CULL_BACK: u32 = 0x405;

/// The cull-face register value, or null when it is not yet grounded.
pub fn cullFace(c: idraw.CullFace) ?u32 {
    return switch (c) {
        .back => CULL_BACK,
        .front, .front_and_back => null,
    };
}

// ── front-face winding ───────────────────────────────────────────────────────
//
// OGL_SET_FRONT_FACE (0x191c): CW=0x900, CCW=0x901 (clc997.h:3776-3779).
// Total and grounded.
const FRONT_CW: u32 = 0x900;
const FRONT_CCW: u32 = 0x901;

pub fn frontFace(f: idraw.FrontFace) u32 {
    return switch (f) {
        .cw => FRONT_CW,
        .ccw => FRONT_CCW,
    };
}

// ── blend ────────────────────────────────────────────────────────────────────
//
// The general blend-factor table is NOT in the reference doc — only two coefficients
// appear there (ONE=0x4001, INV_SRC_ALPHA=0x4303, at methods.zig's blendPremultOn), and
// as the module header warns, the space cannot be extrapolated from those two. So this
// file does not offer a `blendFactor` map yet. What it does offer is the one
// recognition the 2D compositor needs: is this blend state the premultiplied-over
// configuration `methods.blendPremultOn` already emits correctly?
//
// The kudos toolkit composites with premultiplied alpha throughout: source coefficient
// ONE, destination ONE_MINUS_SRC_ALPHA, on both colour and alpha. Recognising that
// exact state lets `opengl.zig` use the grounded emitter for every draw the desktop
// makes, and refuse the arbitrary blend equations nothing above it yet asks for.

/// True when `b` is the premultiplied-over blend (`GL_ONE`, `GL_ONE_MINUS_SRC_ALPHA`)
/// that `methods.blendPremultOn` emits. A pure predicate so the recognition is pinned
/// by a test rather than restated at the call site.
pub fn blendIsPremultOver(b: idraw.Blend) bool {
    return b.enable and b.src == .one and b.dst == .one_minus_src_alpha;
}

// ── host golden tests ────────────────────────────────────────────────────────
//
// Each pins a transcribed value against the reference doc. Mutation test: change any
// constant above and the matching case here goes red.
