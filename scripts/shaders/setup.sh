#!/usr/bin/env bash
# The shader factory's toolchain — the one-time cost behind `make shaders`.
#
# This builds a container image holding a pinned Mesa, built for Ada, with the two
# patches applied. Everything the factory needs is inside it; nothing is installed on
# this machine except docker itself.
#
# It is a container rather than host packages for a reason that is not convenience. The
# blobs in src/drivers/gl/shaders/ are committed binaries, so the compiler that produced
# them is part of the source — and it must therefore be identifiable and repeatable. Mesa
# 26.0.3 also needs SPIRV-LLVM-Translator >= 21.1, which Ubuntu does not package at all,
# so on this machine's userland the factory is not merely unpinned, it is unbuildable.
#
# Cost: a few minutes and ~3 GB, once. Re-run it only when the Dockerfile or a patch
# changes; Docker's layer cache makes an unchanged rebuild almost free.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=container.sh
. "$HERE/container.sh"
pick_docker

echo "shader-setup: building $IMAGE (a few minutes on a cold cache)"
$DOCKER build -t "$IMAGE" -f "$HERE/Dockerfile" "$HERE" || {
    echo "shader-setup: ERROR: image build failed" >&2
    exit 1
}

echo "shader-setup: done. Now: make shaders"
