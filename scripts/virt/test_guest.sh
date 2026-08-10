#!/usr/bin/env bash
# test_guest.sh — the acceptance gate for a built guest image: boot the pair
# under plain QEMU (not kudos) and prove the userland it exists for actually
# comes up. One script, one subcommand per image, matching build_guest.sh.
#
# This is the CHEAP half of verifying a guest. QEMU boots the same kernel and
# initramfs kudos will, on hardware devices instead of kudos's emulated ones, so
# a failure here is the image's fault and never the hypervisor's — which is
# exactly the question worth answering before spending a kudos boot on it.
#
# Usage: scripts/virt/test_guest.sh <staged|firefox|zigserver|ubuntu> [budget_s]
# Requires: qemu-system-x86_64 and an image built by scripts/virt/build_guest.sh.
set -euo pipefail

IMAGE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSETS="$ROOT/assets/virt"

# The port the host reaches the guest's factory on. Only the zig server has a
# service to test; it is forwarded rather than bridged so this gate needs no
# privileges and no network setup.
FACTORY_HOSTPORT=18623
FACTORY_PORT=8623

case "$IMAGE" in
staged)    OUT="$ASSETS";           MARKER="KUDOS-GUEST-UP";      RAM=512;  DEFAULT_BUDGET=60 ;;
firefox)   OUT="$ASSETS/firefox";   MARKER="KUDOS-FIREFOX-UP";    RAM=3072; DEFAULT_BUDGET=300 ;;
zigserver) OUT="$ASSETS/zigserver"; MARKER="KUDOS-ZIGSERVER-UP";  RAM=3072; DEFAULT_BUDGET=420 ;;
ubuntu)    OUT="$ASSETS/ubuntu";    MARKER="KUDOS-UBUNTU-UP";     RAM=1536; DEFAULT_BUDGET=120 ;;
*)
    echo "usage: scripts/virt/test_guest.sh <staged|firefox|zigserver|ubuntu> [budget_s]" >&2
    exit 2
    ;;
esac
BUDGET_S="${2:-$DEFAULT_BUDGET}"

[ -f "$OUT/bzImage" ] && [ -f "$OUT/initramfs.cpio.gz" ] || {
    echo "test_guest: no pair in $OUT — run scripts/virt/build_guest.sh $IMAGE first" >&2
    exit 1
}

LOG="$(mktemp -t "kudos-guest-$IMAGE-XXXXXX.log")"
NET=(-netdev user,id=n0 -device virtio-net-pci,netdev=n0)
# The staged guest's kernel carries no PCI at all (it is built for the devices
# kudos emulates and nothing else), so giving it a NIC would only log a warning.
[ "$IMAGE" = staged ] && NET=()
# Only the zig server has a service to reach, and a forward the image does not
# need is a port this gate can collide with itself on.
[ "$IMAGE" = zigserver ] &&
    NET=(-netdev "user,id=n0,hostfwd=tcp::$FACTORY_HOSTPORT-:$FACTORY_PORT" -device virtio-net-pci,netdev=n0)

qemu-system-x86_64 -m "$RAM" -smp 2 -no-reboot -nographic \
    -kernel "$OUT/bzImage" -initrd "$OUT/initramfs.cpio.gz" \
    -append "console=ttyS0 no_timer_check tsc=reliable mitigations=off" \
    "${NET[@]}" > "$LOG" 2>&1 &
QEMU_PID=$!
cleanup() { kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; }
trap cleanup EXIT

# Every wait states a budget, and a dead guest is reported as dead rather than
# waited out: the log holds whatever it managed to say before it died.
waited=0
until grep -q "$MARKER" "$LOG"; do
    kill -0 "$QEMU_PID" 2>/dev/null || {
        echo "test_guest($IMAGE): FAIL — qemu exited during boot; serial log $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    }
    waited=$((waited + 2))
    [ "$waited" -lt "$BUDGET_S" ] || {
        echo "test_guest($IMAGE): FAIL — no '$MARKER' within ${BUDGET_S}s; serial log $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    }
    sleep 2
done
echo "test_guest($IMAGE): booted to '$MARKER' in ~${waited}s"

# The zig server has one more thing to prove, and it is the whole reason the
# image exists: that it compiles kudos source into a kudos binary. The blob is
# checked for the loader's magic rather than merely for a 200 — a factory that
# answers with the wrong bytes is worse than one that answers with none.
if [ "$IMAGE" = zigserver ]; then
    # Wait for the guest's own warm-up compile first. Its first build takes
    # minutes on an emulated CPU and every build after it takes under a second,
    # so racing it would measure the wrong thing and, on a small guest, fight it
    # for memory. The guest says when it is ready; believe it rather than sleep.
    until grep -q "build cache warm" "$LOG"; do
        kill -0 "$QEMU_PID" 2>/dev/null || {
            echo "test_guest(zigserver): FAIL — qemu exited while warming; log $LOG:" >&2
            tail -30 "$LOG" >&2
            exit 1
        }
        grep -q "warm-up compile FAILED" "$LOG" && {
            echo "test_guest(zigserver): FAIL — the guest's own warm-up compile failed; log $LOG:" >&2
            tail -30 "$LOG" >&2
            exit 1
        }
        waited=$((waited + 2))
        [ "$waited" -lt "$BUDGET_S" ] || {
            echo "test_guest(zigserver): FAIL — build cache not warm within ${BUDGET_S}s; log $LOG:" >&2
            tail -30 "$LOG" >&2
            exit 1
        }
        sleep 2
    done
    echo "test_guest(zigserver): build cache warm at ~${waited}s"
    echo "test_guest(zigserver): compiling scripts/agent/samples/hello.zig through the guest ..."
    python3 - "$FACTORY_HOSTPORT" "$ROOT" <<'PY' || exit 1
import json, sys, urllib.error, urllib.request

port, root = sys.argv[1], sys.argv[2]
src = open(root + "/scripts/agent/samples/hello.zig").read()
abi = open(root + "/src/kernel/loader/abi.zig").read()
version = int([l for l in abi.splitlines() if "ABI_VERSION" in l and "pub const" in l][0]
              .split("=")[1].strip().rstrip(";"), 0)
body = json.dumps({"name": "hello", "kind": "app", "abi_version": version,
                   "source": src}).encode()
req = urllib.request.Request("http://127.0.0.1:%s/compile" % port, data=body,
                             headers={"Content-Type": "application/json"})
try:
    blob = urllib.request.urlopen(req, timeout=300).read()
except urllib.error.HTTPError as e:
    print("test_guest(zigserver): FAIL - factory answered %d: %s"
          % (e.code, e.read().decode()[:400]), file=sys.stderr)
    sys.exit(1)
if blob[:4] != b"KDOS":
    print("test_guest(zigserver): FAIL - answer is not a .kudos image (%r)"
          % blob[:16], file=sys.stderr)
    sys.exit(1)
print("test_guest(zigserver): compiled a %d-byte .kudos app" % len(blob))
PY
fi

echo "test_guest($IMAGE): PASS"
