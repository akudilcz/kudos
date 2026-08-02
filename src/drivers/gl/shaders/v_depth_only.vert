#version 450
// Variant 5: depth-only pass from the light's POV (shadow map render, P7).
// No fragment shader; no varyings.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
void main() {
    gl_Position = pc.light_mvp * pc.model * vec4(a_pos, 1.0);
}
