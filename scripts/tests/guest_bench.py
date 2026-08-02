#!/usr/bin/env python3
"""How fast is a kudos guest, against references measured the same way?

Three workloads run inside a Linux guest, in three places:

  native   the same busybox binary, same shell, on this host directly
  kvm      the same kernel + initramfs in a plain QEMU/KVM guest on this host
  kudos    the same kernel + initramfs in a kudos guest (`vm boot 1`)

Same binary, same shell, same commands: the only thing that differs is what is
executing them. Every interval is measured by the HOST's clock — for the two
guests, the arrival time of a marker line, which is the one number a guest
cannot flatter by mis-emulating its own timer.

The workloads are chosen to separate three costs that behave completely
differently under virtualization:

  cpu      userspace arithmetic. No syscalls, no VM exits. The guest executes
           these instructions on the real CPU, so anything but parity here would
           mean it is not really running natively.
  syscall  8 GiB through read+write. Guest kernel work, no device, no exits.
  ioexit   60 kB to the serial console. Every byte is a port write and every
           port write is a VM exit. This is hypervisor cost, undiluted — and the
           only one of the three that can be dominated by it.

A caveat the numbers cannot state themselves: under QEMU on a developer laptop,
kudos is ITSELF a guest, so a `kudos` exit is a nested exit and costs roughly ten
times what it costs on hardware kudos owns. The `cpu` and `syscall` figures are
unaffected (they take no exits). The `ioexit` figure is nearly all exit cost, so
on this host it measures nesting more than it measures kudos. Run it on real
hardware to see kudos's own number.

Usage: scripts/tests/guest_bench.py [--json]
Exits non-zero if a workload could not be measured at all.
"""
import json
import os
import re
import struct
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts/debug"))
import qmp  # noqa: E402

OUT = os.path.join(ROOT, "build/logs")
PCAP = os.path.join(OUT, "guest-bench.pcap")
QMP_SOCK = "/tmp/kudos-bench-qmp.sock"
ISO = os.path.join(ROOT, "build/kudos.iso")
BZIMAGE = os.path.join(ROOT, "assets/virt/bzImage")
INITRAMFS = os.path.join(ROOT, "assets/virt/initramfs.cpio.gz")
BUSYBOX = os.path.join(OUT, "bench-rootfs/bin/busybox")
NETDEBUG_PORT = 9514
MARKER = "KUDOS-GUEST-UP"

# (name, command, the value the command must report). The third field is not
# decoration: keystroke injection into an emulated USB keyboard is LOSSY, and a
# command that arrives with a character missing does not fail loudly — it runs
# something shorter and reports a time four times better than the truth. So every
# workload counts its own iterations and says so, and a run whose count is wrong
# is retried rather than believed.
WORKLOADS = [
    ("cpu", "i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done", "2000000"),
    ("syscall", "i=0; busybox dd if=/dev/zero of=/dev/null bs=4k count=2000000 2>/dev/null; i=$?", "0"),
    ("ioexit", "i=0; while [ $i -lt 3000 ]; do echo -n xxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo", "3000"),
]


# How far past the KVM reference the kudos guest may be before this reports a
# regression. Not a physics constant: it is the budget, and the point of writing
# it down is that a change which doubles the exit cost fails here instead of
# being noticed months later.
BUDGET = 2.0


def marked(name, cmd):
    """The workload, bracketed by markers BUILT from shell variables, and
    followed by the iteration count it reached.

    A tty echoes the command it is sent. A literal end marker would appear in
    that echo, and timing to it would measure the echo rather than the work —
    reporting a second of work as a millisecond. The trailing count is what
    proves the command arrived intact.
    """
    return f"Y=S; Z=E; echo ${{Y}}{name}; {cmd}; echo ${{Z}}{name}; echo COUNT=$i"


def unpack_rootfs():
    """The guest's own busybox, on the host, so `native` runs the same binary."""
    root = os.path.join(OUT, "bench-rootfs")
    os.makedirs(root, exist_ok=True)
    if not os.path.exists(BUSYBOX):
        subprocess.run(f"zcat {INITRAMFS} | cpio -idm", shell=True, cwd=root,
                       check=True, capture_output=True)
    return root


class Stream:
    """Lines with the host clock time at which each arrived."""

    def __init__(self):
        self.lines = []

    def add(self, ts, text):
        self.lines.append((ts, text))

    def stamp(self, needle, after):
        for ts, text in self.lines:
            if ts > after and needle in text:
                return ts
        return None

    def latest(self):
        """This stream's own notion of "now" — the last record it has seen."""
        return self.lines[-1][0] if self.lines else 0.0

    def after(self, needle, ts_after):
        """The text following `needle` on the first record past `ts_after`."""
        for ts, text in self.lines:
            if ts_after is not None and ts >= ts_after and needle in text:
                tail = text.split(needle, 1)[1]
                return tail.split("\n", 1)[0]
        return None

    def has(self, pattern):
        rx = re.compile(pattern)
        return any(rx.search(t) for _, t in self.lines)


# How many times a mangled command is retyped before the workload is given up on.
TYPING_ATTEMPTS = 4


def time_workloads(stream, poll, send, settle=1.0):
    """Drive each workload and return {name: seconds}, timing marker to marker.

    Retries a workload whose reported iteration count is wrong: that means the
    command did not arrive intact, and its timing describes a different, shorter
    program than the one being measured.
    """
    out = {}
    for name, cmd, want in WORKLOADS:
        for attempt in range(TYPING_ATTEMPTS):
            poll()
            # The time base comes from the STREAM, not from this process's clock.
            # A pcap's packet timestamps are QEMU's, not the wall clock, so a
            # wall-clock base excludes every record in the file.
            base = stream.latest()
            send(marked(name, cmd))
            deadline = time.time() + 300
            start = end = count = None
            while time.time() < deadline:
                poll()
                start = stream.stamp(f"S{name}", base)
                end = stream.stamp(f"E{name}", start) if start else None
                count = stream.after("COUNT=", end) if end else None
                if start and end and count is not None and end > start:
                    break
                time.sleep(0.1)
            if count is not None and count.strip() == want:
                out[name] = end - start
                break
            print(f"  {name:8s} retyping (guest reported {count!r}, wanted {want!r})",
                  flush=True)
            time.sleep(settle)
        time.sleep(settle)
    return out


def bench_native():
    root = unpack_rootfs()
    env = dict(os.environ, PATH=os.path.join(root, "bin") + ":" + os.environ.get("PATH", ""))
    out = {}
    for name, cmd, _want in WORKLOADS:
        subprocess.run([BUSYBOX, "sh", "-c", cmd], env=env, capture_output=True)  # warm
        best = min(_timed([BUSYBOX, "sh", "-c", cmd], env) for _ in range(3))
        out[name] = best
    return out


def _timed(argv, env):
    t0 = time.time()
    subprocess.run(argv, env=env, capture_output=True)
    return time.time() - t0


def bench_kvm():
    """The same kernel and initramfs under a production hypervisor."""
    p = subprocess.Popen(
        ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-smp", "1", "-m", "512M",
         "-kernel", BZIMAGE, "-initrd", INITRAMFS,
         "-append", "console=ttyS0 no_timer_check tsc=reliable mitigations=off",
         "-nographic", "-no-reboot"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    stream = Stream()

    def reader():
        buf = b""
        while True:
            ch = p.stdout.read(1)
            if not ch:
                return
            buf += ch
            if ch in (b"\n", b"\r"):
                stream.add(time.time(), buf.decode("utf-8", "replace"))
                buf = b""

    threading.Thread(target=reader, daemon=True).start()
    try:
        if not _await(lambda: stream.has(MARKER), 120):
            return {}
        time.sleep(1.0)

        def send(text):
            p.stdin.write((text + "\n").encode())
            p.stdin.flush()

        return time_workloads(stream, lambda: None, send)
    finally:
        p.kill()


class Netdebug:
    """kudos's trace stream, with the pcap's own per-packet host timestamps."""

    def __init__(self, path, stream):
        self.path, self.stream, self.off = path, stream, 24

    def poll(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.off)
                data = f.read()
        except FileNotFoundError:
            return
        i = 0
        while i + 16 <= len(data):
            ts_sec, ts_usec, caplen, _ = struct.unpack("<IIII", data[i:i + 16])
            if i + 16 + caplen > len(data):
                break
            pkt = data[i + 16:i + 16 + caplen]
            i += 16 + caplen
            self.off += 16 + caplen
            if len(pkt) < 42 or pkt[12:14] != b"\x08\x00" or pkt[14 + 9] != 17:
                continue
            udp = pkt[14 + (pkt[14] & 0x0F) * 4:]
            if struct.unpack(">H", udp[2:4])[0] != NETDEBUG_PORT:
                continue
            self.stream.add(ts_sec + ts_usec / 1e6, udp[8:].decode("utf-8", "replace"))


def bench_kudos():
    os.makedirs(OUT, exist_ok=True)
    for f in (PCAP, QMP_SOCK):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    p = subprocess.Popen(
        ["qemu-system-x86_64", "-cdrom", ISO, "-boot", "order=d", "-m", "4G", "-smp", "1",
         "-enable-kvm", "-cpu", "host", "-vga", "std",
         "-netdev", "user,id=n0", "-device", "e1000,netdev=n0",
         "-object", f"filter-dump,id=d0,netdev=n0,file={PCAP}",
         "-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0",
         "-display", "none", "-qmp", f"unix:{QMP_SOCK},server,nowait",
         "-no-reboot", "-no-shutdown"],
        stdout=open(os.path.join(OUT, "guest-bench-qemu.log"), "wb"), stderr=subprocess.STDOUT)
    stream = Stream()
    nd = Netdebug(PCAP, stream)
    try:
        if not _await(lambda: (nd.poll(), stream.has(r"xhci:  -> KEYBOARD ready"))[1], 150):
            return {}
        time.sleep(1.5)
        q = qmp.QMP(QMP_SOCK)
        # These commands are long, and the emulated keyboard drops keystrokes
        # when its queue outruns the guest's polling. Slower than the default,
        # because a retyped workload costs far more than the extra seconds.
        q.INTER_KEY_S = 0.09
        q.type_str("vm boot 1")
        q.key("ret")
        if not _await(lambda: (nd.poll(), stream.has(f"vm0: {MARKER}"))[1], 240):
            return {}
        time.sleep(3.0)

        def send(text):
            q.type_str(text)
            q.key("ret")

        return time_workloads(stream, nd.poll, send, settle=2.0)
    finally:
        p.terminate()


def _await(pred, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.25)
    return False


def main():
    if not os.path.exists(ISO):
        print("guest_bench: build the image first:  zig build iso -Dtest-hooks", file=sys.stderr)
        return 1
    results = {}
    for label, fn in (("native", bench_native), ("kvm", bench_kvm), ("kudos", bench_kudos)):
        print(f"== {label} ==", flush=True)
        results[label] = fn()
        for name, _, _w in WORKLOADS:
            v = results[label].get(name)
            print(f"  {name:8s} {v:8.3f} s" if v else f"  {name:8s}   MISSING", flush=True)

    print("\n  workload   native      kvm    kudos   vs native   vs kvm")
    worst = None
    for name, _, _w in WORKLOADS:
        n, k, g = (results[x].get(name) for x in ("native", "kvm", "kudos"))
        if not (n and k and g):
            continue
        print(f"  {name:8s} {n:7.3f}s {k:7.3f}s {g:7.3f}s "
              f"{g / n:9.2f}x {g / k:8.2f}x")
        if name != "ioexit":
            worst = max(worst or 0, g / n)
    if "--json" in sys.argv:
        print(json.dumps(results))

    missing = [n for n, _, _w in WORKLOADS if not all(results[x].get(n) for x in results)]
    if missing:
        print(f"\nguest_bench: FAIL — no measurement for {', '.join(missing)}", file=sys.stderr)
        return 1
    print(f"\nguest_bench: compute and syscall workloads are {worst:.2f}x native "
          f"(budget {BUDGET:.1f}x).")
    return 0 if worst <= BUDGET else 1


if __name__ == "__main__":
    sys.exit(main())
