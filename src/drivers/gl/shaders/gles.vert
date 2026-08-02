#version 450
// The OpenGL ES 1.1 fixed-function vertex stage.
//
// One program per (lights, units, two-sided) — 54 in all. LIGHTS, UNITS and TWO_SIDED
// arrive as -D on the command line (scripts/shaders/build.sh); es/shaderkey.zig decides
// them per draw and ada/variant.zig names the result.
//
// This stage does ALL of the lighting. The standard computes lighting per vertex and
// rasterizes the resulting colour (§2.12, figure 2.6) — there is no per-pixel lighting
// to be had here, and that is not an approximation, it is what ES 1.1 says. Which is
// why the light COUNT unrolls a loop in this file and never appears in the fragment
// program: by the time a fragment exists, lighting is already a colour.
//
// The mirror image is fog: it is a fragment computation over an eye-space distance this
// stage merely passes through, so this program does not branch on the fog mode. That
// asymmetry is the whole reason there are 54 vertex programs and 24 fragment ones
// rather than 216 of each.
//
// Grounding: the OpenGL ES 1.1.12 Full Specification §2.11 (clipping), §2.12 (lighting).
#extension GL_GOOGLE_include_directive : require
#include "gles_state.glsl"

#if !defined(LIGHTS) || !defined(UNITS) || !defined(TWO_SIDED)
#error "gles.vert is a variant template: define LIGHTS, UNITS and TWO_SIDED"
#endif

// The slot IS the semantic (iface/idraw.zig AttribSlot) — ES 1.1 has no general vertex
// attributes, only these six meanings, so the locations are fixed rather than assigned.
//
// Every one of these is read unconditionally, including when the application disabled
// the array: the standard says a vertex without a colour array still has a colour, just
// the same one as every other vertex. The device binds a constant in that case, so
// "disabled" needs no variant here.
layout(location = 0) in vec4 a_position;
layout(location = 1) in vec3 a_normal;
layout(location = 2) in vec4 a_color;
#if UNITS >= 1
layout(location = 3) in vec4 a_texcoord0;
#endif
#if UNITS >= 2
layout(location = 4) in vec4 a_texcoord1;
#endif
layout(location = 5) in float a_point_size;

layout(location = 0) out vec4 v_color;
#if TWO_SIDED
layout(location = 1) out vec4 v_back_color;
#endif
#if UNITS >= 1
layout(location = 2) out vec4 v_texcoord0;
#endif
#if UNITS >= 2
layout(location = 3) out vec4 v_texcoord1;
#endif
// Always written, even when nothing downstream wants it: this program cannot know the
// fog mode, and a fragment program is free to ignore an output it did not ask for.
layout(location = 4) out float v_fog_dist;

out float gl_ClipDistance[MAX_CLIP_PLANES];

#if LIGHTS > 0
// The lighting equation, §2.12.1. `n` is the normal to light against — the vertex
// normal for the front colour, its negation for the back.
vec4 lightSum(vec3 n, vec3 eye_pos) {
    vec4 m_ambient  = gl.material[0];
    vec4 m_diffuse  = gl.material[1];
    vec4 m_specular = gl.material[2];
    vec4 m_emission = gl.material[3];
    float shininess = gl.material[4].x;

    vec3 c = m_emission.rgb + gl.light_model_ambient.rgb * m_ambient.rgb;

    // The standard's lighting model has no local viewer: the eye sits at the origin in
    // eye coordinates, so the direction to it is simply the negated position.
    vec3 eye_dir = normalize(-eye_pos);

    // Unrolled against the key, over COMPACTED slots: es/uniforms.zig packs the first
    // enabled light into slot 0, so a program that enables only GL_LIGHT7 still lights
    // from slot 0 and this loop stays LIGHTS long.
    for (int i = 0; i < LIGHTS; i++) {
        vec4 pos = gl.lights[i].position;
        vec4 atten = gl.lights[i].attenuation;

        // w = 0 is a directional light: the position IS the direction, it is infinitely
        // far away, and the standard gives it no attenuation.
        vec3 vp;
        float attenuation = 1.0;
        if (pos.w == 0.0) {
            vp = normalize(pos.xyz);
        } else {
            vec3 to_light = pos.xyz - eye_pos;
            vp = normalize(to_light);
            float d = length(to_light);
            attenuation = 1.0 / (atten.x + atten.y * d + atten.z * d * d);
        }

        // Spotlights. The cutoff arrives as its cosine so this compares dot products
        // instead of taking an inverse cosine per vertex; a cutoff of 180 degrees means
        // "not a spotlight", and es/uniforms.zig packs that as exactly -1.
        float spot = 1.0;
        vec4 spot_dir = gl.lights[i].spot_dir;
        if (spot_dir.w > -1.0) {
            float cosine = dot(-vp, normalize(spot_dir.xyz));
            spot = cosine < spot_dir.w ? 0.0 : pow(max(cosine, 0.0), atten.w);
        }

        float ndotl = max(dot(n, vp), 0.0);
        vec3 term = gl.lights[i].ambient.rgb * m_ambient.rgb
                  + ndotl * gl.lights[i].diffuse.rgb * m_diffuse.rgb;

        // The specular term is dropped entirely when the surface faces away, which is
        // the standard's rule and not an optimisation: f = 0 unless n . VP > 0.
        if (ndotl > 0.0 && shininess > 0.0) {
            // Blinn-Phong — the halfway vector, not the reflection. §2.12.1 specifies
            // exactly this.
            vec3 h = normalize(vp + eye_dir);
            term += pow(max(dot(n, h), 0.0), shininess)
                  * gl.lights[i].specular.rgb * m_specular.rgb;
        }

        c += attenuation * spot * term;
    }

    // Alpha comes from the diffuse material alone — lighting never computes it.
    return vec4(clamp(c, 0.0, 1.0), m_diffuse.a);
}
#endif

void main() {
    // The mvp already carries the clip correction (es/uniforms.zig CLIP_CORRECTION):
    // GL's y-up, depth [-1,1] convention is turned into the rasterizer's y-down,
    // depth [0,1] there, once, so nothing downstream knows there were two conventions.
    gl_Position = gl.mvp * a_position;

    vec3 eye_pos = (gl.modelview * a_position).xyz;

    // §3.9 permits approximating the distance by |z_e|; we pass the true distance and
    // let the fragment stage apply the curve, which costs one varying and is exact.
    v_fog_dist = length(eye_pos);

    // A disabled point-size array arrives as a constant, so this needs no branch.
    gl_PointSize = a_point_size;

    // Clip planes are tested in EYE coordinates (§2.11): glClipPlane transformed the
    // plane by the inverse modelview when it was called, so no transform belongs here.
    // A disabled plane is packed as all zeroes, which makes this dot zero — and zero is
    // kept, so a disabled plane costs a multiply-add and clips nothing.
    for (int i = 0; i < MAX_CLIP_PLANES; i++)
        gl_ClipDistance[i] = dot(gl.clip_plane[i], vec4(eye_pos, 1.0));

#if LIGHTS > 0
    // The normal matrix is the modelview's upper-left 3x3; renormalizing here is what
    // lets es/uniforms.zig skip the inverse transpose for the rotation-plus-uniform-
    // scale stacks that glRotate/glTranslate/glScale actually build.
    vec3 n = normalize(gl.normal_matrix * a_normal);
    v_color = lightSum(n, eye_pos);
#if TWO_SIDED
    // The back colour is the same equation with the normal reversed — the standard
    // gives no way to specify different back materials in ES (§2.12.1).
    v_back_color = lightSum(-n, eye_pos);
#endif
#else
    // Lighting disabled: the current colour passes straight through.
    v_color = a_color;
#if TWO_SIDED
    v_back_color = a_color;
#endif
#endif

#if UNITS >= 1
    v_texcoord0 = gl.tex_matrix[0] * a_texcoord0;
#endif
#if UNITS >= 2
    v_texcoord1 = gl.tex_matrix[1] * a_texcoord1;
#endif
}
