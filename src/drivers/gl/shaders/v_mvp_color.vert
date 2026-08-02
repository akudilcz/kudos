#version 450
// Variant 2 vertex: MVP transform + color. Rotating cube (P4).
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 1) in vec3 a_color;
layout(location = 0) out vec3 v_color;
void main() {
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_color = a_color;
}
