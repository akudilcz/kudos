#!/usr/bin/env bash
# Fetch, patch and build the shader compiler: Mesa's NVK, and the drm-shim that lets it
# run without a GPU. This is the expensive, unchanging half of the factory, so it runs
# once when the container image is built (scripts/shaders/Dockerfile) rather than on
# every `make shaders`.
#
# It is a pure function of its inputs — the pinned tarball, patches/, and the image's
# toolchain — which is precisely why it belongs in the image. Docker's layer cache
# rebuilds it when a patch changes and never otherwise.
#
# Why NVK at all: kudos has no shader compiler. Its blobs are compiled ahead of time by
# NVIDIA's own compiler (NAK, a Rust library inside NVK), and nothing ships that
# standalone — so we need Mesa's source, not a driver.
set -euo pipefail

MESA_VER="${MESA_VER:?}"
MESA_SHA256="${MESA_SHA256:?}"
MESA="${KUDOS_MESA_DIR:?}"
PATCHES="${PATCHES_DIR:?}"

say() { echo "mesa: $*"; }
fail() { echo "mesa: ERROR: $*" >&2; exit 1; }

# 1. the source, pinned by content. The version alone is not a pin — the hash is. A
# different Mesa is a different compiler, and a different compiler is different blobs.
tarball="/tmp/mesa-$MESA_VER.tar.xz"
say "fetching mesa $MESA_VER"
curl -fsSL -o "$tarball" "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" \
    || fail "could not fetch the mesa tarball"
echo "$MESA_SHA256  $tarball" | sha256sum -c - \
    || fail "mesa tarball does not match its pinned sha256 — refusing to build a compiler we cannot identify"

mkdir -p "$(dirname "$MESA")"
rm -rf "$MESA"
tar -xf "$tarball" -C "$(dirname "$MESA")"
mv "$(dirname "$MESA")/mesa-$MESA_VER" "$MESA"
rm -f "$tarball"

# 2. the two patches. One makes NVK dump the exact image it would have uploaded to the
# GPU; the other teaches the drm-shim to answer as an Ada card.
patch -p1 -d "$MESA" < "$PATCHES/0001-nvk-shader-dump.patch" || fail "shader-dump patch did not apply"
patch -p1 -d "$MESA" < "$PATCHES/0002-drm-shim-ada-classes.patch" || fail "drm-shim patch did not apply"

# 3. configure and build.
#
# CLC (OpenCL C) cannot be turned off here, and it is worth knowing why before anyone
# tries: meson.build:883 lists nouveau_vk in `with_driver_using_cl`, so asking for NVK
# forces `with_clc`, which requires SPIRV-LLVM-Translator >= 21.1. No Ubuntu packages
# that — which is the whole reason this build lives in a container.
#
# Everything not needed to reach NAK is off: no window systems, no GL, no Gallium. We
# want one Vulkan driver's compiler and a shim to run it against.
say "configuring"
meson setup "$MESA/build" "$MESA" \
    -Dvulkan-drivers=nouveau \
    -Dgallium-drivers= \
    -Dtools=drm-shim \
    -Dplatforms= \
    -Dglx=disabled \
    -Degl=disabled \
    -Dgbm=disabled \
    -Dbuildtype=release \
    || fail "meson setup failed"

say "building (several minutes)"
ninja -C "$MESA/build" || fail "mesa build failed"

# 4. prove the two artifacts the factory actually consumes exist, here, where the error
# is about the toolchain — not later, where it would look like a shader problem.
[ -f "$MESA/build/src/nouveau/vulkan/libvulkan_nouveau.so" ] || fail "NVK did not build"
[ -f "$MESA/build/src/nouveau/drm-shim/libnouveau_noop_drm_shim.so" ] || fail "drm-shim did not build"

# 5. drop the object files. The image needs the two shared objects and the ICD, not the
# ~2 GB of intermediates that produced them.
find "$MESA/build" -name '*.o' -delete
say "OK"
