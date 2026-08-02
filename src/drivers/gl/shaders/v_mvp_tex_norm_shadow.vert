#version 450
// Variant 6 vertex: variant 4 + light-space position for shadow receive (P7).
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec3 a_normal;
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_normal;
layout(location = 2) out vec3 v_world;
layout(location = 3) out vec4 v_light_pos;
void main() {
    vec4 world = pc.model * vec4(a_pos, 1.0);
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
    v_normal = mat3(pc.model) * a_normal;
    v_world = world.xyz;
    v_light_pos = pc.light_mvp * world;
}
