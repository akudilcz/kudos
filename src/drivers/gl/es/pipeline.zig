//! State -> idraw.Pipeline: everything about a draw except the vertices.
//!
//! The last pure step. Above this, GL's conventions; below it, the hardware's. The
//! translation is small but every part of it is a bug if it is missed:
//!
//! **y flips.** GL measures window coordinates UP from the bottom left. The framebuffer
//! measures DOWN from the top left. So a viewport or scissor box arrives here in GL's
//! convention and leaves in the framebuffer's, and the frame height is what it turns
//! around. (The matching flip for geometry is in the clip correction —
//! uniforms.CLIP_CORRECTION — because a matrix can carry it for free.)
//!
//! **A disabled test is not a permissive test.** GL_DEPTH_TEST off does not mean
//! GL_ALWAYS: it also means no depth WRITE, whatever glDepthMask says. Lowering "off"
//! to "always" would quietly fill the depth buffer.
//!
//! **Blending and logic op are exclusive.** The standard says enabling GL_COLOR_LOGIC_OP
//! wins, so the pipeline may not carry both.
//!
//! Grounding: the OpenGL ES 1.1.12 Full Specification §2.11 (viewport), §4.1 (per-fragment
//! operations), §4.1.6 (blending vs logic op).

pub const idraw = @import("idraw");
const limits = @import("limits.zig");
const shaderkey = @import("shaderkey.zig");
pub const state = @import("state.zig");
pub const texparam = @import("texparam.zig");

const Context = state.Context;

/// A GL rectangle (y up from the bottom) as a framebuffer rectangle (y down from the
/// top). Height is what the flip turns around: the top edge in one is the bottom edge in
/// the other.
pub fn flipRect(r: state.Viewport, frame_h: u32) idraw.Rect {
    return .{
        .x = r.x,
        .y = @as(i32, @intCast(frame_h)) - (r.y + @as(i32, @intCast(r.h))),
        .w = r.w,
        .h = r.h,
    };
}

/// The sampler state for one contributing unit. Only ever called for a unit
/// shaderkey.unitContributes agreed on, so the lookups below cannot fail — but they are
/// checked rather than asserted, because the two disagreeing is exactly the bug this
/// shape was chosen to prevent.
fn unitFor(g: *const Context, gl_unit: usize) ?idraw.Unit {
    return unitForName(g, g.texture_binding[gl_unit]);
}

/// The sampler state for texture `name`, or null when the name is unbound, unknown,
/// or incomplete — the completeness rule a combiner unit gets, shared by the
/// material-map slots (GL_KUDOS_material_maps), whose null means "neutral identity"
/// rather than "error".
fn unitForName(g: *const Context, name: u32) ?idraw.Unit {
    if (name == 0) return null;
    const rec = g.textures.recordConst(name) orelse return null;
    const h = rec.handle orelse return null;
    const s: texparam.Sampler = @bitCast(@as(u16, @truncate(rec.aux)));
    return .{
        .texture = h,
        .wrap_s = s.wrap_s,
        .wrap_t = s.wrap_t,
        // The hardware filters within a level and between levels separately; GL packs
        // both into one minification token, so it is split apart here.
        .min = switch (s.min_filter) {
            .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear => .nearest,
            .linear, .linear_mipmap_nearest, .linear_mipmap_linear => .linear,
        },
        .mag = s.mag_filter,
        .mip = switch (s.min_filter) {
            .nearest, .linear => .none,
            .nearest_mipmap_nearest, .linear_mipmap_nearest => .nearest,
            .nearest_mipmap_linear, .linear_mipmap_linear => .linear,
        },
    };
}

/// Build the pipeline for the state as it stands, drawing primitive `prim` (which
/// reaches the shader key — OES_point_sprite exists for points alone). `uniform_image`
/// is the packed constant buffer (uniforms.pack), which the caller owns and reuses.
pub fn build(g: *const Context, uniform_image: []const u8, prim: idraw.Prim) idraw.Pipeline {
    var units: [idraw.MAX_UNITS]?idraw.Unit = .{null} ** idraw.MAX_UNITS;
    var idx: [limits.MAX_TEXTURE_UNITS]u8 = undefined;
    const n = shaderkey.contributingUnits(g, &idx);
    for (idx[0..n], 0..) |gl_unit, slot| units[slot] = unitFor(g, gl_unit);

    // The material-map slots (GL_KUDOS_material_maps): resolved by name with the
    // same completeness rule as the units; a slot that fails it stays null and the
    // backend shades that map's neutral identity.
    var mat_maps: [idraw.MatMap.COUNT]?idraw.Unit = .{null} ** idraw.MatMap.COUNT;
    for (g.mat_maps, 0..) |name, slot| mat_maps[slot] = unitForName(g, name);

    return .{
        .key = shaderkey.keyFor(g, prim),
        .viewport = flipRect(g.viewport, g.frame_h),
        // glDepthRangef's arguments are already [0, 1] in ES — the remap that matters is
        // in clip space, and the correction matrix has already done it.
        .depth_range = g.depth_range,
        .scissor = if (g.caps.scissor_test) flipRect(g.scissor_box, g.frame_h) else null,
        .raster = .{
            .cull = if (g.caps.cull_face) g.cull_face else null,
            .front_face = g.front_face,
            // Both zero means no offset, so a disabled offset needs no separate flag.
            .poly_offset_factor = if (g.caps.polygon_offset_fill) g.polygon_offset_factor else 0,
            .poly_offset_units = if (g.caps.polygon_offset_fill) g.polygon_offset_units else 0,
            .line_width = g.line_width,
        },
        .depth = .{
            .test_enable = g.caps.depth_test,
            // With the test off, nothing is written either — this is NOT the same as
            // GL_ALWAYS, which writes every fragment's depth.
            .write = g.caps.depth_test and g.depth_writemask,
            .func = g.depth_func,
        },
        .stencil = .{
            .test_enable = g.caps.stencil_test,
            .func = g.stencil_func,
            .ref = g.stencil_ref,
            .read_mask = g.stencil_value_mask,
            .write_mask = g.stencil_writemask,
            .fail = g.stencil_fail,
            .depth_fail = g.stencil_zfail,
            .depth_pass = g.stencil_zpass,
        },
        // Logic op excludes blending, so a state with both enabled lowers to logic op
        // alone rather than to something the hardware would have to arbitrate.
        .blend = .{
            .enable = g.caps.blend and !g.caps.color_logic_op,
            .src = g.blend_src,
            .dst = g.blend_dst,
        },
        .logic_op = if (g.caps.color_logic_op) g.logic_op else null,
        .alpha_test = if (g.caps.alpha_test) .{ .func = g.alpha_func, .ref = g.alpha_ref } else null,
        .color_mask = g.color_writemask,
        .dither = g.caps.dither,
        .sample_coverage = .{
            .enable = g.caps.sample_coverage and g.caps.multisample,
            .value = g.sample_coverage_value,
            .invert = g.sample_coverage_invert,
        },
        .units = units,
        .mat_maps = mat_maps,
        .uniforms = uniform_image,
    };
}
