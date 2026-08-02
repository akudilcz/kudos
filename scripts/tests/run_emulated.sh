#!/usr/bin/env bash
# Boot-1 integration run — the emulated-VGA track (no GPU). `make test-boot-1-qemu`.
#
# Builds the single-core ISO with the test instrumentation (-Dtest-hooks: the
# terminal-output mirror), boots it headless via vm/run.sh, waits for boot, then runs
# boot1_emulated.py to drive every no-GPU command and assert its output. Fails LOUD
# (non-zero) on any miss.
#
# READBACK IS THE NETWORK (spec TEST-002) — there is no serial port (klog.zig replaced it). So this
# headless boot is given a real wire: a tap the guest broadcasts netdebug onto, dnsmasq
# so it gets a DHCP lease (KMR1 injection is unicast and needs one), and socat capturing
# :9514 into the log the assertions read. See the tap setup below.
#
# NEEDS THE PHYSICAL USB STICK (vm/run.sh passes it through whole via usb-host), which
# lives in lemon. So when this is run from a machine without the stick — the dev laptop —
# it SYNCS ITSELF TO LEMON AND RUNS THERE, over ssh.
#
# THIS IS THE DEFAULT ITERATION LOOP, AND IT COSTS LEMON NOTHING. It runs inside lemon's
# Ubuntu, in QEMU: no netboot, no reset, no wear on the hardware. The native tracks
# reboot lemon and are the FINAL validation step, not the loop — see check.sh.
#
# SELF-LOGGING: all output below is mirrored to build/logs/boot1-run.log with a
# final RUN_EMULATED_EXIT=<code> marker — the verdict is always readable from
# the file even when the invoking harness swallows stdout, and it survives a
# host power-cycle (build/ is real disk, not tmpfs).
#
# Usage: scripts/tests/run_emulated.sh [seconds_to_boot_wait]
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# ── Run where the stick is ──────────────────────────────────────────────────────
# No stick here and not already delegated? Sync to lemon and run there. lemon is NOT
# rebooted: this is a QEMU boot inside its running Ubuntu.
LEMON_HOST="${LEMON_HOST:-lemon}"
REMOTE_DIR="${REMOTE_DIR:-~/kudos-qemu}"
if [ -z "${KUDOS_ON_STICK_HOST:-}" ] && ! lsusb -d 13fe:6500 >/dev/null 2>&1; then
    echo "run_emulated: the USB stick is not on this machine — running on $LEMON_HOST (QEMU; no reboot)"

    # WAIT FOR LEMON TO BE UP FIRST. A native track (test-boot-*-native) ends by
    # rebooting lemon back into Ubuntu, and it takes a minute to get there. Running
    # this straight afterwards — which `make check-hw` does — hits a machine that is
    # still booting: ssh is refused, rsync dies, and the QEMU suite reports RED for a
    # kernel that is perfectly fine. run_native.sh has the same wait for the same reason.
    echo "run_emulated: waiting for $LEMON_HOST to be reachable ..."
    for i in $(seq 1 40); do
        ssh -o BatchMode=yes -o ConnectTimeout=5 "$LEMON_HOST" true 2>/dev/null && break
        [ "$i" = 40 ] && { echo "run_emulated: $LEMON_HOST never came up" >&2; exit 1; }
        sleep 5
    done

    # NOTE the LEADING SLASH on /build/: an unanchored 'build/' also matches
    # scripts/build/, and --delete then removes the build scripts on the far side.
    rsync -a --delete \
        --exclude '/build/' --exclude '.zig-cache/' --exclude '__pycache__/' \
        "$ROOT/" "$LEMON_HOST:$REMOTE_DIR/"
    # Forward KUDOS_SMP across the hop — otherwise the SMP variant selection is lost
    # when the laptop delegates to lemon, and the far side would boot the single-core
    # kernel while reporting as the SMP track.
    # Keepalives, because the far side is a machine under test: if it reboots or
    # wedges mid-suite (a kernel panic, a power cut, someone at the desk), a plain
    # ssh session never sees EOF and this hangs SILENTLY — a dead run that looks
    # exactly like a slow one, for as long as anybody leaves it. Four missed
    # 15-second probes end it instead, and the caller gets a failure it can read.
    exec ssh -t -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$LEMON_HOST" \
        "cd $REMOTE_DIR && PATH=\$HOME/.local/bin:\$PATH KUDOS_ON_STICK_HOST=1 KUDOS_SMP=${KUDOS_SMP:-} scripts/tests/run_emulated.sh $*"
fi

BUILD_DIR="${BUILD_DIR:-build}"
mkdir -p "$ROOT/build/logs"
LOG="$ROOT/build/logs/boot1-run.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "RUN_EMULATED_EXIT=$?" >> "$LOG"' EXIT

# 10s boot wait: boot + Linux-parity USB enumeration (the connect-debounce
# stability window costs ~100ms/port) + first prompt. 3s races enumeration.
WAIT="${1:-10}"

# Single instance: two concurrent runs fight over the QMP/serial sockets and the
# usbdisk image (QEMU's socket chardev BUMPS the previous client on a new connect,
# which breaks the first driver mid-run). flock on a well-known lock file makes a
# second invocation fail loud instead of corrupting the first.
LOCK=/tmp/kudos-emulated-suite.lock
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "run_emulated: FAIL — another emulated-suite run holds $LOCK" >&2
    exit 1
fi

# Preflight: a stale QEMU from an interrupted previous run holds the QMP/serial
# sockets and the usbdisk image — kill it and clear the sockets so this run owns
# them (run.sh also clears them, but only after it has already failed to bind).
if pgrep -f "qemu-system-x86_64.*kudos" >/dev/null 2>&1; then
    echo "run_emulated: killing a stale kudos QEMU from a previous run"
    # sudo: a passthrough run's QEMU is root-owned; an unprivileged pkill
    # silently leaves it holding the tap, the stick and the GPU.
    sudo pkill -9 -f "qemu-system-x86_64.*kudos" || true
    sleep 1
fi
# A SIGKILLed previous run leaks its socat capture (the EXIT trap never ran) —
# and a stale socat still bound to :9514 competes for this run's datagrams, so
# echo records silently vanish and every echo-gated step flakes. Reap it.
if pgrep -f "socat.*9514" >/dev/null 2>&1; then
    echo "run_emulated: killing a stale :9514 capture from a previous run"
    pkill -f "socat.*9514" || true
    sleep 1
fi

# KUDOS_SMP=1 boots the multi-core kernel instead: build kudos-smp.iso as well and
# hand run.sh --smp (which boots it on 4 vCPUs). The boot1 driver reads KUDOS_SMP from
# the environment and runs the SMP proofs + cross-core cases on top of the base suite.
if [ "${KUDOS_SMP:-}" = "1" ]; then
    ISO_TARGETS="iso iso-smp"
    RUN_SMP="--smp"
    echo "run_emulated: building single- + multi-core ISOs (-Dtest-hooks) ..."
else
    ISO_TARGETS="iso"
    RUN_SMP=""
    echo "run_emulated: building single-core ISO (-Dtest-hooks) ..."
fi
# shellcheck disable=SC2086  # deliberate word-split of the target list
zig build $ISO_TARGETS -Dtest-hooks -p "$BUILD_DIR" --cache-dir "$BUILD_DIR/.zig-cache"

# READBACK IS THE NETWORK. kudos has no serial port (src/kernel/debug/klog.zig) —
# the trace bus fans out to sinks and netdebug (UDP broadcast :9514) is the one that
# leaves the machine. So this boot needs a WIRE, which a headless emulated boot never
# had: a tap the guest broadcasts onto, dnsmasq so it gets a lease (KMR1 is unicast
# and needs one), and socat capturing the stream into the log the assertions read.
# There is no UART, so there is no -serial file to fall back on.
echo "run_emulated: bringing up the netdebug tap ..."
sudo ip link del kudoslog 2>/dev/null || true
sudo ip tuntap add dev kudoslog mode tap
sudo ip addr add 10.55.0.1/24 dev kudoslog
sudo ip link set kudoslog up
sudo pkill -f "dnsmasq.*kudoslog" 2>/dev/null || true
sudo dnsmasq --interface=kudoslog --bind-interfaces --except-interface=lo \
    --dhcp-range=10.55.0.50,10.55.0.100,12h --dhcp-option=3,10.55.0.1 \
    --port=0 --pid-file=/tmp/kudos-dnsmasq.pid
: > /tmp/netdebug.log
socat -u udp-recv:9514,reuseaddr - >> /tmp/netdebug.log 2>/dev/null &
SOCAT_PID=$!
export EXTRA_NETDEV="-netdev tap,id=nd0,ifname=kudoslog,script=no,downscript=no -device e1000,netdev=nd0"

echo "run_emulated: booting headless ..."
# Own QEMU's lifetime directly: --no-tail makes run.sh exec QEMU, so RUN_PID IS
# the QEMU process, not a wrapper that could orphan it. Cleanup reaps any QEMU
# bound to our ISO so a hard timeout kill can't leak a headless VM.
# shellcheck disable=SC2086  # $RUN_SMP is one optional flag, deliberately unquoted
# --require-stick: this suite asserts against the stick's CONTENTS (cases.py), so a
# machine without one must fail here rather than boot a stickless kudos and report
# a red suite that is really a missing peripheral.
scripts/vm/run.sh --no-tail --require-stick $RUN_SMP >"$ROOT/build/logs/boot1-qemu.log" 2>&1 &
RUN_PID=$!
# NOTE: this trap REPLACES the early exit-marker trap above (bash semantics),
# so it must write the marker itself as its last act.
cleanup() {
    rc=$?
    kill "$RUN_PID" 2>/dev/null || true
    kill "${SOCAT_PID:-}" 2>/dev/null || true
    sudo pkill -f "dnsmasq.*kudoslog" 2>/dev/null || true
    sudo ip link del kudoslog 2>/dev/null || true
    # Belt-and-braces: reap any QEMU still bound to our kudos ISO (sudo: it
    # may be root-owned if a passthrough run left it behind).
    sudo pkill -f "qemu-system-x86_64.*kudos" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
    echo "RUN_EMULATED_EXIT=$rc" >> "$LOG"
}
trap cleanup EXIT INT TERM

# Wait for the terminal to exist before injecting. The boot-glass terminal emits
# its greeting (`dbg: term.0 = kudos terminal.…`) as a newline-flushed record; the
# FIRST prompt has no trailing newline so it stays buffered until the first command
# echoes — hence we gate on the greeting, not the prompt (see terminal.zig prompt()).
# We also need HID enumeration done so injected keys land: gate on KEYBOARD ready.
echo "run_emulated: waiting ${WAIT}s for boot + terminal + HID ..."
sleep "$WAIT"
i=0
while ! { grep -q "dbg: term.0 = kudos terminal" /tmp/netdebug.log 2>/dev/null \
        && grep -q "xhci:  -> KEYBOARD ready" /tmp/netdebug.log 2>/dev/null; }; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "run_emulated: FAIL — terminal greeting + KEYBOARD ready not seen after boot" >&2
        tail -20 /tmp/netdebug.log >&2 2>/dev/null || true
        exit 1
    fi
    sleep 0.5
done

# QMP must actually ACCEPT a connection before the driver starts — the socket
# file existing is not enough (a stale file from a dead QEMU refuses connects).
i=0
while ! python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect('/tmp/qmp.sock')" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -gt 20 ]; then
        echo "run_emulated: FAIL — QMP socket never became connectable" >&2
        exit 1
    fi
    sleep 0.5
done

echo "run_emulated: driving boot1_emulated.py ..."
python3 scripts/tests/boot1_emulated.py

echo "run_emulated: PASS"
