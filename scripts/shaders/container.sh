# The container the shader factory runs in. Sourced, not executed.
#
# Two facts live here because two scripts need them and they must agree: setup.sh builds
# this image, run.sh runs it.

# Tagged with the Mesa version it carries, because that is what makes one image different
# from another — the compiler inside it.
IMAGE="kudos-shaders:26.0.3"

# shellcheck source=../docker.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker.sh"
