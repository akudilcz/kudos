#!/usr/bin/env python3
"""Pack a rootfs tree as a reproducible gzipped newc cpio initramfs.

Runs as a plain user: every entry is emitted owned root:root with mtime 0 and
the walk order is sorted, so the same tree packs to the same bytes on any
machine with no root, fakeroot or cpio involved. A device node cannot exist in
an unprivileged build tree, so the one node early userspace needs before
devtmpfs is mounted — /dev/console, character 5:1 — is synthesized into the
archive (skipped if the tree somehow carries its own).

Usage: pack_initramfs.py <rootfs-dir> <out.cpio.gz>
"""

import gzip
import os
import stat
import sys

NEWC_MAGIC = b"070701"
# Linux devices.txt: /dev/console is char major 5, minor 1.
CONSOLE_MAJOR = 5
CONSOLE_MINOR = 1
# cpio archives end 512-byte-block aligned; the kernel does not require it but
# archive tools expect it.
BLOCK = 512


def align4(buf: bytearray) -> None:
    buf.extend(b"\0" * (-len(buf) % 4))


def emit(buf: bytearray, name: str, ino: int, mode: int,
         rmajor: int, rminor: int, data: bytes) -> None:
    """Append one newc entry: 6-byte magic, thirteen 8-digit hex fields
    (inode, mode, uid, gid, nlink, mtime, filesize, dev major/minor,
    rdev major/minor, name size, checksum), NUL-terminated name, data;
    name and data each padded to 4 bytes."""
    fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0,
              rmajor, rminor, len(name) + 1, 0]
    buf.extend(NEWC_MAGIC + b"".join(b"%08X" % f for f in fields))
    buf.extend(name.encode() + b"\0")
    align4(buf)
    buf.extend(data)
    align4(buf)


def pack(rootfs: str, out_path: str) -> None:
    names: list[str] = []
    for parent, dirs, files in os.walk(rootfs):
        dirs.sort()
        rel = os.path.relpath(parent, rootfs)
        for n in sorted(dirs + files):
            names.append(n if rel == "." else f"{rel}/{n}")
    if "dev/console" not in names:
        names.append("dev/console")
    names.sort()  # lexicographic order lists every directory before its entries

    buf = bytearray()
    for ino, name in enumerate(names, start=1):
        if name == "dev/console":
            emit(buf, name, ino, stat.S_IFCHR | 0o600,
                 CONSOLE_MAJOR, CONSOLE_MINOR, b"")
            continue
        path = os.path.join(rootfs, name)
        st = os.lstat(path)
        mode = stat.S_IFMT(st.st_mode) | stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            data = os.readlink(path).encode()
        elif stat.S_ISREG(st.st_mode):
            with open(path, "rb") as f:
                data = f.read()
        elif stat.S_ISDIR(st.st_mode):
            data = b""
        else:
            raise SystemExit(f"pack_initramfs: unpackable file type: {name}")
        emit(buf, name, ino, mode, 0, 0, data)

    emit(buf, "TRAILER!!!", 0, 0, 0, 0, b"")
    buf.extend(b"\0" * (-len(buf) % BLOCK))

    # mtime=0 keeps the gzip container as reproducible as its contents.
    with open(out_path, "wb") as f:
        with gzip.GzipFile(fileobj=f, mode="wb", compresslevel=9, mtime=0) as gz:
            gz.write(bytes(buf))


def main() -> None:
    if len(sys.argv) != 3 or not os.path.isdir(sys.argv[1]):
        raise SystemExit(__doc__.strip().splitlines()[-1])
    pack(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
