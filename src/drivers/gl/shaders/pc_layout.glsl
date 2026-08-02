// Shared push-constant block for ALL kudos shader variants (single source of
// truth for the layout; kernel-side mirror: src/drivers/gl/opengl.zig
// PushConstants). Exactly 256 bytes = NVK's maxPushConstantsSize; lands in
// cb0 at offset 0x28. Unlit variants read only `mvp`; the kernel writes the
// full 256 B every frame regardless.
//
// Conventions:
//   - matrices are column-major (std430/GLSL default), Vulkan clip space
//     (Y down, Z in [0,1]) — mat4.zig must produce these.
//   - light_dir.xyz  = normalized direction FROM surface TOWARD the light
//   - light_dir.w    = alpha mode: >0.5 = BLEND (use texture alpha, output
//                      premultiplied), else OPAQUE (output alpha 1). The card
//                      blends premultiplied-over only, so the model's
//                      translucent pass premultiplies here (spec APP-010).
//   - light_color    = rgb * intensity, .w = specular strength
//   - ambient.rgb    = ambient light, .w = shininess exponent
//   - eye_pos.xyz    = camera position in world space
layout(push_constant) uniform PC {
    mat4 mvp;         // offset   0: model-view-projection
    mat4 model;       // offset  64: model-to-world (lighting)
    mat4 light_mvp;   // offset 128: light-space MVP (shadow pass + receive)
    vec4 light_dir;   // offset 192
    vec4 light_color; // offset 208
    vec4 ambient;     // offset 224
    vec4 eye_pos;     // offset 240
} pc;
