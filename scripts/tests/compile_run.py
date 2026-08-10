#!/usr/bin/env python3
"""Compile a program inside kudos and run it — the whole loop, on this laptop.

kudos carries no compiler (spec ARCH-012). This track proves the path that gets
around that WITHOUT a person driving it: a `compile` command in a kudos terminal
sends a .zig file from the ramdisk to a factory over HTTP, the factory answers
with a position-independent `.kudos` image, kudos saves it, and `run` loads and
executes it inside a session address space (MOD-006) — and the program's own
output comes back on the terminal.

It runs on a DEVELOPER LAPTOP and nothing else: no GPU, no USB stick, no lemon.
The factory is started here, on the host, and reached at 10.0.2.2 — QEMU slirp's
address for the machine kudos is running on. The same command inside kudos
reaches the zig-server GUEST instead when one is booted (`vm 3`); the loop is
identical either way, and the host factory is what makes it cheap enough to gate.

Readback is netdebug, lifted out of QEMU's own packet dump rather than a tap (the
same trick guest_boot.py uses), so it needs no privileges. Injection is QMP into
the emulated USB keyboard.

Fails LOUD (non-zero) with the captured trace on any miss.

Two drivers, one loop:
  (default)  a PERSON at the shell — `compile hello.zig hello` then `run hello`.
  --agent    THE AGENT — the F10 window is asked in English to write the program,
             compile it and run it, and the same three things are asserted. This
             is the whole point of the machine (AGT-001): it needs a service
             credential, and it costs LLM tokens, so it is not part of the gate.

Usage: scripts/tests/compile_run.py [--agent] [--factory HOST:PORT] [--keep] [--display]
Requires: build/kudos-smp.iso built with -Dtest-hooks, and zig on PATH (the
factory shells out to it). --factory points kudos at a factory that is ALREADY
running — the zig-server guest, say — instead of starting one on the host.
"""
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts/debug"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmp  # noqa: E402
from guest_boot import Netdebug, wait_for  # noqa: E402  (the same trace decoder)

OUT = os.path.join(ROOT, "build/logs")
PCAP = os.path.join(OUT, "compile-run.pcap")
QMP_SOCK = "/tmp/kudos-compile-run-qmp.sock"
LOG = os.path.join(OUT, "compile-run.log")
# The SMP image: `run` needs a session address space to contain a fault in, and
# the single-core kernel has none — it refuses the run rather than executing a
# module uncontained.
ISO = os.path.join(ROOT, "build/kudos-smp.iso")

# The factory this test starts on the host. 10.0.2.2 is slirp's address for the
# host from inside the guest; the port is the factory's own default.
FACTORY_PORT = 8623
FACTORY_HOST = f"10.0.2.2:{FACTORY_PORT}"

# What the agent is asked for. Plain English, no ABI hints and no tool names: the
# system prompt already documents both, and a request that spells out the answer
# proves the prompt rather than the agent.
AGENT_PROMPT = ("write a tiny zig app called hello that prints hello world, "
                "compile it, then run it and tell me what it printed")
# How long the agent gets. Several LLM round trips, each with a tool call after
# it, over a link that is a QEMU slirp hop from a laptop.
AGENT_BUDGET_S = 300
# The passphrase the credential was sealed with (scripts/agent/sealkey.sh's
# default). A build sealed with another one is told so by the /login refusal.
AGENT_PASSPHRASE = os.environ.get("KUDOS_AGENT_PASSPHRASE", "welcome")

# The module built from the seeded sample (main_root.seedRamdisk).
SOURCE = "hello.zig"
MODULE = "hello"
# What the sample prints. It lives in scripts/agent/samples/hello.zig, which is
# the file the image seeds, so this is one string in two places by necessity —
# the assertion has to state what "it ran" means.
EXPECTED_OUTPUT = "hello from a .kudos app"

# Budgets. A compile is a network round trip plus a real zig invocation on the
# host: a warm cache does it in under a second, a cold one takes tens.
BOOT_BUDGET_S = 90
NET_BUDGET_S = 30
COMPILE_BUDGET_S = 120
RUN_BUDGET_S = 30


def start_factory():
    """The host-side compile factory, or None when one is already listening."""
    import socket
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", FACTORY_PORT)) == 0:
            print(f"compile_run: using the factory already on :{FACTORY_PORT}")
            return None
    log = open(os.path.join(OUT, "compile-run-factory.log"), "wb")
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "scripts/agent/factory.py"), "serve",
         "--host", "0.0.0.0", "--port", str(FACTORY_PORT)],
        stdout=log, stderr=subprocess.STDOUT)
    # The factory binds before it prints; a moment here beats a retry loop around
    # every later step.
    for _ in range(50):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", FACTORY_PORT)) == 0:
                print(f"compile_run: factory {proc.pid} serving :{FACTORY_PORT}")
                return proc
        time.sleep(0.2)
    proc.kill()
    raise SystemExit("compile_run: the factory never bound its port")


def start_qemu(display):
    os.makedirs(OUT, exist_ok=True)
    for f in (PCAP, QMP_SOCK):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    cmd = [
        "qemu-system-x86_64",
        "-cdrom", ISO,
        "-boot", "order=d",
        "-m", "4G",
        "-smp", "4",
        "-enable-kvm",
        "-cpu", "host",
        "-vga", "std",
        "-netdev", "user,id=n0",
        "-device", "e1000,netdev=n0",
        "-object", f"filter-dump,id=d0,netdev=n0,file={PCAP}",
        "-device", "qemu-xhci,id=xhci",
        "-device", "usb-kbd,bus=xhci.0",
        "-device", "usb-tablet,bus=xhci.0",
        "-display", "gtk" if display else "none",
        "-qmp", f"unix:{QMP_SOCK},server,nowait",
        "-no-reboot", "-no-shutdown",
    ]
    return subprocess.Popen(cmd, stdout=open(os.path.join(OUT, "compile-run-qemu.log"), "wb"),
                            stderr=subprocess.STDOUT)


def fail(nd, why):
    with open(LOG, "w") as f:
        f.write(nd.text)
    print(f"\ncompile_run: FAIL — {why}", file=sys.stderr)
    print(f"  the captured trace is in {LOG}", file=sys.stderr)
    print("\n".join(nd.text.splitlines()[-25:]), file=sys.stderr)
    return 1


def send(q, nd, line, echo, budget, label):
    """Type one command line and prove it ARRIVED before waiting on its effect.

    A dropped keystroke otherwise shows up as a mysterious timeout on the next
    assertion instead of as what it is — so the echoed line is the first thing
    checked, and a mistyped line fails here, naming itself.
    """
    q.type_str(line)
    q.key("ret")
    if not wait_for(nd, echo, 15, f"typed: {label}"):
        return False
    return True


def drive_agent(q, nd):
    """Ask the agent, in English, for the whole loop — and check it did it.

    The agent window (AGT-002, F10) is a terminal whose every committed line is a
    turn, so this drives it exactly as a person would: unlock the credential,
    type the request, and watch the tools it chooses. What is asserted is the
    EVIDENCE of each step — the factory's answer, the module the loader ran, and
    the program's own output — never the agent's prose about them.
    """
    q.key("f10")
    if not wait_for(nd, r"kudos agent", 20, "agent window"):
        return fail(nd, "F10 did not open the agent window")
    time.sleep(1.0)

    # The credential is sealed into the image (AGT-017) and starts locked.
    q.type_str(f"/login {AGENT_PASSPHRASE}")
    q.key("ret")
    if not wait_for(nd, r"unlocked — the agent is ready", 30, "credential"):
        return fail(nd, "the sealed credential would not open — wrong passphrase, "
                        "or no credential in this build (-Dagent-key)")

    q.type_str(AGENT_PROMPT)
    q.key("ret")
    print(f"  ..   asked: {AGENT_PROMPT}")

    # The agent window announces each tool as it is called (● <name>), so these
    # are the agent's OWN choices, not this script's: it had to decide to compile
    # and then to run. The prose in between is not asserted — a model is free to
    # narrate however it likes, and a test that pins its wording tests the model.
    if not wait_for(nd, r"● compile_app", AGENT_BUDGET_S, "agent called compile_app"):
        return fail(nd, "the agent never sent anything to the factory")
    if not wait_for(nd, r"● run_app", AGENT_BUDGET_S, "agent called run_app"):
        return fail(nd, "the agent compiled a program and never ran it")
    if not wait_for(nd, r"hello,? world", AGENT_BUDGET_S, "agent reported the output"):
        return fail(nd, "the agent never reported what the program printed")

    # The strongest evidence is not the agent's account of itself: it is the
    # ARTIFACT. Open a FRESH terminal (F12 takes focus wherever it lands, so the
    # keystrokes below cannot go to a window that is closing) and run the module
    # there — the program's output and its exit status then come back through a
    # path the agent has no part in.
    q.key("f12")
    if not wait_for(nd, r"kudos terminal\. type 'help'", 20, "shell terminal"):
        return fail(nd, "F12 did not open a terminal to check the artifact in")
    time.sleep(1.0)
    q.type_str(f"run {MODULE}")
    q.key("ret")
    if not wait_for(nd, r"\[exit 0\]", RUN_BUDGET_S, "shell ran the agent's module"):
        return fail(nd, "the module the agent compiled does not run from the shell")

    with open(LOG, "w") as f:
        f.write(nd.text)
    print(f"\ncompile_run: PASS — the agent wrote, compiled and ran a program, "
          f"trace in {LOG}")
    return 0


def main():
    global FACTORY_HOST
    keep = "--keep" in sys.argv
    agent = "--agent" in sys.argv
    if "--factory" in sys.argv:
        FACTORY_HOST = sys.argv[sys.argv.index("--factory") + 1]
    if not os.path.exists(ISO):
        print("compile_run: build the image first:  zig build iso-smp -Dtest-hooks",
              file=sys.stderr)
        return 1
    # A factory named on the command line is somebody else's to run (the
    # zig-server guest, usually); only the default one is ours to start and kill.
    factory = None if "--factory" in sys.argv else start_factory()
    proc = start_qemu("--display" in sys.argv)
    nd = Netdebug(PCAP)
    print(f"compile_run: qemu {proc.pid}, image {ISO}")
    try:
        if not wait_for(nd, r"dbg: term\.0 = kudos terminal", BOOT_BUDGET_S, "kudos terminal"):
            return fail(nd, "kudos never reached its terminal")
        time.sleep(1.0)
        q = qmp.QMP(QMP_SOCK)

        # 1. The network, which `compile` needs and boot leaves down on purpose.
        if not send(q, nd, "net ip", r"net ip", NET_BUDGET_S, "net ip"):
            return fail(nd, "the `net ip` line never reached the terminal")
        if not wait_for(nd, r"ip\s+10\.0\.2\.\d+", NET_BUDGET_S, "dhcp lease"):
            return fail(nd, "kudos never leased an address from slirp")

        # 2. Point the compiler at this host (AGT: the factory is configurable at
        #    runtime because a guest factory only announces its address at boot).
        if not send(q, nd, f"compile factory {FACTORY_HOST}", r"compile factory",
                    NET_BUDGET_S, "compile factory"):
            return fail(nd, "the `compile factory` line never reached the terminal")
        if not wait_for(nd, rf"compile: factory {FACTORY_HOST}".replace(".", r"\."),
                        NET_BUDGET_S, "factory set"):
            return fail(nd, "kudos did not accept the factory address")

        if agent:
            return drive_agent(q, nd)

        # 3. Compile the seeded sample. ARCH-012: the compile happens off-target.
        if not send(q, nd, f"compile {SOURCE} {MODULE}", r"compile hello\.zig",
                    COMPILE_BUDGET_S, "compile hello.zig"):
            return fail(nd, "the `compile` line never reached the terminal")
        if not wait_for(nd, rf"compiled {MODULE}\.kudos \(\d+ bytes\)",
                        COMPILE_BUDGET_S, "compiled"):
            return fail(nd, "the factory never returned a .kudos image")

        # 4. Run it: the loader verifies the image and executes it in a session
        #    address space, and what the program printed comes back here.
        if not send(q, nd, f"run {MODULE}", r"run hello", RUN_BUDGET_S, "run hello"):
            return fail(nd, "the `run` line never reached the terminal")
        if not wait_for(nd, EXPECTED_OUTPUT, RUN_BUDGET_S, "program output"):
            return fail(nd, "the compiled program never printed its line")
        if not wait_for(nd, r"\[exit 0\]", RUN_BUDGET_S, "exit status"):
            return fail(nd, "the program did not exit 0")

        with open(LOG, "w") as f:
            f.write(nd.text)
        print(f"\ncompile_run: PASS — compiled and ran {MODULE}.kudos inside kudos, "
              f"trace in {LOG}")
        return 0
    finally:
        if keep:
            print(f"compile_run: leaving qemu {proc.pid} up (qmp {QMP_SOCK})")
        else:
            proc.kill()
            proc.wait()
        if factory is not None:
            factory.kill()
            factory.wait()


if __name__ == "__main__":
    sys.exit(main())
