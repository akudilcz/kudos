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
        self.seen_rids = []  # last 8, as in fileproto.Dedup
        self.keys = []
        self.mouse = []
        self.shots = 0
        self.shot_lands_at = None

    def _dedup(self, rid):
        if rid in self.seen_rids:
            return True
        self.seen_rids.append(rid)
        del self.seen_rids[:-8]
        return False

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
        if op in (kmir.OP_KEY, kmir.OP_MOUSE, kmir.OP_SHOT):
            if not self._dedup(rid):
                if op == kmir.OP_KEY:
                    self.keys.append(body[0])
                elif op == kmir.OP_MOUSE:
                    self.mouse.append(struct.unpack("<hhB", body[:5]))
                else:
                    self.shots += 1
                    self.shot_lands_at = time.time() + 0.7
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

        # ── SHOT flow: trigger → generation bump → byte-exact download ──────
        old_gen = guest.files["screenshot.png"][1]
        path = c.screenshot(d)
        assert guest.shots == 1, guest.shots
        assert guest.files["screenshot.png"][1] == old_gen + 1
        with open(path, "rb") as f:
            assert f.read() == guest.files["screenshot.png"][0], "screenshot corrupted"

    stop.set()
    t.join(timeout=2)
    print("netdebug lossy-loopback test PASSED (20% drop, 10% dup, 10% reorder; "
          "exactly-once inject + WRITE + SHOT flow)")


if __name__ == "__main__":
    main()
