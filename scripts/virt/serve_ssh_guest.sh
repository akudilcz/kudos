#!/usr/bin/env bash
# serve_ssh_guest.sh — serve the "kudos lab Linux" netboot pair over plain HTTP
# so a kudos `vm boot` can fetch it (the background fetch path speaks http
# only). Serves assets/virt/ssh/ on port 8000, all interfaces; the URL shape
# the catalog entry (src/kernel/virt/guestlist.zig) expects is
#
#     http://<this-host>:8000/bzImage
#     http://<this-host>:8000/initramfs.cpio.gz
#
# where <this-host> is 10.0.2.2 when kudos runs under QEMU slirp on this
# machine (slirp's address for the host), or this machine's LAN IP when kudos
# runs on real hardware (lemon) — the catalog ships the 10.0.2.2 form.
#
# Usage: scripts/virt/serve_ssh_guest.sh [port]   (default 8000)
set -euo pipefail

PORT="${1:-8000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/assets/virt/ssh"

[ -f "$OUT/bzImage" ] && [ -f "$OUT/initramfs.cpio.gz" ] || {
    echo "serve_ssh_guest: no pair in $OUT — run scripts/virt/build_ssh_guest.sh first" >&2
    exit 1
}
exec python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$OUT"
