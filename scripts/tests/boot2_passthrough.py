#!/usr/bin/env python3
"""Boot-2 integration driver — the real-4090 passthrough track (GPU + desktop).

Assumes run_passthrough.sh has already built the -Dtest-hooks -Dflip-sample ISO,
started passthrough.sh (booting the 4090), and is capturing the netdebug UDP:9514
stream to a log file (argv[1]). Drives kudos over the KMR1 RPC channel (UDP:9515,
kmir.Client) and asserts against that capture. Phases:

  1. GPU BRING-UP — GSP-RM boots (GSP_INIT_DONE), presents flow (FLIPREC
     heartbeats), no Xid fault.
  2. SMOOTH FROM THE FIRST PRESENT — kudos is GPU-only, so "the desktop is shown"
     is the first GPU present; from that instant the -Dflip-sample window (anchored
     at the first present, 600 frames = 10 s) must report steady=1 — NOT ONE dropped
     frame in the first 10 s — and PASS. Then the boot milestones (bootmark.py):
     the kernel's boot-to-first-present verdict must say PASS (PERF-002) and the
     lease must have come from the async BACKGROUND bind, never the blocking
     one (PERF-014).
  3. EVERY COMMAND — all passthrough/both cases from cases.py (same table and
     assertion helpers as boot 1), typed over KMR1 keystroke injection.
  4. GRAPHICS LOAD + PARSE + RENDER — five model windows opened at once
     (ramdisk duck + teapot, and the rabbit loaded OFF THE USB DISK), each
     confirmed via the terminal mirror + wm.win records.
  5. 60 Hz UNDER LOAD — `flipstat` re-arms the cadence sample while the five
     GL windows spin; the fresh FLIPSTAT verdict must be PASS. This is the
     flagship rendering-performance regression.
  6. WM UNDER GPU — the full control matrix on the composited desktop: drag
     (terminal + model window), click-to-focus, maximise/exact-restore, grip
     resize (the app re-lays-out its GL viewport live), close box (wm.closed +
     count down). Then the present loop is proven alive by pulling a full-res
     CRC-verified screenshot artifact off the ramdisk.
  7. STRESS THRASH — try to break it: (SMP) extra terminals pinned to APs run
     `prime` in parallel while the desktop composites and the models spin, with
     a fresh FLIPSTAT verdict demanded DURING the grind; a keyboard+mouse event
     flood that must drain without wedging (the trailing echo survives); rapid
     open/maximise/restore/close chaos cycles with exact wm.nwins bookkeeping;
     a final sweep that no wedge report or spin-budget overrun fired; and the
     PERF-008 gate — the cumulative input->present latency counters must show
     ZERO presents where injected input took longer than one frame to appear.

Fails LOUD on the first missing assertion. Results mirror to
build/logs/boot2-result.log so the verdict survives stdout quirks AND host power-cycles.
"""

import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts", "tools", "netdebug-mcp"))  # kmir
sys.path.insert(0, HERE)  # cases

import kmir  # noqa: E402
import cases  # noqa: E402
import cadence  # noqa: E402  — the shared FLIPSTAT verdict home (native uses it too)
import bootmark  # noqa: E402  — the shared PERF-002/PERF-014 boot-milestone home
import aa_metric  # noqa: E402  — the DSK-009 anti-aliasing metric (host-tested separately)

RESULT_LOG = os.path.join(ROOT, "build", "logs", "boot2-result.log")
SHOT_DIR = os.path.join(ROOT, "build", "logs", "shots")
os.makedirs(os.path.join(ROOT, "build", "logs"), exist_ok=True)

BOOT_TIMEOUT_S = 360      # covers passthrough.sh's ISO build + vfio bind + GSP-RM bring-up
FLIPSTAT_TIMEOUT_S = 90   # warmup (seeds) + 600 frames ≈ 10 s at 60 Hz + generous margin

# KUDOS_SMP=1 (set by run_passthrough.sh --smp) boots the multi-core kernel: assert the
# AP bring-up trace and pull in the SMP-track cases. The 60 Hz idle + under-load cadence
# phases (2 and 5) are unchanged — running them here IS the multi-core cadence signal.
SMP = os.environ.get("KUDOS_SMP") == "1"

# The five simultaneously-spinning models (phase 4/5): ramdisk + USB-disk paths.
FIVE_MODELS = [
    # APP-008: several 3D models shown at once, one window each, composited
    # live on the GPU. (Alpha blending is judged by the render-oracle suite
    # against Khronos' AlphaBlendModeTest reference — none of these five models
    # is blended, so this run is not evidence for it and no longer claims to be.)
    "show duck.glb",
    "show teapot.glb",
    "show /usbdisk/models/rabbit.glb",
    "show duck.glb",
    "show teapot.glb",
]

passed = 0
capture_path = None


def _record(line):
    print(line, flush=True)
    try:
        with open(RESULT_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def read_capture():
    try:
        with open(capture_path, "r", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def fail(msg, grep=None):
    _record(f"boot2: FAIL — {msg}")
    if grep:
        for ln in read_capture().splitlines():
            if grep in ln:
                _record("   " + ln)
    _record(f"boot2: {passed} assertions passed before the failure")
    sys.exit(1)


def ok(what):
    global passed
    passed += 1
    _record(f"boot2:   OK  {what}")


def wait_for(substring, timeout_s, what):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if substring in read_capture():
            return
        time.sleep(0.5)
    fail(f"timed out after {timeout_s:.0f}s waiting for {what} ({substring!r})")


def type_line(client, text):
    for ch in text:
        b = ord(ch)
        if b > 0x7F:
            fail(f"non-ASCII char {ch!r} in command {text!r}")
        client.inject_key(b)
        time.sleep(0.02)
    client.inject_key(ord("\r"))
    time.sleep(1.2)  # settle: mirror lines arrive over netdebug within a frame


def scoped_mirror(cmd):
    mirror = cases.mirror_text(read_capture(), core=0)
    idx = mirror.rfind(f"$ {cmd}")
    if idx == -1:
        return None
    nl = mirror.find("\n", idx)
    return mirror[nl + 1:] if nl != -1 else ""


def run_case(client, case, deadline_s=25):
    """Type the command, then POLL until every expected substring appears in its
    scoped output (or fail at the deadline). No fixed settle sleeps: a command
    that computes quietly (rt spins ~0.5 s with nothing emitted) must not be
    asserted early — silence is not completion."""
    type_line(client, case.cmd)
    deadline = time.time() + deadline_s
    last_err = None
    while time.time() < deadline:
        scoped = scoped_mirror(case.cmd)
        if scoped is not None:
            try:
                cases.assert_case(case, scoped)
                last_err = None
                break
            except cases.CaseFailure as e:
                last_err = e  # output still streaming — keep polling
        time.sleep(0.2)
    else:
        if last_err is not None:
            fail(str(last_err), grep="term.0 = ")
        fail(f"command {case.cmd!r} was never echoed to the mirror", grep="term.0")
    global passed
    passed += len(case.expects)
    _record(f"boot2:   OK  {case.cmd!r} ({len(case.expects)} assertions)")


_INPUT_LATENCY_RE = re.compile(r"dbg: gpu\.input_present_(max_us|over_budget) = (\d+)")


def input_latency_counters():
    """Latest cumulative PERF-008 counters from the capture: the worst
    receipt->present latency any input saw (max_us) and how many presents showed
    input later than one frame (over_budget). Counters re-emit on every change
    and on a stats dump; the last occurrence of each is the current value."""
    vals = {}
    for m in _INPUT_LATENCY_RE.finditer(read_capture()):
        vals[m.group(1)] = int(m.group(2))
    return vals


def flipstat_count():
    return cadence.verdict_count(read_capture())


def latest_flipstat():
    return cadence.latest_verdict(read_capture())


def phase1():
    # PLAT-001: bring-up is gated in-kernel on the RTX 4090's PCI identity
    # (10de:2684) — GSP_INIT_DONE cannot arrive from any other device.
    _record("boot2: PHASE 1 — GPU bring-up")
    wait_for("GSP_INIT_DONE received", BOOT_TIMEOUT_S, "GSP-RM boot")
    ok("GSP-RM booted (GSP_INIT_DONE)")
    wait_for("FLIPREC", BOOT_TIMEOUT_S, "presents flowing (FLIPREC)")
    ok("desktop presents flowing (FLIPREC heartbeat)")
    if "Xid" in read_capture():
        fail("GPU Xid fault during bring-up", grep="Xid")
    ok("no Xid fault")
    if SMP:
        # Prove the APs came online before we trust the cadence phases on multi-core.
        # `smp: N usable cores discovered` (smp.zig) with N >= 2; `smp/diag: core-0
        # tasks spawned` shows the SMP scheduler path ran, not the cooperative loop.
        blob = read_capture()
        m = re.search(r"smp: (\d+) usable cores discovered", blob)
        if not m or int(m.group(1)) < 2:
            fail("SMP kernel did not discover >= 2 usable cores "
                 f"({m.group(0) if m else 'no trace'})", grep="smp:")
        ok(f"SMP topology discovered ({m.group(1)} usable cores)")
        if "smp/diag: core-0 tasks spawned" not in blob:
            fail("SMP kernel: BSP never reached the SMP scheduler path", grep="smp/diag")
        ok("SMP scheduler path ran on the BSP")


_flipstat_field = cadence.field  # the shared parser (phase 5/7 read raw fields)


def phase2():
    # SMOOTH FROM THE FIRST PRESENT. kudos is GPU-only: "the desktop is shown" is
    # the first GPU present, and from that instant it must hold 60 Hz with NO
    # dropped frame. The -Dflip-sample build now anchors its window at the first
    # present (warmup = the cold-start seeds only) and records 10 s (600 frames);
    # the verdict's `steady=1` means no inter-present interval exceeded one refresh
    # + the jitter budget — i.e. not a single missed vblank in that 10 s.
    _record("boot2: PHASE 2 — 10 s smooth from the first GPU present (no dropped frame)")
    # The first present must actually have happened (the anchor).
    deadline = time.time() + FLIPSTAT_TIMEOUT_S
    while time.time() < deadline and cadence.FIRST_PRESENT_ANCHOR not in read_capture():
        time.sleep(1)
    if cadence.FIRST_PRESENT_ANCHOR not in read_capture():
        fail("no first GPU present — the desktop never reached the panel", grep="gpu.present")
    ok("first GPU present reached the panel (desktop shown)")
    # Then the 10 s from-first-present verdict, judged by the shared rules.
    while time.time() < deadline and flipstat_count() < 1:
        time.sleep(1)
    good, detail = cadence.judge_window(latest_flipstat())
    if not good:
        fail(f"10 s from the first present: {detail}", grep="FLIPSTAT")
    ok(f"10 s smooth from the first present — no dropped frame ({detail})")


def phase_boot_milestones():
    """PERF-002 + PERF-014, judged from the capture by the shared bootmark
    rules. Runs after phase 2: the FLIPSTAT verdict phase 2 waited on is
    emitted long after gpu.zig's boot-to-first-present line, so that line is
    already in the capture (or never will be) — no extra wait. The DHCP lease
    lands in the background a beat later, so its record IS polled, with a
    stated budget."""
    _record("boot2: PHASE 2b — boot milestones (PERF-002 budget, PERF-014 bind path)")
    good, detail = bootmark.judge_boot_to_first_present(read_capture())
    if not good:
        fail(f"PERF-002: {detail}", grep="boot-to-first-present")
    ok(f"desktop within the boot budget ({detail}) [PERF-002]")

    deadline = time.time() + bootmark.DHCP_BOUND_TIMEOUT_S
    while time.time() < deadline and bootmark.DHCP_BOUND not in read_capture():
        time.sleep(1)
    good, detail = bootmark.judge_network_off_critical_path(read_capture())
    if not good:
        fail(f"PERF-014: {detail} (waited {bootmark.DHCP_BOUND_TIMEOUT_S}s for the bind)",
             grep="dhcp:")
    ok(f"networking off the boot critical path ({detail}) [PERF-014]")


def phase3(client):
    selected = cases.cases_for("passthrough", smp=SMP)
    total = cases.count_assertions("passthrough", smp=SMP)
    _record(f"boot2: PHASE 3 — {len(selected)} commands / {total} assertions")
    for case in selected:
        run_case(client, case)


def hud_toggle(client):
    """HUD-003: F1 draws the heads-up display ABOVE the desktop and windows and
    leaves window state untouched. This is the GPU track, so the HUD really
    paints between the two presses (render.zig draws it after the windows and
    the dock); the wm mirror must not move a window, the focus, or a pixel of
    geometry across show + hide."""
    before = cases.wm_state(read_capture())
    client.inject_key(0, kmir.KEY_F1)
    time.sleep(0.8)
    on = cases.wm_state(read_capture())
    if (on["nwins"], on["focus"], on["wins"]) != (before["nwins"], before["focus"], before["wins"]):
        fail(f"F1 (HUD) disturbed window state: {before} -> {on}")
    client.inject_key(0, kmir.KEY_F1)
    time.sleep(0.8)
    off = cases.wm_state(read_capture())
    if (off["nwins"], off["focus"], off["wins"]) != (before["nwins"], before["focus"], before["wins"]):
        fail(f"HUD hide disturbed window state: {before} -> {off}")
    ok("F1 HUD shown and hidden over the live desktop; window state untouched (HUD-003)")


def refocus_terminal(p):
    """Click the boot terminal's body so typed commands reach its shell again —
    `show` FOCUSES the new model window (by design), and keystrokes follow
    focus, so typing after a `show` without refocusing goes to a window with no
    shell and silently vanishes (exactly how the first phase-4 run failed)."""
    st = cases.wm_state(read_capture())
    found = cases.win_by_title(st, "term #0")
    if found is None:
        fail("boot terminal missing from wm state — cannot refocus")
    tid, g = found
    # Right-bottom body quadrant: cascaded model windows spawn top-left and
    # never reach here; stays clear of the resize bands + the grip corner.
    p.goto(g["x"] + g["w"] - 120, g["y"] + g["h"] - 120)
    p.c.inject_mouse(0, 0, 1)
    time.sleep(0.15)
    p.c.inject_mouse(0, 0, 0)
    time.sleep(0.4)
    st = cases.wm_state(read_capture())
    if st["focus"] is None or st["focus"][0] != tid:
        fail(f"terminal refocus click did not take (focus={st['focus']})")


def await_scoped(cmd, needle, deadline_s=25):
    """Poll until `needle` appears in cmd's scoped mirror output — no fixed
    sleeps (model parse + VRAM upload land on the first draw, whose timing
    varies with GL load)."""
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        scoped = scoped_mirror(cmd)
        if scoped is not None and needle in scoped:
            return
        time.sleep(0.3)
    fail(f"{cmd!r}: {needle!r} never appeared in its output", grep="term.0 = ")


def phase4(client, p):
    _record("boot2: PHASE 4 — load + parse + render five models at once")
    st = cases.wm_state(read_capture())
    base_n = st["nwins"]
    if base_n is None:
        fail("no wm.nwins record — WM state mirror missing?")
    for i, cmd in enumerate(FIVE_MODELS):
        type_line(client, cmd)
        await_scoped(cmd, "opened")
        ok(f"model window {i + 1} opened ({cmd.split()[1]})")
        refocus_terminal(p)  # `show` focused the model window; take focus back
    st = cases.wm_state(read_capture())
    if st["nwins"] != base_n + len(FIVE_MODELS):
        fail(f"expected {base_n + len(FIVE_MODELS)} windows, wm.nwins={st['nwins']}")
    ok(f"all {len(FIVE_MODELS)} model windows live (wm.nwins={st['nwins']})")
    if "Xid" in read_capture():
        fail("Xid fault while opening model windows", grep="Xid")
    ok("no Xid fault with five GL windows up")

    # RENDER PROOF (the 'opened' print alone waved invisible windows through —
    # the mirror reclaim/reuse bug): the whole desktop is ONE GL context (every
    # window, 2D and 3D, draws inline into the one whole-desktop frame), so the
    # proof is that context rendering LIVE with all five models in the scene —
    # its frame counter advancing at the panel rate, its mirror mapped, its
    # pixels not blank — and no loud render-failure record. Per-window liveness
    # is proven separately: phase 6 drags/maximises the models (wm.win moves
    # under real clicks) and the screenshot captures their pixels.
    import re
    stat_re = re.compile(r"GLSTAT s0 u=true ph=\S+ k=(\d+)")
    mirror_re = re.compile(r"GLSTAT slot=0 mirror va=0x[0-9a-f]+ stride=\d+ origin=0x([0-9a-f]+) mid=0x([0-9a-f]+)")
    deadline = time.time() + 30
    proven = False
    while time.time() < deadline and not proven:
        tail = read_capture()[-200_000:]
        for sig in ("mirror MISSING", "will be INVISIBLE", "unaligned remap"):
            if sig in tail:
                fail(f"render-failure record '{sig}' with five models up", grep=sig)
        ks = [int(k) for k in stat_re.findall(tail)]
        mirrors = mirror_re.findall(tail)
        # Advancing k across dumps + a mapped mirror whose sampled pixels are
        # not both blank (all-zero would mean the de-tile never landed).
        proven = (len(ks) >= 2 and ks[-1] > ks[0]
                  and any(int(o, 16) or int(m, 16) for o, m in mirrors[-3:]))
        if not proven:
            time.sleep(1)
    if not proven:
        fail("the whole-desktop GL context is not rendering live with five models up "
             f"(k samples {len(stat_re.findall(read_capture()))}, advancing mirror pixels absent)")
    ok("whole-desktop GL context rendering live with five models inline "
       "(k advancing, mirror mapped, pixels present)")


def phase5(client):
    _record("boot2: PHASE 5 — 60 Hz under load (five spinning models)")
    before = flipstat_count()
    type_line(client, "flipstat")
    await_scoped("flipstat", "sampling re-armed")
    ok("`flipstat` re-armed the cadence sample")
    deadline = time.time() + FLIPSTAT_TIMEOUT_S
    while time.time() < deadline and flipstat_count() <= before:
        time.sleep(1)
    if flipstat_count() <= before:
        fail("no fresh FLIPSTAT verdict after the re-arm", grep="FLIPREC")
    line = latest_flipstat()
    if "verdict=PASS" not in line:
        fail(f"60 Hz UNDER LOAD failed: {line[line.find('FLIPSTAT'):].strip()!r}",
             grep="FLIPSTAT")
    ok(f"five spinning models hold 60 Hz ({line[line.find('FLIPSTAT'):].strip()})")


class Pointer:
    """Closed-loop KMR1 pointer driver — same design as boot 1's (QMP) pointer:
    pointer ACCELERATION is burst-length-dependent, so every burst re-measures
    the actual/commanded factor via a harmless right-click probe (wm.ptr records
    on button edges, read from the netdebug capture) and adapts."""

    CHUNK = 32
    PACE_S = 0.03

    def __init__(self, client):
        self.c = client
        self.x = 0
        self.y = 0
        self.scale = 1.0
        self.pin()

    def pin(self):
        for _ in range(3):
            self.c.inject_mouse(-4000, -4000, 0)
            time.sleep(0.05)
        self.x, self.y = 0, 0

    def _burst(self, dx, dy):
        steps = max(1, (max(abs(dx), abs(dy)) + self.CHUNK - 1) // self.CHUNK)
        for i in range(steps):
            sx = dx * (i + 1) // steps - dx * i // steps
            sy = dy * (i + 1) // steps - dy * i // steps
            self.c.inject_mouse(sx, sy, 0)
            time.sleep(self.PACE_S)

    def probe(self):
        self.c.inject_mouse(0, 0, 2)   # right press — no WM action binds it
        time.sleep(0.15)
        self.c.inject_mouse(0, 0, 0)   # release
        time.sleep(0.6)
        st = cases.wm_state(read_capture())
        if st["ptr"] is None:
            fail("no wm.ptr record after a probe click — pointer hook missing?")
        self.x, self.y = st["ptr"][0], st["ptr"][1]
        return self.x, self.y

    def goto(self, tx, ty, tol=8):
        # 60 attempts: the acceleration re-estimation can stall a few px short
        # near the target for several rounds before the scale settles, and a
        # catapulted overshoot (below) needs the walk back.
        for _ in range(60):
            dx, dy = tx - self.x, ty - self.y
            if abs(dx) <= tol and abs(dy) <= tol:
                return
            cmd_x = int(dx / self.scale) or (1 if dx > 0 else -1)
            cmd_y = int(dy / self.scale) or (1 if dy > 0 else -1)
            # Never overdrive past 2x the remaining distance: the desktop
            # accelerates large deltas SUPER-linearly, so a low scale estimate
            # turns a short approach into a catapult across the screen (a 13 px
            # approach measured 95 -> 3439) and the walk back burns the budget.
            if abs(cmd_x) > 2 * abs(dx):
                cmd_x = 2 * dx
            if abs(cmd_y) > 2 * abs(dy):
                cmd_y = 2 * dy
            bx, by = self.x, self.y
            self._burst(cmd_x, cmd_y)
            self.probe()
            commanded = (cmd_x * cmd_x + cmd_y * cmd_y) ** 0.5
            actual = ((self.x - bx) ** 2 + (self.y - by) ** 2) ** 0.5
            if commanded > 0 and actual / commanded > 0.05:
                self.scale = min(8.0, max(0.2, 0.5 * self.scale + 0.5 * actual / commanded))
        fail(f"pointer never converged on ({tx},{ty}) (at {self.x},{self.y})")

    def click(self, tx, ty):
        """Left-click at desktop coordinates (tx, ty): converge, press, release."""
        self.goto(tx, ty)
        self.c.inject_mouse(0, 0, 1)
        time.sleep(0.15)
        self.c.inject_mouse(0, 0, 0)
        time.sleep(0.6)

    def screen(self):
        """(w, h) of the desktop the pointer moves on — the MONITOR's mode, from
        the kernel's own present record. The pointer clamps at the panel edge,
        so a target computed below it is unreachable by construction; ask the
        machine instead of assuming a height."""
        m = None
        for line in read_capture().splitlines():
            mm = re.search(r"primary monitor (\d+)x(\d+)", line)
            if mm:
                m = mm
        if m is None:
            fail("no 'primary monitor WxH' record in the capture — cannot size the screen")
        return int(m.group(1)), int(m.group(2))

    def drag(self, fx, fy, dx, dy, win_id=None, tol=12):
        """Press at (fx,fy) and drag by (dx,dy). With win_id given the drag is
        CLOSED-LOOP: mid-drag there are no button edges for wm.ptr probes, but
        the dragged window's own wm.win records update live — exact ground
        truth for how far the pointer really moved, so the desktop's pointer
        acceleration is corrected while the button is still held. The open
        loop overshoots by the acceleration factor (an open +500 sank the
        terminal's title past the panel's bottom edge)."""
        self.goto(fx, fy)
        start = cases.wm_state(read_capture())["wins"].get(win_id) if win_id is not None else None
        self.c.inject_mouse(0, 0, 1)   # press (starts the drag on a title bar)
        time.sleep(0.2)
        if start is None:
            self._burst_held(int(dx / self.scale), int(dy / self.scale))
        else:
            tx, ty = start["x"] + dx, start["y"] + dy
            for _ in range(10):
                g = cases.wm_state(read_capture())["wins"].get(win_id)
                if g is None:
                    break
                rx, ry = tx - g["x"], ty - g["y"]
                if abs(rx) <= tol and abs(ry) <= tol:
                    break
                bx, by = g["x"], g["y"]
                self._burst_held(int(rx / self.scale) or (1 if rx > 0 else -1),
                                 int(ry / self.scale) or (1 if ry > 0 else -1))
                time.sleep(0.5)
                g2 = cases.wm_state(read_capture())["wins"].get(win_id)
                if g2 is not None:
                    moved = ((g2["x"] - bx) ** 2 + (g2["y"] - by) ** 2) ** 0.5
                    commanded = max(1.0, (rx * rx + ry * ry) ** 0.5 / self.scale)
                    if moved / commanded > 0.05:
                        self.scale = min(8.0, max(0.2, 0.5 * self.scale + 0.5 * moved / commanded))
        self.c.inject_mouse(0, 0, 0)   # release
        time.sleep(0.8)

    def _burst_held(self, dx, dy):
        steps = max(1, (max(abs(dx), abs(dy)) + self.CHUNK - 1) // self.CHUNK)
        for i in range(steps):
            sx = dx * (i + 1) // steps - dx * i // steps
            sy = dy * (i + 1) // steps - dy * i // steps
            self.c.inject_mouse(sx, sy, 1)  # button held throughout
            time.sleep(self.PACE_S)


def aa_conformance(shot_path, term_g):
    """Spec DSK-009 — window chrome is anti-aliased. The focused terminal's three
    traffic-light discs are curved, high-contrast chrome edges. On a single-sample
    rasteriser their rims are hard (aa_score ~0); the GPU's 8x MSAA fills them with
    partial-coverage pixels (a real 4090 disc measures ~0.36). Measure the discs and
    require the AA floor — a hard rim means MSAA is not reaching the chrome.

    Soft-skips (loudly) only if Pillow is absent, so a box without the image library
    still runs the rest of boot-2 rather than failing on the tooling."""
    try:
        from PIL import Image
    except ImportError:
        _record("boot2: DSK-009 AA conformance SKIPPED — Pillow (PIL) not installed")
        return
    img = Image.open(shot_path).convert("RGB")
    r = cases.TL_R
    best = None
    measured = 0
    for cx, cy in cases.disc_centers(term_g):
        crop = aa_metric.luminance_crop(img, cx - r - 3, cy - r - 3, 2 * (r + 3), 2 * (r + 3))
        score, info = aa_metric.edge_aa_score(crop)
        if score is None:  # no high-contrast edge here (disc unfocused/occluded)
            continue
        measured += 1
        if best is None or score > best[0]:
            best = (score, info, (cx, cy))
    if best is None:
        fail("DSK-009 AA: no high-contrast traffic-light edge in the capture "
             f"(terminal at {term_g['x']},{term_g['y']} — occluded or off-screen?)")
    score, info, (cx, cy) = best
    if score < aa_metric.AA_MIN_SCORE:
        fail(f"DSK-009 AA: chrome edge at ({cx},{cy}) scored {score:.3f}, under the "
             f"{aa_metric.AA_MIN_SCORE} floor — the disc rim is hard (MSAA off?): "
             f"span={info[2]:.0f} hard_jumps={info[3]} intermediate={info[4]}")
    ok(f"DSK-009: window chrome anti-aliased (disc-rim aa_score={score:.2f} "
       f">= {aa_metric.AA_MIN_SCORE}; {measured}/3 discs high-contrast)")


def phase6(client, p):
    _record("boot2: PHASE 6 — WM under GPU compositing + screenshot")
    st = cases.wm_state(read_capture())
    if not st["wins"]:
        fail("no windows in wm state at phase 6")

    # 6a. Drag the TERMINAL — it is topmost (phase 4's refocus raised it), its
    # glass body composites OVER the spinning GL windows (the heaviest blend
    # path), and moving it down EXPOSES the model cascade it fully covers —
    # without this, no model window has a single clickable pixel (z-order).
    found = cases.win_by_title(st, "term #0")
    if found is None:
        fail("boot terminal missing at phase 6")
    tid, tg = found
    # Screen-capped and closed-loop for the same reason as the sweep's staging
    # drag: an open +500 overshoots under pointer acceleration, and the
    # refocus point must stay reachable on the panel.
    _, sh = p.screen()
    dy = max(0, min(500, sh - (tg["y"] + tg["h"]) - 8))
    p.drag(*cases.title_center(tg), 150, dy, win_id=tid)
    tg2 = cases.wm_state(read_capture())["wins"].get(tid)
    if tg2 is None or tg2["y"] < tg["y"] + min(200, max(0, dy - 40)):
        fail(f"terminal drag did not reach +{dy} ({tg} -> {tg2})")
    ok(f"glass terminal dragged over live GL windows (+{tg2['x'] - tg['x']},+{tg2['y'] - tg['y']})")

    # 6b. Drag the newest model window — its title bar is now exposed.
    wid = max(cases.wm_state(read_capture())["wins"])
    g = cases.wm_state(read_capture())["wins"][wid]
    p.drag(*cases.title_center(g), 300, 150)
    g2 = cases.wm_state(read_capture())["wins"].get(wid)
    if g2 is None or (g2["x"] == g["x"] and g2["y"] == g["y"]):
        fail(f"drag did not move window {wid} ({g} -> {g2})")
    ok(f"GL model window dragged under GPU compositing "
       f"(+{g2['x'] - g['x']},+{g2['y'] - g['y']})")

    # 6c. Click-to-focus: the model window's body click must focus + raise it
    # (the terminal was topmost until now — this proves the click reached the
    # model window through the compositor's real z-order, not a stale one).
    p.click(*cases.body_center(g2))
    st = cases.wm_state(read_capture())
    if st["focus"] is None or st["focus"][0] != wid:
        fail(f"model body click did not focus it (focus={st['focus']})")
    ok("click-to-focus: model window body click focused it")

    # 6d. Maximise box fills from the origin; a second click restores the EXACT
    # pre-max geometry. A maximised GL window is the heaviest single-window
    # render (full-screen 3D viewport) — the present loop must ride through it.
    p.click(*cases.max_box_center(g2))
    g3 = cases.wm_state(read_capture())["wins"].get(wid)
    if g3 is None or not g3["max"] or g3["x"] != 0 or g3["y"] != 0 \
            or g3["w"] <= g2["w"] or g3["h"] <= g2["h"]:
        fail(f"maximise box did not maximise ({g2} -> {g3})")
    ok(f"maximise filled the screen with a live GL viewport ({g3['w']}x{g3['h']})")
    p.click(*cases.max_box_center(g3))
    g4 = cases.wm_state(read_capture())["wins"].get(wid)
    if g4 is None or g4["max"] \
            or (g4["x"], g4["y"], g4["w"], g4["h"]) != (g2["x"], g2["y"], g2["w"], g2["h"]):
        fail(f"restore did not return the exact geometry ({g2} -> {g4})")
    ok("second maximise click restored the exact pre-max geometry")

    # 6e. Grip resize: park near the origin first so the grip has room to grow
    # on any panel, then drag the bottom-right grip. The app's onResize re-lays
    # the GL viewport live — growth well past jitter proves the resize really
    # reached the window, not just the pointer.
    if g4["x"] > 60 or g4["y"] > 60:
        p.drag(*cases.title_center(g4), 40 - g4["x"], 40 - g4["y"])
        g4 = cases.wm_state(read_capture())["wins"].get(wid) or g4
    p.drag(*cases.grip_center(g4), 90, 70)
    g5 = cases.wm_state(read_capture())["wins"].get(wid)
    if g5 is None or g5["w"] <= g4["w"] + 40 or g5["h"] <= g4["h"] + 30:
        fail(f"grip resize did not grow the window ({g4} -> {g5})")
    ok(f"grip resize grew the GL window (+{g5['w'] - g4['w']},+{g5['h'] - g4['h']})")

    # 6f. Close box: the window closes for real — wm.closed emitted, count back
    # down, and its GL resources retire without an Xid fault.
    n_before = cases.wm_state(read_capture())["nwins"]
    p.click(*cases.close_box_center(g5))
    st = cases.wm_state(read_capture())
    if st["nwins"] != n_before - 1 or wid not in st["closed"]:
        fail(f"close box did not close the window (nwins {n_before} -> {st['nwins']})")
    ok("close box closed the GL window (wm.closed emitted)")

    # 6g. Focus the boot terminal so its traffic lights render full-colour (a firm,
    # high-contrast edge) and its title bar is on top — the DSK-009 AA target below
    # is measured from this same capture.
    found = cases.win_by_title(cases.wm_state(read_capture()), "term #0")
    if found is None:
        fail("boot terminal missing before the screenshot/AA check")
    aa_id, aa_g = found
    p.click(*cases.title_center(aa_g))
    aa_g = cases.wm_state(read_capture())["wins"].get(aa_id, aa_g)

    # Screenshot artifact: serviced by the same session loop that composites —
    # a fresh CRC-verified capture proves the loop stayed alive through all of it.
    try:
        path = client.screenshot(SHOT_DIR)
    except kmir.KmirError as e:
        fail(f"screenshot failed — session loop stalled? {e}")
    ok(f"screenshot artifact saved: {path}")

    # DSK-009: prove the chrome the GPU just composited is anti-aliased.
    aa_conformance(path, aa_g)
    # PERF-013: the pull's measured rate (window-pipelined KMR1 reads). The rig
    # baseline is 15 MiB/s with 0 retransmits; the floor is half that, so load
    # jitter passes while a collapse to per-slot retries (~1 MiB/s) fails loudly.
    lp = getattr(client, "last_pull", None)
    if lp:
        ok(f"screenshot transfer: {lp['bytes']} B in {lp['seconds']:.2f}s = "
           f"{lp['mib_s']:.1f} MiB/s ({lp['retransmits']} retransmits) [PERF-013]")
        if lp["mib_s"] < 7.5:
            fail(f"screenshot transfer {lp['mib_s']:.1f} MiB/s is under the "
                 f"PERF-013 floor (7.5 MiB/s; baseline 15)")
    # R65: the capture itself (CE copy + composite, before encode) is under 1 s.
    m = re.search(r"screenshot\.png saved .*capture_ms=(\d+)", read_capture())
    if not m:
        fail("no capture_ms in the screenshot trace line (old image?)")
    if int(m.group(1)) >= 1000:
        fail(f"screenshot capture took {m.group(1)} ms (R65 budget: < 1000 ms)")
    ok(f"screenshot capture under budget ({m.group(1)} ms)")
    if "Xid" in read_capture():
        fail("Xid fault by end of run", grep="Xid")
    ok("no Xid fault through the whole run")


def phase7(client, p):
    _record("boot2: PHASE 7 — stress thrash: parallel primes, event flood, chaos cycles")
    st = cases.wm_state(read_capture())
    found = cases.win_by_title(st, "term #0")
    if found is None:
        fail("boot terminal missing at phase 7")
    term_id = found[0]

    def focus_terminal():
        g = cases.wm_state(read_capture())["wins"].get(term_id)
        if g is None:
            fail("boot terminal vanished during the thrash")
        p.click(*cases.body_center(g))

    # 7a. (SMP) Parallel primes: spawn two terminals — each pins to its own AP —
    # and set both grinding at once. Core 0 keeps compositing throughout; each
    # prime's completion arrives on its OWN core's terminal mirror.
    grinding = False
    if SMP:
        for _ in range(2):
            # `term` must come from the IDLE core-0 shell each time — the
            # previous AP terminal is already grinding and consumes nothing.
            focus_terminal()
            type_line(client, "term")  # the new terminal spawns focused, on its own AP
            time.sleep(0.5)
            type_line(client, "prime 500000")  # grinds that AP; echo returns when done
        grinding = True
        ok("two AP-pinned terminals set grinding primes in parallel")

    # 7b. 60 Hz while the machine is busiest: models spinning, (SMP) primes
    # grinding on the APs. The verdict must be PASS — rendering never yields
    # its frame budget to compute load.
    focus_terminal()
    before = flipstat_count()
    type_line(client, "flipstat")
    await_scoped("flipstat", "sampling re-armed")
    deadline = time.time() + FLIPSTAT_TIMEOUT_S
    while time.time() < deadline and flipstat_count() <= before:
        time.sleep(1)
    if flipstat_count() <= before:
        fail("no FLIPSTAT verdict during the thrash", grep="FLIPREC")
    line = latest_flipstat()
    if "verdict=PASS" not in line:
        fail(f"60 Hz UNDER THRASH failed: {line[line.find('FLIPSTAT'):].strip()!r}",
             grep="FLIPSTAT")
    ok(f"60 Hz held under thrash ({line[line.find('FLIPSTAT'):].strip()})")

    if grinding:
        # Both primes announce on their own cores' mirrors (term.<core> records,
        # core != 0) — proof the work really ran cross-core, not serialized.
        deadline = time.time() + 90
        done = set()
        while time.time() < deadline and len(done) < 2:
            for core in range(1, 8):
                if core not in done and "prime: found" in cases.mirror_text(read_capture(), core=core):
                    done.add(core)
            time.sleep(1)
        if len(done) < 2:
            fail(f"parallel primes did not complete on two APs (done on cores {sorted(done)})",
                 grep="prime")
        ok(f"primes completed in parallel on cores {sorted(done)}")

    # 7c. Event-queue flood: a keystroke storm interleaved with pointer motion.
    # Every queue must absorb or coalesce — no wedge, no lost trailing input.
    # The garbage line commits with Enter (the shell must still parse), then a
    # clean echo proves the input path end-to-end after the storm.
    focus_terminal()
    for i in range(60):
        client.inject_key(ord("a") + (i % 26))
        if i % 4 == 0:
            client.inject_mouse(7 if (i % 8) else -7, 5 if (i % 16) else -5, 0)
        time.sleep(0.01)
    client.inject_key(ord("\r"))
    time.sleep(1.5)
    run_case(client, cases.Case("echo flood-ok", ("flood-ok",), "both"))
    ok("event flood drained; input path echoes cleanly after the storm")

    # 7d. Chaos cycles: open a spinning model, maximise it mid-spin (heaviest
    # single-window render), restore, close — three times, fast. The window
    # count must come back exactly; sloppy teardown shows up here as drift.
    n0 = cases.wm_state(read_capture())["nwins"]
    for i in range(3):
        focus_terminal()
        type_line(client, "show teapot.glb")
        time.sleep(1.5)
        st2 = cases.wm_state(read_capture())
        wid = max(st2["wins"])
        if wid == term_id:
            fail(f"chaos cycle {i}: model window never appeared")
        g = st2["wins"][wid]
        p.click(*cases.max_box_center(g))
        g2 = cases.wm_state(read_capture())["wins"].get(wid)
        if g2 is None or not g2["max"]:
            fail(f"chaos cycle {i}: maximise mid-spin did not take ({g} -> {g2})")
        p.click(*cases.max_box_center(g2))
        g3 = cases.wm_state(read_capture())["wins"].get(wid)
        if g3 is None or g3["max"]:
            fail(f"chaos cycle {i}: restore did not take ({g2} -> {g3})")
        p.click(*cases.close_box_center(g3))
        st3 = cases.wm_state(read_capture())
        if wid in st3["wins"] or wid not in st3["closed"]:
            fail(f"chaos cycle {i}: close box did not close window {wid}")
    nend = cases.wm_state(read_capture())["nwins"]
    if nend != n0:
        fail(f"chaos cycles leaked windows (nwins {n0} -> {nend})")
    ok("3 open/maximise/restore/close chaos cycles; wm.nwins bookkeeping exact")

    # 7e. The diagnostics stayed quiet: no core went dark long enough for the
    # deadman to fire and no bounded spin overran its budget — through ALL of it.
    blob = read_capture()
    if "wedge:" in blob:
        fail("a wedge report fired during the thrash", grep="wedge:")
    if "spin_exceeded" in blob:
        fail("a spin-budget overrun fired during the thrash", grep="spin_exceeded")
    ok("diagnostics quiet through the thrash (no wedge, no spin overrun)")
    # Fresh screenshot: the session loop that composites also serves this — one
    # more CRC-verified capture proves it rode out the whole phase.
    try:
        path = client.screenshot(SHOT_DIR)
    except kmir.KmirError as e:
        fail(f"post-thrash screenshot failed — session loop stalled? {e}")
    ok(f"post-thrash screenshot artifact saved: {path}")
    if "Xid" in read_capture():
        fail("Xid fault during the thrash", grep="Xid")
    ok("no Xid fault through the thrash")

    # 7f. PERF-008 — input on screen within one frame, for EVERY input this run
    # injected (typed commands, drags, the 7c flood). The kernel latches each
    # event's receipt TSC at sampling and judges it at the present that shows it;
    # the counters are cumulative, so one read here gates the whole run. A single
    # over-budget present is a FAIL — the requirement is per-event, not average.
    client.dump_stats()
    deadline = time.time() + 10
    lat = input_latency_counters()
    while time.time() < deadline and "over_budget" not in lat:
        time.sleep(0.5)
        lat = input_latency_counters()
    if "over_budget" not in lat:
        fail("stats dump has no gpu.input_present_over_budget counter", grep="input_present")
    if lat["over_budget"] > 0:
        fail(f"PERF-008: {lat['over_budget']} present(s) showed input later than "
             f"one frame (worst {lat.get('max_us', '?')} us)", grep="input_present")
    ok(f"PERF-008: all input on screen within one frame "
       f"(worst receipt->present {lat.get('max_us', 0)} us)")


def main():
    global capture_path
    if len(sys.argv) < 2:
        print("usage: boot2_passthrough.py <netdebug-capture-log>", file=sys.stderr)
        sys.exit(2)
    capture_path = sys.argv[1]
    try:
        open(RESULT_LOG, "w").close()
    except OSError:
        pass

    phase1()
    phase2()
    phase_boot_milestones()
    ip = kmir.discover_ip(None)
    _record(f"boot2: kudos guest at {ip}, driving over KMR1 :9515")
    client = kmir.Client(ip)
    phase3(client)
    hud_toggle(client)
    p = Pointer(client)  # shared closed-loop pointer: phase-4 refocusing + phase-6 drag
    phase4(client, p)
    phase5(client)
    phase6(client, p)
    phase7(client, p)
    _record(f"boot2: PASS — {passed} assertions green")


if __name__ == "__main__":
    main()
