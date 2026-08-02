#version 450
// Fragment for variants 1-2: interpolated vertex color.
layout(location = 0) in vec3 v_color;
layout(location = 0) out vec4 o_color;
void main() {
    o_color = vec4(v_color, 1.0);
}
