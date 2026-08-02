#!/usr/bin/env bash
# lemon's address — the ONE home for it.
#
# The rig's IP was hardcoded in eight scripts, and when it moved every one of
# them was wrong at once: runs failed with "No route to host" until each caller
# was passed LEMON_IP by hand. ~/.ssh/config already had to be correct for the
# ssh half of every track to work, so it IS the source of truth; this asks ssh
# to resolve it rather than restating it.
#
# LEMON_IP still overrides, for a rig that is not in ssh config at all.
set -uo pipefail

if [ -n "${LEMON_IP:-}" ]; then
    echo "$LEMON_IP"
    exit 0
fi

host="${LEMON_HOST:-lemon}"
ip="$(ssh -G "$host" 2>/dev/null | awk '/^hostname /{print $2; exit}')"

# `ssh -G` echoes the alias back when there is no matching Host block; an alias
# is not an address, and silently returning one would surface as a DNS failure
# three layers down instead of here.
if [ -z "$ip" ] || [ "$ip" = "$host" ]; then
    echo "lemonip: no HostName for '$host' in ~/.ssh/config — set LEMON_IP" >&2
    exit 1
fi
echo "$ip"
