# assets/models — the USB-stick test-model corpus

Models seeded onto the physical kudos stick's `/usbdisk/models/` (the boot-2
case table expects `rabbit.glb` there; scripts/tests/cases.py). The kernel's
own parser vets every file here — `zig build glbcheck && build/bin/glbcheck
assets/models/*.glb` must say OK before a model is added.

- `rabbit.glb` — "Rabbit" by Poly by Google, CC-BY 3.0,
  https://poly.pizza/m/dyeBDJxhDwP (706 verts, untextured — exercises the
  baseColorFactor flat-color path, complementing the textured in-kernel duck).

## Khronos glTF-Sample-Assets conformance corpus (spec R70–R72)

The reference models the glTF conformance requirements name, fetched from
https://github.com/KhronosGroup/glTF-Sample-Assets. Most ship as glTF-Binary
(.glb); `Triangle`, `TriangleWithoutIndices`, and `SimpleMeshes` have no .glb
upstream, so they ship as the self-contained glTF-Embedded variant (.gltf, a
JSON document with a base64 data-URI buffer) — the same parser loads both
container forms, and .gltf additionally exercises the JSON container and the
non-indexed draw path. Licenses per the upstream repo's per-model metadata:

Geometry and texture tier (R71 / TEST-005):
- `Triangle.gltf`, `TriangleWithoutIndices.gltf`, `SimpleMeshes.gltf` — Khronos, CC0.
- `Box.glb`, `BoxInterleaved.glb` — Khronos, CC0.
- `BoxTextured.glb` — Khronos, CC-BY 4.0.

Feature validation (R72) — CC-BY 4.0:
- `AlphaBlendModeTest.glb` — alpha OPAQUE/MASK/BLEND side by side (R36).
- `VertexColorTest.glb` — per-vertex colour modulation.
- `TextureCoordinateTest.glb` — UV orientation/addressing.
- `OrientationTest.glb` — node transforms / coordinate handedness.
- `NormalTangentTest.glb` — tangent handedness (PBR-tier stretch goal).

Stress / PBR sweep:
- `MetalRoughSpheres.glb` — metal/roughness parameter matrix, CC-BY 4.0
  (256k verts, 1.5M indices — the volume stress).

ES 1.1 has no PBR shading: the fixed-function viewer renders these models'
geometry, base colour, and blending; metal-rough/normal-map channels are
parse-vetted (glbcheck) but not yet shaded. That gap is visible, not silent.

The in-kernel/ramdisk models (`teapot.glb`, `duck.glb`) live in
`src/ui/assets/` — they are @embedFile'd into the kernel image, which is why
they are not here.
