"""KMR1-backed input injector — the native tracks' replacement for QMP.

The integration phases (boot1_emulated.py) drive kudos through a small object: they
call q.type_str / q.key / q.move / q.button and nothing else. Under QEMU that object
is a QMP socket into the emulator. On real hardware there IS no emulator to ask, so
this presents THE SAME FOUR METHODS over KMR1 (UDP :9515), and the phases run
unchanged against lemon.

That is the whole point of keeping the surface identical: the case table and the
assertions are shared between emulated and native, so a regression cannot pass on one
track while silently breaking on the other.

Two mappings are worth knowing, because they are the only places the transports
genuinely differ:

  - ARROWS ARE NOT NAMED KEYS. kudos carries Up/Down as ASCII control bytes
    (keyboard.KEY_UP = 0x10), so they inject as plain characters. Only F10/F11/F12
    have no character at all, and OP_KEY's second byte carries those.
  - BUTTONS ARE A MASK, NOT EVENTS. QMP sends down/up events; KMR1's OP_MOUSE takes a
    button bitmask alongside the motion. We hold the mask here and re-send it, so a
    press-move-release drag arrives as kudos expects.
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "netdebug-mcp"))
import kmir  # noqa: E402

# QMP qcode -> what KMR1 must send. (ascii, named)
QCODE = {
    "ret": (ord("\n"), kmir.KEY_NONE),
    "spc": (ord(" "), kmir.KEY_NONE),
    "up": (kmir.KEY_UP_ASCII, kmir.KEY_NONE),
    "down": (kmir.KEY_DOWN_ASCII, kmir.KEY_NONE),
    "f1": (0, kmir.KEY_F1),
    "f10": (0, kmir.KEY_F10),
    "f11": (0, kmir.KEY_F11),
    "f12": (0, kmir.KEY_F12),
}

BUTTON_BIT = {"left": 0x01, "right": 0x02, "middle": 0x04}


class Kmr1Input:
    """QMP-shaped injector over KMR1. Same four methods the phases call."""

    def __init__(self, ip):
        self.c = kmir.Client(ip)
        self.buttons = 0  # held-button mask; every motion carries it
        # ACCUMULATE RELATIVE MOTION INTO AN ABSOLUTE POSITION, and send absolute.
        #
        # This is exactly what QEMU does internally: the phases send relative deltas, QEMU
        # tracks a position and hands its usb-tablet ABSOLUTE coordinates — which bypass
        # kudos's pointer-acceleration curve (imouse.zig: "irrelevant for abs events").
        # Send those same deltas as RELATIVE motion to real hardware and the curve
        # amplifies them: the suite's title drag overshot and pinned the cursor to the
        # screen edge (x=0 y=767), moving the window to the corner. Doing the accumulation
        # here makes the native pointer behave identically to the emulated one, which is
        # the whole contract of this class.
        self.x, self.y = 0, 0
        self.home()

    def home(self):
        """Drive the cursor into the top-left corner, so relative motion is deterministic.

        THE TRACKS DISAGREE ABOUT WHERE THE POINTER STARTS. QEMU accumulates the harness's
        relative motion into an absolute position of its own, which begins at the origin —
        so the emulated phases can compute a drag as a series of deltas and know exactly
        where they land. lemon's pointer is a real relative mouse whose cursor sits
        wherever it was left, so the same deltas landed the dragged window at x=0,y=748.
        Slamming the cursor against the corner (the compositor clamps it) gives the native
        track the same known origin the emulated one gets for free.
        """
        self.x, self.y = 0, 0
        self.c.inject_mouse_abs(0, 0, self.buttons)
        time.sleep(0.2)

    # fileserv's RX slot is ONE DEEP: a request arriving while another is unserviced is
    # dropped (the host retransmits). That is fine at rest, but kudos's service loop can
    # be busy for a long stretch — `prime 5000` pegs the core — and a burst of keystrokes
    # fired as fast as the wire allows then leans entirely on retransmits landing inside
    # a window that may not come. Pace them: a keystroke every INTER_KEY_S is still far
    # faster than a human types, and it keeps the slot free between presses. Matches
    # qmp.py's INTER_KEY_S so both injection paths stress the kernel identically.
    INTER_KEY_S = 0.05

    def type_str(self, s):
        for ch in s:
            self.c.inject_key(ord(ch))
            time.sleep(self.INTER_KEY_S)

    def key(self, qcode):
        if qcode not in QCODE:
            raise KeyError(f"kmr1_input: no mapping for qcode {qcode!r} — add it to QCODE")
        ascii_byte, named = QCODE[qcode]
        self.c.inject_key(ascii_byte, named)
        time.sleep(self.INTER_KEY_S)

    def move(self, dx, dy):
        # The phases speak deltas; kudos is told the resulting POSITION (see __init__).
        # Clamped to a generous screen box so a deliberate over-move (the phases use them
        # to drive the cursor to an edge) still lands at the edge rather than wrapping the
        # i16 on the wire.
        self.x = max(0, min(32000, self.x + dx))
        self.y = max(0, min(32000, self.y + dy))
        self.c.inject_mouse_abs(self.x, self.y, self.buttons)

    def button(self, name, down):
        bit = BUTTON_BIT[name]
        self.buttons = (self.buttons | bit) if down else (self.buttons & ~bit)
        # Press/release AT THE CURRENT POSITION: a press that also moved the cursor would
        # grab the wrong thing.
        self.c.inject_mouse_abs(self.x, self.y, self.buttons)
