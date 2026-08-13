#!/usr/bin/env python3
"""Boot kudos in QEMU, boot a Linux guest inside it, and prove the guest ran.

This is the nested-virtualisation track, and unlike the other suites it runs on a
DEVELOPER LAPTOP: it needs no GPU, no USB stick and no lemon. kudos runs as the L1
hypervisor under KVM (`-cpu host` exposes VMX when the host has
kvm_intel.nested=Y), and the Linux guest it boots is the one staged into the image
by scripts/virt/build_guest.sh.

Readback is netdebug, lifted out of QEMU's own packet dump rather than a tap: the
guest's serial console is mirrored onto the kudos trace bus by a -Dtest-hooks
build (src/kernel/virt/machine.zig), so the guest's boot log leaves the machine
the same way every other kudos trace does. Injection is QMP into the emulated USB
keyboard, exactly as the boot-1 suite does it.

Fails LOUD (non-zero) with the captured log on any miss.

Usage: scripts/tests/guest_boot.py [--keep] [--display]
"""
import os
import re
import struct
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts/debug"))
import qmp  # noqa: E402

OUT = os.path.join(ROOT, "build/logs")
PCAP = os.path.join(OUT, "guest-boot.pcap")
QMP_SOCK = "/tmp/kudos-guest-qmp.sock"
LOG = os.path.join(OUT, "guest-boot.log")
ISO = os.path.join(ROOT, "build/kudos.iso")

# The netdebug port every kudos trace leaves on (drivers/net/debug/netdebug.zig).
NETDEBUG_PORT = 9514
# Guest RAM is 128 MiB and the image decompresses ~1 MiB of kernel; a laptop does
# the whole boot in a couple of seconds, but a loaded machine can take far longer,
# and a budget that is too tight reads as a failure that is really a slow host.
BOOT_BUDGET_S = 90
# The marker the staged initramfs prints once it has a console (build_guest.sh).
MARKER = "KUDOS-GUEST-UP"


def start_qemu(display):
    os.makedirs(OUT, exist_ok=True)
    for f in (PCAP, QMP_SOCK):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    cmd = [
        "qemu-system-x86_64",
        "-cdrom", ISO,
        "-boot", "order=d",
        "-m", "8G",
        # ONE core: the guest is then pumped from kudos's own frame loop on core 0
        # (virt.pumpAll), which is the path this track exists to exercise.
        "-smp", "1",
        "-enable-kvm",
        "-cpu", "host",
        "-vga", "std",
        "-netdev", "user,id=n0",
        "-device", "e1000,netdev=n0",
        "-object", f"filter-dump,id=d0,netdev=n0,file={PCAP}",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,bus=xhci.0",
        "-device", "usb-tablet,bus=xhci.0",
        "-display", "gtk" if display else "none",
        "-qmp", f"unix:{QMP_SOCK},server,nowait",
        "-no-reboot", "-no-shutdown",
    ]
    return subprocess.Popen(cmd, stdout=open(os.path.join(OUT, "guest-qemu.log"), "wb"),
                            stderr=subprocess.STDOUT)


class Netdebug:
    """kudos's trace stream, decoded from the growing packet dump."""

    def __init__(self, path):
        self.path = path
        self.off = 24  # classic pcap global header
        self.text = ""

    def poll(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.off)
                data = f.read()
        except FileNotFoundError:
            return ""
        out, i = [], 0
        while i + 16 <= len(data):
            _, _, caplen, _ = struct.unpack("<IIII", data[i:i + 16])
            if i + 16 + caplen > len(data):
                break
            pkt = data[i + 16:i + 16 + caplen]
            i += 16 + caplen
            self.off += 16 + caplen
            if len(pkt) < 42 or pkt[12:14] != b"\x08\x00" or pkt[14 + 9] != 17:
                continue
            udp = pkt[14 + (pkt[14] & 0x0F) * 4:]
            if struct.unpack(">H", udp[2:4])[0] != NETDEBUG_PORT:
                continue
            out.append(udp[8:].decode("utf-8", "replace"))
        self.text += "".join(out)
        return "".join(out)


def wait_for(nd, pattern, timeout, label):
    rx = re.compile(pattern)
    deadline = time.time() + timeout
    while time.time() < deadline:
        nd.poll()
        m = rx.search(nd.text)
        if m:
            print(f"  ok   {label}: {m.group(0)[:100]}")
            return m
        time.sleep(0.25)
    return None


def fail(nd, why):
    with open(LOG, "w") as f:
        f.write(nd.text)
    print(f"\nguest_boot: FAIL — {why}", file=sys.stderr)
    print(f"  the captured trace is in {LOG}", file=sys.stderr)
    guest = [l for l in nd.text.splitlines() if "vm0:" in l or "virt:" in l]
    print("\n".join(guest[-25:]), file=sys.stderr)
    return 1


def main():
    keep = "--keep" in sys.argv
    if not os.path.exists(ISO):
        print("guest_boot: build the image first:  zig build iso -Dtest-hooks", file=sys.stderr)
        return 1
    proc = start_qemu("--display" in sys.argv)
    nd = Netdebug(PCAP)
    print(f"guest_boot: qemu {proc.pid}, image {ISO}")
    try:
        if not wait_for(nd, r"dbg: term\.0 = kudos terminal", 60, "kudos terminal"):
            return fail(nd, "kudos never reached its terminal")
        if not wait_for(nd, r"virt: VT-x present", 10, "vt-x"):
            return fail(nd, "no VT-x in the guest CPU — is kvm_intel.nested=Y?")
        if not wait_for(nd, r"xhci:  -> KEYBOARD ready", 30, "keyboard"):
            return fail(nd, "the emulated keyboard never enumerated")
        time.sleep(1.0)

        q = qmp.QMP(QMP_SOCK)
        q.type_str("kudos vm boot 1")
        q.key("ret")
        print("  ..   typed: vm boot")

        if not wait_for(nd, r"virt: vmxon ok", 10, "vmxon"):
            return fail(nd, "the host core never entered VMX operation")
    # VIRT-001 and VIRT-003: the machine enters VMX operation and boots an unmodified
    # Linux kernel; VIRT-004: userspace comes up from the in-memory initramfs.
        if not wait_for(nd, r"vm0: Linux version", BOOT_BUDGET_S, "linux kernel"):
            return fail(nd, "the guest kernel never announced itself")
        if not wait_for(nd, r"vm0: .*Run /init as init", BOOT_BUDGET_S, "userspace"):
            return fail(nd, "the guest kernel never started its init")
        if not wait_for(nd, rf"vm0: {MARKER}", BOOT_BUDGET_S, "guest init marker"):
            return fail(nd, f"the guest's init never printed {MARKER}")

        with open(LOG, "w") as f:
            f.write(nd.text)
        lines = [l for l in nd.text.splitlines() if "vm0:" in l]
        print(f"\nguest_boot: PASS — {len(lines)} lines of guest console, log in {LOG}")
        return 0
    finally:
        if keep:
            print(f"guest_boot: leaving qemu {proc.pid} up (qmp {QMP_SOCK})")
        else:
            proc.terminate()


if __name__ == "__main__":
    sys.exit(main())
