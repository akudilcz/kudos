#!/usr/bin/env bash
# `make shaders` — regenerate the committed shader blobs inside the toolchain container.
#
# This is the host half: it mounts the repo into the image and runs build.sh there. The
# work itself is in build.sh, which never runs outside the container, because the
# compiler it drives only exists inside one.
#
# There is no GPU in this loop. NVK compiles for Ada against a drm-shim that pretends to
# be one, so a laptop produces the blobs lemon will run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=container.sh
. "$HERE/container.sh"
pick_docker

$DOCKER image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "shader-factory: ERROR: the toolchain image $IMAGE does not exist." >&2
    echo "  Build it once with: make shaders-setup" >&2
    exit 1
}

# The blobs must land in the working tree owned by the user who ran make, not by root.
# A container writing root-owned files into a git tree is a mess to clean up and an easy
# thing to prevent.
exec $DOCKER run --rm \
    -v "$REPO:/kudos" \
    -u "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    "$IMAGE" \
    bash /kudos/scripts/shaders/build.sh
