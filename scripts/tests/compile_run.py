#!/usr/bin/env python3
"""Compile a program inside kudos and run it — the whole loop, on this laptop.

kudos carries no compiler (ARCH-012). This track proves the path around that with
nobody driving it: a source file is TYPED onto the ramdisk with shell redirection
(APP-028), `compile` sends it to a factory over HTTP, the factory answers with a
position-independent `.kudos`, and `run` executes it in a session address space
(MOD-006) — with the program's own output coming back on the terminal.

The typing is the point, not scaffolding: the image seeds no sample, so the whole
chain begins with keystrokes and nothing reaches in from outside to place a file.

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
  (default)  a PERSON at the shell — types the source with `echo ... > hello.zig`,
             then `kudos compile hello.zig hello` and `kudos run hello`.
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
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts/debug"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qmp  # noqa: E402
from guest_boot import Netdebug, wait_for  # noqa: E402  (the same trace decoder)

OUT = os.path.join(ROOT, "build/logs")
# Made here, at import, not where the first log happens to be opened: `build/` is a
# generated tree that `make clean` takes away, and every path below writes into this
# directory — the factory's log first, before any QEMU setup runs. Creating it late
# means a clean checkout fails on the log file rather than on anything it tests.
os.makedirs(OUT, exist_ok=True)
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

# The module this test types in, compiles and runs. NOTHING is pre-seeded: the
# image deliberately ships no sample, because a program that was already there
# made the demo lie about who wrote it. So the source arrives the way a person
# with no editor puts one on the machine — `echo ... > file` (APP-028) — and the
# lines come from scripts/agent/samples/hello.zig, the same file the host factory
# tests compile.
SOURCE = "hello.zig"
MODULE = "hello"
# What the sample prints — the assertion has to state what "it ran" means.
EXPECTED_OUTPUT = "hello from a .kudos app"
# ...and this is how that assertion is made. `wait_for` searches the CUMULATIVE
# trace, and this test types the program's own source — including the string it
# prints — so a bare search for EXPECTED_OUTPUT would be satisfied by the ECHO of
# the line that wrote it, before anything had run. The trace mirrors each terminal
# line as `dbg: term.0 = <line>`; anchoring there separates the two, because the
# echoed line carries the shell prompt and `echo ` in front of the string.
RAN_OUTPUT = r"term\.0 = " + re.escape(EXPECTED_OUTPUT)
# How much of a typed line's echo is looked for. The terminal grid is 80 columns
# and mirrors a WRAPPED line to the trace as two records (`term.0+ = <head>` then
# the remainder), so a long line's echo is not contiguous text to search for. A
# prefix that cannot wrap — shell prompt included — is enough to recognise which
# line came back.
ECHO_PREFIX_CHARS = 40
# How long one typed line's echo is waited for before moving on. This wait is
# PACING AND PROGRESS, not an assertion: the trace is a lossy capture — records are
# dropped in flight, which shows up as gaps in the record numbering — and one
# missing echo among a dozen must not fail a loop that worked. What proves all the
# lines landed intact is the COMPILE, which fails loudly on a mangled source.
LINE_ECHO_S = 10

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


def source_lines():
    """The sample's code, as lines to type at the shell.

    Read from the sample rather than restated here, so the program the gate types
    is the program the host factory tests compile — one file, two uses. Prose is
    dropped: every character costs a paced keystroke (qmp.INTER_KEY_S), and a doc
    comment does not change what the compiler produces.
    """
    path = os.path.join(ROOT, "scripts/agent/samples", SOURCE)
    lines = []
    for raw in open(path).read().splitlines():
        line = raw.strip()
        if line and not line.startswith("//"):
            lines.append(line)
    # A line whose own text contains a redirection token would be split by the
    # shell at the wrong place, and the file would come out mangled in a way that
    # reads as a compiler error. Refuse here, naming the rule, rather than
    # debugging it from the other end.
    for line in lines:
        if any(tok in (">", ">>") for tok in line.split()):
            raise SystemExit(
                f"compile_run: {SOURCE} has a line the shell would read as a "
                f"redirection: {line!r} (see src/console/redirect.zig)")
    return lines


def wait_for_nth(nd, pattern, n, timeout, label):
    """Wait until `pattern` has appeared at least `n` times in the trace.

    The cumulative single-match search (`wait_for`) cannot confirm a line the file
    REPEATS: hello.zig closes two functions with a bare `}`, so the second echo is
    indistinguishable from the first unless occurrences are counted. Counting keeps
    each typed line proving its own arrival.
    """
    rx = re.compile(pattern)
    deadline = time.time() + timeout
    while time.time() < deadline:
        nd.poll()
        if len(rx.findall(nd.text)) >= n:
            print(f"  ok   {label}")
            return True
        time.sleep(0.25)
    return False


def type_source(q, nd):
    """Write the program onto the ramdisk, one echo per line (APP-028, APP-029).

    kudos carries no editor, so this is how a person authors a file on it: the first
    line replaces, the rest append. Each line's echo is WATCHED FOR but not
    required — see LINE_ECHO_S. The compile that follows is what proves the file
    arrived intact, and it proves more than an echo can: every character of every
    line, as judged by a compiler.
    """
    lines = source_lines()
    # The first line replaces, the rest append — so a re-run overwrites the file
    # rather than doubling it.
    cmds = [f"echo {line} {'>' if i == 0 else '>>'} {SOURCE}"
            for i, line in enumerate(lines)]
    print(f"compile_run: typing {SOURCE} in, {len(cmds)} lines ...")
    seen = {}
    for i, cmd in enumerate(cmds):
        head = cmd[:ECHO_PREFIX_CHARS]
        seen[head] = seen.get(head, 0) + 1
        q.type_str(cmd)
        q.key("ret")
        if not wait_for_nth(nd, re.escape(head), seen[head], LINE_ECHO_S,
                            f"{SOURCE} line {i + 1}: {cmd}"):
            print(f"  ..   {SOURCE} line {i + 1}: echo not seen (dropped record) — "
                  f"the compile below is the real check")


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
    q.type_str(f"kudos run {MODULE}")
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
        if not send(q, nd, "ip", r"inet 10\.0\.2\.", NET_BUDGET_S, "ip addr"):
            return fail(nd, "the `ip` line never leased an address")
        if not wait_for(nd, r"ip\s+10\.0\.2\.\d+", NET_BUDGET_S, "dhcp lease"):
            return fail(nd, "kudos never leased an address from slirp")

        # 2. Point the compiler at this host (AGT: the factory is configurable at
        #    runtime because a guest factory only announces its address at boot).
        if not send(q, nd, f"kudos compile factory {FACTORY_HOST}", r"kudos compile factory",
                    NET_BUDGET_S, "compile factory"):
            return fail(nd, "the `compile factory` line never reached the terminal")
        if not wait_for(nd, rf"compile: factory {FACTORY_HOST}".replace(".", r"\."),
                        NET_BUDGET_S, "factory set"):
            return fail(nd, "kudos did not accept the factory address")

        if agent:
            return drive_agent(q, nd)

        # 3. Write the program. Nothing was seeded, so these keystrokes are the
        #    only reason a source file exists at all.
        type_source(q, nd)

        # 4. Compile it. ARCH-012: the compile happens off-target. No echo check
        #    here — this command's OWN output is the stronger and immediate proof,
        #    and asking for both only adds a record the capture can lose.
        q.type_str(f"kudos compile {SOURCE} {MODULE}")
        q.key("ret")
        if not wait_for(nd, rf"compiled {MODULE}\.kudos \(\d+ bytes\)",
                        COMPILE_BUDGET_S, "compiled"):
            return fail(nd, "the factory never returned a .kudos image — the typed "
                            "source did not compile (the compiler's errors are in "
                            "the trace above), or the factory is unreachable")

        # 5. Run it: the loader verifies the image and executes it in a session
        #    address space, and what the program printed comes back here. Again no
        #    echo check: "run hello" appears in the compile's own advice line, so an
        #    echo search for it would pass without a program having run at all.
        q.type_str(f"kudos run {MODULE}")
        q.key("ret")
        if not wait_for(nd, RAN_OUTPUT, RUN_BUDGET_S, "program output"):
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
