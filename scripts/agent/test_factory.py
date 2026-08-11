#!/usr/bin/env python3
"""Tests for the kudos compile factory + .kudos loader.

Runs with pytest if present, and also standalone: `python3 test_factory.py`.
Covers, against REAL compiler output (ARCH-012: agent code compiles off-target
into loadable binary modules):
  - a valid app compiles to a well-formed .kudos (header, CRC, kind);
  - the compiled machine code actually RUNS (via scripts/agent/hostload.zig,
    which reuses the kernel loader) and produces the right answer;
  - a syntactically broken source is rejected with LLM-usable errors (the retry
    signal);
  - an app that needs absolute addressing is rejected as not position
    independent (the soundness guard — such code would break loaded off VMA 0);
  - the feature build path (kind = feature) works;
  - the HTTP surface returns 200 / 409 / 422 correctly.

Needs `zig` on PATH (skips otherwise).
"""

import http.client
import http.server
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SAMPLES = os.path.join(HERE, "samples")
sys.path.insert(0, HERE)
import factory  # noqa: E402

HAVE_ZIG = shutil.which(os.environ.get("ZIG", "zig")) is not None
ABI = factory.parse_abi() if HAVE_ZIG else None

_hostload = None


def hostload_path():
    """Build the host loader/executor once; cache it for the run."""
    global _hostload
    if _hostload:
        return _hostload
    out = os.path.join(tempfile.gettempdir(), "kudos_hostload_test")
    subprocess.check_call([
        os.environ.get("ZIG", "zig"), "build-exe",
        "--dep", "hotload", "-Mroot=" + os.path.join(HERE, "hostload.zig"),
        "--dep", "abi", "-Mhotload=" + os.path.join(REPO, "src", "kernel", "loader", "hotload.zig"),
        "-Mabi=" + os.path.join(REPO, "src", "kernel", "loader", "abi.zig"),
        "-femit-bin=" + out,
    ])
    _hostload = out
    return out


def compile_sample(name, kind="app"):
    src = open(os.path.join(SAMPLES, name)).read()
    return factory.compile_kudos(src, kind=kind, name=name.split(".")[0], abi=ABI)


def run_blob(blob, *extra):
    """Load and execute a .kudos via hostload; return (rc, stdout). For a
    feature blob, extra = (command, args?) dispatches after register."""
    with tempfile.NamedTemporaryFile(suffix=".kudos", delete=False) as f:
        f.write(blob)
        path = f.name
    try:
        p = subprocess.run([hostload_path(), path, *extra],
                           capture_output=True, text=True, timeout=20)
        return p.returncode, p.stdout
    finally:
        os.unlink(path)


def parse_header(blob):
    magic, ver, kind, code_len, mem_len, crc = struct.unpack("<6I", blob[:factory.HEADER_SIZE])
    return dict(magic=magic, ver=ver, kind=kind, code_len=code_len, mem_len=mem_len, crc=crc)


# ── tests ───────────────────────────────────────────────────────────────────

def test_hello_compiles_to_valid_kudos():
    res = compile_sample("hello.zig")
    assert res["ok"], res
    h = parse_header(res["blob"])
    assert h["magic"] == ABI["magic"]
    assert h["ver"] == ABI["version"]
    assert h["kind"] == ABI["kinds"]["app"]
    assert h["mem_len"] >= h["code_len"] > 0
    assert len(res["blob"]) == factory.HEADER_SIZE + h["code_len"]


def test_hello_executes():
    rc, out = run_blob(compile_sample("hello.zig")["blob"])
    assert rc == 0 and "hello from a .kudos app" in out, (rc, out)


def test_compute_executes():
    rc, out = run_blob(compile_sample("compute.zig")["blob"])
    assert rc == 0 and "sum(1..100)=5050" in out, (rc, out)


def test_primesum_executes():
    # The end-user scenario: "sum the first 20 primes" -> 639.
    rc, out = run_blob(compile_sample("primesum.zig")["blob"])
    assert rc == 0 and "639" in out, (rc, out)


def test_crashy_compiles_but_is_not_run_here():
    # A faulting app still compiles to a valid .kudos; containment is on-target.
    res = compile_sample("crashy.zig")
    assert res["ok"], res
    assert parse_header(res["blob"])["kind"] == ABI["kinds"]["app"]


def test_feature_build_path():
    res = compile_sample("hello_feature.zig", kind="feature")
    assert res["ok"], res
    assert parse_header(res["blob"])["kind"] == ABI["kinds"]["feature"]


# MOD-003: a loaded feature registers a new shell command and dispatches it
# with no restart; MOD-001: the blob really executes through the kernel loader.
def test_feature_registers_and_dispatches():
    # The self-improvement loop's load half: a real feature blob registers
    # through hotload.registerBlob and its command runs through hotload.dispatch
    # — the exact kernel code, on the laptop.
    blob = compile_sample("greet_feature.zig", kind="feature")["blob"]
    rc, out = run_blob(blob, "greet")
    assert rc == 0, (rc, out)
    assert "greet feature ready" in out, out          # register-time log
    assert "greetings from a hot-loaded feature" in out, out  # dispatched command
    rc, out = run_blob(blob, "greet", "andrew")
    assert rc == 0 and "greetings from a hot-loaded feature, andrew" in out, out
    # an unknown command is a loud miss, not a silent no-op
    rc, out = run_blob(blob, "nope")
    assert rc == 3, (rc, out)


def test_compile_error_is_fed_back():
    res = factory.compile_kudos("pub fn main(api: *const abi.Api) i32 { not valid zig }",
                                kind="app", abi=ABI)
    assert not res["ok"]
    assert res["stage"] == factory.STAGE_COMPILE
    assert "app.zig" in res["errors"]  # the model sees a real file:line diagnostic


def test_absolute_addressing_is_rejected():
    # Soundness guard: a function-pointer table needs absolute addresses, which
    # would be wrong once the kernel loads the image off VMA 0. It must be
    # rejected as a relocation, not silently accepted.
    src = (
        'const abi = @import("abi.zig");\n'
        "fn a(_: *const abi.Api) i32 { return 1; }\n"
        "fn b(_: *const abi.Api) i32 { return 2; }\n"
        "const tbl = [_]*const fn (*const abi.Api) i32{ a, b };\n"
        "pub fn main(api: *const abi.Api) i32 {\n"
        "    const i: usize = @intCast(api.millis(api.ctx) % 2);\n"
        "    return tbl[i](api);\n"
        "}\n"
    )
    res = factory.compile_kudos(src, kind="app", abi=ABI)
    assert not res["ok"] and res["stage"] == factory.STAGE_RELOC, res


def _serve(workspace=None, token=None):
    factory.Handler.abi = ABI
    factory.Handler.workspace = workspace
    factory.Handler.token = token
    srv = http.server.HTTPServer(("127.0.0.1", 0), factory.Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    return srv


def _post(port, obj, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    h = {"Content-Type": "application/json"}
    h.update(headers or {})
    c.request("POST", "/compile", json.dumps(obj), h)
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, body


def _get(port, path):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    c.request("GET", path)
    r = c.getresponse()
    body = r.read()
    c.close()
    return r.status, body


def test_http_endpoints():
    srv = _serve()
    port = srv.server_address[1]
    try:
        hello = open(os.path.join(SAMPLES, "hello.zig")).read()
        # good -> 200 octet-stream, a loadable blob
        st, body = _post(port, {"abi_version": ABI["version"], "kind": "app", "source": hello})
        assert st == 200 and parse_header(body)["magic"] == ABI["magic"], (st, body[:32])
        # wrong abi version -> 409
        st, _ = _post(port, {"abi_version": ABI["version"] + 99, "kind": "app", "source": hello})
        assert st == 409, st
        # broken source -> 422 with errors
        st, body = _post(port, {"abi_version": ABI["version"], "kind": "app", "source": "nope"})
        assert st == 422 and b"errors" in body, (st, body[:64])
    finally:
        srv.shutdown()


def test_bad_module_names_rejected():
    srv = _serve()
    port = srv.server_address[1]
    try:
        hello = open(os.path.join(SAMPLES, "hello.zig")).read()
        for bad in ("../evil", "A B", "UPPER", "9lead", "x" * 33):
            st, _ = _post(port, {"abi_version": ABI["version"], "kind": "app",
                                 "name": bad, "source": hello})
            assert st == 400, (bad, st)
        st, _ = _get(port, "/sources/../evil")
        assert st == 400, st
    finally:
        srv.shutdown()


def test_workspace_persists_and_serves_sources():
    ws = tempfile.mkdtemp(prefix="kudos-ws-")
    srv = _serve(workspace=ws)
    port = srv.server_address[1]
    try:
        hello = open(os.path.join(SAMPLES, "hello.zig")).read()
        feat = open(os.path.join(SAMPLES, "hello_feature.zig")).read()
        # empty workspace -> empty list
        st, body = _get(port, "/sources")
        assert st == 200 and json.loads(body) == [], (st, body)
        # successful builds persist source + kind
        st, _ = _post(port, {"abi_version": ABI["version"], "kind": "app",
                             "name": "hello", "source": hello})
        assert st == 200, st
        st, _ = _post(port, {"abi_version": ABI["version"], "kind": "feature",
                             "name": "greet", "source": feat})
        assert st == 200, st
        st, body = _get(port, "/sources")
        entries = json.loads(body)
        assert st == 200 and [(e["name"], e["kind"]) for e in entries] == \
            [("greet", "feature"), ("hello", "app")], entries
        # source round-trips verbatim
        st, body = _get(port, "/sources/hello")
        assert st == 200 and body.decode() == hello, st
        # overwrite IS the update path
        st, _ = _post(port, {"abi_version": ABI["version"], "kind": "app",
                             "name": "hello", "source": hello + "// v2\n"})
        assert st == 200, st
        st, body = _get(port, "/sources/hello")
        assert body.decode().endswith("// v2\n"), body[-32:]
        # a failed build persists nothing new
        st, _ = _post(port, {"abi_version": ABI["version"], "kind": "app",
                             "name": "broken", "source": "nope"})
        assert st == 422, st
        st, _ = _get(port, "/sources/broken")
        assert st == 404, st
        # /abi serves the contract file byte-for-byte
        st, body = _get(port, "/abi")
        assert st == 200 and body == open(factory.ABI_ZIG, "rb").read(), st
        # unknown GET -> 404
        st, _ = _get(port, "/nope")
        assert st == 404, st
    finally:
        srv.shutdown()
        shutil.rmtree(ws, ignore_errors=True)


def test_factory_token_gates_posts():
    srv = _serve(token="sekrit")
    port = srv.server_address[1]
    try:
        hello = open(os.path.join(SAMPLES, "hello.zig")).read()
        req = {"abi_version": ABI["version"], "kind": "app", "source": hello}
        st, _ = _post(port, req)
        assert st == 401, st
        st, _ = _post(port, req, headers={"X-Factory-Token": "wrong"})
        assert st == 401, st
        st, _ = _post(port, req, headers={"X-Factory-Token": "sekrit"})
        assert st == 200, st
        # GETs stay open: source visibility is not the protected asset
        st, _ = _get(port, "/abi")
        assert st == 200, st
    finally:
        srv.shutdown()


def test_entry_owns_byte_zero_of_the_image():
    # The loader calls byte 0 of the image, so `.entry` has to BE byte 0. A PIE
    # link also emits ALLOCATED dynamic-linking metadata (.dynsym, .hash, ...);
    # sections the linker script does not name are orphans it places at the
    # front, which pushes the code off byte 0. Nothing else notices: the image
    # has no relocations, the header is well formed, the blob loads — and then
    # the machine executes a symbol table and dies with a wild instruction
    # pointer. This source is the shape that triggers it (a helper call and a
    # @memcpy of a literal); it must RUN, not merely compile.
    src = (
        'const abi = @import("abi.zig");\n'
        "noinline fn label(buf: []u8) usize {\n"
        '    @memcpy(buf[0..4], "ent=");\n'
        "    buf[4] = 'o';\n"
        "    buf[5] = 'k';\n"
        "    buf[6] = '\\n';\n"
        "    return 7;\n"
        "}\n"
        "pub fn main(api: *const abi.Api) i32 {\n"
        "    var buf: [16]u8 = undefined;\n"
        "    const n = label(&buf);\n"
        "    api.print(api.ctx, &buf, n);\n"
        "    return 0;\n"
        "}\n"
    )
    res = factory.compile_kudos(src, kind="app", abi=ABI)
    assert res["ok"], res
    rc, out = run_blob(res["blob"])
    assert rc == 0 and "ent=ok" in out, (rc, out)


def main():
    if not HAVE_ZIG:
        print("SKIP: zig not on PATH")
        return 0
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL", t.__name__, "->", repr(e))
    print("\n%d/%d passed" % (len(tests) - failed, len(tests)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
