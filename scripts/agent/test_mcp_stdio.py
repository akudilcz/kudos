#!/usr/bin/env python3
"""Test that kudos's MCP handler works as a real stdio MCP server: drive the
scripts/agent/mcp_stdio.zig binary (built on src/agent/mcp.zig) with JSON-RPC
over stdin/stdout and check initialize / tools/list / tools/call. This is the
laptop proof of the "netdebug tools served over MCP" port — the same handler
that runs in the kernel, exercised through a real client transcript.

Standalone (`python3 test_mcp_stdio.py`) and pytest. Needs zig.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
HAVE_ZIG = shutil.which(os.environ.get("ZIG", "zig")) is not None


def build():
    out = os.path.join(tempfile.gettempdir(), "kudos_mcp_stdio")
    subprocess.check_call([
        os.environ.get("ZIG", "zig"), "build-exe",
        "--dep", "mcp", "-Mroot=" + os.path.join(HERE, "mcp_stdio.zig"),
        "-Mmcp=" + os.path.join(REPO, "src", "agent", "mcp.zig"),
        "-femit-bin=" + out,
    ])
    return out


def test_mcp_stdio_server():
    if not HAVE_ZIG:
        print("SKIP: zig not on PATH")
        return
    server = build()
    reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize"},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},  # no reply
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "kudos_status", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "list_files", "arguments": {"path": "/ramdisk"}}},
    ]
    stdin = "".join(json.dumps(r) + "\n" for r in reqs)
    p = subprocess.run([server], input=stdin, capture_output=True, text=True, timeout=20)
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    # The notification produced no reply, so 4 responses for 5 requests.
    assert len(lines) == 4, (len(lines), p.stdout)
    resp = [json.loads(ln) for ln in lines]

    assert resp[0]["id"] == 1 and "protocolVersion" in resp[0]["result"]
    # tools/list carries the kudos tool surface
    names = {t["name"] for t in resp[1]["result"]["tools"]}
    assert {"kudos_status", "list_files", "screenshot"} <= names, names
    status_text = resp[2]["result"]["content"][0]["text"]
    assert json.loads(status_text)["cores_online"] == 4
    assert resp[2]["result"]["isError"] is False
    assert "primesum.kudos" in resp[3]["result"]["content"][0]["text"]


def main():
    try:
        test_mcp_stdio_server()
        print("PASS test_mcp_stdio_server")
        return 0
    except AssertionError as e:
        print("FAIL:", e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
