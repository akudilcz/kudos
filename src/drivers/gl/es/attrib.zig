//! What an array's bytes mean, and who has to do the work.
//!
//! An application describes an array as a size and a type — 3 floats, 4 unsigned bytes.
//! The vertex-fetch hardware decodes most of those itself. This file decides which, and
//! it is the whole of the decision, so nothing downstream has to reason about GL types.
//!
//! ## The rule that is easy to get backwards
//!
//! Integer components do NOT all mean the same thing, and the difference is per
//! attribute rather than per type:
//!
//!   * A **colour** of unsigned bytes is NORMALIZED: 255 means 1.0. (§2.12, figure 2.6:
//!     "[0, 2^k-1] -> Convert to [0.0, 1.0]".)
//!   * A **normal** of signed bytes is also NORMALIZED: 127 means 1.0. The specification
//!     says so in as many words — "for the normal array... byte, short, or integer
//!     values are converted to floating-point values as indicated for the corresponding
//!     (signed) type in table 2.7" (§2.8).
//!   * A **position** or **texture coordinate** of signed bytes is RAW: -128 means
//!     -128.0. It is a coordinate, and no sentence in §2.8 converts it. Normalizing one
//!     would collapse a model into a two-unit cube.
//!
//! Getting this wrong does not fail: it renders a model that is lit wrongly, or 127
//! times too large.
//!
//! ## GL_FIXED is the one the hardware cannot do
//!
//! 16.16 is not a format any vertex fetcher decodes, so an array of it must be widened
//! to float on the CPU before the GPU ever sees it. That is the only conversion this
//! layer is obliged to perform, and marking it here is what lets the draw path stage
//! exactly the arrays that need it and pass the rest through untouched.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.8 (table 2.4, the array
//! conversions), §2.12 (figure 2.6, table 2.7).

const std = @import("std");
pub const idraw = @import("idraw");
const state = @import("state.zig");

pub const DataType = state.ArrayPointer.DataType;

/// How an array reaches the GPU.
pub const Resolved = union(enum) {
    /// The fetcher decodes these bytes as they are. No copy, no conversion — a buffer
    /// object's data is drawn in place.
    native: idraw.AttribFormat,
    /// The CPU must widen every component to float first. Only GL_FIXED needs this.
    widen: idraw.AttribFormat,
};

/// Bytes per component, as the application stored them.
pub fn componentSize(t: DataType) u32 {
    return switch (t) {
        .byte, .ubyte => 1,
        .short, .ushort => 2,
        .fixed, .float => 4,
    };
}

/// A float format of `size` components — what a widened array becomes.
fn floatFormat(size: u32) idraw.AttribFormat {
    return switch (size) {
        1 => .f32x1,
        2 => .f32x2,
        3 => .f32x3,
        else => .f32x4,
    };
}

/// How this attribute's (size, type) reaches the GPU. Null when the combination is not
/// one the standard allows for this slot — but `vertex.zig` has already rejected those,
/// so a null here means the two files disagree, not that an application erred.
pub fn resolve(slot: idraw.AttribSlot, size: u32, t: DataType) ?Resolved {
    // 16.16 first: no fetcher decodes it, whatever the attribute.
    if (t == .fixed) return .{ .widen = floatFormat(size) };
    if (t == .float) return .{ .native = floatFormat(size) };

    return switch (slot) {
        // A colour's unsigned bytes are normalized, and it is always four of them.
        .color => switch (t) {
            .ubyte => if (size == 4) .{ .native = .u8x4_unorm } else null,
            else => null,
        },
        // A normal's signed components are normalized, and it is always three.
        .normal => switch (t) {
            .byte => if (size == 3) .{ .native = .i8x3_snorm } else null,
            .short => if (size == 3) .{ .native = .i16x3_snorm } else null,
            else => null,
        },
        // Coordinates are raw: the integer IS the value.
        .position, .texcoord0, .texcoord1 => switch (t) {
            .byte => switch (size) {
                2 => .{ .native = .i8x2 },
                3 => .{ .native = .i8x3 },
                4 => .{ .native = .i8x4 },
                else => null,
            },
            .short => switch (size) {
                2 => .{ .native = .i16x2 },
                3 => .{ .native = .i16x3 },
                4 => .{ .native = .i16x4 },
                else => null,
            },
            else => null,
        },
        // A point size is one float or one fixed; both are handled above.
        .point_size => null,
    };
}

/// Does this array have to be staged through the CPU?
pub fn needsWidening(t: DataType) bool {
    return t == .fixed;
}

/// The byte width of one element AFTER any widening — what a staged array occupies.
pub fn stagedElementSize(size: u32, t: DataType) u32 {
    return if (needsWidening(t)) size * 4 else size * componentSize(t);
}
