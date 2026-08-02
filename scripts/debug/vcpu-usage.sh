#!/bin/sh
# Per-kudos-core CPU usage, measured OUTSIDE kudos: each QEMU vCPU is a host
# thread, so the host's own accounting says how busy each kudos core really is
# (e.g. whether a busy guest saturates the core it runs on, or a core properly
# parks when idle, KRN-007). Prints one line per second per core.
#
# Usage: scripts/debug/vcpu-usage.sh   (QEMU must be running with the QMP
# socket at /tmp/qmp.sock — every scripts/vm/run.sh mode provides it)
set -e
QPID=$(pgrep -o qemu-system) || { echo "vcpu-usage: no qemu-system running" >&2; exit 1; }

# vCPU index -> host thread id, from QMP (one JSON line per response).
MAP=$(printf '{"execute":"qmp_capabilities"}\n{"execute":"query-cpus-fast"}\n' \
    | timeout 5 socat - unix:/tmp/qmp.sock \
    | python3 -c '
import sys, json
for line in sys.stdin:
    d = json.loads(line)
    if isinstance(d.get("return"), list):
        for c in d["return"]:
            print(c["cpu-index"], c["thread-id"])')
[ -n "$MAP" ] || { echo "vcpu-usage: QMP gave no vCPU list" >&2; exit 1; }

HZ=$(getconf CLK_TCK)
echo "kudos core usage (host view, 1 s samples; Ctrl-C to stop)"
while :; do
    LINE=""
    for pair in $(echo "$MAP" | tr ' ' ':'); do
        IDX=${pair%%:*}
        TID=${pair##*:}
        T1=$(awk '{print $14+$15}' "/proc/$QPID/task/$TID/stat")
        eval "T1_$IDX=$T1"
    done
    sleep 1
    for pair in $(echo "$MAP" | tr ' ' ':'); do
        IDX=${pair%%:*}
        TID=${pair##*:}
        T2=$(awk '{print $14+$15}' "/proc/$QPID/task/$TID/stat")
        eval "T1=\$T1_$IDX"
        PCT=$(( (T2 - T1) * 100 / HZ ))
        LINE="$LINE core$IDX=${PCT}%"
    done
    echo "$LINE"
done
