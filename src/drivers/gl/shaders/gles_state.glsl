// OpenGL ES 1.1 fixed-function state, as the shaders read it.
//
// GENERATED. DO NOT EDIT. Regenerate with:
//
//     python3 scripts/gl/es11_glsl_layout.py
//
// Read out of src/drivers/gl/es/uniforms.zig, which packs these bytes. The two
// sides of a constant-buffer ABI that disagree do not fail to build — they render
// garbage — so there is only one side, and this is the other end of it.
//
// NOT push constants: this block is 1376 bytes and NVK's maxPushConstantsSize
// is 256. It is a uniform buffer, bound as a cbuf by address, which also keeps it away
// from the LOAD_CONSTANT_BUFFER window that hangs the engine past 16 dwords.
//
// What follows is that block, GlState, together with the limits that size it, the
// Light and TexEnv structs it holds, and the texture-environment bytecode vocabulary.

// The standard's minimums, as es/limits.zig states them. The shaders size their
// loops from these rather than from a literal that would drift.
#define MAX_LIGHTS            8
#define MAX_CLIP_PLANES       6
#define MAX_TEXTURE_UNITS     2

struct Light {
    vec4 ambient;
    vec4 diffuse;
    vec4 specular;
    vec4 position;      // eye space; w = 0 directional, 1 positional
    vec4 spot_dir;      // xyz direction, w = cos(cutoff); -1 means not a spotlight
    vec4 attenuation;   // constant, linear, quadratic, spot_exponent
};

struct TexEnv {
    vec4 color;
    // The COMBINE bytecode. Four words carrying 905,969,664 settings per unit — the
    // reason this is interpreted rather than compiled into a program per state.
    uvec4 words;
};

layout(std140, set = 0, binding = 2) uniform GlState {
    mat4 mvp;                           // 0x000  projection * modelview, clip-corrected
    mat4 modelview;                     // 0x040  for eye-space position
    mat3 normal_matrix;                 // 0x080  three vec4s in std140
    mat4 tex_matrix[2];                 // 0x0B0
    vec4 material[5];                   // 0x130  ambient, diffuse, specular, emission, (shininess,0,0,0)
    vec4 light_model_ambient;           // 0x180
    vec4 fog_color;                     // 0x190
    vec4 fog_params;                    // 0x1A0  density, start, end, 1/(end-start)
    vec4 misc;                          // 0x1B0  alpha_ref, point_size, 0, 0
    vec4 clip_plane[6];                 // 0x1C0
    Light lights[8];                    // 0x220
    TexEnv texenv[2];                   // 0x520
} gl;

#define TEX0_BINDING          0
#define TEX1_BINDING          1

// ── the texture-environment bytecode ─────────────────────────────────────────
//
// Names and values read from es/state.zig, packed by es/uniforms.zig's envWord0..3.
// Zig numbers an enum by declaration order and so does the bytecode, so these are
// generated rather than transcribed — inserting a case renumbers its successors,
// and a transcribed copy would keep compiling while reading the wrong function.
// TEXTURE_ENV_MODE — the five fixed functions, then COMBINE.
#define ENV_REPLACE               0u
#define ENV_MODULATE              1u
#define ENV_DECAL                 2u
#define ENV_BLEND                 3u
#define ENV_ADD                   4u
#define ENV_COMBINE               5u

// COMBINE_RGB.
#define CRGB_REPLACE              0u
#define CRGB_MODULATE             1u
#define CRGB_ADD                  2u
#define CRGB_ADD_SIGNED           3u
#define CRGB_INTERPOLATE          4u
#define CRGB_SUBTRACT             5u
#define CRGB_DOT3_RGB             6u
#define CRGB_DOT3_RGBA            7u

// COMBINE_ALPHA — no DOT3: a dot product has no alpha-only meaning.
#define CALPHA_REPLACE            0u
#define CALPHA_MODULATE           1u
#define CALPHA_ADD                2u
#define CALPHA_ADD_SIGNED         3u
#define CALPHA_INTERPOLATE        4u
#define CALPHA_SUBTRACT           5u

// SRC_n — where an argument comes from.
#define SRC_TEXTURE               0u
#define SRC_CONSTANT              1u
#define SRC_PRIMARY_COLOR         2u
#define SRC_PREVIOUS              3u

// OPERAND_n for RGB — two bits, because rgb may read either colour or alpha.
#define OPRGB_SRC_COLOR           0u
#define OPRGB_ONE_MINUS_SRC_COLOR 1u
#define OPRGB_SRC_ALPHA           2u
#define OPRGB_ONE_MINUS_SRC_ALPHA 3u

// OPERAND_n for ALPHA — one bit: an alpha operand can only read alpha.
#define OPA_SRC_ALPHA             0u
#define OPA_ONE_MINUS_SRC_ALPHA   1u

// Where each field sits, mirroring es/uniforms.zig's envWord0..3.
#define ENV_MODE(w0)              ((w0) & 7u)
#define ENV_CRGB(w0)              (((w0) >> 3) & 0xFu)
#define ENV_CALPHA(w0)            (((w0) >> 7) & 7u)
#define ENV_SRC_RGB(w1, i)        (((w1) >> (2u * (i))) & 3u)
#define ENV_SRC_ALPHA(w1, i)      (((w1) >> (6u + 2u * (i))) & 3u)
#define ENV_OP_RGB(w2, i)         (((w2) >> (2u * (i))) & 3u)
#define ENV_OP_ALPHA(w2, i)       (((w2) >> (6u + (i))) & 1u)
// The scales are shifts: 1, 2, 4 become 0, 1, 2.
#define ENV_RGB_SCALE(w3)         float(1u << ((w3) & 3u))
#define ENV_ALPHA_SCALE(w3)       float(1u << (((w3) >> 2) & 3u))

// GLSTATE_BYTES = 1376
//
// That is es/uniforms.zig's SIZE, arrived at independently by walking this block.
// If the two ever disagree the shaders read the wrong bytes, so --check refuses.
