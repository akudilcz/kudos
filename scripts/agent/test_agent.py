#!/usr/bin/env python3
"""End-to-end tests of the openclaw agent loop on the host: the real loop.run
(built into scripts/agent/hostagent.zig) driven by a stub OpenRouter, using the
real compile factory, kernel loader, and hot-load core. Proves both cycles —
app: prompt -> compile -> run -> answer (the generated app computes 639); and
self-improvement: survey sources -> compile_feature -> load_feature ->
invoke_command -> answer, with the source persisted in the factory workspace.

Runs standalone (`python3 test_agent.py`) and under pytest. Needs zig on PATH.
"""

import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import factory  # noqa: E402
import stub_openrouter  # noqa: E402

HAVE_ZIG = shutil.which(os.environ.get("ZIG", "zig")) is not None


def build_hostagent():
    out = os.path.join(tempfile.gettempdir(), "kudos_hostagent_test")
    subprocess.check_call([
        os.environ.get("ZIG", "zig"), "build-exe",
        "--dep", "loop", "--dep", "prompt", "--dep", "hotload", "--dep", "inet",
        "-Mroot=" + os.path.join(HERE, "hostagent.zig"),
        # loop streams its chat through inet.BodySink (the injected transport's
        # contract type), so loop's module must see the inet app-seam — the same
        # wiring build.zig gives the `loop` host-test row.
        "--dep", "inet", "-Mloop=" + os.path.join(REPO, "src", "agent", "loop.zig"),
        "--dep", "abi", "-Mprompt=" + os.path.join(REPO, "src", "agent", "prompt.zig"),
        "--dep", "abi", "-Mhotload=" + os.path.join(REPO, "src", "kernel", "loader", "hotload.zig"),
        "-Mabi=" + os.path.join(REPO, "src", "kernel", "loader", "abi.zig"),
        "-Minet=" + os.path.join(REPO, "src", "iface", "inet.zig"),
        "-femit-bin=" + out,
    ])
    return out


def _serve(handler):
    srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def _run_agent(script, prompt, workspace=None):
    """Run hostagent against the factory + the given stub script; return the
    completed process."""
    hostagent = build_hostagent()

    factory.Handler.abi = factory.parse_abi()
    factory.Handler.workspace = workspace
    factory.Handler.token = None
    fac_srv, fac_port = _serve(factory.Handler)

    stub_openrouter.Handler.step = 0  # reset the scripted conversation
    stub_openrouter.Handler.script = script
    stub_srv, stub_port = _serve(stub_openrouter.Handler)

    try:
        return subprocess.run(
            [hostagent,
             "http://127.0.0.1:%d/v1/chat/completions" % stub_port,
             "http://127.0.0.1:%d" % fac_port,
             prompt],
            capture_output=True, text=True, timeout=60,
        )
    finally:
        fac_srv.shutdown()
        stub_srv.shutdown()


# AGT-007: a natural-language request becomes a compiled, executed application
# — the real loop, the real factory, the real loader, one asserted number out.
def test_agent_builds_and_runs_primesum():
    # AGT-008: an agent-generated app compiles to a .kudos module and RUNS.
    if not HAVE_ZIG:
        print("SKIP: zig not on PATH")
        return

    p = _run_agent(stub_openrouter.SCRIPT, "sum the first 20 primes")
    assert p.returncode == 0, p.stderr
    # The model's final answer and the real computed result both present.
    assert "639" in p.stdout, p.stdout
    assert "primes" in p.stdout, p.stdout


def test_agent_uses_the_file_and_state_tools():
    if not HAVE_ZIG:
        print("SKIP: zig not on PATH")
        return

    p = _run_agent(stub_openrouter.FILE_SCRIPT, "note something and check state")
    assert p.returncode == 0, p.stderr
    # write_file confirmed the path; read_file returned the exact content;
    # system_state reported the file count — the AGT-006 tool surface end to end.
    assert "wrote 33 bytes to /ramdisk/agent-note.txt" in p.stdout, p.stdout
    assert "hello from the agent tool surface" in p.stdout, p.stdout
    assert "host.files = 1" in p.stdout, p.stdout
    assert "requested to open the clock window" in p.stdout, p.stdout


def test_agent_improves_with_feature():
    if not HAVE_ZIG:
        print("SKIP: zig not on PATH")
        return

    ws = tempfile.mkdtemp(prefix="kudos-ws-")
    try:
        p = _run_agent(stub_openrouter.IMPROVE_SCRIPT, "improve kudos", workspace=ws)
        assert p.returncode == 0, p.stderr
        # register-time log, then the dispatched command's real output
        assert "greet feature ready" in p.stdout, p.stdout
        assert "greetings from a hot-loaded feature, kudos" in p.stdout, p.stdout
        # the source of the improvement persisted for the next session to build on
        assert os.path.exists(os.path.join(ws, "greet.zig")), os.listdir(ws)
    finally:
        shutil.rmtree(ws, ignore_errors=True)


def main():
    failed = 0
    for t in (test_agent_builds_and_runs_primesum,
              test_agent_uses_the_file_and_state_tools,
              test_agent_improves_with_feature):
        try:
            t()
            print("PASS", t.__name__)
        except AssertionError as e:
            failed += 1
            print("FAIL", t.__name__, "->", e)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
