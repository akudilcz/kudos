#!/usr/bin/env bash
# boot-3-QEMU — the SMP scheduling-stress suite's emulated smoke twin.
# `make test-boot-3-qemu`.
#
# Proves the boot-3 suite's own logic without spending a lemon reboot: boots
# kudos-smp on 8 vCPUs (so phase LOAD's oversubscription means something) and
# runs BOTH assertion layers of the track:
#
#   in-kernel   -Dverify-script (src/console/verifyscript.zig): lifecycle cycles,
#               per-session address spaces, rt, the VM stage, stress churn, the
#               wake storm, and the loss-counter sweep — the assertions only the
#               kernel can make. The driver gates on `verify: ALL PASS` before
#               it injects anything (the verify task is an input producer until
#               then).
#   host-side   boot3_native.py in its qemu track: the same phases lemon runs,
#               over the same transports (KMR1 :9515 injection, netdebug :9514
#               readback). The GPU instruments (FLIPSTAT, SHOT) have no present
#               path here, so the track asserts the shell's honest no-GPU
#               flipstat error instead — no GPU asserts, by design.
#
# NEEDS NO STICK, no lemon, and no root: runs wherever there is KVM. GUEST
# COVERAGE IS PRESENCE-GATED: with no guest blobs in assets/virt (they are
# git-ignored; scripts/virt/build_guest.sh makes them) the in-kernel VM stage
# and the driver's GUEST phase both SKIP LOUDLY — stage the blobs to turn that
# coverage on. BOOT3_SKIP_GUEST=1 skips the driver's guest phase even when a
# guest is staged (for iterating the other phases past a guest-fatal defect).
# NETWORKING IS ALL SLIRP: kudos' net
# stack binds the FIRST NIC, which is run.sh's user-mode netdev — slirp forwards
# the guest's netdebug broadcast to the host loopback (the capture binds
# 127.0.0.1:9514, which also keeps a wedged kudos elsewhere on the LAN from
# bleeding its own :9514 broadcasts into this run's evidence), and a hostfwd on
# the same netdev (run.sh N0_HOSTFWD) carries KMR1 requests in. A tap + dnsmasq
# would sit on the SECOND NIC, which kudos never uses.
#
# BOOT3_SOAK_MIN=<minutes> and BOOT3_SEED=<n> pass through to the driver.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
mkdir -p "$ROOT/build/logs"
LOG="$ROOT/build/logs/boot-3-qemu-run.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "RUN_BOOT3_QEMU_EXIT=$?" >> "$LOG"' EXIT

# Single instance — and the SAME lock file as run_emulated.sh, because both
# suites fight over the QMP/monitor sockets and the :9514 capture.
LOCK=/tmp/kudos-emulated-suite.lock
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "run_boot3_qemu: FAIL — another emulated-suite run holds $LOCK" >&2
    exit 1
fi

# Preflight: reap a stale QEMU / :9514 capture from an interrupted previous run
# (same failure modes, same cure as run_emulated.sh).
if pgrep -f "qemu-system-x86_64.*kudos" >/dev/null 2>&1; then
    echo "run_boot3_qemu: killing a stale kudos QEMU from a previous run"
    sudo pkill -9 -f "qemu-system-x86_64.*kudos" || true
    sleep 1
fi
if pgrep -f "socat.*9514" >/dev/null 2>&1; then
    echo "run_boot3_qemu: killing a stale :9514 capture from a previous run"
    pkill -f "socat.*9514" || true
    sleep 1
fi

# The verify-script stage walks the LIVE page tables in-kernel: each terminal
# session holds its own address space (MEM-002) and neither space resolves the
# other's arena (MEM-004); the driver hard-fails the run on any stage failure.
echo "run_boot3_qemu: building kudos-smp (-Dtest-hooks -Dverify-script) ..."
zig build iso-smp -Dtest-hooks -Dverify-script -p "$BUILD_DIR" --cache-dir "$BUILD_DIR/.zig-cache"

# Evidence rotation, same contract as the native tracks: previous trace to
# .prev, a FAILED run's trace to .failed (which a later success never touches).
# bind=127.0.0.1: slirp delivers the guest's trace to the loopback, and binding
# there means a kudos elsewhere on the LAN (a wedged lemon, another dev box)
# cannot write into this run's evidence.
NETDEBUG_LOG="${NETDEBUG_LOG:-$ROOT/build/logs/boot-3-qemu-netdebug.log}"
[ -f "$NETDEBUG_LOG" ] && cp -f "$NETDEBUG_LOG" "$NETDEBUG_LOG.prev"
: > "$NETDEBUG_LOG"
# rcvbuf: the drain ships up to 8 datagrams per 16 ms tick and a counter dump
# bursts dozens of lines at once; the kernel default socket buffer dropped two
# consecutive datagrams (a visible seq gap) exactly on a gate-asserted line.
socat -u udp-recv:9514,bind=127.0.0.1,reuseaddr,rcvbuf=1048576 - >> "$NETDEBUG_LOG" 2>/dev/null &
SOCAT_PID=$!
export NETDEBUG_LOG

# 8 vCPUs so phase LOAD oversubscribes a real core count; a laptop-friendly RAM
# cap (the built-in guest needs 128 MiB on top of kudos' own use). The KMR1
# hostfwd rides the slirp NIC kudos actually uses (see run.sh N0_HOSTFWD).
echo "run_boot3_qemu: booting kudos-smp headless on 8 vCPUs ..."
SMP_CORES="${SMP_CORES:-8}" MEM_GB="${MEM_GB:-12}" \
    N0_HOSTFWD=",hostfwd=udp:127.0.0.1:9515-:9515" \
    scripts/vm/run.sh --no-tail --smp --no-stick >"$ROOT/build/logs/boot-3-qemu-qemu.log" 2>&1 &
RUN_PID=$!
# NOTE: this trap REPLACES the early exit-marker trap above (bash semantics),
# so it must write the marker itself as its last act.
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ] && [ -s "$NETDEBUG_LOG" ]; then
        cp -f "$NETDEBUG_LOG" "$NETDEBUG_LOG.failed"
        echo "run_boot3_qemu: FAILED — trace preserved at $NETDEBUG_LOG.failed" >&2
        echo "run_boot3_qemu: last 15 trace lines:" >&2
        tail -15 "$NETDEBUG_LOG" >&2
    fi
    kill "$RUN_PID" 2>/dev/null || true
    kill "${SOCAT_PID:-}" 2>/dev/null || true
    sudo pkill -f "qemu-system-x86_64.*kudos" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
    echo "RUN_BOOT3_QEMU_EXIT=$rc" >> "$LOG"
}
trap cleanup EXIT INT TERM

# Wait for the boot terminal before handing over (the driver then waits for the
# in-kernel verify verdict itself). Gate on the greeting only: boot-3 injects
# over KMR1, so USB HID enumeration is not a prerequisite here.
echo "run_boot3_qemu: waiting for the boot terminal ..."
i=0
while ! grep -q "dbg: term.0 = kudos terminal" "$NETDEBUG_LOG" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 120 ]; then
        echo "run_boot3_qemu: FAIL — no terminal greeting after boot" >&2
        tail -20 "$NETDEBUG_LOG" >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.5
done

echo "run_boot3_qemu: driving boot3_native.py (qemu track) ..."
# KUDOS_IP=127.0.0.1: KMR1 goes through the hostfwd; the guest replies through
# slirp's NAT to the requester, so the round trip needs no guest-side address.
BOOT3_TRACK=qemu BOOT3_WAIT_VERIFY=1 KUDOS_IP=127.0.0.1 \
    python3 scripts/tests/boot3_native.py

echo "run_boot3_qemu: PASS"
