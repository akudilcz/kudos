//! GL_KUDOS_material_maps — attach glTF material maps to a lit draw (spec RND-005).
//!
//! OpenGL ES 1.1's fixed-function fragment cannot address the five textures a glTF
//! metallic-roughness material carries, and kudos has no runtime shader compiler to
//! grow the pipeline toward ES 2.0. This vendor extension is the narrow bridge: four
//! sticky bindings — metallic-roughness, normal, occlusion, emissive — that a lit
//! draw carries alongside its base-colour unit, each sampled by the physically-based
//! fragment program through the mesh's texcoord0. Binding zero clears a slot; an
//! unbound or incomplete slot shades as the map's neutral identity (idraw.MatMap).
//!
//! The tokens below are kudos-assigned. enums.zig and entrypoints.zig are generated
//! from the Khronos ES 1.1 sources and must not carry names Khronos never issued, so
//! a vendor extension's tokens live here, in the module that owns the extension.

const idraw = @import("idraw");
const enums = @import("enums.zig");
const state = @import("state.zig");

const GLenum = enums.GLenum;
const GLuint = enums.GLuint;
const Context = state.Context;

/// The slot semantics (and order) of the four maps — the extension's own type,
/// re-published from the seam so callers never import idraw themselves.
pub const MatMap = idraw.MatMap;

/// Extension presence token, mirroring the generated GL_OES_* pattern.
pub const GL_KUDOS_material_maps: enums.GLint = 1;
/// The map selectors glMaterialMapKUDOS accepts, in idraw.MatMap slot order.
/// 0x6Bxx is outside every range the Khronos registry has allocated.
pub const GL_METAL_ROUGH_MAP_KUDOS: GLenum = 0x6B00;
pub const GL_NORMAL_MAP_KUDOS: GLenum = 0x6B01;
pub const GL_OCCLUSION_MAP_KUDOS: GLenum = 0x6B02;
pub const GL_EMISSIVE_MAP_KUDOS: GLenum = 0x6B03;

/// glMaterialMapKUDOS. Records `texture` as the named material map for the draws
/// that follow, the way glBindTexture records a unit's texture: sticky until
/// rebound, zero clears. The name need not be complete yet — completeness is
/// judged when the draw is built, where an incomplete map contributes its
/// neutral identity rather than an error.
pub fn materialMap(g: *Context, map: GLenum, texture: GLuint) void {
    const slot: idraw.MatMap = switch (map) {
        GL_METAL_ROUGH_MAP_KUDOS => .metal_rough,
        GL_NORMAL_MAP_KUDOS => .normal,
        GL_OCCLUSION_MAP_KUDOS => .occlusion,
        GL_EMISSIVE_MAP_KUDOS => .emissive,
        else => return g.recordError(.invalid_enum),
    };
    g.mat_maps[@intFromEnum(slot)] = texture;
}
