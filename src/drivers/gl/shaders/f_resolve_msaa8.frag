#version 450
// MSAA 8x resolve: average the 8 samples of the bound multisampled texture
// at this fragment's pixel (box filter — the standard MSAA resolve).
layout(set = 0, binding = 0) uniform sampler2DMS u_tex;
layout(location = 0) out vec4 o_color;
void main() {
    ivec2 p = ivec2(gl_FragCoord.xy);
    vec4 acc = vec4(0.0);
    for (int i = 0; i < 8; i++)
        acc += texelFetch(u_tex, p, i);
    o_color = acc * 0.125;
}
