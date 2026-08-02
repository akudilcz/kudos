#version 450
// Fragment for variant 4: texture * physically-based Cook-Torrance shading,
// one directional light. glTF 2.0 metallic-roughness BRDF (spec R60/R61):
// GGX (Trowbridge-Reitz) normal distribution + Smith geometry + Fresnel-
// Schlick — energy-conserving, replacing the old ad-hoc Blinn-Phong. It reads
// the SAME push block: roughness is derived from the shininess lane
// (ambient.w) so no push-constant layout change is needed, and the material is
// treated as a dielectric (metallic 0). Per-material metallic/roughness/
// emissive from glTF are extracted by the loader (glb.Submesh) for the future
// per-submesh material path; this shader is the shading-model upgrade.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_world;
layout(location = 0) out vec4 o_color;

const float PI = 3.14159265359;

// GGX / Trowbridge-Reitz normal distribution.
float distributionGGX(float n_dot_h, float rough) {
    float a = rough * rough;
    float a2 = a * a;
    float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
    return a2 / max(PI * d * d, 1e-7);
}

// Schlick-GGX geometry term for one direction.
float geometrySchlick(float n_dot_x, float k) {
    return n_dot_x / (n_dot_x * (1.0 - k) + k);
}

vec3 fresnelSchlick(float cos_theta, vec3 f0) {
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

void main() {
    vec4 base = texture(u_tex, v_uv);
    vec3 albedo = base.rgb;
    // Roughness from the shininess lane: Blinn-Phong exponent → GGX roughness
    // (alpha = sqrt(2/(shininess+2))), clamped off the mirror singularity.
    float rough = clamp(sqrt(2.0 / (max(pc.ambient.w, 1.0) + 2.0)), 0.05, 1.0);
    const float metallic = 0.0; // dielectric (per-material metal is a later tier)

    vec3 n = normalize(v_normal);
    vec3 l = normalize(pc.light_dir.xyz);
    vec3 v = normalize(pc.eye_pos.xyz - v_world);
    vec3 h = normalize(l + v);

    float n_dot_l = max(dot(n, l), 0.0);
    float n_dot_v = max(dot(n, v), 1e-4);
    float n_dot_h = max(dot(n, h), 0.0);
    float v_dot_h = max(dot(v, h), 0.0);

    vec3 f0 = mix(vec3(0.04), albedo, metallic);
    float ndf = distributionGGX(n_dot_h, rough);
    float k = (rough + 1.0) * (rough + 1.0) / 8.0; // direct-lighting remap
    float g = geometrySchlick(n_dot_v, k) * geometrySchlick(n_dot_l, k);
    vec3 fr = fresnelSchlick(v_dot_h, f0);

    vec3 specular = (ndf * g * fr) / max(4.0 * n_dot_v * n_dot_l, 1e-4);
    // Energy conservation: the non-specular fraction diffuses (metals: none).
    vec3 kd = (vec3(1.0) - fr) * (1.0 - metallic);
    vec3 diffuse = kd * albedo / PI;

    vec3 color = (diffuse + specular) * pc.light_color.rgb * n_dot_l
               + pc.ambient.rgb * albedo; // ambient term
    // Alpha mode (pc.light_dir.w): BLEND uses the texture's alpha and outputs
    // premultiplied (the card blends premultiplied-over only); OPAQUE forces 1.
    float out_a = (pc.light_dir.w > 0.5) ? base.a : 1.0;
    o_color = vec4(color * out_a, out_a);
}
