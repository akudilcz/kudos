#version 450
// 2D UI vertex program: MVP transform, then pass the RGBA vertex colour and the
// texture coordinate through to the fragment stage.
//
// The kudos 2D toolkit (kgl) streams position, colour and one texture coordinate for
// every shape it draws — a flat fill, a glyph and an image are the same three
// attributes, differing only in which texture the coordinate lands in (a flat fill
// samples a 1x1 white texel, so one program serves all three). This is the vertex half
// of that program.
//
// Attribute locations are the idraw AttribSlot indices — position 0, colour 2,
// texcoord0 3 — so the GR backend can bind each enabled slot to its own shader input
// without a per-shader remap table.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(location = 0) in vec3 a_pos;
layout(location = 2) in vec4 a_color;
layout(location = 3) in vec2 a_uv;
layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_uv;
void main() {
    gl_Position = pc.mvp * vec4(a_pos, 1.0);
    v_color = a_color;
    v_uv = a_uv;
}
