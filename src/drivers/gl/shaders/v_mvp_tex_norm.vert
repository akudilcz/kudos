#version 450
// Variant 4 vertex: MVP + UV + world-space normal/position. Lit cube (P6).
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_world;
void main() {
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
    // model is rotation+uniform-scale only (cube demo) -> mat3 suffices, no
    // inverse-transpose. Revisit if non-uniform scale ever appears.
    v_normal = mat3(pc.model) * a_normal;
    v_world = (pc.model * vec4(a_pos, 1.0)).xyz;
}
