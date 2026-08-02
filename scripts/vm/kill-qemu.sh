#!/bin/sh
# Stop a kudos passthrough QEMU and release the VFIO group if it is still held.
#
# GRACEFUL FIRST: ask kudos to shut down over KMR1 (UDP :9515) so it runs its GSP
# teardown — destroy WPR2, unload GSP-RM — and powers off, QEMU exiting on its own
# with the 4090 left CLEAN. A hard kill with GSP-RM still resident wedges the card
# (Xid 62 / RmInitAdapter 0x62) for the host driver, and a hard kill MID-TEARDOWN is
# worse still (half-destroyed WPR2).
#
# The ACK must be a real reply from the kernel's own net stack, never a grep of a log
# file: kudos has no serial port, so a serial handshake would ACK never and fall silently
# through to the hard kill on every run. kudos ACKs KMR1 immediately and acts ~5 s later
# (fileserv.ACTION_GRACE_MS), so a lost ACK still has a live machine to retransmit to.
#
#   - no ACK within ACK_WAIT_S → kudos is not listening → hard kill is the only option.
#   - once teardown has STARTED, let it FINISH: wait up to TEARDOWN_WAIT_S for QEMU to
#     exit on its own. Never hard-kill a teardown in progress; if it truly hangs past
#     that generous bound, warn loudly before the last-resort kill.
#
# This is the single "stop the guest" primitive — both `make stop` (restore.sh) and the
# `make start` exit path (passthrough.sh) call it.
#
# Run as root. Safe to run when no passthrough guest is active (a no-op).
set -e

# Card identity comes from the one shared definition.
. "$(dirname "$0")/../gpu/env.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (sudo $0)" >&2
    exit 1
fi

MCP_DIR="$(cd "$(dirname "$0")/../tools/netdebug-mcp" && pwd)"
# Seconds to wait for kudos to ACK the KMR1 shutdown before concluding it is not there.
ACK_WAIT_S=8
# Seconds to wait for the FULL GSP teardown once it has started. The teardown has real
# multi-second waits (falcon quiesce up to 2 s, FWSEC-SB, booter_unload on SEC2 under
# vfio), so this is generous — interrupting it is what wedges the card. kudos also waits
# ACTION_GRACE_MS (~5 s) after the ACK before it begins.
TEARDOWN_WAIT_S=60

qemu_running() { pgrep -af '^qemu-system-' | grep -q kudos; }

# One QMP round-trip against the guest's monitor socket; prints the reply JSON
# (or {} on any failure — a dead socket must not abort the teardown flow).
qmp() {
    python3 -c "
import json, socket, sys
try:
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(2)
    s.connect('/tmp/qmp.sock')
    f = s.makefile('rw')
    f.readline()  # greeting
    f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n'); f.flush(); f.readline()
    f.write(json.dumps(json.loads(sys.argv[1])) + '\n'); f.flush()
    print(f.readline().strip())
except Exception:
    print('{}')
" "$1" 2>/dev/null
}

if qemu_running; then
    echo "kill-qemu: asking kudos to shut down cleanly (KMR1 OP_SHUTDOWN)…"
    if PYTHONPATH="$MCP_DIR" timeout "$ACK_WAIT_S" python3 -c "
import sys, kmir
try:
    ip = kmir.discover_ip()
    kmir.Client(ip).shutdown()
    print('kill-qemu: kudos ACKed at %s — orderly GSP teardown starting' % ip)
except Exception as e:
    print('kill-qemu: no KMR1 answer (%s)' % e, file=sys.stderr)
    sys.exit(1)
"; then
        # ACKed: it WILL tear down. Let it finish — do not interrupt. The VM runs
        # with -no-shutdown, so QEMU NEVER exits by itself: the guest's ACPI
        # power-off parks it in QMP status "shutdown", and that status is the
        # clean-teardown signal — we then quit QEMU ourselves.
        j=0
        while [ "$j" -lt "$TEARDOWN_WAIT_S" ]; do
            qemu_running || { echo "kill-qemu: kudos powered off cleanly (GSP torn down)."; break; }
            if qmp '{"execute":"query-status"}' | grep -q '"shutdown"'; then
                echo "kill-qemu: kudos powered off (QMP status: shutdown; GSP torn down) — quitting QEMU."
                qmp '{"execute":"quit"}' > /dev/null
                sleep 1
                break
            fi
            sleep 1
            j=$((j + 1))
        done
        qemu_running && echo "kill-qemu: WARNING — teardown did not finish in ${TEARDOWN_WAIT_S}s; it may be hung." >&2
    else
        echo "kill-qemu: WARNING — kudos did not answer KMR1 in ${ACK_WAIT_S}s (not listening)." >&2
    fi
fi

# Last resort: hard-kill anything still up. Reaching here means kudos never
# acknowledged, or the teardown hung — either way the 4090 may need FLR/SBR
# (scripts/gpu/unbind.sh / sbr.sh, or `make stop` which chains them) or a power-off.
if qemu_running; then
    echo "kill-qemu: hard-killing kudos — the 4090 may need a reset or power-off." >&2
    pgrep -af '^qemu-system-' | awk '/kudos/ { print $1 }' | xargs -r kill -9 2>/dev/null || true
fi

# Free the card's VFIO group if anything still holds it. The group number is
# derived from sysfs (machine-specific — see scripts/gpu/env.sh); if the card has no
# IOMMU group there is no vfio node to free, so skip rather than guess.
if GROUP="$(gpu_vfio_group)"; then
    fuser -k "/dev/vfio/$GROUP" 2>/dev/null || true
else
    echo "kill-qemu: no VFIO group for the card — skipping group release" >&2
fi
rm -f /tmp/mon.sock /tmp/qmp.sock
