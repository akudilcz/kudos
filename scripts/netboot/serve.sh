#!/bin/sh
# The netboot server: lemon's firmware boots off THIS, and always gets whatever is
# in build/netboot/ right now. Nothing is ever staged on lemon's disk.
#
#   scripts/netboot/serve.sh start    dnsmasq (proxyDHCP + TFTP) + HTTP, backgrounded
#   scripts/netboot/serve.sh stop     kill both
#   scripts/netboot/serve.sh status   are they up? what is being served?
#   scripts/netboot/serve.sh log      the dnsmasq DHCP/TFTP conversation (why a boot failed)
#
# The chain, and why each hop is what it is:
#
#   lemon firmware  --DHCP-->  THE ROUTER              address + "boot bootnetx64.efi
#                                                      from 192.168.20.103" (options 66/67)
#                   --TFTP-->  our dnsmasq             the ~700 KB GRUB EFI image (firmware
#                                                      speaks only TFTP, so this hop has no choice)
#   GRUB            --TFTP-->  our dnsmasq             grub.cfg (tiny)
#   GRUB            --HTTP-->  our python http.server  kernel.elf + any GSP blobs
#   multiboot2 -> kudos runs.
#
# WHY THE ROUTER OWNS THE DHCP HALF. The obvious design is a DHCP PROXY here
# (dnsmasq `dhcp-range=<subnet>,proxy`), answering only the PXE part while the
# router keeps handing out addresses. It cannot work from this laptop: we are on
# WIFI, and the AP does not bridge LAN broadcast to wireless clients — not one
# broadcast frame of any kind reaches us, so lemon's PXE DHCPDISCOVER never
# arrives. A broadcast conversation we cannot hear is a conversation we cannot join.
#
# So the router carries the two options that name us (66 = TFTP server, 67 = boot
# file), and every hop that touches THIS laptop is unicast — TFTP and HTTP both
# cross the AP like any other traffic. Set SERVE_PXE=1 to run the DHCP proxy anyway
# (correct, and simpler, the moment this laptop is on the wire by Ethernet).
#
# SAFETY: this server is the off switch. lemon only netboots when its one-shot
# BootNext is armed (lemon.sh boot) AND we answer the TFTP fetch. Stop this server
# and lemon cannot boot kudos at all — the fetch times out and the firmware falls
# through BootOrder into Ubuntu.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
NETDIR="$ROOT/$BUILD_DIR/netboot"
RUNDIR="$ROOT/$BUILD_DIR/netboot-server"
HTTP_PORT="${HTTP_PORT:-8099}"

# The interface (and address) that faces lemon — asked of the routing table rather
# than guessed, so this works on wifi, on ethernet, or on a different subnet.
LEMON_IP="${LEMON_IP:-$("$(dirname "$0")/lemonip.sh")}"
SERVE_IP="${SERVE_IP:-$(ip route get "$LEMON_IP" | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
IFACE="${IFACE:-$(ip route get "$LEMON_IP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')}"
SUBNET="$(echo "$SERVE_IP" | cut -d. -f1-3).0"

DNSMASQ_PID="$RUNDIR/dnsmasq.pid"
HTTP_PID="$RUNDIR/http.pid"
DNSMASQ_LOG="$RUNDIR/dnsmasq.log"
HTTP_LOG="$RUNDIR/http.log"

# `ps -p`, not `kill -0`: dnsmasq runs as root, and kill -0 from our user fails with
# EPERM on a root process — which would report a perfectly healthy server as "down"
# and refuse to boot lemon.
alive() { [ -f "$1" ] && ps -p "$(cat "$1")" >/dev/null 2>&1; }

# Who is listening on our HTTP port, whoever started it — prints the pid, empty
# when the port is free. The pid FILE only knows about servers this script
# started; the port is the thing lemon actually fetches from.
port_holder() {
    ss -lptnH "sport = :$HTTP_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2
}

# Is the port answering? The only question that matters to a netboot, and the
# one a pid proves nothing about. Bounded: a bind is immediate or it failed.
http_serving() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -sf -o /dev/null --max-time 2 "http://$SERVE_IP:$HTTP_PORT/" && return 0
        sleep 0.2
    done
    return 1
}

case "${1:-status}" in

start)
    [ -f "$NETDIR/bootnetx64.efi" ] || { echo "serve: no bootloader staged — run 'make netboot' first" >&2; exit 1; }
    mkdir -p "$RUNDIR"

    if alive "$DNSMASQ_PID"; then
        echo "serve: dnsmasq already running (pid $(cat "$DNSMASQ_PID"))"
    else
        # --port=0 disables the DNS server entirely: we are here for DHCP-proxy and
        # TFTP only, and standing up an unexpected resolver on someone's LAN would be
        # rude and confusing.
        # --dhcp-match/--pxe-service on client-arch 7/9 (x86-64 UEFI) so we answer
        # only machines that are actually asking for a UEFI network boot.
        # --user=root: dnsmasq drops to `nobody` by default, which cannot traverse a
        # 750 home directory — the TFTP root lives in the repo, so it would serve
        # nothing but "Permission denied". This is a developer-laptop tool serving
        # one directory to one machine on a LAN, not a daemon.
        #
        # DHCP is OFF by default (--port=0 kills DNS; no --dhcp-range means no DHCP
        # at all): the router hands out addresses AND the two PXE options that name
        # us. We are a pure TFTP server here, which is unicast and therefore actually
        # reachable from wifi. SERVE_PXE=1 adds the proxy back for the wired case.
        if [ "${SERVE_PXE:-0}" = "1" ]; then
            # The pxe-service menu text must be ONE shell word — PXE_ARGS is
            # deliberately unquoted at the call site (word-split into separate
            # arguments), so a space in "kudos netboot" would split it into two args
            # and dnsmasq rejects the line with "junk found in command line".
            PXE_ARGS="--dhcp-range=$SUBNET,proxy
                      --dhcp-match=set:efi64,option:client-arch,7
                      --dhcp-match=set:efi64,option:client-arch,9
                      --pxe-service=tag:efi64,x86-64_EFI,kudos,bootnetx64.efi
                      --dhcp-boot=tag:efi64,bootnetx64.efi,,$SERVE_IP"
        else
            PXE_ARGS=""
        fi
        # shellcheck disable=SC2086
        sudo dnsmasq \
            --conf-file=/dev/null \
            --port=0 \
            --user=root \
            --interface="$IFACE" \
            --bind-interfaces \
            $PXE_ARGS \
            --enable-tftp \
            --tftp-root="$NETDIR" \
            --log-dhcp \
            --log-facility="$DNSMASQ_LOG" \
            --pid-file="$DNSMASQ_PID"
        if [ "${SERVE_PXE:-0}" = "1" ]; then
            echo "serve: dnsmasq up on $IFACE ($SERVE_IP) — proxyDHCP for $SUBNET/24 + TFTP $NETDIR"
        else
            echo "serve: dnsmasq up on $IFACE ($SERVE_IP) — TFTP only (the router carries options 66/67)"
        fi
    fi

    if alive "$HTTP_PID"; then
        echo "serve: http already running (pid $(cat "$HTTP_PID"))"
    else
        # A server left over from an earlier session holds the port while our pid
        # file knows nothing about it. Starting on top of that dies instantly with
        # EADDRINUSE, and reporting "up" for the corpse strands the next netboot:
        # `status` then says down, and a native track aborts before it ever
        # reaches lemon — with a message about the rig being stranded that is not
        # what happened. So name the holder instead of racing it.
        if holder="$(port_holder)" && [ -n "$holder" ]; then
            echo "serve: $SERVE_IP:$HTTP_PORT is already held by pid $holder, which this" >&2
            echo "  server did not start (a leftover from an earlier session). Stop it," >&2
            echo "  then start again:   kill $holder && $0 start" >&2
            exit 1
        fi
        # Serves the SAME directory dnsmasq's TFTP root points at, so there is exactly
        # one copy of the truth: `make netboot` overwrites it and the next boot gets it.
        setsid python3 -m http.server "$HTTP_PORT" --directory "$NETDIR" --bind "$SERVE_IP" \
            >"$HTTP_LOG" 2>&1 &
        echo $! > "$HTTP_PID"
        # PROVE it bound before claiming it is up. python exits on a bind failure,
        # so a report taken at launch describes a process that may already be gone.
        if ! http_serving; then
            echo "serve: http did NOT come up on $SERVE_IP:$HTTP_PORT" >&2
            [ -s "$HTTP_LOG" ] && tail -n 3 "$HTTP_LOG" >&2
            rm -f "$HTTP_PID"
            exit 1
        fi
        echo "serve: http up on $SERVE_IP:$HTTP_PORT — serving $NETDIR"
    fi
    ;;

stop)
    alive "$DNSMASQ_PID" && sudo kill "$(cat "$DNSMASQ_PID")" && echo "serve: dnsmasq stopped" || true
    alive "$HTTP_PID" && kill "$(cat "$HTTP_PID")" && echo "serve: http stopped" || true
    rm -f "$DNSMASQ_PID" "$HTTP_PID"
    ;;

status)
    alive "$DNSMASQ_PID" && echo "dnsmasq: UP (pid $(cat "$DNSMASQ_PID")) — proxyDHCP $SUBNET/24 + TFTP on $IFACE/$SERVE_IP" \
                         || echo "dnsmasq: down"
    # Answer the question lemon asks — "will a fetch work?" — not "does a pid
    # file exist?". They came apart once: a leftover server held the port, the
    # pid file knew nothing of it, and `status` said down while HTTP was serving
    # perfectly well. A netboot aborted on that.
    if http_serving; then
        _hp="$(port_holder)"
        if [ -f "$HTTP_PID" ] && [ "$_hp" = "$(cat "$HTTP_PID")" ]; then
            echo "http:    UP (pid $_hp) — http://$SERVE_IP:$HTTP_PORT/"
        else
            echo "http:    UP (pid ${_hp:-?}, NOT started by this server — a leftover) — http://$SERVE_IP:$HTTP_PORT/"
        fi
    else
        echo "http:    down"
    fi
    if [ -f "$NETDIR/kernel.elf" ]; then
        echo "serving: $NETDIR"
        ls -la "$NETDIR" | sed -n '2,$p' | awk '{printf "  %-20s %10s  %s %s %s\n", $9, $5, $6, $7, $8}'
    else
        echo "serving: (nothing staged — run 'make netboot')"
    fi
    ;;

log)
    # The single most useful artifact when a netboot does not happen: it shows whether
    # lemon even asked (DHCPDISCOVER with client-arch 7/9), what we told it, and
    # whether it then came back for the file over TFTP.
    [ -f "$DNSMASQ_LOG" ] && tail -n "${2:-40}" "$DNSMASQ_LOG" || echo "serve: no dnsmasq log yet"
    echo "--- http ---"
    [ -f "$HTTP_LOG" ] && tail -n "${2:-20}" "$HTTP_LOG" || echo "serve: no http log yet"
    ;;

*)
    echo "usage: $0 {start|stop|status|log}" >&2
    exit 1
    ;;
esac
