#version 450
// Variant 3 vertex: MVP transform + UV. Textured cube (P5).
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec2 a_uv;
layout(location = 0) out vec2 v_uv;
void main() {
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_uv = a_uv;
}
