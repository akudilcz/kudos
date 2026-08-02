# The container the compile factory runs in. Sourced, not executed.
#
# The zig pin has ONE home: scripts/setup.sh. It is read here so the image tag,
# the build args, and the host toolchain can never disagree about which compiler
# "the" compiler is.
AGENT_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_VERSION="$(sed -n 's/^ZIG_VERSION=//p' "$AGENT_HERE/../setup.sh")"
ZIG_SHA256="$(sed -n 's/^ZIG_SHA256=//p' "$AGENT_HERE/../setup.sh")"

# Tagged with the zig version it carries, because that is what makes one image
# different from another — the compiler inside it.
IMAGE="kudos-factory:$ZIG_VERSION"

# shellcheck source=../docker.sh
. "$AGENT_HERE/../docker.sh"
