#!/usr/bin/env bash
# Build the iso and run it under 4090 passthrough. `zig build iso` bumps
# BUILD_NUMBER and stamps it into the kernel banner; on real HW the serial UART is
# OFF (it caps FPS — netdebug is the trace channel), so confirm which image booted
# via the NETDEBUG-BUILD banner over netdebug (kudos-netdebug MCP), not COM1.
#
# --manage-vfio (what `make start` over SSH uses): own the WHOLE card lifecycle so a
# single command does everything from a normal running desktop:
#   1. stop the display-manager (the desktop runs ON the 4090, so it must let go —
#      binding to vfio-pci refuses while a DM is active). The host monitors briefly go blank.
#   2. bind the 4090 to vfio-pci.
#   3. reset + run kudos on the real card (the monitors then show the kudos desktop,
#      driven by the passed-through physical keyboard/mouse).
#   4. ON ANY EXIT (normal, error, Ctrl-C): unbind the card back to nvidia. This is
#      CRASH-SAFE — a mid-run failure never strands the GPU on vfio.
# The display-manager is deliberately NOT restarted here: iterating (run→look→exit→
# tweak→run) stays fast because the monitors don't thrash back to the Linux desktop
# between runs. Restore the Linux desktop with `make stop` (scripts/gpu/restore.sh)
# when done.
#
# Without --manage-vfio the script assumes the card is ALREADY bound: it neither
# stops the DM nor unbinds, so a direct caller with a pre-bound card is not
# force-unbound out from under them.
#
# Run WITHOUT sudo: it self-elevates only the parts that need root (vfio/QEMU/KVM),
# so `zig build` runs as the invoking user (zig is not on root's PATH — building
# under sudo silently fails and boots a STALE iso, the exact bug this guards).
# Usage: scripts/vm/passthrough.sh [--manage-vfio] [extra run.sh args…]  (NOT sudo)
# The guest runs with no time limit: it exits only when kudos powers off, or when
# this wrapper is interrupted (Ctrl-C) / killed — the EXIT/INT/TERM trap releases
# the GPU on every path. Stop a run explicitly with `make stop`.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; cd "$ROOT"

# Card identity comes from the one shared definition.
. scripts/gpu/env.sh

MANAGE_VFIO=0
TAKE_DISPLAY=0
BUILD_OPTS=""
# Leading wrapper flags (consumed here; everything after is forwarded to run.sh):
#   --manage-vfio        own the full VFIO lifecycle (bind → run → unbind)
#   --take-display       consent to stop the DM + grab input from a non-interactive
#                        caller (an agent/cron/orphan); required there, see below
#   --build-opts "OPTS"  extra `zig build` options for this run's image
#                        (e.g. "-Dtest-hooks -Dflip-sample=true")
while [ $# -gt 0 ]; do
    case "${1:-}" in
        --manage-vfio) MANAGE_VFIO=1; shift ;;
        --take-display) TAKE_DISPLAY=1; shift ;;
        --build-opts) BUILD_OPTS="${2:-}"; shift 2 ;;
        *) break ;;
    esac
done

# --manage-vfio takes the WHOLE machine: it stops the display-manager (all
# monitors go dark) and passes the physical keyboard + mouse into the guest. If
# the caller is not an interactive terminal — an orphaned background job, an
# agent, a cron task — then nobody is at the helm, and an interruption that skips
# the cleanup trap (SIGKILL, session teardown) strands the host headless AND
# inputless: to a person at the desk that is indistinguishable from a hard hang,
# recoverable only by power-cycling. So a non-interactive
# caller must opt in EXPLICITLY; there is no silent path to taking the display.
if [ "$MANAGE_VFIO" = "1" ] && ! [ -t 0 ] && ! [ -t 1 ] \
        && [ "$TAKE_DISPLAY" != "1" ]; then
    echo "REFUSING --manage-vfio from a non-interactive shell: this stops the" >&2
    echo "display-manager and grabs the physical keyboard/mouse — if this process" >&2
    echo "is killed uncleanly the machine is left dark with no local input." >&2
    echo "Run 'make start' from an interactive terminal (a real SSH session), or" >&2
    echo "pass --take-display to consent explicitly:" >&2
    echo "    scripts/vm/passthrough.sh --manage-vfio --take-display ..." >&2
    echo "Recover a stranded host with: sudo scripts/gpu/restore.sh  (make stop)" >&2
    exit 4
fi
EXTRA="$@"
export GSP_FW_DIR="${GSP_FW_DIR:-/lib/firmware/nvidia/ad102/gsp}"
# All build artifacts under build/ — matches Makefile + mkiso.sh.
BUILD_DIR="${BUILD_DIR:-build}"

# 1. Build FIRST, as this user (bumps + stamps BUILD_NUMBER into the kernel banner).
#    Abort loudly if zig is missing rather than proceeding to boot an old iso.
#    Serial UART is OFF in this (real-HW) build — confirm which image booted via the
#    NETDEBUG-BUILD banner over netdebug (the kudos-netdebug MCP), not COM1.
command -v zig >/dev/null || { echo "run-verified: zig not on PATH — run WITHOUT sudo" >&2; exit 3; }
# Build the iso matching the requested variant: --smp in the forwarded args means
# run.sh will boot kudos-smp.iso, so build that target instead of the single-core one.
case " $EXTRA " in
    *" --smp "*) ISO_TARGET="iso-smp" ;;
    *)           ISO_TARGET="iso" ;;
esac
# --build-opts: extra zig build options for this run's image (e.g.
# "-Dflip-sample=true" for the FLIPSTAT measurement build; "-Dtest-hooks" for the
# integration harness). The
# rebuild here is the stale-ISO guard, so the options MUST flow through it — a
# pre-built ISO would be overwritten.
# shellcheck disable=SC2086  # deliberate word-split of the options list
zig build "$ISO_TARGET" $BUILD_OPTS -p "$BUILD_DIR" --cache-dir "$BUILD_DIR/.zig-cache" >/dev/null
echo "run-verified: built kudos build #$(tr -d '[:space:]' < BUILD_NUMBER) (confirm live via netdebug)"

cleanup() {
    if [ -n "${TAIL_PID:-}" ]; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    # kill-qemu.sh stops the guest GRACEFULLY first (KMR1 `shutdown` → GSP
    # teardown → poweroff) and only hard-kills as a last resort — the single
    # source of truth for stopping kudos, shared with `make stop`.
    sudo scripts/vm/kill-qemu.sh 2>/dev/null || true
    # Crash-safe: if WE bound the card, always release it back to nvidia on exit
    # (normal, error, or Ctrl-C) so a failed run never leaves the GPU on vfio.
    # scripts/gpu/unbind.sh FLRs the card on the way out so the host driver gets it clean.
    # The Linux desktop is restored separately by `make stop` (see header).
    if [ "$MANAGE_VFIO" = "1" ]; then
        sudo scripts/gpu/unbind.sh >/dev/null 2>&1 || true
    fi
    # Remove the netdebug tap, the DHCP server, and their firewall allows on every
    # exit path so a failed run never strands them (a leftover kudoslog would make
    # the next `ip tuntap add` fail; a leftover dnsmasq would hold the tap / :67; a
    # leftover ufw rule would accumulate). All idempotent.
    sudo pkill -f "dnsmasq.*kudoslog" 2>/dev/null || true
    # Also clear any stale dnsmasq state files: a root-owned or nobody:root log
    # blocks the next run's dnsmasq ("cannot open log … Permission denied"). We log
    # to stderr, so these should not exist — drop them so an old file never resurfaces.
    sudo rm -f /tmp/kudos-dnsmasq.log /run/kudos-dnsmasq.pid 2>/dev/null || true
    if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
        sudo ufw delete allow in on kudoslog to any port 9514 proto udp >/dev/null 2>&1 || true
        sudo ufw delete allow in on kudoslog to any port 9515 proto udp >/dev/null 2>&1 || true
        sudo ufw delete allow in on kudoslog to any port 67 proto udp >/dev/null 2>&1 || true
    fi
    sudo ip link del kudoslog 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --manage-vfio: stop the display-manager (frees the 4090; the vfio bind refuses while
# it is up) then bind the card. Idempotent — a no-op if the DM is already down, so
# repeated `make start` iterations don't re-stop it. See header.
if [ "$MANAGE_VFIO" = "1" ]; then
    if systemctl is-active --quiet display-manager 2>/dev/null; then
        echo "run-verified: stopping display-manager (frees the 4090)…"
        sudo systemctl isolate multi-user.target
    fi
    echo "run-verified: binding 4090 to vfio-pci…"
    sudo scripts/gpu/bind.sh >/dev/null
fi

# 2. Kill any prior QEMU and free the vfio group (the busy-race root cause). Needs root.
sudo scripts/vm/kill-qemu.sh 2>/dev/null || true
sleep 3
# Group number derived from sysfs (machine-specific — scripts/gpu/env.sh). Under
# --manage-vfio the card is bound by now, so the group must exist; without
# --manage-vfio the caller pre-bound it themselves.
VFIO_GROUP="$(gpu_vfio_group)"
if sudo fuser "/dev/vfio/$VFIO_GROUP" 2>/dev/null; then
    echo "run-verified: /dev/vfio/$VFIO_GROUP still busy after kill — aborting" >&2
    exit 1
fi

# 3. Clean state, reset the card, run (root).
sudo rm -f /tmp/serial.log /tmp/mon.sock /tmp/qmp.sock
sudo scripts/gpu/health.sh reset >/dev/null 2>&1 || true

# netdebug tap: run.sh --passthrough attaches an emulated e1000 on this tap so
# kudos' netdebug broadcast reaches the host MCP on :9514. Recreate it fresh each run (idempotent: drop any stale
# one first), give it an address so the segment has a broadcast domain, bring it
# up. Fail loudly if any step errors — a half-made tap would leave netdebug dark
# with no NIC for QEMU to open. The cleanup trap removes it on every exit.
sudo ip link del kudoslog 2>/dev/null || true
sudo ip tuntap add dev kudoslog mode tap
sudo ip addr add 10.55.0.1/24 dev kudoslog
sudo ip link set kudoslog up
# The host firewall must let the netdebug broadcast in on the tap. With ufw active
# (default INPUT policy DROP + a broadcast-catch rule), the guest's
# 0.0.0.0 -> 255.255.255.255:9514 datagrams are silently dropped before reaching
# the MCP's socket — verified: frames arrive on the tap (tcpdump) but no socket
# sees them until this allow exists. Scope it to the tap interface so the rest of
# the host stays firewalled. The cleanup trap deletes it. (No ufw = no INPUT DROP
# policy to work around, so nothing to add.)
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    sudo ufw allow in on kudoslog to any port 9514 proto udp >/dev/null
    # netdebug replies (guest 9515 -> host ephemeral)
    sudo ufw allow in on kudoslog to any port 9515 proto udp >/dev/null
    # DHCP: the guest broadcasts DISCOVER to udp/67; ufw's default INPUT DROP would
    # eat it (same as the netdebug broadcast) so dnsmasq never sees it. Allow 67 on
    # the tap so the guest can get a lease and `net` comes UP in the kudos terminal.
    sudo ufw allow in on kudoslog to any port 67 proto udp >/dev/null
    echo "run-verified: ufw allow netdebug udp/9514 + dhcp udp/67 on kudoslog"
fi
# DHCP server on the tap so kudos' DHCP client (src/drivers/net/stack/dhcp.zig, RFC 2131)
# gets a lease → `net` UP with an IP in the kudos terminal. dnsmasq bound ONLY to
# kudoslog (no host DNS/DHCP hijack): a small lease range on the tap's 10.55.0.0/24,
# gateway/DNS = the tap host (10.55.0.1). Killed in the cleanup trap. --no-daemon
# in the background so its lifetime is tied to this run, not left resident.
if command -v dnsmasq >/dev/null; then
    sudo pkill -f "dnsmasq.*kudoslog" 2>/dev/null || true
    # --log-facility=- : log to stderr, NOT a file. A file log
    # (/tmp/kudos-dnsmasq.log) is the root cause of the recurring "cannot open
    # log … Permission denied" that silently kills DHCP: dnsmasq drops to the
    # `nobody` user after binding, and a log file left behind by a hard-killed
    # prior run (owned nobody:root 0660) can't always be reopened by the next
    # run's post-drop process. netdebug is the debug channel; dnsmasq's own log has
    # no consumer here, so stderr (visible in this run's output on error) removes
    # the permission trap entirely. --pid-file=- likewise avoids a stale pid file.
    # --no-daemon is REQUIRED here (not just intent): without it dnsmasq forks
    # and the sudo wrapper exits, so the liveness check below reads a dead pid
    # and aborts a perfectly good run. Foreground keeps its lifetime tied to
    # this script and the pid checkable.
    sudo dnsmasq --no-daemon --interface=kudoslog --bind-interfaces --except-interface=lo \
        --no-hosts --no-resolv --dhcp-authoritative \
        --dhcp-range=10.55.0.50,10.55.0.150,255.255.255.0,1h \
        --dhcp-option=3,10.55.0.1 --dhcp-option=6,10.55.0.1 \
        --pid-file=- --log-facility=- &
    DNSMASQ_PID=$!
    # dnsmasq exits asynchronously on a bind/config error — a backgrounded `&`
    # alone would swallow that and the guest would silently never get a lease.
    # Verify it is still alive before proceeding (fail loud, CLAUDE.md).
    sleep 1
    if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
        echo "run-verified: dnsmasq FAILED to start on kudoslog (see its stderr above) — aborting" >&2
        exit 1
    fi
    echo "run-verified: dnsmasq serving DHCP on kudoslog (10.55.0.50-150)"
fi
echo "run-verified: netdebug tap kudoslog up (e1000 -> host MCP :9514)"

# The live trace is on NETDEBUG now (UDP :9514, the kudos-netdebug MCP), not COM1 —
# real-HW/passthrough builds ship with the serial UART OFF (it busy-waits at 38400
# baud and caps the desktop at ~30 FPS). The NETDEBUG-BUILD banner carries the build
# identity if you want to confirm which image booted (netdebug_build_banner).

# No time limit: run until kudos powers off on its own or the user interrupts
# (Ctrl-C / a signal to this wrapper). Either way the EXIT/INT/TERM trap above
# tears QEMU down and releases the GPU, so a bounded `timeout` is unnecessary.
sudo scripts/vm/run.sh --passthrough --no-tail $EXTRA || true
