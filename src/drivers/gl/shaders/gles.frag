#version 450
// The OpenGL ES 1.1 fixed-function fragment stage.
//
// One program per (units, two-sided, fog) — 24 in all. UNITS, TWO_SIDED and FOG arrive
// as -D on the command line (scripts/shaders/build.sh).
//
// The light count is deliberately absent. ES 1.1 lights per vertex (§2.12), so by the
// time a fragment exists its lighting is already a colour that was interpolated across
// the primitive — this stage could not tell one light from eight. Two-sidedness does
// reach here, because the standard picks between the front and back colours by the sign
// of the polygon's window-space signed area, which is exactly gl_FrontFacing.
//
// ## Why the texture environment is interpreted
//
// One texture unit's COMBINE state is 8 RGB functions x 6 ALPHA functions x 4^3 RGB
// sources x 4^3 ALPHA sources x 4^3 RGB operands x 2^3 ALPHA operands x 3 RGB_SCALE
// x 3 ALPHA_SCALE = 905,969,664 settings. Two units square it to 8.2e17. A program per
// state is not large, it is impossible — so the state arrives as four words in the
// constant buffer and the loop below decodes them.
//
// It costs less than it looks. Every branch below tests a constant-buffer value, so it
// is warp-uniform: all threads take the same side and nothing diverges. What it does
// cost is registers, which a few models on a 4090 can afford.
//
// Grounding: the OpenGL ES 1.1.12 Full Specification §3.7.12 (texture environment), §3.9
// (fog); the bytecode is packed by es/uniforms.zig envWord0..3.
#extension GL_GOOGLE_include_directive : require
#include "gles_state.glsl"

#if !defined(UNITS) || !defined(TWO_SIDED) || !defined(FOG)
#error "gles.frag is a variant template: define UNITS, TWO_SIDED and FOG"
#endif

// OES_point_sprite (the `_spr` variants): a point draw whose units may take their
// texture coordinates from the point's own (s, t) — gl_PointCoord — instead of the
// interpolated coordinate. Which units replace arrives per draw as a bitmask in
// gl.misc.z, bit i = packed unit i, so one program covers every replace combination.
// Sprites are point draws only; a point is always front-facing, so TWO_SIDED never
// combines with SPRITE and the factory does not build that pairing.
#ifndef SPRITE
#define SPRITE 0
#endif
#if SPRITE && TWO_SIDED
#error "a point sprite has no back face: SPRITE excludes TWO_SIDED"
#endif

// Fog modes, matching iface/idraw.zig FogMode's tags.
#define FOG_OFF     0
#define FOG_LINEAR  1
#define FOG_EXP     2
#define FOG_EXP2    3

layout(location = 0) in vec4 v_color;
#if TWO_SIDED
layout(location = 1) in vec4 v_back_color;
#endif
#if UNITS >= 1
layout(location = 2) in vec4 v_texcoord0;
#endif
#if UNITS >= 2
layout(location = 3) in vec4 v_texcoord1;
#endif
#if FOG != FOG_OFF
layout(location = 4) in float v_fog_dist;
#endif

layout(location = 0) out vec4 o_color;

// Only the fragment stage samples, so the samplers are declared here rather than in the
// generated header — the set layout grants them no vertex stage. The binding numbers
// still come from the header, because shader_factory.c and the kernel must agree with
// them.
#if UNITS >= 1
layout(set = 0, binding = TEX0_BINDING) uniform sampler2D u_tex0;
#endif
#if UNITS >= 2
layout(set = 0, binding = TEX1_BINDING) uniform sampler2D u_tex1;
#endif

#if UNITS >= 1
// One argument of the COMBINE equation: pick a source, then read it through an operand.
vec4 srcValue(uint src, vec4 texel, vec4 constant, vec4 primary, vec4 previous) {
    if (src == SRC_TEXTURE)       return texel;
    if (src == SRC_CONSTANT)      return constant;
    if (src == SRC_PRIMARY_COLOR) return primary;
    return previous;
}

// The whole environment for one unit: `previous` in, the new colour out. Table 3.16 for
// the five fixed functions, then the COMBINE decoder.
vec4 texEnv(uint w0, uint w1, uint w2, uint w3,
            vec4 constant, vec4 previous, vec4 primary, vec4 texel) {
    uint mode = ENV_MODE(w0);

    if (mode == ENV_REPLACE)  return texel;
    if (mode == ENV_MODULATE) return previous * texel;
    if (mode == ENV_DECAL)
        // The texel's own alpha blends its colour over what came before; alpha passes
        // through untouched.
        return vec4(mix(previous.rgb, texel.rgb, texel.a), previous.a);
    if (mode == ENV_BLEND)
        // The texel picks, per channel, between what came before and the constant.
        return vec4(mix(previous.rgb, constant.rgb, texel.rgb), previous.a * texel.a);
    if (mode == ENV_ADD)
        return vec4(min(previous.rgb + texel.rgb, 1.0), previous.a * texel.a);

    // COMBINE.
    uint crgb   = ENV_CRGB(w0);
    uint calpha = ENV_CALPHA(w0);

    vec3  arg_rgb[3];
    float arg_a[3];
    for (uint i = 0u; i < 3u; i++) {
        vec4 s_rgb = srcValue(ENV_SRC_RGB(w1, i),   texel, constant, primary, previous);
        vec4 s_a   = srcValue(ENV_SRC_ALPHA(w1, i), texel, constant, primary, previous);

        uint op_rgb = ENV_OP_RGB(w2, i);
        if (op_rgb == OPRGB_SRC_COLOR)                 arg_rgb[i] = s_rgb.rgb;
        else if (op_rgb == OPRGB_ONE_MINUS_SRC_COLOR)  arg_rgb[i] = 1.0 - s_rgb.rgb;
        else if (op_rgb == OPRGB_SRC_ALPHA)            arg_rgb[i] = vec3(s_rgb.a);
        else                                           arg_rgb[i] = vec3(1.0 - s_rgb.a);

        arg_a[i] = ENV_OP_ALPHA(w2, i) == OPA_SRC_ALPHA ? s_a.a : 1.0 - s_a.a;
    }

    vec3 rgb;
    if (crgb == CRGB_REPLACE)          rgb = arg_rgb[0];
    else if (crgb == CRGB_MODULATE)    rgb = arg_rgb[0] * arg_rgb[1];
    else if (crgb == CRGB_ADD)         rgb = arg_rgb[0] + arg_rgb[1];
    else if (crgb == CRGB_ADD_SIGNED)  rgb = arg_rgb[0] + arg_rgb[1] - 0.5;
    else if (crgb == CRGB_INTERPOLATE) rgb = mix(arg_rgb[1], arg_rgb[0], arg_rgb[2]);
    else if (crgb == CRGB_SUBTRACT)    rgb = arg_rgb[0] - arg_rgb[1];
    else
        // DOT3_RGB and DOT3_RGBA: the arguments are unsigned encodings of a signed
        // vector, so each is biased back by 0.5 and the result scaled by 4. One scalar
        // lands in every channel.
        rgb = vec3(4.0 * dot(arg_rgb[0] - 0.5, arg_rgb[1] - 0.5));

    float alpha;
    if (calpha == CALPHA_REPLACE)          alpha = arg_a[0];
    else if (calpha == CALPHA_MODULATE)    alpha = arg_a[0] * arg_a[1];
    else if (calpha == CALPHA_ADD)         alpha = arg_a[0] + arg_a[1];
    else if (calpha == CALPHA_ADD_SIGNED)  alpha = arg_a[0] + arg_a[1] - 0.5;
    else if (calpha == CALPHA_INTERPOLATE) alpha = mix(arg_a[1], arg_a[0], arg_a[2]);
    else                                   alpha = arg_a[0] - arg_a[1];

    // DOT3_RGBA drives alpha from the same scalar, and the alpha combiner is ignored.
    if (crgb == CRGB_DOT3_RGBA) alpha = rgb.r;

    return clamp(vec4(rgb * ENV_RGB_SCALE(w3), alpha * ENV_ALPHA_SCALE(w3)), 0.0, 1.0);
}
#endif

void main() {
    // §2.12.1: for a polygon the selection is by the sign of its signed area in window
    // coordinates, after FrontFace has had its say — which is what gl_FrontFacing
    // reports. Points and lines are always front-facing, and the rasterizer says so.
#if TWO_SIDED
    vec4 primary = gl_FrontFacing ? v_color : v_back_color;
#else
    vec4 primary = v_color;
#endif

    vec4 c = primary;

#if SPRITE
    uint cr_mask = uint(gl.misc.z);
#endif

#if UNITS >= 1
#if SPRITE
    vec2 tc0 = (cr_mask & 1u) != 0u ? gl_PointCoord : v_texcoord0.xy / v_texcoord0.w;
#else
    vec2 tc0 = v_texcoord0.xy / v_texcoord0.w;
#endif
    c = texEnv(gl.texenv[0].words.x, gl.texenv[0].words.y,
               gl.texenv[0].words.z, gl.texenv[0].words.w,
               gl.texenv[0].color, c, primary, texture(u_tex0, tc0));
#endif
#if UNITS >= 2
#if SPRITE
    vec2 tc1 = (cr_mask & 2u) != 0u ? gl_PointCoord : v_texcoord1.xy / v_texcoord1.w;
#else
    vec2 tc1 = v_texcoord1.xy / v_texcoord1.w;
#endif
    // The units chain: unit 1's "previous" is unit 0's result, while "primary" stays
    // the colour the vertex stage produced (§3.7.12).
    c = texEnv(gl.texenv[1].words.x, gl.texenv[1].words.y,
               gl.texenv[1].words.z, gl.texenv[1].words.w,
               gl.texenv[1].color, c, primary, texture(u_tex1, tc1));
#endif

#if FOG != FOG_OFF
    // f is clamped to [0,1] whichever equation produced it (§3.9), and blends the fog
    // colour toward the fragment: f = 1 leaves the fragment untouched.
    float f;
#if FOG == FOG_LINEAR
    // (end - c) / (end - start). es/uniforms.zig precomputed the reciprocal, and packs
    // it as zero for an empty range rather than dividing by zero here.
    f = (gl.fog_params.z - v_fog_dist) * gl.fog_params.w;
#elif FOG == FOG_EXP
    f = exp(-gl.fog_params.x * v_fog_dist);
#else
    float dz = gl.fog_params.x * v_fog_dist;
    f = exp(-dz * dz);
#endif
    f = clamp(f, 0.0, 1.0);
    // Fog leaves alpha alone — it is a colour operation only.
    c.rgb = mix(gl.fog_color.rgb, c.rgb, f);
#endif

    o_color = c;
}
