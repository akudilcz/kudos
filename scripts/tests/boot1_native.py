#!/usr/bin/env python3
"""boot-1-NATIVE: the boot-1 suite, run against kudos on REAL HARDWARE (lemon).

Same cases, same assertions, same phases as the emulated track — only the transport
differs, and that is deliberate: a regression must not be able to pass under QEMU
while breaking on the metal. This driver imports boot1_emulated and runs ITS phases,
swapping two things underneath them:

  injection  QMP (an emulator socket)  ->  KMR1 (UDP :9515, kmr1_input.Kmr1Input)
  readback   /tmp/netdebug.log          ->  the same file, filled by run_native.sh's
                                            netdebug capture instead of a QEMU boot

Everything else — the case table (cases.py), the mirror parsing, the window-manager
assertions — is shared code, so there is exactly one definition of what "boot-1 passes"
means and both tracks are held to it.

WHY THIS EXISTS. The emulated track proves the logic; only the native track proves the
machine. Every bug that has actually cost us a physical trip to lemon — enumeration
under masked interrupts, a DHCP lease thrown away, SuperSpeedPlus babble — was invisible
in QEMU and would have stayed invisible in an emulated-only suite.

Run via scripts/tests/run_native.sh (which builds, netboots lemon, and captures);
this file assumes kudos is already up and streaming.
"""

import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import boot1_emulated as b1  # noqa: E402  — the phases, cases and assertions live there
import kmr1_input  # noqa: E402
import cadence  # noqa: E402  — the shared FLIPSTAT verdict home (passthrough uses it too)
import bootmark  # noqa: E402  — the shared PERF-002/PERF-014 boot-milestone home

sys.path.insert(0, os.path.join(HERE, "..", "tools", "netdebug-mcp"))
import kmir  # noqa: E402

def lemon_ip():
    """The rig's address, from its ONE home (scripts/netboot/lemonip.sh, which
    reads ~/.ssh/config). Hardcoding it here is how eight scripts were all
    wrong at once the day the rig moved."""
    import subprocess
    helper = os.path.join(HERE, "..", "netboot", "lemonip.sh")
    return subprocess.run([helper], capture_output=True, text=True,
                          check=True).stdout.strip()


LEMON_IP = os.environ.get("LEMON_IP") or lemon_ip()
NETDEBUG_LOG = os.environ.get("NETDEBUG_LOG", "/tmp/netdebug-native.log")


# The desktop comes up BEFORE USB on a normal boot, so gating on the terminal alone starts
# typing into a machine that has no keyboard yet — and phase 1's own first assertion is
# that the keyboard is there. The stick mounts AFTER HID enumerates, so gating on the
# Readiness must gate ONLY on signals that survive a dropped datagram. The async DHCP
# bind commits the lease a beat AFTER USB enumeration, so the one-shot boot lines
    # PER-001, PER-002 and PER-003: the USB keyboard, mouse and mass-storage drive are all
    # enumerated and driven — every typed case downstream is the consequence.
# ("xhci: -> KEYBOARD ready", "usbdisk: FAT volume mounted") are emitted while
# telemetry is still buffered/broadcast and can be lost — a keyboard that IS enumerated
# and live then looks absent (proven: the flight-recorder bootlog showed kbd reports
# climbing past 1000 on a boot the netdebug capture never showed "KEYBOARD ready" for).
# So gate the keyboard on the RE-EMITTED inventory `usb.hid_present = kbd=N mouse=M`
# (xhci re-emits it every heartbeat, like the wm-state mirror), and let the stick be
# proven by the phase that lists it — a dropped one-shot no longer fails a healthy boot.
_KBD_PRESENT = re.compile(r"usb\.hid_present = kbd=[1-9]")

# That the terminal is up is proven two ways, and EITHER suffices. The greeting is the
# cleaner proof (the shell actually rendered text), but it is the EARLIEST test-hook line —
# emitted at desktop-create, before the KMR1 ping has registered this collector — so on the
# native transport it is the one datagram most likely to be dropped before netdebug replays
# its backlog. The wm-state mirror carries the same fact (a terminal window exists and is
# being composited) and emitWmState RE-EMITS it every compositor tick, so a dropped first
# copy is recovered by the next. Requiring one-or-the-other keeps the readiness proof from
# hanging on a single early packet — while phase 1 still independently types into the
# terminal and asserts the response, so nothing about "the terminal works" goes unchecked.
_TERM_GREETING = "dbg: term.0 = kudos terminal"
_TERM_WINDOW = re.compile(r"dbg: wm\.win\d+ = .*t=term #0")


def _terminal_up(log):
    return _TERM_GREETING in log or _TERM_WINDOW.search(log) is not None


def wait_for_desktop(timeout_s=300):
    """Block until kudos is driveable: a terminal is up AND USB HID enumerated AND mounted.

    Generous: the full (non-heartbeat) image is ~31 MB to fetch, and lemon's USB tree is
    deep — hubs, audio, an LED controller — so enumeration takes real time on a cold boot.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            with open(NETDEBUG_LOG, errors="replace") as f:
                log = f.read()
        except OSError:
            log = ""
        if _terminal_up(log) and _KBD_PRESENT.search(log):
            return log
        # PING AS EARLY AS POSSIBLE, and keep pinging until it lands. The first KMR1
        # datagram kudos receives tells it who the collector is, and from then on the
        # trace is UNICAST — which over wifi means the AP acknowledges and retries it.
        # Do this DURING the boot wait, not after: netdebug replays its backlog once the
        # path is proven, so registering the collector early means the boot log itself
        # comes back reliably instead of broadcast (8% of it went missing that way).
        try:
            kmir.Client(LEMON_IP).ping()
        except Exception:
            pass  # not up yet — that is what we are waiting for
        time.sleep(1.0)
    missing = []
    if not _terminal_up(log):
        missing.append("a terminal (greeting or wm-state mirror)")
    if not _KBD_PRESENT.search(log):
        missing.append("an enumerated keyboard (re-emitted usb.hid_present kbd>=1)")
    b1.fail(f"boot1-native: kudos not driveable within {timeout_s}s — never saw: {missing}")


def phase_cadence(timeout_s=90):
    """boot-2-native ONLY: measure 60 Hz cadence over the first 10 s from the
    first GPU present, on the metal. kudos is GPU-only, so the first whole-frame present IS "the desktop is
    shown"; the kernel auto-arms a -Dflip-sample window there and, ~10 s later,
    emits one FLIPSTAT verdict. This reads that verdict (no injection — the window
    is measured at IDLE, exactly as the passthrough phase 2 does) and judges it by
    the SHARED rules: a full 10 s (n >= 600) with not a single dropped frame
    (steady == 1) and an overall PASS. This is the same measurement that only ever
    ran under QEMU before — where the host scheduler's own preemption of the vCPU
    added ~2 ms stalls the guest could not cause. On bare metal there is no host to
    preempt the CPU, so a passing window here is the strongest cadence evidence the
    suite collects — not a proof the guarantee holds for every run.
    """
    b1._record("boot2-native: CADENCE — 10 s smooth from the first GPU present (no dropped frame)")
    deadline = time.time() + timeout_s
    while time.time() < deadline and cadence.FIRST_PRESENT_ANCHOR not in b1.read_serial():
        time.sleep(1)
    if cadence.FIRST_PRESENT_ANCHOR not in b1.read_serial():
        b1.fail("no first GPU present — the desktop never reached the panel on the 4090",
                context_grep="gpu.present")
    b1.ok("first GPU present reached the panel (desktop shown)")
    while time.time() < deadline and cadence.verdict_count(b1.read_serial()) < 1:
        time.sleep(1)
    good, detail = cadence.judge_window(cadence.latest_verdict(b1.read_serial()))
    if not good:
        b1.fail(f"10 s from the first present, on the metal: {detail}", context_grep="FLIPSTAT")
    b1.ok(f"10 s smooth from the first present on the 4090 — no dropped frame ({detail})")

    # Boot milestones, judged by the SHARED bootmark rules (the passthrough
    # track asserts the same two). The FLIPSTAT verdict above landed ~10 s
    # after gpu.zig's boot-to-first-present line, so PERF-002 needs no wait;
    # the DHCP lease commits in the background, so PERF-014's record is polled
    # against a stated budget.
    good, detail = bootmark.judge_boot_to_first_present(b1.read_serial())
    if not good:
        b1.fail(f"PERF-002 on the metal: {detail}", context_grep="boot-to-first-present")
    b1.ok(f"desktop within the boot budget ({detail}) [PERF-002]")
    dhcp_deadline = time.time() + bootmark.DHCP_BOUND_TIMEOUT_S
    while time.time() < dhcp_deadline and bootmark.DHCP_BOUND not in b1.read_serial():
        time.sleep(1)
    good, detail = bootmark.judge_network_off_critical_path(b1.read_serial())
    if not good:
        b1.fail(f"PERF-014 on the metal: {detail} "
                f"(waited {bootmark.DHCP_BOUND_TIMEOUT_S}s for the bind)", context_grep="dhcp:")
    b1.ok(f"networking off the boot critical path ({detail}) [PERF-014]")


def main():
    # Point the shared phases at the native capture instead of the QEMU serial mirror.
    b1.SERIAL_LOG = NETDEBUG_LOG
    # lemon's peripherals are whatever is plugged into the desk — hubs, audio, an LED
    # controller — so the exact device/port counts QEMU guarantees do not hold here. The
    # INVARIANT still does: a keyboard, a mouse, and the storage stick. Asserting QEMU's
    # numbers on real hardware would be testing the desk, not the kernel.
    b1.EXACT_COUNTS = False
    # KMR1 injects downstream of the USB HID decoder, so xhci's report counters cannot
    # move for injected input — see phase1. The real keyboard/mouse enumerating is the
    # native equivalent of that check, and it is asserted.
    b1.ASSERT_USB_REPORT_COUNTS = False
    # Real silicon: take the hardware variants of rig-specific cases (lspci prints
    # lemon's I226-V, not QEMU's e1000).
    b1.TRACK = "native"

    # A SEPARATE result log per track: a shared log would let a native run overwrite the
    # emulated run's assertions, and a green retry erase the red run before it. Evidence
    # has to outlive the next run.
    track = "boot-2-native" if os.environ.get("GSP", "") or "gpu" in os.environ.get(
        "NETDEBUG_LOG", "") or "boot-2" in os.environ.get("NETDEBUG_LOG", "") else "boot-1-native"
    b1.RESULT_LOG = os.path.join(b1.ROOT, "build", "logs", f"{track}-result.log")
    try:
        os.makedirs(os.path.dirname(b1.RESULT_LOG), exist_ok=True)
        open(b1.RESULT_LOG, "w").close()
    except OSError:
        pass

    gpu_track = track == "boot-2-native"

    b1._record(f"native: waiting for kudos on {LEMON_IP} to reach the desktop")
    wait_for_desktop()

    q = kmr1_input.Kmr1Input(LEMON_IP)
    b1._record("boot1-native: kudos is up — driving over KMR1")

    # boot-2-native runs the GPU stack, so the desktop composites on the real 4090
    # and the from-first-present cadence guarantee is measurable — assert it FIRST,
    # while the desktop is idle, before any typed command dirties it. (The no-GPU
    # boot-1-native track has no present ring, so there is no window to judge.)
    if gpu_track:
        phase_cadence()

    b1.phase1(q)
    b1.phase2(q)
    b1.phase3(q)
    b1.phase4(q)
    b1.phase5(q)
    phase_mcp()
    b1._record(f"native: PASS — {b1.passed} assertions green on real hardware")


def phase_mcp():
    """MCP over netdebug (AGT-011/AGT-013): a remote client drives kudos's tool
    registry end to end. tools/list must return the agent's own tools, and a
    tools/call of read_file must return a known ramdisk file's contents."""
    b1._record("boot1: PHASE MCP — kudos as an MCP server over netdebug")
    c = kmir.Client(LEMON_IP)

    listed = c.mcp({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    names = [t["name"] for t in listed["result"]["tools"]]
    for expect in ("read_file", "write_file", "system_state", "open_app", "compile_app"):
        if expect not in names:
            b1.fail(f"MCP tools/list missing '{expect}' (got {names})")
    b1.ok(f"MCP tools/list returned {len(names)} tools incl. the AGT-006 surface")

    called = c.mcp({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": {"name": "read_file",
                               "arguments": {"path": "/ramdisk/motd.txt"}}})
    text = called["result"]["content"][0]["text"]
    if "kudos" not in text.lower():
        b1.fail(f"MCP read_file(/ramdisk/motd.txt) did not return the motd (got {text!r})")
    b1.ok("MCP tools/call read_file returned the ramdisk file over netdebug")


if __name__ == "__main__":
    main()
