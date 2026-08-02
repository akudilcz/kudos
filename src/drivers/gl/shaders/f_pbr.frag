#version 450
// Fragment for the material-maps dialect (GL_KUDOS_material_maps, spec RND-005;
// APP-011): texture × physically-based Cook-Torrance shading with the four glTF
// metallic-roughness maps, one directional light plus the ANALYTIC ENVIRONMENT
// (ENV_*): one hemispheric radiance field about the light axis — sampled at the
// normal it is the diffuse irradiance, sampled at the view reflection it is
// what a smooth surface mirrors, widening toward the diffuse answer as
// roughness spreads the lobe. Base colour and emissive decode from sRGB,
// lighting runs linear, and the result leaves through the ACES tone map and
// the sRGB encode. Roughness/metallic read the metal-rough map's G/B channels
// (material factors are baked into the texels by the loader), the shading
// normal is bent by the normal map through a derivative cotangent frame (the
// mesh carries no tangents), occlusion gates the environment terms, emissive
// is added outside the exposure (the glow is the surface's own radiance, not
// scene light). The CPU statement of the same equations is soft.zig's
// pbrFragment — the two are edited together, never apart.
#extension GL_GOOGLE_include_directive : require
#include "pc_layout.glsl"
layout(set = 0, binding = 0) uniform sampler2D u_tex;
layout(set = 0, binding = 1) uniform sampler2D u_mr;
layout(set = 0, binding = 3) uniform sampler2D u_normal;
layout(set = 0, binding = 4) uniform sampler2D u_occlusion;
layout(set = 0, binding = 5) uniform sampler2D u_emissive;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_normal;
layout(location = 2) in vec3 v_world;
layout(location = 0) out vec4 o_color;

const float PI = 3.14159265359;

// The analytic environment — soft.zig's ENV_* constants, spelled once there
// and once here.
const vec3 ENV_SKY = vec3(0.80, 0.62, 0.40);
const vec3 ENV_GROUND = vec3(0.30, 0.22, 0.13);
const float ENV_EXPOSURE = 0.85;

// sRGB decode/encode (IEC 61966-2-1), the piecewise curve per channel.
vec3 srgbToLinear(vec3 c) {
    bvec3 lo = lessThanEqual(c, vec3(0.04045));
    vec3 lin = c / 12.92;
    vec3 pow_ = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(pow_, lin, lo);
}

vec3 linearToSrgb(vec3 c) {
    bvec3 lo = lessThanEqual(c, vec3(0.0031308));
    vec3 lin = c * 12.92;
    vec3 pow_ = 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055;
    return mix(pow_, lin, lo);
}

// The ACES filmic tone map (Narkowicz's rational fit).
vec3 acesTonemap(vec3 x) {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
}

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

// Bend the interpolated normal by the tangent-space normal texel. The tangent
// frame comes from screen-space derivatives (Schüler's cotangent frame) — the
// mesh has no tangent attribute, and the derivative frame needs none. A
// degenerate UV mapping collapses the frame; the guard falls back to the
// interpolated normal, matching soft.zig's null-frame path.
vec3 perturbNormal(vec3 n, vec3 pos, vec2 uv) {
    vec3 nt = texture(u_normal, uv).rgb * 2.0 - 1.0;
    vec3 dp1 = dFdx(pos);
    vec3 dp2 = dFdy(pos);
    vec2 duv1 = dFdx(uv);
    vec2 duv2 = dFdy(uv);
    vec3 dp2perp = cross(dp2, n);
    vec3 dp1perp = cross(n, dp1);
    vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;
    float det = max(dot(t, t), dot(b, b));
    if (det < 1e-14) return n;
    float invmax = inversesqrt(det);
    return normalize(mat3(t * invmax, b * invmax, n) * nt);
}

void main() {
    vec4 base = texture(u_tex, v_uv);
    vec3 albedo = srgbToLinear(base.rgb); // base/emissive texels are sRGB
    vec3 mr = texture(u_mr, v_uv).rgb;
    // Roughness clamped off the mirror singularity, exactly as the soft mirror.
    float rough = clamp(mr.g, 0.05, 1.0);
    float metallic = mr.b;
    float ao = texture(u_occlusion, v_uv).r;
    vec3 emissive = srgbToLinear(texture(u_emissive, v_uv).rgb);

    vec3 n = perturbNormal(normalize(v_normal), v_world, v_uv);
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
    vec3 direct = (diffuse + specular) * pc.light_color.rgb * n_dot_l;

    // The analytic environment: irradiance × albedo on the diffuse half, the
    // reflected radiance Fresnel-weighted on the specular half, occlusion
    // gating both.
    float hemi = 0.5 * dot(n, l) + 0.5;
    vec3 rdir = 2.0 * n_dot_v * n - v;
    float rhemi = 0.5 * dot(rdir, l) + 0.5;
    vec3 irr = mix(ENV_GROUND, ENV_SKY, hemi);
    vec3 irr_r = mix(ENV_GROUND, ENV_SKY, rhemi);
    vec3 irr_spec = mix(irr_r, irr, rough); // wide lobes converge on irradiance
    vec3 f90 = max(vec3(1.0 - rough), f0); // rough surfaces lose grazing sheen
    float fv = pow(clamp(1.0 - n_dot_v, 0.0, 1.0), 5.0);
    vec3 fenv = f0 + (f90 - f0) * fv;
    vec3 env = (irr * albedo * (1.0 - metallic) + irr_spec * fenv) * ao;

    // Emissive is the surface's own radiance — the camera exposure scales the
    // scene light around it, not the glow itself.
    vec3 lin = (direct + env) * ENV_EXPOSURE + emissive;
    vec3 color = linearToSrgb(acesTonemap(lin));

    // Alpha mode (pc.light_dir.w): BLEND uses the texture's alpha and outputs
    // premultiplied (the card blends premultiplied-over only); OPAQUE forces 1.
    float out_a = (pc.light_dir.w > 0.5) ? base.a : 1.0;
    o_color = vec4(color * out_a, out_a);
}
