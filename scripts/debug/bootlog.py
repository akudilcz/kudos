#!/usr/bin/env python3
"""Seed and read the kudos boot-log ring on the USB stick (/usbdisk/bootlog.txt).

kudos writes its trace stream to a FIXED-SIZE pre-existing file on the stick,
in place (it never creates or grows the file — that would need FAT metadata
writes it deliberately avoids). This host tool owns both ends the kernel can't:

  seed  <mountpoint> [MiB]   create bootlog.txt at a fixed size (default 8 MiB),
                            header initialised so the first boot starts a fresh
                            ring. Run once (or to reset the history).
  read  <mountpoint>        de-ring the file: print the boot log in chronological
                            order (oldest first), following the header cursor.
  pull                      the same, but read the stick DIRECTLY with mtools —
                            no mountpoint, no mount at all. `make bootlog`.
                            --last  print only the most recent boot.

WHY `pull` EXISTS. `read` needs the stick MOUNTED, and mounting it is exactly what
makes QEMU's usb-host passthrough fail with EBUSY — so the one tool for reading the
flight recorder could not be used on the machine that produces it without breaking the
next run. `pull` reads the FAT directly (mtools, over ssh to lemon by default), which
is the same trick scripts/tests/usbdisk.py uses. It needs nothing mounted and nothing
stopped.

Layout (src/drivers/storage/bootlog.zig):
  bytes [0,512)  header  "KUDOSLOG v1 seq=<n> cursor=<n>"  (space-padded, \\n-term)
  bytes [512,N)  body ring — kudos appends at `cursor`, wrapping at the end and
                 bumping `seq`. So the chronological order is:
                 [cursor..end) (older, from before the last wrap) then [0..cursor).
"""

import os
import re
import subprocess
import sys

HEADER = 512
MAGIC = b"KUDOSLOG"


def seed(mount, mib):
    path = os.path.join(mount, "bootlog.txt")
    size = mib * 1024 * 1024
    hdr = b"%s v1 seq=0 cursor=0\n" % MAGIC
    hdr = hdr + b" " * (HEADER - len(hdr) - 1) + b"\n"
    with open(path, "wb") as f:
        f.write(hdr)
        # Fill the body with newlines so a partially-written ring reads cleanly.
        f.write(b"\n" * (size - HEADER))
    os.sync()
    print(f"seeded {path}: {mib} MiB ring, fresh header")


def read(mount):
    path = os.path.join(mount, "bootlog.txt")
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(MAGIC):
        sys.exit(f"{path}: not a kudos boot-log (bad magic) — seed it first")
    hdr = data[:HEADER]
    m = re.search(rb"cursor=(\d+)", hdr)
    seq = re.search(rb"seq=(\d+)", hdr)
    cursor = int(m.group(1)) if m else 0
    body = data[HEADER:]
    # Chronological de-ring: everything after the cursor is older (pre-wrap),
    # then everything up to the cursor. If seq==0 the ring never wrapped, so the
    # pre-cursor part is the whole log and the post-cursor part is empty fill.
    older = body[cursor:] if (seq and int(seq.group(1)) > 0) else b""
    newer = body[:cursor]
    out = (older + newer).rstrip(b"\n")
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.write(b"\n")
    sys.stderr.write(f"\n[bootlog: seq={seq.group(1).decode() if seq else '?'} "
                     f"cursor={cursor} of {len(body)} body bytes]\n")


def _deringed(data, path="bootlog.txt"):
    """Chronological bytes from a raw ring image."""
    if not data.startswith(MAGIC):
        sys.exit(f"{path}: not a kudos boot-log (bad magic) — seed it first")
    hdr = data[:HEADER]
    m = re.search(rb"cursor=(\d+)", hdr)
    seq = re.search(rb"seq=(\d+)", hdr)
    cursor = int(m.group(1)) if m else 0
    wrapped = bool(seq) and int(seq.group(1)) > 0
    body = data[HEADER:]
    older = body[cursor:] if wrapped else b""
    out = (older + body[:cursor]).rstrip(b"\n")
    return out, (seq.group(1).decode() if seq else "?"), cursor, len(body)


def pull(only_last=False):
    """Read the ring straight off the stick with mtools — nothing mounted."""
    host = os.environ.get("USBDISK_HOST", "lemon")
    dev = os.environ.get("USBDISK_DEV", "/dev/disk/by-label/KUDOSUSB")
    cmd = ["sudo", "-n", "env", "MTOOLS_SKIP_CHECK=1", "mtype", "-i", dev, "::bootlog.txt"]
    if host:
        cmd = ["ssh", "-o", "BatchMode=yes", host] + cmd
    r = subprocess.run(cmd, capture_output=True, check=False)
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"bootlog: cannot read the stick"
                 + (f" on {host}" if host else "")
                 + f": {r.stderr.decode(errors='replace').strip()}")

    out, seq, cursor, body_len = _deringed(r.stdout)

    if only_last:
        # Each boot opens with `===== kudos boot #N (log seq M) =====`.
        marks = [m.start() for m in re.finditer(rb"^===== kudos boot #", out, re.M)]
        if marks:
            out = out[marks[-1]:]

    sys.stdout.buffer.write(out)
    sys.stdout.buffer.write(b"\n")
    # Flush stdout BEFORE the summary. stderr is unbuffered and stdout is block-buffered
    # when piped, so without this the footer overtakes the log it is a footer for.
    sys.stdout.flush()
    boots = len(re.findall(rb"^===== kudos boot #", out, re.M))
    sys.stderr.write(f"\n[bootlog: seq={seq} cursor={cursor} of {body_len} body bytes; "
                     f"{boots} boot(s){' — showing the last one' if only_last else ''}]\n")


def main(argv):
    if len(argv) >= 2 and argv[1] == "pull":
        pull(only_last="--last" in argv)
        return
    if len(argv) < 3 or argv[1] not in ("seed", "read"):
        sys.exit(__doc__)
    if argv[1] == "seed":
        seed(argv[2], int(argv[3]) if len(argv) > 3 else 8)
    else:
        read(argv[2])


if __name__ == "__main__":
    main(sys.argv)
