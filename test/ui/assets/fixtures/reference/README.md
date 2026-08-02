# test/ui/assets/fixtures/reference — published Khronos reference renderings

The official screenshots of the feature-validation models, from the Khronos
glTF-Sample-Assets repository. They are what spec TEST-006 means by "their
published reference renderings": the host conformance suite
(test/ui/assets/render_oracle_test.zig) renders each model through the soft-raster
pipeline and holds the frame to its screenshot here with the perceptual
metric in test/support/percept.zig. Committed (not fetched at build time) so the
suite is hermetic and a silent upstream re-render cannot move the bar.

Each file is `Models/<name>/screenshot/screenshot.png` from
https://github.com/KhronosGroup/glTF-Sample-Assets (main branch), i.e.

    https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/<name>/screenshot/screenshot.png

Licenses per the upstream per-model `metadata.json`:

| screenshot | license (SPDX) | artist / owner |
|---|---|---|
| AlphaBlendModeTest.png | CC-BY-4.0 | Ed Mackey / Analytical Graphics, Inc. |
| VertexColorTest.png | CC-BY-4.0 | Ed Mackey / Analytical Graphics, Inc. |
| TextureCoordinateTest.png | CC0-1.0 | Ed Mackey / Analytical Graphics, Inc. |
| OrientationTest.png | CC-BY-4.0 | Khronos |
| NormalTangentTest.png | CC0-1.0 | Ed Mackey / Analytical Graphics, Inc. |
| MetalRoughSpheres.png | CC-BY-4.0 | Ed Mackey / Analytical Graphics, Inc. |

The models themselves ship in assets/models/ (see its README for the model
licenses); the self-blessed byte-exact goldens the fast regression layer uses
live in test/ui/assets/fixtures/renders/.
