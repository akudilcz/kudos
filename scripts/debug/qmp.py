#!/usr/bin/env python3
"""Drive QEMU over QMP for headless testing: reliable PS/2 mouse + keyboard
injection and screendumps. The human monitor's mouse_move is flaky; QMP
input-send-event delivers relative events reliably.

Usage:
  scripts/debug/qmp.py CMD [CMD ...]
where each CMD is one of:
  m,DX,DY        relative mouse move (raw deltas, 1:1 with the guest cursor)
  d,BUTTON       button down (left|right|middle)
  u,BUTTON       button up
  k,KEY          tap a key (qcode, e.g. 'a', 'spc', 'ret')
  t,STRING       type an ASCII string (handles shifted symbols)
  s,SECONDS      sleep (float)
  shot,PATH      screendump to a PPM file
"""
import socket, json, sys, time

SOCK = "/tmp/qmp.sock"

# ASCII char -> (qcode, needs_shift), for a US layout. The WHOLE printable set,
# not a subset: a partial table is worse than none, because a missing character is
# dropped and the rest still sent, so the guest runs something subtly different
# from what was asked and the difference surfaces as a result, not an error.
_SYMS = {
    " ": ("spc", False), "\t": ("tab", False), "\n": ("ret", False),
    "`": ("grave_accent", False), "~": ("grave_accent", True),
    "!": ("1", True), "@": ("2", True), "#": ("3", True), "$": ("4", True),
    "%": ("5", True), "^": ("6", True), "&": ("7", True), "*": ("8", True),
    "(": ("9", True), ")": ("0", True),
    "-": ("minus", False), "_": ("minus", True),
    "=": ("equal", False), "+": ("equal", True),
    "[": ("bracket_left", False), "{": ("bracket_left", True),
    "]": ("bracket_right", False), "}": ("bracket_right", True),
    "\\": ("backslash", False), "|": ("backslash", True),
    ";": ("semicolon", False), ":": ("semicolon", True),
    "'": ("apostrophe", False), '"': ("apostrophe", True),
    ",": ("comma", False), "<": ("comma", True),
    ".": ("dot", False), ">": ("dot", True),
    "/": ("slash", False), "?": ("slash", True),
}


def char_qcode(ch):
    """The keystroke that produces `ch`, or (None, False) if there is none."""
    if ch in _SYMS:
        return _SYMS[ch]
    if "a" <= ch <= "z" or "0" <= ch <= "9":
        return (ch, False)
    if "A" <= ch <= "Z":
        return (ch.lower(), True)
    return (None, False)


class QMP:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rw")
        self._read()  # greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        return json.loads(self.f.readline())

    def cmd(self, execute, **args):
        obj = {"execute": execute}
        if args:
            obj["arguments"] = args
        self.f.write(json.dumps(obj) + "\n")
        self.f.flush()
        while True:
            r = self._read()
            if "return" in r or "error" in r:
                return r  # skip async events

    def send_events(self, events):
        self.cmd("input-send-event", events=events)

    def move(self, dx, dy):
        self.send_events([
            {"type": "rel", "data": {"axis": "x", "value": dx}},
            {"type": "rel", "data": {"axis": "y", "value": dy}},
        ])

    def button(self, name, down):
        self.send_events([{"type": "btn", "data": {"button": name, "down": down}}])

    def key(self, qcode):
        self.send_events([{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": qcode}}}])
        self.send_events([{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": qcode}}}])

    def key_shifted(self, qcode, shift):
        def ev(qc, down):
            return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qc}}}
        evs = []
        if shift:
            evs.append(ev("shift", True))
        evs += [ev(qcode, True), ev(qcode, False)]
        if shift:
            evs.append(ev("shift", False))
        self.send_events(evs)

    # QEMU's usb-hid device queues at most 16 input events (8 key presses); events
    # arriving while the queue is full are dropped, and the guest only drains it when
    # its main loop reaches xhci.poll(). Pace keystrokes so a burst never outruns one
    # poll gap: 50 ms/char is still faster than a human types.
    INTER_KEY_S = 0.05

    def type_str(self, s):
        for ch in s:
            qc, shift = char_qcode(ch)
            if qc is None:
                # Loudly, not silently: a dropped character makes the guest run
                # a DIFFERENT command from the one asked for, and the caller
                # then reads the result as though it answered the question.
                raise ValueError(f"no keystroke for character {ch!r} in {s!r}")
            self.key_shifted(qc, shift)
            time.sleep(self.INTER_KEY_S)

    def screendump(self, path):
        self.cmd("screendump", filename=path)


def main(argv):
    q = QMP(SOCK)
    for tok in argv:
        parts = tok.split(",")
        op = parts[0]
        if op == "m":
            q.move(int(parts[1]), int(parts[2]))
        elif op == "d":
            q.button(parts[1], True)
        elif op == "u":
            q.button(parts[1], False)
        elif op == "k":
            q.key(parts[1])
        elif op == "t":
            q.type_str(tok[2:])  # everything after "t,"
        elif op == "s":
            time.sleep(float(parts[1]))
        elif op == "shot":
            q.screendump(parts[1])
            time.sleep(0.3)
        else:
            print("unknown cmd:", tok, file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1:])
