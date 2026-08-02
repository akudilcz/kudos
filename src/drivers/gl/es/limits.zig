//! The floors the standard sets, and the sizes we build to.
//!
//! OpenGL ES 1.1 states a minimum for each implementation-dependent value: at least 8
//! lights, a modelview stack at least 16 deep, and so on. An implementation may exceed
//! them, and an application is entitled to ask what it actually got.
//!
//! These are the numbers kudos builds its arrays to, so they must be compile-time
//! constants. They are NOT what `glGet` answers for values the device decides — the
//! largest texture, the sample count, subpixel precision — because that would let this
//! module promise something the silicon cannot honour. Those come from
//! `iface/idraw.zig`'s `Limits`, read from the device at context creation. The floors
//! below are what we check the device against.

/// GL_MAX_LIGHTS. Floor 8. Each is a full parameter set in the constant buffer, and the
/// shader key spends 4 bits on the enabled count, so 8 is also our ceiling.
pub const MAX_LIGHTS: u32 = 8;

/// GL_MAX_CLIP_PLANES. Floor 6.
pub const MAX_CLIP_PLANES: u32 = 6;

/// GL_MAX_MODELVIEW_STACK_DEPTH. Floor 16.
pub const MAX_MODELVIEW_STACK_DEPTH: u32 = 16;

/// GL_MAX_PROJECTION_STACK_DEPTH. Floor 2. Deeper than the floor because it costs 64
/// bytes a level and an application that pushes projection twice is not exotic.
pub const MAX_PROJECTION_STACK_DEPTH: u32 = 4;

/// GL_MAX_TEXTURE_STACK_DEPTH. Floor 2. Per texture unit.
pub const MAX_TEXTURE_STACK_DEPTH: u32 = 4;

/// GL_MAX_TEXTURE_UNITS. Floor 1 — the standard requires only one, and multitexture is
/// expressible without being mandated. Two is what fixed-function content that uses it
/// at all expects: a base map plus a light map or decal.
pub const MAX_TEXTURE_UNITS: u32 = 2;

/// GL_SUBPIXEL_BITS floor. Reported from the device, checked against this.
pub const MIN_SUBPIXEL_BITS: u32 = 4;

/// GL_MAX_TEXTURE_SIZE floor. Reported from the device, checked against this.
pub const MIN_TEXTURE_SIZE: u32 = 64;

/// The largest mip chain a texture can have at MAX texture size — log2(8192) + 1. Sizes
/// the per-texture level arrays.
pub const MAX_MIP_LEVELS: u32 = 14;

pub const idraw = @import("idraw");

/// Does this device meet the standard's floors? A device that does not cannot host a
/// conforming implementation, and finding that out at context creation beats finding it
/// out when an application's texture silently fails to bind.
pub fn deviceMeetsFloors(l: idraw.Limits) bool {
    return l.max_texture_size >= MIN_TEXTURE_SIZE and
        l.texture_units >= 1 and
        l.subpixel_bits >= MIN_SUBPIXEL_BITS and
        l.samples >= 1;
}
