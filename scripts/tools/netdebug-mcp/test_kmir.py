#!/usr/bin/env python3
"""netdebug client reliability test under an injected loss profile: a loopback
fake guest that drops 20% of
datagrams, duplicates 10%, and delays (reorders) 10% — the download must still
complete byte-exact, injections must land EXACTLY once (guest-side request_id
dedup, mirroring fileproto.Dedup), and the async SHOT flow must return the new
screenshot bytes. Run: python3 test_kmir.py"""

import binascii
import os
import random
import socket
import struct
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(__file__))
import kmir  # noqa: E402


class FakeGuest:
    """The guest server's observable behavior, including injection dedup and
    the asynchronous screenshot (SHOT acks, the file lands ~0.7 s later)."""

    def __init__(self):
        self.files = {
            "screenshot.png": [os.urandom(200_000), 7],
            "hello.txt": [b"hello, kudos!", 3],
        }
        self.seen_rids = []  # last 8 (rid, result) pairs, as in fileproto.Dedup
        self.keys = []
        self.mouse = []
        self.shots = 0
        self.shot_lands_at = None
        # A bounded input ring, as the real machine has. `room` is how many more
        # keystrokes it will take before it starts refusing; the real one drains
        # continuously, so a test sets this to model a machine under pressure.
        self.room = 1 << 30
        self.title = "terminal"
        self.focus_asks = 0
        # The trace retention window, seq -> the stamped wire line: what
        # OP_RESEND serves. Seqs 40..49 retained; anything else has expired.
        self.retained = {
            40 + i: f"[{40 + i:06d}] retained line {40 + i}\n".encode() for i in range(10)
        }

    def _dedup(self, rid):
        """The recorded result for `rid` if already dispatched, else None."""
        for r, result in self.seen_rids:
            if r == rid:
                return result
        return None

    def _record(self, rid, result=0):
        self.seen_rids.append((rid, result))
        del self.seen_rids[:-8]

    def _take_key(self, ch):
        if self.room <= 0:
            return False
        self.room -= 1
        self.keys.append(ch)
        return True

    def _tick(self):
        # An armed SHOT lands as a NEW screenshot.png after its delay.
        if self.shot_lands_at is not None and time.time() >= self.shot_lands_at:
            self.files["screenshot.png"][0] = os.urandom(150_000)
            self.files["screenshot.png"][1] += 1
            self.shot_lands_at = None

    def reply(self, req):
        magic, op, _fl, rid = kmir.HDR.unpack_from(req)
        if magic != kmir.MAGIC:
            return None
        body = req[kmir.HDR.size:]
        self._tick()
        if op == kmir.OP_LIST:
            out = struct.pack("<H", len(self.files))
            for name, (data, gen) in self.files.items():
                nb = name.encode()
                out += struct.pack("<H", len(nb)) + nb + struct.pack(
                    "<III", gen, len(data), binascii.crc32(data) & 0xFFFFFFFF)
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_LIST_R, 0, rid) + out
        if op == kmir.OP_READ:
            (nlen,) = struct.unpack_from("<H", body, 0)
            name = body[2:2 + nlen].decode()
            gen, off, ln = struct.unpack_from("<IIH", body, 2 + nlen)
            data, real_gen = self.files[name]
            if gen != real_gen:
                return kmir.HDR.pack(kmir.MAGIC, kmir.OP_ERR, 0, rid) + bytes([kmir.ERR_GENERATION])
            chunk = data[off:off + min(ln, kmir.CHUNK)]
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_READ_R, 0, rid) + struct.pack(
                "<IIH", gen, off, len(chunk)) + chunk
        if op == kmir.OP_WRITE:
            (nlen,) = struct.unpack_from("<H", body, 0)
            name = body[2:2 + nlen].decode()
            data = body[2 + nlen:]
            gen = self.files[name][1] + 1 if name in self.files else 1
            self.files[name] = [data, gen]
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_WRITE_R, 0, rid) + struct.pack("<I", gen)
        if op == kmir.OP_FOCUS:
            # Not deduped: focusing a named window is idempotent, and a caller
            # polling for confirmation must be told where focus is NOW.
            self.focus_asks += 1
            if body:
                self.title = body.decode()
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_FOCUS_R, 0, rid) + self.title.encode()
        if op == kmir.OP_WRITE_AT:
            # Append-only chunked write, the guest's rules exactly: offset 0
            # truncates, offset == len appends, offset+len == len re-ACKs a
            # retransmit, anything else is a desync error.
            (nlen,) = struct.unpack_from("<H", body, 0)
            name = body[2:2 + nlen].decode()
            (off,) = struct.unpack_from("<I", body, 2 + nlen)
            data = body[2 + nlen + 4:]
            cur = self.files.get(name, [b"", 0])[0]
            if off == 0:
                self.files[name] = [data, self.files.get(name, [b"", 0])[1] + 1]
                total = len(data)
            elif off == len(cur):
                self.files[name][0] = cur + data
                total = len(cur) + len(data)
            elif off + len(data) == len(cur):
                total = len(cur)  # the lost-reply retransmit
            else:
                return kmir.HDR.pack(kmir.MAGIC, kmir.OP_ERR, 0, rid) + bytes([kmir.ERR_GENERATION])
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_WRITE_AT_R, 0, rid) + struct.pack("<I", total)
        if op == kmir.OP_RESEND:
            # Not deduped: a pure read of the retained trace, capped guest-side
            # exactly as fileproto.RESEND_MAX_LINES caps the real one.
            from_seq, count = struct.unpack_from("<IB", body, 0)
            out = b""
            for i in range(min(count, kmir.RESEND_MAX_LINES)):
                seq = (from_seq + i) % 1_000_000
                if seq in self.retained:
                    out += self.retained[seq]
            return kmir.HDR.pack(kmir.MAGIC, kmir.OP_RESEND_R, 0, rid) + out
        if op in (kmir.OP_KEY, kmir.OP_TEXT, kmir.OP_MOUSE, kmir.OP_SHOT):
            result = self._dedup(rid)
            if result is None:
                result = 0
                if op == kmir.OP_KEY:
                    # A refused key is NOT recorded and NOT acked, so the retry
                    # of the identical datagram is a fresh attempt.
                    if not self._take_key(body[0]):
                        return kmir.HDR.pack(kmir.MAGIC, kmir.OP_ERR, 0, rid) + bytes([kmir.ERR_BUSY])
                elif op == kmir.OP_TEXT:
                    for i, ch in enumerate(body):
                        if not self._take_key(ch):
                            break
                        result = i + 1
                elif op == kmir.OP_MOUSE:
                    self.mouse.append(struct.unpack("<hhB", body[:5]))
                else:
                    self.shots += 1
                    self.shot_lands_at = time.time() + 0.7
                self._record(rid, result)
            if op == kmir.OP_TEXT:
                return kmir.HDR.pack(kmir.MAGIC, kmir.OP_TEXT_R, 0, rid) + struct.pack("<H", result)
            return kmir.HDR.pack(kmir.MAGIC, op | 0x80, 0, rid)
        return None


def serve(sock, guest, stop):
    rng = random.Random(1234)
    delayed = []
    while not stop.is_set():
        try:
            req, addr = sock.recvfrom(2048)
        except socket.timeout:
            continue
        reply = guest.reply(req)
        if reply is None:
            continue
        # Chaos: drop 20%, duplicate 10%, delay 10% (sent later = reordered).
        r = rng.random()
        if r < 0.20:
            continue
        sock.sendto(reply, addr)
        if r < 0.30:
            sock.sendto(reply, addr)
        if 0.30 <= r < 0.40:
            delayed.append((reply, addr))
        if delayed and rng.random() < 0.5:
            sock.sendto(*delayed.pop(0))


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", 0))
    srv.settimeout(0.05)
    port = srv.getsockname()[1]
    guest = FakeGuest()
    stop = threading.Event()
    t = threading.Thread(target=serve, args=(srv, guest, stop), daemon=True)
    t.start()

    with tempfile.TemporaryDirectory() as d:
        c = kmir.Client("127.0.0.1", port=port)

        # ── injections: exactly-once despite drop/dup/reorder ───────────────
        for ch in b"ls\n":
            c.inject_key(ch)
        assert guest.keys == [0x6C, 0x73, 0x0A], guest.keys
        c.inject_mouse(-200, 35, 0b101)
        c.inject_mouse(10, -5, 0)
        assert guest.mouse == [(-200, 35, 0b101), (10, -5, 0)], guest.mouse

        # ── WRITE: creates then bumps generation ────────────────────────────
        # WRITE is NOT request_id-deduped guest-side (unlike KEY/MOUSE/SHOT), so
        # a duplicated datagram under the lossy channel can bump the generation
        # more than once — assert a bump happened, not an exact +1. The final
        # content is what matters and is deterministic.
        g1 = c.write_file("marker.txt", b"round 1")
        g2 = c.write_file("marker.txt", b"round 2")
        assert g2 > g1, (g1, g2)
        assert guest.files["marker.txt"][0] == b"round 2"

        # ── TEXT: a whole command line, byte-exact, through a machine that
        # keeps running out of room (DIAG-019/DIAG-020) ─────────────────────
        #
        # This is the case one-key-per-datagram got wrong. A dropped byte does
        # not truncate a command, it CHANGES it — "rm -rf /tmp/x" losing its 'x'
        # is a different command that still runs — so the count in the reply
        # exists to make a short delivery impossible to mistake for a complete
        # one, and the client resends from exactly where kudos stopped.
        guest.keys.clear()
        guest.room = 5  # far less than the line: forces several resumptions
        line = "firefox --profile /tmp/p https://en.wikipedia.org/wiki/Main_Page\n"

        def refill():
            # A real desktop drains its ring continuously; this stands in for it.
            while not stop.is_set():
                guest.room = max(guest.room, 5)
                time.sleep(0.005)

        refiller = threading.Thread(target=refill, daemon=True)
        refiller.start()
        typed = c.inject_text(line)
        assert typed == len(line), (typed, len(line))
        assert bytes(guest.keys) == line.encode(), bytes(guest.keys)

        # A single key against a FULL machine is refused, not acked — and the
        # client waits it out rather than reporting a keystroke that never landed.
        guest.room = 0
        c.inject_key(ord("Z"))
        assert guest.keys[-1] == ord("Z"), bytes(guest.keys[-4:])

        # ── FOCUS: name the window instead of clicking it (DIAG-021/022) ────
        assert c.focused_window() == "terminal", c.focused_window()
        assert c.focus_window("linux") == "linux", c.focus_window("linux")
        assert c.focused_window() == "linux"

        # ── SHOT flow: trigger → generation bump → byte-exact download ──────
        old_gen = guest.files["screenshot.png"][1]
        path = c.screenshot(d)
        assert guest.shots == 1, guest.shots
        assert guest.files["screenshot.png"][1] == old_gen + 1
        with open(path, "rb") as f:
            assert f.read() == guest.files["screenshot.png"][0], "screenshot corrupted"

        # ── WRITE_AT: a multi-chunk push lands byte-exact, exactly once, through
        # the same 20%-drop channel — the offset check is what makes a
        # retransmitted chunk safe (DIAG-025) ────────────────────────────────
        big = os.urandom(5 * kmir.CHUNK + 137)
        c.write_file("cube.kudos", big)
        assert guest.files["cube.kudos"][0] == big, "chunked write corrupted the file"

        # ── RESEND: gap recovery through the same chaotic channel (DIAG-023) ─
        # The retained window serves lines back verbatim; a request straddling
        # the retention edge yields exactly the lines that still exist, so a
        # permanent loss is countable rather than retried forever.
        text = c.resend(41, 3)
        assert text == ("[000041] retained line 41\n[000042] retained line 42\n"
                        "[000043] retained line 43\n"), repr(text)
        edge = c.resend(38, 4)  # 38,39 expired; 40,41 retained
        assert "[000040]" in edge and "[000041]" in edge and "[000038]" not in edge, repr(edge)
        # Greedy asks are capped at the datagram-shaped maximum, never an error.
        capped = c.resend(40, 200)
        assert capped.count("\n") == kmir.RESEND_MAX_LINES, repr(capped)

    stop.set()
    t.join(timeout=2)
    print("netdebug lossy-loopback test PASSED (20% drop, 10% dup, 10% reorder; "
          "exactly-once inject + flow-controlled TEXT + FOCUS + WRITE + SHOT + RESEND)")


if __name__ == "__main__":
    main()
