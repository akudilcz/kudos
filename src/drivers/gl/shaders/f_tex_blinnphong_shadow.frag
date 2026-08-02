#version 450
// Fragment for variant 6: Blinn-Phong * shadow-map visibility.
// u_shadow is a depth texture with a depth-compare sampler (TSC
// DEPTH_COMPARE=1, func LEQUAL): the HW returns
// the comparison result, sampled here through sampler2DShadow.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(set = 0, binding = 1) uniform sampler2DShadow u_shadow;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_world;
layout(location = 3) in vec4 v_light_pos;
layout(location = 0) out vec4 o_color;
void main() {
    vec3 albedo = texture(u_tex, v_uv).rgb;
    vec3 n = normalize(v_normal);
    vec3 l = normalize(pc.light_dir.xyz);
    vec3 v = normalize(pc.eye_pos.xyz - v_world);
    vec3 h = normalize(l + v);
    float diff = max(dot(n, l), 0.0);
    float spec = pow(max(dot(n, h), 0.0), pc.ambient.w) * pc.light_color.w;

    // light-space NDC -> [0,1] uv; constant bias against acne.
    vec3 sc = v_light_pos.xyz / v_light_pos.w;
    vec2 suv = sc.xy * 0.5 + 0.5;
    float vis = texture(u_shadow, vec3(suv, sc.z - 0.0015));
    if (sc.z > 1.0 || suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0)
        vis = 1.0; // outside the shadow map: lit

    vec3 color = albedo * (pc.ambient.rgb + pc.light_color.rgb * (diff * vis))
               + pc.light_color.rgb * (spec * vis);
    o_color = vec4(color, 1.0);
}
