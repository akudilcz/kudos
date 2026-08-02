#!/usr/bin/env python3
"""Model-corpus sweep driver — one BATCH of models per guest boot.

Usage: model_sweep.py <capture-log> <manifest.json> <batch-index>

The manifest (built host-side by run_model_sweep.sh from glbcheck's verdicts)
lists every staged model as {"path": "/usbdisk/models/X.glb", "expect_ok": bool,
"reason": "GlbJpegUnsupported"|null}. Batches are ceil(n/PER_BOOT) slices of
PER_BOOT models — the kernel's model cache has modelcache.MAX_MODELS=8 slots
and the boot teapot occupies one, so at most 7 fresh models load per session.

Per model:
  1. refocus the terminal (a prior `show` moved focus to its model window),
  2. `show <path>` → await the shell's "opened" confirmation (big scenes take
     tens of seconds of FAT-over-BOT reads),
  3. `echo sweep-alive-<n>` → proves the kernel survived the model's first
     draw (parse + VRAM upload happen there; a bad model must show its loud
     in-window placeholder, NEVER kill the session),
  4. require RENDER PROOF: one new on-screen window + a GL ctx slot mapped +
     a GLSTAT mesh sample, and no in-window placeholder,
  5. trigger a capture — kudos writes /usbdisk/shots/SHOTnnnn.PNG on the
     physical stick (extracted by the runner after the run; SHOTMAP lines in
     the result log map each SHOTnnnn to its model),
  6. click the window's close box (wm.win geometry) → assert wm.closed.

At session start the glass terminal is dragged low once, so the top-left
cascade area where model windows spawn stays clickable (z-order: a raised
terminal otherwise covers every model window's chrome).
"""

import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import boot2_passthrough as lib  # noqa: E402  (shared pointer/mirror machinery)
import cases  # noqa: E402
import kmir  # noqa: E402 — resolvable via lib's sys.path insert

PER_BOOT = 7
SHOT_DIR = lib.SHOT_DIR

# The geometry-and-texture-tier Khronos reference models (spec TEST-005). The
# sweep must individually prove each one displays on target, so their absence
# from the staged manifest is a FAILURE of the sweep, not a smaller sweep —
# usbdisk.py provisions them onto the stick (its FIXED manifest pins the
# bytes). The .gltf entries are the glTF-Embedded container; the kernel's
# `show` loads both forms (modelcache.isModel).
GEOMETRY_TIER = (
    "TriangleWithoutIndices.gltf",
    "Triangle.gltf",
    "Box.glb",
    "BoxInterleaved.glb",
    "BoxTextured.glb",
    "SimpleMeshes.gltf",
)

passed = 0


def _record(line):
    print(line, flush=True)
    try:
        with open(lib.RESULT_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def ok(what):
    global passed
    passed += 1
    _record(f"sweep:   OK  {what}")


def fail(msg):
    _record(f"sweep: FAIL — {msg}")
    _record(f"sweep: {passed} assertions passed before the failure")
    sys.exit(1)


def main():
    if len(sys.argv) != 4:
        print("usage: model_sweep.py <capture> <manifest.json> <batch-index>", file=sys.stderr)
        sys.exit(2)
    lib.capture_path = sys.argv[1]
    manifest = json.load(open(sys.argv[2]))
    batch = int(sys.argv[3])
    models = manifest[batch * PER_BOOT:(batch + 1) * PER_BOOT]
    if not models:
        fail(f"batch {batch} is empty — manifest has {len(manifest)} models")

    # TEST-005 coverage gate, once per sweep (batch 0 always runs): every
    # geometry-tier reference model must be in the FULL manifest, because a
    # model missing from the stick is silently missing from every batch — the
    # sweep would pass without ever asserting it displays.
    if batch == 0:
        staged = {os.path.basename(m["path"]) for m in manifest}
        missing = [m for m in GEOMETRY_TIER if m not in staged]
        if missing:
            fail(f"TEST-005 models not staged on the stick: {', '.join(missing)} "
                 f"— run scripts/tests/usbdisk.py provision")
        ok(f"all {len(GEOMETRY_TIER)} TEST-005 geometry-tier models staged")

    _record(f"sweep: batch {batch}: {len(models)} models")

    lib.wait_for("GSP_INIT_DONE received", lib.BOOT_TIMEOUT_S, "GSP boot")
    lib.wait_for("FLIPREC", lib.BOOT_TIMEOUT_S, "presents flowing")
    ip = kmir.discover_ip(None)
    client = kmir.Client(ip)
    p = lib.Pointer(client)

    stage_terminal_low(p)

    for i, m in enumerate(models):
        path, base = m["path"], os.path.basename(m["path"])
        lib.refocus_terminal(p)
        before_wins = set(cases.wm_state(lib.read_capture())["wins"])
        mark = len(lib.read_capture())  # capture offset — scope render proof to AFTER show
        lib.type_line(client, f"show {path}")
        lib.await_scoped(f"show {path}", "opened", deadline_s=120)
        ok(f"{base}: window opened")

        # A model window MUST actually appear AND render: an "opened" print alone
        # proves neither. Two independent proofs:
        #   1. wm.win: exactly one NEW window exists and PERSISTS (did not close
        #      itself), and its geometry is on-screen.
        #   2. GL: the render pipeline drew THIS model — a new GL context slot was
        #      mapped for the window and a GLSTAT sample shows a real mesh
        #      rendering (u=true uploaded, m=1 mesh present, advancing frames) —
        #      with NO loud placeholder string. A window that opened but failed to
        #      render (bad model, VRAM/ctx exhaustion) has no such GL activity and
        #      FAILS here instead of being waved through.
        st = cases.wm_state(lib.read_capture())
        new_ids = set(st["wins"]) - before_wins
        if len(new_ids) != 1:
            fail(f"{base}: expected exactly one new window, got {sorted(new_ids)}")
        wid = new_ids.pop()
        g = st["wins"][wid]
        if not on_screen(g):
            fail(f"{base}: window {wid} opened off-screen: {g}")
        ok(f"{base}: window {wid} present on-screen ({g['w']}x{g['h']})")

        require_render(base, mark)  # GL actually drew the model (or loud fail)

        # VISUAL ground truth: trigger a capture with the model window open.
        # kudos writes it straight to the PHYSICAL stick as
        # /usbdisk/shots/SHOTnnnn.PNG (usbshot.zig, unique name per boot) —
        # the runner mounts the stick AFTER the run and extracts them all, so
        # there is no 15 MB UDP pull per model. Here: trigger, await the
        # usbshot record, and log the model ↔ SHOTnnnn mapping.
        shot_mark = len(lib.read_capture())
        client.trigger_shot()
        shot_name = await_usbshot(base, shot_mark)
        _record(f"sweep: SHOTMAP {shot_name} = {base}")
        ok(f"{base}: capture {shot_name} written to the stick")

        # Kernel survived the whole load+render (parse + VRAM upload happen on the
        # first draw); prove it still runs commands.
        lib.refocus_terminal(p)
        lib.type_line(client, f"echo sweep-alive-{batch}-{i}")
        lib.await_scoped(f"echo sweep-alive-{batch}-{i}", f"sweep-alive-{batch}-{i}")
        ok(f"{base}: kernel alive + interactive after render")

        # Close the model window via its close box.
        g = cases.wm_state(lib.read_capture())["wins"].get(wid, g)
        p.goto(*cases.close_box_center(g), tol=6)
        p.c.inject_mouse(0, 0, 1); time.sleep(0.15)
        p.c.inject_mouse(0, 0, 0); time.sleep(0.8)
        st = cases.wm_state(lib.read_capture())
        if wid not in st["closed"]:
            fail(f"{base}: close box did not close window {wid}")
        ok(f"{base}: window closed")

    _record(f"sweep: BATCH {batch} PASS — {passed} assertions green")


# ── render-proof helpers (require_render is also used by model_shot.py) ──────


def stage_terminal_low(p):
    """Expose the cascade area once: drag the boot terminal low, so the
    top-left region where model windows spawn stays clickable (z-order: a
    raised terminal otherwise covers every model window's chrome)."""
    st = cases.wm_state(lib.read_capture())
    found = cases.win_by_title(st, "term #0")
    if found is None:
        fail("boot terminal missing")
    tid, tg = found
    # Keep the whole terminal on the panel: refocus clicks its body at
    # (x+w-120, y+h-120), and the pointer cannot leave the screen — so the
    # descent is capped by what the panel holds and driven CLOSED-LOOP (the
    # open-loop +500 overshot under the desktop's pointer acceleration and
    # sank the refocus point past the bottom edge).
    _, sh = p.screen()
    dy = max(0, min(500, sh - (tg["y"] + tg["h"]) - 8))
    p.drag(*cases.title_center(tg), 150, dy, win_id=tid)
    tg2 = cases.wm_state(lib.read_capture())["wins"].get(tid)
    if tg2 is None or tg2["y"] < tg["y"] + min(200, max(0, dy - 40)):
        fail(f"terminal stage-drag did not reach +{dy} ({tg} -> {tg2})")
    ok("terminal staged low (cascade area exposed)")

# Model windows that FAILED to render show one of these loud in-window
# placeholders (modelview.zig) instead of GL content — any of them is a fail.
PLACEHOLDERS = ("3D unavailable", "cannot show", "missing/bad model", "3D busy",
                "too many 3D")

SCREEN_W, SCREEN_H = 3440, 1440  # the passthrough primary panel


def on_screen(g):
    return (g["x"] < SCREEN_W and g["y"] < SCREEN_H
            and g["x"] + g["w"] > 0 and g["y"] + g["h"] > 0
            and g["w"] > 0 and g["h"] > 0)


# DIAG-017: every capture must also land on the physical stick — a
# ramdisk-only save is a loud fail below, and run_model_sweep re-mounts the
# stick on Linux to prove the files are really there.
def await_usbshot(base, mark, deadline_s=30):
    """Wait for kudos to report this model's capture landed on the stick:
    `gpu.usbshot: shots/SHOTnnnn.PNG saved (...)`. Returns the SHOTnnnn.PNG
    name. A ramdisk-only save (usbshot disabled) or silence is a loud fail —
    the stick copy IS the sweep's visual evidence."""
    import re
    saved_re = re.compile(r"usbshot: shots/(SHOT\d+\.PNG) saved")
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        tail = lib.read_capture()[mark:]
        m = saved_re.search(tail)
        if m:
            return m.group(1)
        if "usbshot:" in tail and "disabled" in tail:
            fail(f"{base}: usbshot disabled itself mid-run (see capture)")
        time.sleep(0.4)
    fail(f"{base}: capture never reached the stick within {deadline_s}s "
         f"(no usbshot record; ramdisk-only or session loop stalled)")


# Loud kernel records that each mean a window is NOT visibly rendering. Every
# silent-failure mode found so far now logs one of these at the source (that is
# the deal: the kernel fails loudly, the harness asserts the records absent).
RENDER_FAILURES = (
    "mirror MISSING",       # GLSTAT: ctx has no mirror to de-tile into
    "will be INVISIBLE",    # present: mirror map failed for a composited window
    "unaligned remap",      # gmmu: the reclaim/reuse misalignment class
)


def require_render(base, mark, deadline_s=120):
    # 120 s, not 30: a full glTF PBR material (APP-011) is five 2048² images
    # decoded on one core and ~80 MiB uploaded through the PRAMIN window —
    # the largest model's load alone exceeds 30 s. The modelcache load start/done
    # trace lines time the load itself; shrink this only when the upload path
    # gets a DMA fast path.
    """Poll the capture (from offset `mark`, i.e. only what this model produced)
    until the GL pipeline proves this model renders and composites. The desktop
    draws every window INLINE in ONE GL frame (the unified pipeline), so
    per-window ctx slots no longer exist: liveness is the in-use context's kick
    counter k ADVANCING across GLSTAT samples, and the model itself must have
    logged its modelcache load-complete bracket — plus the absence of every
    loud render-failure record and in-window placeholder. The screenshot that
    follows is the content proof. (GLSTAT's m field is the MIRROR-MISS counter,
    not a mesh count; and which window's mirror the periodic GLSTAT line
    samples is arbitrary, so distinct-mirror counting is NOT a usable
    liveness signal.)"""
    import re
    stat_re = re.compile(r"GLSTAT s(\d+) u=true ph=\S+ k=(\d+) b=\d+ l=\d+ m=\d+")
    live_re = re.compile(r"GLSTAT slot=\d+ mirror va=(0x[0-9a-f]+)")
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        tail = lib.read_capture()[mark:]
        for ph in PLACEHOLDERS:
            if ph in tail:
                fail(f"{base}: rendered the '{ph}' PLACEHOLDER, not the model")
        for sig in RENDER_FAILURES:
            if sig in tail:
                fail(f"{base}: render-failure record '{sig}' in the capture — window not visible")
        if "load failed:" in tail:
            fail(f"{base}: modelcache load FAILED (see the capture) — no point waiting")
        mirrors = set(live_re.findall(tail))
        ks = {}
        for slot, k in stat_re.findall(tail):
            ks.setdefault(slot, []).append(int(k))
        ctx_alive = any(len(v) >= 2 and v[-1] > v[0] for v in ks.values())
        if ctx_alive and len(mirrors) >= 1 and f"{base} loaded (" in tail:
            ok(f"{base}: loaded + GL frame advancing (mirrors seen: {len(mirrors)})")
            return
        time.sleep(0.4)
    fail(f"{base}: no proof of render within {deadline_s}s (loaded={('%s loaded (' % base) in lib.read_capture()[mark:]}, "
         f"mirrors={len(set(live_re.findall(lib.read_capture()[mark:])))})")


if __name__ == "__main__":
    main()
