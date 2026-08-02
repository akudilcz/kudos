#!/bin/sh
# lemon — the remote bare-metal target. Boot it into kudos without ever touching
# its bootloader, boot order, or the Windows/Ubuntu installs.
#
#   scripts/netboot/lemon.sh boot     PRIMARY: netboot the current build (nothing staged)
#   scripts/netboot/lemon.sh status    what is armed / what is running
#   scripts/netboot/lemon.sh recover   reboot lemon back into Ubuntu, now
#   scripts/netboot/lemon.sh disarm    cancel the one-shot (next boot = Ubuntu)
#   scripts/netboot/lemon.sh setup     once: install the GRUB stub (DISK fallback only)
#   scripts/netboot/lemon.sh arm       DISK FALLBACK: rsync the build to /boot/kudos, arm GRUB
#
# THE BOOT IS FETCHED, NOT STAGED. lemon's firmware has a UEFI network device in
# its BootOrder (`Boot0009* UEFI:Network Device`) and Secure Boot is off, so it can
# PXE-boot straight off this laptop: `efibootmgr --bootnext` points the NEXT boot
# at the network, our dnsmasq answers with a GRUB image, and that GRUB pulls
# build/netboot/kernel.elf over HTTP. Whatever is in that directory when lemon
# resets is what lemon runs — there is no staged copy that can go stale.
# (scripts/netboot/serve.sh is the server; `make netboot-serve` starts it.)
#
# THE ONE-SHOT IS THE WHOLE SAFETY MODEL, and netboot makes it stronger. `BootNext`
# is a next-boot-only EFI variable the FIRMWARE clears as it hands off, so kudos
# boots exactly once: any subsequent reset — panic, self-reboot, power cut — falls
# through BootOrder into Ubuntu and lemon comes back on the network by itself. And
# if our server is not running, the PXE attempt simply times out into Ubuntu too.
# Two independent ways for a wedged kudos to end up back in a working Linux, on a
# machine nobody can walk to.
#
# The DISK path (setup/arm) predates this and still works: it rsyncs the tree to
# lemon's /boot/kudos and boots it with grub-reboot. Kept as a fallback for when
# this laptop is off or the PXE path misbehaves.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUILD_DIR="${BUILD_DIR:-build}"
NETDIR="$BUILD_DIR/netboot"
HOST="${LEMON_HOST:-lemon}"          # ~/.ssh/config alias; lemonip.sh reads its HostName
TARGET_DIR="${TARGET_DIR:-/boot/kudos}"
ENTRY_ID="kudos"                     # --id in the GRUB stub; what grub-reboot names

# Where lemon fetches from. Asked of the routing table (not guessed), so the stub
# always names the address lemon can actually reach us on. Baked into the GRUB stub
# at `setup` — re-run setup if this laptop's address changes.
LEMON_IP="${LEMON_IP:-$("$(dirname "$0")/lemonip.sh")}"
SERVE_IP="${SERVE_IP:-$(ip route get "$LEMON_IP" | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
HTTP_PORT="${HTTP_PORT:-8099}"

# The address the ROUTER hands to lemon as DHCP option 66 (TFTP server). It is
# configured once, in the router, and it names THIS laptop — so if our lease ever
# moves, lemon's firmware TFTPs at a machine that is not us and the boot dies with
# no clue why. Pin the expectation here and shout when it drifts; the fix is a DHCP
# reservation for `laptop` on the router, not a code change.
PINNED_IP="${NETBOOT_SERVER_IP:-192.168.20.103}"
if [ "$SERVE_IP" != "$PINNED_IP" ]; then
    echo "lemon: WARNING — this laptop is $SERVE_IP but the router's PXE option 66 names $PINNED_IP." >&2
    echo "lemon:           lemon will TFTP at the wrong host and fall back to Ubuntu." >&2
    echo "lemon:           Fix: reserve $PINNED_IP for 'laptop' on the router, or set NETBOOT_SERVER_IP." >&2
fi

sshl() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$@"; }

require_tree() {
    [ -f "$NETDIR/kernel.elf" ] || { echo "lemon: no staged tree — run 'make netboot' first" >&2; exit 1; }
}

case "${1:-status}" in

setup)
    echo "lemon: installing the GRUB stub (additive — Windows/Ubuntu untouched)"
    # WHY THE KERNEL IS PULLED BY LINUX AND NOT BY THE BOOTLOADER. lemon's BIOS
    # "Network Stack" is off, so there is no firmware PXE to boot from, and a
    # disk-booted GRUB has no NIC at all — this board instantiates the UEFI network
    # stack only when booting FROM the network. Turning either on needs someone
    # standing at the machine.
    #
    # So lemon's Ubuntu fetches the kernel over HTTP from this laptop, arms the
    # one-shot, and reboots into it. The kernel still travels over the network on
    # every boot and build/netboot/ is still the single copy — it just crosses the
    # wire a few seconds earlier, carried by a stack that actually exists.
    #
    # So the stub is the simple one: find the root filesystem, source the recipe that
    # the pull just wrote. It never changes again.
    sshl "set -e
        ROOT_UUID=\$(findmnt -no UUID /)
        sudo tee /etc/grub.d/40_custom >/dev/null <<'EOF'
#!/bin/sh
exec tail -n +3 \$0
# kudos — added by scripts/netboot/lemon.sh. Boots ONLY when armed one-shot
# (grub-reboot); never the default. Remove this file + update-grub to undo.
menuentry \"kudos (netboot)\" --id kudos {
    insmod part_gpt
    insmod ext2
    search --no-floppy --fs-uuid --set=root \$ROOT_UUID
    source /boot/kudos/kudos.cfg
}
EOF
        sudo chmod +x /etc/grub.d/40_custom

        # GRUB_DEFAULT=saved makes GRUB honour the one-shot grub-reboot writes.
        # The saved default stays Ubuntu, so a normal boot is unchanged.
        if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
            sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        else
            echo 'GRUB_DEFAULT=saved' | sudo tee -a /etc/default/grub >/dev/null
        fi
        sudo update-grub 2>&1 | grep -iE 'kudos|error|warn' || true
        sudo grub-set-default 0    # default entry = Ubuntu, explicitly
    "
    echo "lemon: setup done — default boot is still Ubuntu; kudos only boots when armed"
    echo "lemon: it will fetch its kernel from http://$SERVE_IP:$HTTP_PORT/ on every armed boot"
    ;;

arm)
    require_tree
    echo "lemon: shipping $(du -sh "$NETDIR" | cut -f1) to $HOST:$TARGET_DIR"
    # --delete so a no-firmware build actually REMOVES the stale fw/ blobs rather
    # than leaving kudos.cfg and the tree disagreeing.
    rsync -a --delete --info=progress2 "$NETDIR/" "$HOST:$TARGET_DIR/"
    sshl "sudo grub-reboot $ENTRY_ID"
    echo "lemon: ARMED — next boot (and ONLY the next boot) is kudos"
    ;;

boot)
    # lemon PULLS the build from us over HTTP, then boots it. Nothing is pushed and
    # nothing is kept: the copy in build/netboot/ is the only one, so the boot cannot
    # run a stale kernel — whatever is in that directory when this runs is what lemon
    # executes. (See `setup` for why the pull is done by Linux and not by the firmware
    # or GRUB: neither has a network on this board.)
    [ -f "$NETDIR/kernel.elf" ] || { echo "lemon: nothing staged — run 'make netboot' first" >&2; exit 1; }

    # The server must be up BEFORE lemon fetches. Refuse rather than waste a boot.
    scripts/netboot/serve.sh status | grep -q "^http: *UP" || {
        echo "lemon: the netboot server is NOT running — start it with 'make netboot-serve'" >&2
        exit 1
    }

    echo "lemon: fetching build $(cat BUILD_NUMBER 2>/dev/null || echo '?') from http://$SERVE_IP:$HTTP_PORT/"
    # --fail so a 404 or a dead server is an ERROR, not a truncated kernel silently
    # written over the last good one. Fetch to .new and rename only on success: a
    # half-downloaded kernel that GRUB then tries to boot is the one failure mode
    # here that costs a physical trip.
    sshl "set -e
        mkdir -p $TARGET_DIR
        curl -fsS --connect-timeout 5 -o $TARGET_DIR/kernel.elf.new http://$SERVE_IP:$HTTP_PORT/kernel.elf
        curl -fsS --connect-timeout 5 -o $TARGET_DIR/kudos.cfg.new http://$SERVE_IP:$HTTP_PORT/kudos.cfg
        mv -f $TARGET_DIR/kernel.elf.new $TARGET_DIR/kernel.elf
        mv -f $TARGET_DIR/kudos.cfg.new  $TARGET_DIR/kudos.cfg
        echo \"lemon: fetched \$(stat -c%s $TARGET_DIR/kernel.elf) bytes\"
    "

    # GRUB's one-shot: written to grubenv, CLEARED by GRUB as it hands off. kudos
    # boots exactly once — any later reset (its own 30 s self-reboot, a panic, a power
    # cut) falls back to Ubuntu and lemon returns on the network by itself.
    echo "lemon: arming the one-shot (kudos boots ONCE; any later reset = Ubuntu)"
    sshl "sudo grub-reboot $ENTRY_ID"

    echo "lemon: rebooting into kudos"
    # The reboot kills the ssh session; that exit status is expected, not an error.
    # -i overrides logind inhibitors: GNOME's session holds a block inhibitor on a
    # desktop install, and a plain `systemctl reboot` from ssh is REFUSED with
    # "Operation denied due to active block inhibitor".
    sshl 'sudo systemctl reboot -i' || true
    echo "lemon: rebooted. Watch it come up with the netdebug MCP, or: socat -u udp-recv:9514 -"
    echo "       (netboot server log: scripts/netboot/serve.sh log)"
    ;;

status)
    echo "== lemon =="
    if sshl 'true' 2>/dev/null; then
        echo "reachable over SSH  -> Linux is up (kudos is NOT running)"
        # The last netboot attempt's breadcrumbs (written by the GRUB stub, survive
        # the fallback reboot): entered -> after_bootp -> (booted, or fetch_failed).
        # `entered` alone means GRUB ran but net_bootp never returned; after_bootp
        # with an empty kudos_ip means efinet found no usable card.
        sshl 'echo "  netboot:  $(sudo grub-editenv list 2>/dev/null | grep -E "^kudos_(stage|ip|card)=" | tr "\n" " " || echo "(never attempted)")"
              echo "  uptime:   $(uptime -p)"
              echo "  bootnext: $(sudo efibootmgr | sed -n "s/^BootNext: /netboot armed -> entry /p" || true)$(sudo efibootmgr | grep -q "^BootNext:" || echo "(not armed)")"
              echo "  grubenv:  $(sudo grub-editenv list 2>/dev/null | grep next_entry || echo "(disk one-shot not armed)")"
              echo "  staged:   $(ls /boot/kudos/kernel.elf >/dev/null 2>&1 && echo "$(du -sh /boot/kudos | cut -f1) at /boot/kudos (disk fallback)" || echo "(no disk tree)")"'
        echo "  --- server (this laptop) ---"
        scripts/netboot/serve.sh status | sed 's/^/  /'
    elif ping -c1 -W2 "$(getent hosts lemon.local | awk '{print $1}')" >/dev/null 2>&1; then
        echo "NOT reachable over SSH, but answers ping -> kudos is probably running"
    else
        echo "NOT reachable at all -> kudos is running (no ping), or lemon is down/wedged"
    fi
    ;;

disarm)
    # Both one-shots: the firmware's (netboot path) and GRUB's (disk path). Clearing
    # only one would leave a machine that still boots kudos on the next reset.
    sshl 'sudo efibootmgr --delete-bootnext >/dev/null 2>&1 || true
          sudo grub-editenv - unset next_entry 2>/dev/null || true'
    echo "lemon: disarmed — next boot is Ubuntu"
    ;;

recover)
    # Only works while Linux is up. If kudos is wedged, this cannot help: lemon's
    # PCH watchdog cannot reset it (NO_REBOOT is stuck), so the remedies are KMR1
    # OP_REBOOT (needs a lease — `kmir.py reboot`), the heartbeat image's bounded
    # run (it reboots itself), or a physical power cycle.
    echo "lemon: rebooting into Ubuntu"
    sshl 'sudo efibootmgr --delete-bootnext >/dev/null 2>&1 || true
          sudo grub-editenv - unset next_entry 2>/dev/null || true
          sudo systemctl reboot -i' || true
    ;;

*)
    echo "usage: $0 {setup|arm|boot|status|disarm|recover}" >&2
    exit 1
    ;;
esac
