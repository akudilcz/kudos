#version 450
// Lit-geometry vertex program: MVP transform, plus the eye-space normal and position the
// Blinn-Phong fragment (f_tex_blinnphong) needs for one directional light.
//
// This is the vertex half of the model-viewer's lit path. It is v_mvp_tex_norm rebound to
// the idraw AttribSlot layout — position 0, normal 1, texcoord0 3 — so the GR backend
// binds every shader's attributes by the same rule. The fragment stays as it was.
//
// The backend marshals eye-space lighting into this program's push-constant block: `model`
// carries the modelview (so a normal and a position land in eye space), and the eye is the
// origin, which is exactly where OpenGL ES 1.1 lights — so `mat3(model) * normal` and
// `model * pos` are the eye-space quantities the standard's lighting equation wants.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_normal;
layout(location = 3) in vec2 a_uv;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_world;
void main() {
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
    // Rigid modelview (the viewer only rotates and translates), so mat3 is the correct
    // normal transform with no inverse-transpose.
    v_normal = mat3(pc.model) * a_normal;
    v_world = (pc.model * vec4(a_pos, 1.0)).xyz;
}
