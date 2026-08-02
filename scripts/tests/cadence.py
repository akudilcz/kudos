"""Frame-cadence verdict checks — the ONE home for reading a `-Dflip-sample`
FLIPSTAT verdict out of a netdebug capture and judging it.

Shared by the passthrough driver (boot2_passthrough.py) and the native driver
(boot1_native.py) so both tracks judge "smooth 60 Hz" by IDENTICAL rules. The
kernel (present.zig) records a window of inter-present intervals and emits one
greppable `FLIPSTAT verdict=…` line; flip_stats.zig (host-tested) is the source
of truth for the verdict itself. This module only parses and thresholds that
line — it holds no cadence policy the kernel does not already own.
"""

import re

# The kernel logs this exactly once, on the first whole-desktop GPU present
# (present.zig, `st.presents == 0`). kudos is GPU-only, so this line IS "the
# desktop is shown" — the anchor the from-first-present window is measured from.
FIRST_PRESENT_ANCHOR = "GPU DESKTOP active — first whole-frame flip"

# A full from-first-present window is 600 frames (~10 s at 60 Hz) — the kernel's
# FLIP_SAMPLE_FRAMES. A verdict with fewer samples means the window was cut short
# and its "no dropped frame" claim does not yet cover the whole 10 s.
MIN_WINDOW_FRAMES = 600


def field(line, name):
    """Pull one `name=<int>` field out of a FLIPSTAT verdict line, or None."""
    m = re.search(rf"\b{name}=(\d+)", line)
    return int(m.group(1)) if m else None


def verdict_count(text):
    """How many FLIPSTAT verdicts the capture holds so far (poll for a new one)."""
    return len(re.findall(r"FLIPSTAT verdict=", text))


def latest_verdict(text):
    """The most recent FLIPSTAT verdict line, or "" if none yet. The verdict
    leads the record (present.zig), so netdebug's 120-B line cap can only ever
    truncate the stats tail, never the `verdict=PASS/FAIL` token itself."""
    lines = [ln for ln in text.splitlines() if "FLIPSTAT verdict=" in ln]
    return lines[-1] if lines else ""


def judge_window(line):
    """Judge one window's verdict line. Returns (ok, detail).

    ok is True only when the window is a full 10 s (n >= MIN_WINDOW_FRAMES), no
    inter-present interval exceeded one refresh + the jitter budget (steady == 1
    — not a single missed vblank), and the kernel's overall verdict PASSes. The
    detail string is the trimmed verdict line, suitable for an ok()/fail() message.
    """
    if not line:
        return False, "no FLIPSTAT verdict"
    verdict = line[line.find("FLIPSTAT"):].strip()
    n = field(line, "n")
    steady = field(line, "steady")
    if n is None or n < MIN_WINDOW_FRAMES:
        return False, f"window shorter than 10 s (n={n}): {verdict!r}"
    if steady != 1:
        return False, f"a frame was dropped (steady=0): {verdict!r}"
    if "verdict=PASS" not in line:
        return False, f"verdict not PASS: {verdict!r}"
    return True, verdict
