#!/usr/bin/env bash
# One-time: build the compile-factory image — the pinned zig toolchain behind
# `make factory`. Everything the factory needs is inside it; nothing is
# installed on this machine except docker itself. Re-run only when the
# Dockerfile or the zig pin in scripts/setup.sh changes; the layer cache makes
# an unchanged rebuild almost free.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=container.sh
. "$HERE/container.sh"
pick_docker

echo "factory-setup: building $IMAGE (zig $ZIG_VERSION)"
$DOCKER build -t "$IMAGE" \
    --build-arg ZIG_VERSION="$ZIG_VERSION" \
    --build-arg ZIG_SHA256="$ZIG_SHA256" \
    -f "$HERE/Dockerfile" "$HERE" || {
    echo "factory-setup: ERROR: image build failed" >&2
    exit 1
}

echo "factory-setup: done. Now: make factory"
