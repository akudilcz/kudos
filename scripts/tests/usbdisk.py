#!/usr/bin/env python3
"""The USB stick is a TEST FIXTURE. Pin it, verify it, provision it.

    scripts/tests/usbdisk.py verify      # does the stick match the manifest?
    scripts/tests/usbdisk.py provision   # make it match

WHY THIS EXISTS. cases.py asserts against the stick's contents — `ls /usbdisk`
expects `hello.txt  (36 bytes)`, `models/`, `scenes/`; `cat /usbdisk/hello.txt`
expects an exact line. Nothing in the repo defined those contents and nothing
checked them, so the suite was asserting against whatever happened to be on a
physical device sitting in another machine. Drift there surfaces as a kernel bug
three minutes into a boot — or, worse, as a PASS for the wrong reason.

The stick lives permanently in lemon, so this reaches it over ssh and reads the
FAT **directly with mtools — never mounting it**. Mounting is what makes QEMU's
usb-host passthrough fail with EBUSY, and a verify step that breaks the run it is
guarding would be worse than no verify step.

Two classes of content, and the difference matters:

  FIXED    — content is pinned by sha256 and sourced from the repo. These are what
             the assertions read. If one drifts, the suite is lying.
  PRESENT  — the KERNEL writes these (the boot-log ring, screenshots). Only their
             existence/size is checked; pinning their bytes would fail on every
             boot, which is the fastest way to teach someone to ignore a check.
"""

import hashlib
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Where the stick is. It is always in lemon; set USBDISK_HOST= (empty) to drive a
# stick plugged into the machine running this script.
HOST = os.environ.get("USBDISK_HOST", "lemon")
DEV = os.environ.get("USBDISK_DEV", "/dev/disk/by-label/KUDOSUSB")

# FIXED: stick path -> (repo source, sha256 of that source).
# The hash is pinned HERE as well as derivable from the file, on purpose: it locks
# the stick AND the repo source to each other, so a corrupted source cannot quietly
# "verify" a corrupted stick.
FIXED = {
    "hello.txt": (
        "test/ui/assets/fixtures/usbdisk/hello.txt",
        "75a3cd4119d0e6a3e15bb4213c9a61b52005516a393a4ccf4039b7247a4040c1",
    ),
    # A deliberately faulting app (scripts/agent/samples/crashy.zig, compiled by
    # the factory) so a live shell can `run` it: AGT-009 is about the fault being
    # CONTAINED, which only a real module execution can show.
    "crashy.kudos": (
        "test/ui/assets/fixtures/usbdisk/crashy.kudos",
        "ba41cbbb4d7ac39b7cb3b8671ed38e1a6dab54a092673a96c200d2eb3cf6864a",
    ),
    # A PNG the desktop can adopt as its background (DSK-003): the requirement is
    # about choosing a picture FROM THE STICK, so the fixture has to live here.
    "pic.png": (
        "assets/media/background.png",
        "c69f6f669e7f539f9148dc249a802501f0d4c017ae582bf7da7954057329f304",
    ),
    "models/rabbit.glb": (
        "assets/models/rabbit.glb",
        "3baf1cb4ac38d1f884ace72b05fcbdc61b46057b3cbd456b57b824ba86839fce",
    ),
    "models/teapot.glb": (
        "src/ui/assets/teapot.glb",
        "75fc8dee3324d5b446cceacb9a487cbb648d72f62bf4edb37ba18323d47df0af",
    ),
    # The geometry-and-texture-tier Khronos reference models (spec TEST-005):
    # the model sweep asserts each of the six loads AND renders on target, so
    # each is pinned here — a model missing from the stick would otherwise
    # surface as a sweep failure three minutes into a rigged boot. The three
    # .gltf entries are the glTF-Embedded container (JSON, data-URI buffer);
    # the kernel's `show` loads both forms (modelcache.isModel).
    "models/Triangle.gltf": (
        "assets/models/Triangle.gltf",
        "6bf10f2d1e07643cbda968fc6941929d52d4dfd4250182c852103668997f706a",
    ),
    "models/TriangleWithoutIndices.gltf": (
        "assets/models/TriangleWithoutIndices.gltf",
        "ee329910d99e32017cc8462eb880a42496b3c2ea56692e7b7ee613af331d631d",
    ),
    "models/SimpleMeshes.gltf": (
        "assets/models/SimpleMeshes.gltf",
        "021cef90f29927aa7881daeff6acc84465bfb715dd1c9e4ab6f051bbe4b35828",
    ),
    "models/Box.glb": (
        "assets/models/Box.glb",
        "ed52f7192b8311d700ac0ce80644e3852cd01537e4d62241b9acba023da3d54e",
    ),
    "models/BoxInterleaved.glb": (
        "assets/models/BoxInterleaved.glb",
        "b2ae631f118f1d13f829cdf9d9dc0fe7cb582de20b8c51d17f81f77a1cbf290c",
    ),
    "models/BoxTextured.glb": (
        "assets/models/BoxTextured.glb",
        "b510eca2e2ef33f62f9ed57d6e7ce2d10ebb2bdebc4a8e59d347719ba81abdf4",
    ),
}

# Directories that must exist. `scenes/` is empty and stays empty — but `ls /usbdisk`
# asserts it, so its absence is a real failure, not a cosmetic one.
#
# Compared CASE-INSENSITIVELY, because FAT is: the kernel creates `shots/` with a
# bare 8.3 name and no long-filename entry, so it reads back as `SHOTS`. A
# case-sensitive check here reported a perfectly healthy stick as broken and would
# have had us "provision" over it.
DIRS = ["models", "scenes", "shots"]

# PRESENT: the kernel owns these bytes. Name -> expected size (None = any).
BOOTLOG_BYTES = 8 * 1024 * 1024
PRESENT = {"bootlog.txt": BOOTLOG_BYTES}


def _mtools(args, capture=True):
    """Run one mtools command against the stick, over ssh when it is remote."""
    cmd = ["sudo", "-n", "env", "MTOOLS_SKIP_CHECK=1"] + args
    if HOST:
        cmd = ["ssh", "-o", "BatchMode=yes", HOST] + [_q(c) for c in cmd]
    return subprocess.run(cmd, capture_output=capture, check=False)


def _q(s):
    return s if all(c.isalnum() or c in "/._-:=" for c in s) else "'" + s.replace("'", "'\\''") + "'"


def _listing():
    """The whole tree as {path: size}, read straight out of the FAT."""
    r = _mtools(["mdir", "-i", DEV, "-b", "-/", "::/"])
    if r.returncode != 0:
        die(f"cannot read the stick at {DEV}"
            + (f" on {HOST}" if HOST else "")
            + f"\n  mtools said: {r.stderr.decode(errors='replace').strip()}")
    out = {}
    for line in r.stdout.decode(errors="replace").splitlines():
        line = line.strip()
        if not line.startswith("::/"):
            continue
        out[line[3:].rstrip("/")] = None
    return out


def _size(path):
    r = _mtools(["mdir", "-i", DEV, f"::/{path}"])
    if r.returncode != 0:
        return None
    # mdir prints the file's own entry; take the size column.
    base = os.path.basename(path)
    stem = base.rsplit(".", 1)[0].upper()[:8]
    for line in r.stdout.decode(errors="replace").splitlines():
        if line.upper().startswith(stem):
            parts = line.split()
            for p in parts[1:]:
                if p.isdigit():
                    return int(p)
    return None


def _sha_on_stick(path):
    r = _mtools(["mtype", "-i", DEV, f"::{path}"])
    if r.returncode != 0:
        return None
    return hashlib.sha256(r.stdout).hexdigest()


def die(msg):
    print(f"usbdisk: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def verify():
    where = f"{HOST}:{DEV}" if HOST else DEV
    print(f"usbdisk: verifying {where} against the manifest")
    tree = _listing()
    problems = []

    lower = {p.lower() for p in tree}
    for d in DIRS:
        if d.lower() not in lower:
            problems.append(f"missing directory  {d}/")

    for path, (src, want) in FIXED.items():
        local = os.path.join(ROOT, src)
        if not os.path.exists(local):
            problems.append(f"repo source missing: {src}")
            continue
        with open(local, "rb") as fh:
            got_src = hashlib.sha256(fh.read()).hexdigest()
        if got_src != want:
            problems.append(
                f"REPO SOURCE changed: {src}\n"
                f"      pinned {want[:16]}…  actual {got_src[:16]}…\n"
                f"      (if this change is intended, update FIXED[] in this file)")
            continue
        got = _sha_on_stick(path)
        if got is None:
            problems.append(f"missing on stick   {path}")
        elif got != want:
            problems.append(f"CONTENT DIFFERS    {path}\n"
                            f"      want {want[:16]}…  got {got[:16]}…")

    for path, want_size in PRESENT.items():
        size = _size(path)
        if size is None:
            problems.append(f"missing on stick   {path} (kernel-written; "
                            f"seed it: scripts/debug/bootlog.py seed <mount>)")
        elif want_size is not None and size != want_size:
            problems.append(f"WRONG SIZE         {path}: want {want_size} B, got {size} B\n"
                            f"      the boot-log ring is a FIXED-SIZE file the kernel writes "
                            f"in place;\n      re-seed it: scripts/debug/bootlog.py seed <mount>")

    if problems:
        print("usbdisk: the stick does NOT match the manifest:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print("\n  The integration suites assert against these contents. Fix with:\n"
              "      make usbdisk-provision\n", file=sys.stderr)
        sys.exit(1)

    n = len(FIXED) + len(PRESENT) + len(DIRS)
    print(f"usbdisk: OK — {n} manifest entries match ({len(FIXED)} content-pinned)")


def provision():
    where = f"{HOST}:{DEV}" if HOST else DEV
    print(f"usbdisk: provisioning {where} to match the manifest")

    for d in DIRS:
        _mtools(["mmd", "-i", DEV, f"::/{d}"])  # already-exists is fine

    for path, (src, want) in FIXED.items():
        local = os.path.join(ROOT, src)
        with open(local, "rb") as fh:
            got = hashlib.sha256(fh.read()).hexdigest()
        if got != want:
            die(f"repo source {src} does not match its pinned hash — refusing to "
                f"copy it onto the stick.\n  pinned {want}\n  actual {got}")
        # -o: overwrite without prompting. The stick is a fixture, not an archive.
        if HOST:
            # Stream the file through ssh; mcopy reads stdin with '-'.
            cmd = ["ssh", "-o", "BatchMode=yes", HOST,
                   f"sudo -n env MTOOLS_SKIP_CHECK=1 mcopy -o -i {DEV} - ::{path}"]
            with open(local, "rb") as fh:
                r = subprocess.run(cmd, stdin=fh, capture_output=True, check=False)
        else:
            r = _mtools(["mcopy", "-o", "-i", DEV, local, f"::{path}"])
        if r.returncode != 0:
            die(f"could not write {path}: {r.stderr.decode(errors='replace').strip()}")
        print(f"  wrote {path}  ({src})")

    # bootlog.txt is deliberately NOT provisioned here: it is a fixed-size ring the
    # kernel writes in place, and recreating it is bootlog.py's job, not ours.
    if _size("bootlog.txt") != BOOTLOG_BYTES:
        print("usbdisk: NOTE — bootlog.txt is missing or the wrong size. It is the "
              "kernel's\n  boot-log ring; seed it with: scripts/debug/bootlog.py seed <mount>",
              file=sys.stderr)

    print("usbdisk: provisioned; re-verifying")
    verify()


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in ("verify", "provision"):
        print(__doc__)
        sys.exit(2)
    (verify if sys.argv[1] == "verify" else provision)()
