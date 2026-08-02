#!/usr/bin/env python3
"""Keyboard-only model screenshot driver — the single model-shot path.

Given a running kudos guest (booted by shot.sh under QEMU passthrough) and its
netdebug capture, this waits for the GPU desktop, opens ONE model maximised with
`show <path> max`, pulls a full-res screenshot, and then PROVES the render was
live GL (not an in-window placeholder or a stalled mirror) via the trace-only
model_sweep.require_render check. It drives the keyboard only: `max` maximises
the window, so there is no pointer-convergence dance and no mouse machinery —
just the keyboard and the trace-only render proof.

The shot is pulled BEFORE the render proof on purpose: the picture is the
deliverable, so it is saved unconditionally, and the proof then runs as a loud
trailing assertion (a failed render exits non-zero, but the PNG is already on
disk for inspection).

Usage: model_shot.py <capture-log> <model-path-in-kudos> <out-dir>
       prints "SHOT <path>" on success, or a loud reason and a non-zero exit.
"""

import os
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "tools", "netdebug-mcp"))  # kmir
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))              # boot2 lib

import kmir  # noqa: E402
import boot2_passthrough as lib  # noqa: E402
import model_sweep  # noqa: E402 — trace-only render proof (require_render), no pointer

# The two trace markers that bracket a usable desktop: GSP-RM up, then the
# compositor announcing the session is live (both emitted on every GPU boot).
GSP_MARK = "GSP_INIT_DONE received"
DESKTOP_MARK = "desktop session live"
# A big model is tens of seconds of FAT-over-USB read + parse + VRAM upload.
UPLOAD_SETTLE_S = 15
OPEN_DEADLINE_S = 90


def die(msg):
    print(f"model-shot: {msg}", flush=True)
    sys.exit(1)


def main():
    if len(sys.argv) != 4:
        die("usage: model_shot.py <capture> <model-path> <out-dir>")
    lib.capture_path = sys.argv[1]
    model, out_dir = sys.argv[2], sys.argv[3]
    os.makedirs(out_dir, exist_ok=True)

    print("model-shot: waiting for GPU desktop ...", flush=True)
    lib.wait_for(GSP_MARK, lib.BOOT_TIMEOUT_S, "GSP-RM boot")
    lib.wait_for(DESKTOP_MARK, lib.BOOT_TIMEOUT_S, "desktop live")
    print("model-shot: desktop up", flush=True)

    client = kmir.Client(kmir.discover_ip(None))

    # Prove the KMR1 control channel round-trips BEFORE typing. A missing tap
    # route (the classic passthrough failure) fails here in seconds instead of
    # hanging every keystroke on an 8-attempt retry.
    for i in range(20):
        try:
            client.ping()
            break
        except Exception as e:  # noqa: BLE001
            print(f"model-shot: KMR1 not ready ({i}): {e}", flush=True)
            time.sleep(2)
    else:
        die("KMR1 never answered — the guest is unreachable (tap route?)")

    # The model is opened with `show <path>`; kudos prints "opened <name>" once
    # the window exists.
    open_cmd = f"show {model} max"
    print(f"model-shot: {open_cmd}", flush=True)
    # Everything the model produces starts here — scope the render proof to it so
    # the boot teapot's earlier frames can't stand in for the model's.
    mark = len(lib.read_capture())
    lib.type_line(client, open_cmd)

    deadline = time.time() + OPEN_DEADLINE_S
    while time.time() < deadline:
        cap = lib.read_capture()
        if f"opened {model}" in cap:
            print("model-shot: model window opened", flush=True)
            break
        if any(s in cap for s in ("load failed", "MISSING", "BlockIoFailed", "not found")):
            die(f"kudos could not load the model — see the capture ({lib.capture_path})")
        time.sleep(1)
    else:
        die("no 'opened' confirmation within the deadline")

    time.sleep(UPLOAD_SETTLE_S)  # let parse + VRAM upload finish before the shot
    pulled = client.screenshot(out_dir)
    lp = getattr(client, "last_pull", None)
    if lp:
        print(f"model-shot: transfer {lp['bytes']} B in {lp['seconds']:.2f}s = "
              f"{lp['mib_s']:.1f} MiB/s ({lp['retransmits']} retransmits) [PERF-013]", flush=True)
    print(f"SHOT {pulled}", flush=True)

    # Trace-only proof the picture is a live-GL render, not a placeholder or a
    # stalled mirror (require_render exits loudly on failure). Runs after the shot
    # so the PNG is always saved for inspection even when the proof fails.
    base = os.path.basename(model)
    model_sweep.require_render(base, mark)


if __name__ == "__main__":
    main()
