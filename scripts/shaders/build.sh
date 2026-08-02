#!/usr/bin/env bash
# kudos shader factory — builds the checked-in SM89 shader blobs.
#
# THIS RUNS INSIDE THE TOOLCHAIN CONTAINER. `make shaders` (scripts/shaders/run.sh) is
# the front door; running this on a normal machine will not find a compiler, because the
# compiler is the container (scripts/shaders/Dockerfile, and setup.sh for why).
#
# Pipeline: GLSL → SPIR-V (glslang) → NVK/NAK running GPU-less under Mesa's
# nouveau drm-shim, with a patched
# nvk_shader_upload that dumps the exact upload image → src/drivers/gl/shaders/
# <name>.{sph,bin,meta.json}, optionally + nvdisasm .sass for review.
#
# There is no GPU in this loop. NVK compiles for Ada (NOUVEAU_CHIPSET=192) against a
# drm-shim that pretends to be one, so a laptop produces the same blobs lemon would.
#
# Deterministic inputs: the GLSL sources + the pinned Mesa and patches baked into the
# image. Re-run whenever a shader source changes; commit the regenerated blobs.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MESA="${KUDOS_MESA_DIR:-/opt/mesa}"
OUT="$REPO/src/drivers/gl/shaders"

fail() { echo "shader-factory: ERROR: $*" >&2; exit 1; }

# The compiler is built into the image (scripts/shaders/mesa.sh). If it is missing we are
# not in the container, and saying that beats a confusing failure four steps later.
NVK_LIB="$MESA/build/src/nouveau/vulkan/libvulkan_nouveau.so"
SHIM_LIB="$MESA/build/src/nouveau/drm-shim/libnouveau_noop_drm_shim.so"
[ -f "$NVK_LIB" ] && [ -f "$SHIM_LIB" ] || fail \
    "no compiler at $MESA — this script runs inside the toolchain container. Use: make shaders"
ICD="$MESA/build/src/nouveau/vulkan/nouveau_devenv_icd.x86_64.json"
[ -f "$ICD" ] || fail "NVK dev ICD not found at $ICD"
[ -d "$OUT" ] || fail "$OUT missing"

# 3. GLSL → SPIR-V
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SPVS=()

compile() { # <out-name> <stage> <source> [-D...]
    local name="$1" stage="$2" src="$3"; shift 3
    glslangValidator -V --target-env vulkan1.3 -I"$OUT" -S "$stage" "$@" "$src" \
        -o "$TMP/$name.$stage.spv" >/dev/null || fail "glslang failed on $name"
    SPVS+=("$TMP/$name.$stage.spv")
}

# 3a. The fixed shaders — one blob each, name taken from the file.
for src in "$OUT"/*.vert "$OUT"/*.frag; do
    b="$(basename "$src")"
    # gles.vert/gles.frag are variant TEMPLATES: they do not compile without their
    # -D defines, and 3b below is what compiles them.
    case "$b" in gles.vert | gles.frag) continue ;; esac
    compile "${b%.*}" "${b##*.}" "$src"
done

# 3b. The ES 1.1 fixed-function variants.
#
# The counts are read out of the generated header rather than spelled here, so
# es/limits.zig remains the one place that decides how many lights and units exist.
hdr="$OUT/gles_state.glsl"
[ -f "$hdr" ] || fail "$hdr missing — run: python3 scripts/gl/es11_glsl_layout.py"
max_lights="$(sed -n 's/^#define MAX_LIGHTS  *\([0-9]*\).*/\1/p' "$hdr")"
max_units="$(sed -n 's/^#define MAX_TEXTURE_UNITS  *\([0-9]*\).*/\1/p' "$hdr")"
[ -n "$max_lights" ] && [ -n "$max_units" ] || fail "could not read the limits out of $hdr"

# The naming rule is ada/variant.zig's — spelled there for the kernel, here for the
# build. They cannot be allowed to drift apart silently, and they cannot: variant.zig
# has a test that resolves all 216 keys against the manifest THIS loop produces, so a
# disagreement is a red host test rather than a black window.
n_vert=0
for l in $(seq 0 "$max_lights"); do
    for u in $(seq 0 "$max_units"); do
        for ts in 0 1; do
            name="v_l${l}_u${u}"; [ "$ts" = 1 ] && name="${name}_2s"
            compile "$name" vert "$OUT/gles.vert" \
                "-DLIGHTS=$l" "-DUNITS=$u" "-DTWO_SIDED=$ts"
            n_vert=$((n_vert + 1))
        done
    done
done

# The fragment stage never sees a light. ES 1.1 lights per vertex (§2.12), so lighting
# has already become an interpolated colour by the time a fragment exists — which is
# why this loop has no `l` and there are 24 of these rather than 216.
n_frag=0
for u in $(seq 0 "$max_units"); do
    for ts in 0 1; do
        for fog in 0:off 1:lin 2:exp 3:exp2; do
            name="f_u${u}"; [ "$ts" = 1 ] && name="${name}_2s"
            name="${name}_${fog#*:}"
            compile "$name" frag "$OUT/gles.frag" \
                "-DUNITS=$u" "-DTWO_SIDED=$ts" "-DFOG=${fog%%:*}"
            n_frag=$((n_frag + 1))
        done
    done
done

# The OES_point_sprite fragment variants (`_spr`): units >= 1 only (with no
# contributing unit there is nothing to replace) and never two-sided (a point is
# always front-facing), which is why this loop is 8 programs rather than 24.
for u in $(seq 1 "$max_units"); do
    for fog in 0:off 1:lin 2:exp 3:exp2; do
        compile "f_u${u}_${fog#*:}_spr" frag "$OUT/gles.frag" \
            "-DUNITS=$u" "-DTWO_SIDED=0" "-DFOG=${fog%%:*}" "-DSPRITE=1"
        n_frag=$((n_frag + 1))
    done
done
echo "shader-factory: $n_vert vertex + $n_frag fragment variants for the fixed-function key space"

# 4. build + run the harness (dumps .sph/.bin/.meta.json via the NVK patch)
gcc -O2 -o "$TMP/shader_factory" "$REPO/scripts/shaders/shader_factory.c" \
    -lvulkan || fail "harness build failed"
LD_PRELOAD="$SHIM_LIB" \
NOUVEAU_CHIPSET=192 \
VK_ICD_FILENAMES="$ICD" \
NVK_SHADER_DUMP_DIR="$OUT" \
    "$TMP/shader_factory" "${SPVS[@]}" || fail "factory harness failed"

# 5. disassemble every blob for human review — OPTIONAL. The .sass files are for a human
# reading the SASS; the kernel embeds only .sph and .bin. Skipped without complaint when
# CUDA is not installed, because it is not part of the product.
if command -v nvdisasm >/dev/null 2>&1; then
    for bin in "$OUT"/*.bin; do
        nvdisasm -b SM89 "$bin" > "${bin%.bin}.sass" || fail "nvdisasm failed on $bin"
    done
else
    echo "shader-factory: nvdisasm absent — skipping the .sass review dumps (blobs unaffected)"
fi

# 6. generate manifest.zig (the kernel's single entry to the blob set)
python3 - "$OUT" <<'PYEOF' || fail "manifest generation failed"
import json, os, sys
out = sys.argv[1]
names = sorted(n[: -len(".meta.json")] for n in os.listdir(out) if n.endswith(".meta.json"))
with open(os.path.join(out, "manifest.zig"), "w") as f:
    f.write("//! GENERATED by scripts/shaders/build.sh - DO NOT EDIT.\n")
    f.write("//! One entry per shader variant: the SM89 upload image pieces\n")
    f.write("//! (128B SPHv4 + raw code) and the launch metadata the 3D class\n")
    f.write("//! binding needs.\n\n")
    f.write("pub const Stage = enum(u32) { vertex = 0, fragment = 4 };\n\n")
    f.write("pub const Shader = struct {\n")
    f.write("    name: []const u8,\n    stage: Stage,\n    num_gprs: u32,\n")
    f.write("    slm_size: u32,\n    sph: []const u8,\n    code: []const u8,\n};\n\n")
    f.write("pub const shaders = [_]Shader{\n")
    for n in names:
        m = json.load(open(os.path.join(out, n + ".meta.json")))
        st = "vertex" if m["stage"] == 0 else "fragment"
        f.write(f'    .{{ .name = "{n}", .stage = .{st}, .num_gprs = {m["num_gprs"]}, '
                f'.slm_size = {m["slm_size"]}, .sph = @embedFile("{n}.sph"), '
                f'.code = @embedFile("{n}.bin") }},\n')
    f.write("};\n")
print(f"manifest.zig: {len(names)} shaders")
PYEOF

echo "shader-factory: OK — blobs in $OUT:"
ls -la "$OUT"/*.bin
