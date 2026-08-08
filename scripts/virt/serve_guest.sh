#!/usr/bin/env bash
# serve_guest.sh — serve the locally built guest images over plain HTTP so a
# kudos `vm boot` can fetch one (the background fetch path speaks http only).
#
# Serves assets/virt/ on port 8000, all interfaces, so EVERY locally built image
# is reachable at once under its own directory — one server, and a catalog URL
# that names exactly one image:
#
#     http://<this-host>:8000/ssh/bzImage       (build_ssh_guest.sh)
#     http://<this-host>:8000/firefox/bzImage   (build_firefox_guest.sh)
#
# where <this-host> is 10.0.2.2 when kudos runs under QEMU slirp on this machine
# (slirp's address for the host), or this machine's LAN IP when kudos runs on
# real hardware (lemon) — the catalog ships the 10.0.2.2 form.
#
# Usage: scripts/virt/serve_guest.sh [port]   (default 8000)
set -euo pipefail

PORT="${1:-8000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/assets/virt"

# Say what is actually servable rather than failing on one image's absence: the
# operator asked for a server, and which images exist is the useful answer.
found=0
for dir in "$OUT"/*/; do
    [ -f "$dir/bzImage" ] && [ -f "$dir/initramfs.cpio.gz" ] || continue
    echo "serve_guest: $(basename "$dir")/ ($(du -h "$dir/initramfs.cpio.gz" | cut -f1) initramfs)"
    found=1
done
[ "$found" = 1 ] || {
    echo "serve_guest: no built image pair under $OUT — run a scripts/virt/build_*_guest.sh first" >&2
    exit 1
}
exec python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$OUT"
