#!/usr/bin/env python3
"""A module draws 3D in its own window: the window + gl capability loop, end to
end, in QEMU.

Steps, each through the channel a real user or tool would use:
  1. the factory compiles scripts/agent/samples/cube.zig (in-process, host zig);
  2. the blob lands on the ramdisk over netdebug's chunked write (DIAG-025);
  3. `run cube` is typed on the emulated keyboard;
  4. the window is asserted from the WM mirror (MOD-012), the animation from two
     differing screendumps (MOD-015), and no `frame refused` line proves the
     validator passed real frames (MOD-016);
  5. the window is closed remotely over MCP, and the run must end (MOD-014).

Laptop only: no GPU, so the replay lands on the software rasteriser; the 4090
runs the same draw calls via check-hw.

Usage: scripts/tests/cube_run.py [--keep] [--display]
Requires: build/kudos-smp.iso built with -Dtest-hooks -Dsoft-display, zig on PATH.
"""

import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts/debug"))
sys.path.insert(0, os.path.join(ROOT, "scripts/agent"))
sys.path.insert(0, os.path.join(ROOT, "scripts/tools/netdebug-mcp"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmp  # noqa: E402
import kmir  # noqa: E402
import factory  # noqa: E402
from guest_boot import Netdebug, wait_for  # noqa: E402

OUT = os.path.join(ROOT, "build/logs")
os.makedirs(OUT, exist_ok=True)
PCAP = os.path.join(OUT, "cube-run.pcap")
QMP_SOCK = "/tmp/kudos-cube-run-qmp.sock"
LOG = os.path.join(OUT, "cube-run.log")
ISO = os.path.join(ROOT, "build/kudos-smp.iso")
# The KMR1 port, reached through slirp's hostfwd on loopback (the guest is not
# routable from the host; QEMU forwards this one port in).
KMIR_FWD_PORT = 19515

BOOT_BUDGET_S = 90
WINDOW_BUDGET_S = 30
SPIN_SETTLE_S = 2.0  # between screendumps: ~80 degrees of cube at 40 deg/s

def fail(nd, why):
    with open(LOG, "w") as f:
        f.write(nd.text)
    print(f"\ncube_run: FAIL — {why}", file=sys.stderr)
    print(f"  the captured trace is in {LOG}", file=sys.stderr)
    print("\n".join(nd.text.splitlines()[-20:]), file=sys.stderr)
    return 1


def start_qemu(display):
    for f in (PCAP, QMP_SOCK):
        if os.path.exists(f):
            os.unlink(f)
    # compile_run's proven flags, plus ONE addition: the hostfwd that lets the
    # KMR1 client reach the guest's netdebug RPC port from loopback.
    cmd = [
        "qemu-system-x86_64",
        "-cdrom", ISO,
        "-boot", "order=d",
        "-m", "4G",
        "-smp", "4",
        "-enable-kvm",
        "-cpu", "host",
        "-vga", "std",
        "-netdev", f"user,id=n0,hostfwd=udp:127.0.0.1:{KMIR_FWD_PORT}-:{kmir.PORT}",
        "-device", "e1000,netdev=n0",
        "-object", f"filter-dump,id=d0,netdev=n0,file={PCAP}",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,bus=xhci.0",
        "-device", "usb-tablet,bus=xhci.0",
        "-display", "gtk" if display else "none",
        "-qmp", f"unix:{QMP_SOCK},server,nowait",
        "-no-reboot", "-no-shutdown",
    ]
    return subprocess.Popen(cmd, stdout=open(os.path.join(OUT, "cube-run-qemu.log"), "wb"),
                            stderr=subprocess.STDOUT)


def screendump(q, path):
    q.screendump(path)
    for _ in range(20):
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path, "rb").read()
        time.sleep(0.1)
    return b""


def main():
    keep = "--keep" in sys.argv
    if not os.path.exists(ISO):
        print("cube_run: build the image first:  zig build iso-smp -Dtest-hooks", file=sys.stderr)
        return 1

    # 1. The factory compiles the reference cube — in-process, no HTTP.
    src = open(os.path.join(ROOT, "scripts/agent/samples/cube.zig")).read()
    res = factory.compile_kudos(src, kind="app", name="cube")
    if not res["ok"]:
        print(f"cube_run: cube.zig does not compile: {res['errors']}", file=sys.stderr)
        return 1
    blob = res["blob"]
    print(f"cube_run: cube.kudos compiled ({len(blob)} bytes)")

    proc = start_qemu("--display" in sys.argv)
    nd = Netdebug(PCAP)
    print(f"cube_run: qemu {proc.pid}, image {ISO}")
    try:
        if not wait_for(nd, r"dbg: term\.0 = kudos terminal", BOOT_BUDGET_S, "kudos terminal"):
            return fail(nd, "kudos never reached its terminal")
        # The KEYBOARD must be live before anything is typed — the terminal
        # greets before USB enumeration finishes, and keystrokes into a
        # not-yet-polled HID vanish without a trace (literally).
        if not wait_for(nd, r"xhci: polling started", 30, "usb keyboard live"):
            return fail(nd, "the emulated keyboard never enumerated")
        time.sleep(0.5)
        q = qmp.QMP(QMP_SOCK)

        # 2. The network, so KMR1 can reach in; then the blob over the chunked
        #    write (DIAG-025) — bigger than one datagram, so this IS the test
        #    of WRITE_AT against the real machine.
        q.type_str("net ip")
        q.key("ret")
        if not wait_for(nd, r"ip\s+10\.0\.2\.\d+", 30, "dhcp lease"):
            return fail(nd, "kudos never leased an address from slirp")
        client = kmir.Client("127.0.0.1", port=KMIR_FWD_PORT)
        client.write_file("cube.kudos", blob)
        print(f"  ok   pushed cube.kudos over KMR1 ({len(blob)} bytes, chunked)")

        # 3. Run it, as a person would.
        q.type_str("run cube")
        q.key("ret")

        # 4. The window opens (MOD-012): the WM mirror records a window titled
        #    "kudos app".
        if not wait_for(nd, r"dbg: wm\.win\d+ = .*t=kudos app", WINDOW_BUDGET_S, "blob window open"):
            return fail(nd, "the module never got its window")

        # 5. The cube spins: two screendumps a beat apart must differ (the
        #    machine is otherwise idle — nothing else animates the frame), and
        #    no frame may have been refused by the validator (MOD-015, MOD-016).
        time.sleep(2.0)  # first frames land
        shot_a = screendump(q, os.path.join(OUT, "cube-a.ppm"))
        time.sleep(SPIN_SETTLE_S)
        shot_b = screendump(q, os.path.join(OUT, "cube-b.ppm"))
        if not shot_a or not shot_b:
            return fail(nd, "screendump produced nothing")
        if shot_a == shot_b:
            return fail(nd, "the window is not animating (two dumps identical)")
        print("  ok   the scene animates (screendumps differ)")
        if "blobwin: frame refused" in nd.text:
            return fail(nd, "the validator refused frames — the recorder and replay disagree")
        print("  ok   no frame was refused by the validator")

        # 6. Close the window REMOTELY; the run must end and the shell prompt
        #    return (MOD-014). The window tool goes through the same MCP surface
        #    the agent drives.
        client.mcp({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": {"name": "window",
                               "arguments": {"action": "close", "window": "kudos app"}}})
        if not wait_for(nd, r"\[exit 0\]", WINDOW_BUDGET_S, "run ended on window close"):
            return fail(nd, "closing the window did not end the module's run")

        with open(LOG, "w") as f:
            f.write(nd.text)
        print(f"\ncube_run: PASS — a compiled module drew a rotating cube in its own "
              f"window and its run ended with the window, trace in {LOG}")
        return 0
    finally:
        if keep:
            print(f"cube_run: leaving qemu {proc.pid} up (qmp {QMP_SOCK})")
        else:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    sys.exit(main())
