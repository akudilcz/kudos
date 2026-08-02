#version 450
// 2D UI fragment program: the sampled texel MODULATED by the interpolated vertex
// colour.
//
// GL_MODULATE (texel * primary colour) is the one texture environment the 2D toolkit
// uses, and this program is it, specialised to a single unit. What each kind of 2D draw
// gets out of it falls out of what it samples:
//   - a flat fill samples a 1x1 white texel, so the output is the vertex colour;
//   - a glyph samples coverage replicated into every channel, so the output is
//     coverage * colour;
//   - an image samples its own texels.
//
// The output is premultiplied, matching the compositor's blend (ONE,
// ONE_MINUS_SRC_ALPHA): the toolkit supplies premultiplied vertex colours, and
// texel * colour keeps a premultiplied texel premultiplied. This is the same arithmetic
// the software backend (soft.zig) evaluates, so a window drawn on the 4090 matches the
// one drawn on the CPU.
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;
layout(location = 0) out vec4 o_color;
void main() {
    o_color = texture(u_tex, v_uv) * v_color;
}
