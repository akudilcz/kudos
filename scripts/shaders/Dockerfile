# The shader factory's toolchain, pinned.
#
# kudos's shader blobs are compiled by NVIDIA's own compiler (NAK, inside Mesa's NVK),
# driven GPU-less: a drm-shim pretends to be an Ada card, NVK compiles for it, and a
# patch dumps the exact image it would have uploaded. The blobs are committed, so the
# compiler that produced them is part of the source in every sense that matters — a
# different Mesa, or a different LLVM under it, is a different compiler and different
# output.
#
# That is why this is an image and not a list of `apt install` lines in a README. Mesa
# 26.0.3 requires SPIRV-LLVM-Translator >= 21.1, and asking for NVK forces that
# requirement on (scripts/shaders/mesa.sh §3 explains the meson path). Ubuntu 24.04 ships
# 19.1, so the factory simply cannot be built on this machine's userland. Debian sid can,
# and pinning it by digest makes "cannot" into "pinned".
#
# Build it with `make shaders-setup`; use it with `make shaders`.

# Pinned by digest, not by tag: `sid` is a moving target, and a toolchain that drifts
# under committed binaries is the bug this image exists to prevent.
FROM debian:sid@sha256:7469781d68f44940c9494eeba6e7ab89063947f794320d61c193bf027aeb7761

ARG MESA_VER=26.0.3
ARG MESA_SHA256=ddb7443d328e89aa45b4b6b80f077bf937f099daeca8ba48cabe32aab769e134

ENV DEBIAN_FRONTEND=noninteractive
ENV KUDOS_MESA_DIR=/opt/mesa
ENV PATCHES_DIR=/opt/patches

# The toolchain, in four groups: build system, Mesa's own generators, the LLVM/CLC stack
# that NVK forces on (llvm-21 — the version whose SPIRV translator is >= 21.1), and Rust,
# because NAK is written in Rust. libvulkan-dev is for the harness in build.sh, which is
# an ordinary Vulkan program.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential meson ninja-build pkg-config patch curl xz-utils ca-certificates \
        python3 python3-mako python3-ply python3-yaml flex bison \
        libexpat1-dev zlib1g-dev libzstd-dev libdrm-dev libvulkan-dev \
        llvm-21-dev libclang-21-dev clang-21 libclc-21-dev libllvmspirvlib-21-dev \
        spirv-tools spirv-tools-dev glslang-tools \
        rustc cargo bindgen cbindgen \
    && rm -rf /var/lib/apt/lists/*

# Patches first, in their own layer: they are the input most likely to change, and Docker
# rebuilds Mesa exactly when they do.
COPY patches /opt/patches
COPY mesa.sh /opt/mesa.sh
RUN MESA_VER="$MESA_VER" MESA_SHA256="$MESA_SHA256" bash /opt/mesa.sh

# The repo is mounted here at run time; nothing of kudos is baked in.
WORKDIR /kudos
