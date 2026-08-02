#!/usr/bin/env bash
# test_ssh_guest.sh — the acceptance gate for the "kudos lab Linux" pair: boot
# it under host QEMU and prove the two things the image exists for — a getty
# on the serial console, and dropbear answering ssh with a working bash.
#
# Runs entirely OUTSIDE kudos (cheapest signal first) on q35 + virtio-net-pci:
# QEMU 10.x microvm's virtio-mmio probe returns EINVAL on this kernel, and the
# gate is about the IMAGE (bash + dropbear + DHCP over ssh) — the kudos
# hypervisor exercises the MMIO path itself. The guest discovers its console from
# the cmdline and finds a 16550 at the standard port, so the same kernel boots
# unmodified here and inside kudos. The NIC is slirp, ssh on localhost:2222.
#
# Usage: scripts/virt/test_ssh_guest.sh
# Requires: qemu-system-x86_64, sshpass; artifacts from build_ssh_guest.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/assets/virt/ssh"
SSH_PORT=2222
ROOT_PASSWORD="kudos"      # the image's documented lab default (build_ssh_guest.sh)
BOOT_BUDGET_S=90           # kernel + init + dropbear key generation, generously
MARKER="KUDOS-SSH-GUEST-UP"

[ -f "$OUT/bzImage" ] && [ -f "$OUT/initramfs.cpio.gz" ] || {
    echo "test_ssh_guest: no pair in $OUT — run scripts/virt/build_ssh_guest.sh first" >&2
    exit 1
}

LOG="$(mktemp /tmp/ssh_guest_serial.XXXXXX.log)"
QEMU_PID=""
cleanup() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || true
}
trap cleanup EXIT

qemu-system-x86_64 \
    -M q35 -cpu max -m 512M \
    -kernel "$OUT/bzImage" -initrd "$OUT/initramfs.cpio.gz" \
    -append "console=ttyS0 no_timer_check tsc=reliable mitigations=off nokaslr" \
    -display none -serial "file:$LOG" -monitor none \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
    -device virtio-net-pci,netdev=n0 &
QEMU_PID=$!

SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3 -o LogLevel=ERROR)

# One budget covers boot + dropbear's first-connection key generation.
deadline=$((SECONDS + BOOT_BUDGET_S))
ssh_up=0
while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "test_ssh_guest: FAIL — qemu exited during boot; serial log $LOG:" >&2
        tail -30 "$LOG" >&2
        exit 1
    fi
    if sshpass -p "$ROOT_PASSWORD" ssh "${SSH_OPTS[@]}" root@127.0.0.1 true 2>/dev/null; then
        ssh_up=1
        break
    fi
    sleep 2
done
if [ "$ssh_up" != 1 ]; then
    echo "test_ssh_guest: FAIL — no ssh login within ${BOOT_BUDGET_S}s; serial log $LOG:" >&2
    tail -30 "$LOG" >&2
    exit 1
fi

# The real assertions, over the ssh session the image exists to provide.
REMOTE_OUT="$(sshpass -p "$ROOT_PASSWORD" ssh "${SSH_OPTS[@]}" root@127.0.0.1 \
    'echo SSH-GUEST-OK; echo "shell=$0"; bash --version | head -1; uname -sr; ip -o addr show dev eth0 | head -2')"
echo "$REMOTE_OUT"
echo "$REMOTE_OUT" | grep -q '^SSH-GUEST-OK$' || { echo "test_ssh_guest: FAIL — remote echo missing" >&2; exit 1; }
echo "$REMOTE_OUT" | grep -q 'shell=.*bash' || { echo "test_ssh_guest: FAIL — root shell is not bash" >&2; exit 1; }
echo "$REMOTE_OUT" | grep -q 'GNU bash' || { echo "test_ssh_guest: FAIL — bash missing" >&2; exit 1; }

# And the serial half: init reached its marker and a getty put up a login
# prompt on ttyS0 — the console kudos mirrors into the VM window.
grep -q "$MARKER" "$LOG" || { echo "test_ssh_guest: FAIL — init marker not on serial ($LOG)" >&2; exit 1; }
grep -q "login:" "$LOG" || { echo "test_ssh_guest: FAIL — no getty login prompt on serial ($LOG)" >&2; exit 1; }

echo "test_ssh_guest: PASS — serial getty up, ssh login as root works, bash is the shell"
echo "  (manual check: sshpass -p $ROOT_PASSWORD ssh -p $SSH_PORT root@127.0.0.1)"
