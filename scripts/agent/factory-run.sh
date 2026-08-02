#!/usr/bin/env bash
# `make factory` — serve the compile factory from the pinned-toolchain container.
#
# The repo is mounted READ-ONLY: the factory can compile from it but can never
# write into kudos source — the agent's only write channels are the workspace
# volume (its own module sources) and the compiled blobs it is handed back.
# The named volume keeps agent-authored sources across container restarts.
#
# FACTORY_TOKEN and OPENROUTER_API_KEY pass through from the environment when
# set: the first gates the POST endpoints on this LAN-exposed port, the second
# lets /chat relay to OpenRouter.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=container.sh
. "$HERE/container.sh"
pick_docker

# Secrets (OPENROUTER_API_KEY, FACTORY_TOKEN) live in the git-ignored .env at
# the repo root and are sourced here, so `make factory` just works.
if [ -f "$REPO/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$REPO/.env"
    set +a
fi

$DOCKER image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "factory: ERROR: the toolchain image $IMAGE does not exist." >&2
    echo "  Build it once with: make factory-setup" >&2
    exit 1
}

FACTORY_PORT="${FACTORY_PORT:-8623}"

# Pass secrets by VALUE, not by name: pick_docker may run `sudo docker`, and
# sudo strips the environment, so a bare `-e OPENROUTER_API_KEY` would forward
# an unset variable and the /chat relay would 401.
exec $DOCKER run --rm --init \
    -p "$FACTORY_PORT:8623" \
    -v "$REPO:/kudos:ro" \
    -v kudos-factory-workspace:/workspace \
    -e FACTORY_TOKEN="${FACTORY_TOKEN:-}" \
    -e OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    "$IMAGE" \
    python3 /kudos/scripts/agent/factory.py serve \
        --host 0.0.0.0 --port 8623 --workspace /workspace
