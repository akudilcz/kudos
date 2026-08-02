#version 450
// MSAA resolve pass vertex: passthrough NDC position for the 3-vertex
// fullscreen triangle. No varyings — the fragment uses gl_FragCoord.
layout(location = 0) in vec3 a_pos;
void main() {
    gl_Position = vec4(a_pos, 1.0);
}
