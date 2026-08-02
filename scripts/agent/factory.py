#!/usr/bin/env python3
"""The kudos compile factory.

kudos carries no compiler (spec ARCH-012). The agent generates Zig source and
sends it here; this host service compiles it off-target into a `.kudos` binary —
a flat, position-independent image the kernel loader verifies and runs. Same
philosophy as the committed shader-blob factory: the heavy, secret-free build
lives on the host.

Two ways in:
  - `factory.py compile app.zig -o app.kudos [--kind app]` — one-shot CLI, used
    by the tests.
  - `factory.py serve [--host H] [--port P] [--workspace DIR]` — an HTTP endpoint
    the kernel POSTs to over the LAN. With a workspace, the source of every
    successful build is kept and served read-only (GET /sources, /sources/<name>,
    /abi) so the agent can list, reread, and update its own modules. Setting
    FACTORY_TOKEN requires POSTs to carry a matching X-Factory-Token header.

The `.kudos` header is stamped to match `src/kernel/loader/abi.zig` exactly (magic,
version, kind, code_len, mem_len, CRC-32). Those constants are PARSED from that
file so the factory and the kernel can never disagree.
"""

import argparse
import binascii
import http.server
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ABI_ZIG = os.path.join(REPO_ROOT, "src", "kernel", "loader", "abi.zig")
HARNESS_DIR = os.path.join(os.path.dirname(__file__), "harness")

ZIG = os.environ.get("ZIG", "zig")
BUILD_TIMEOUT_S = 30
HEADER_SIZE = 24  # six u32 fields; asserted against abi.zig below

# Module names become workspace file names and URL path segments, so the set of
# accepted names is the path-traversal guard: lowercase identifier, bounded.
NAME_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")

# Distinct outcomes the caller (and the tests) branch on.
STAGE_OK = "ok"
STAGE_COMPILE = "compile_error"   # zig rejected the source -> HTTP 422
STAGE_RELOC = "not_position_independent"  # leftover relocations -> HTTP 422
STAGE_INTERNAL = "internal"       # a factory/tool failure -> HTTP 500


class AbiError(RuntimeError):
    pass


def parse_abi():
    """Read magic/version/kinds and the header field count from abi.zig."""
    src = open(ABI_ZIG).read()

    def const_u32(name):
        m = re.search(r"pub const %s: u32 = (0x[0-9a-fA-F_]+|\d+);" % name, src)
        if not m:
            raise AbiError("abi.zig: missing %s" % name)
        return int(m.group(1).replace("_", ""), 0)

    magic = const_u32("ABI_MAGIC")
    version = const_u32("ABI_VERSION")

    kinds = {}
    for km in re.finditer(r"(\w+)\s*=\s*(\d+)\s*,", src[src.index("pub const Kind"):]):
        kinds[km.group(1)] = int(km.group(2))
        if km.group(1) == "feature":
            break

    # Guard the header layout the Python packer assumes (six u32 fields).
    hdr = re.search(r"pub const Header = extern struct \{(.*?)\};", src, re.S).group(1)
    nfields = len(re.findall(r"^\s*\w+:\s*u32,", hdr, re.M))
    if nfields * 4 != HEADER_SIZE:
        raise AbiError("abi.zig Header changed shape (%d u32 fields); update factory" % nfields)

    return {"magic": magic, "version": version, "kinds": kinds}


def _strip_paths(text, workdir):
    """Make compiler output reproducible/safe: drop the temp workdir prefix."""
    return text.replace(workdir + os.sep, "").replace(workdir, "")


def _readelf_has_relocations(elf):
    out = subprocess.check_output(["readelf", "-r", elf], text=True)
    return bool(re.search(r"R_X86_64", out))


def _image_mem_len(elf):
    """Total loaded size incl. the zeroed .bss tail = max(addr+size) over ALLOC
    sections, aligned to 16 (matches app.ld's __image_end)."""
    out = subprocess.check_output(["readelf", "-SW", elf], text=True)
    end = 0
    for ln in out.splitlines():
        m = re.match(
            r"\s*\[\s*\d+\]\s+(\S+)\s+(\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\S+\s+(\S+)",
            ln,
        )
        if not m:
            continue
        _, _, addr, _, size, flags = m.groups()
        if "A" in flags:
            end = max(end, int(addr, 16) + int(size, 16))
    return (end + 15) & ~15


def stamp(kind_val, code, mem_len, abi):
    """Build the .kudos file bytes: header + code. Mirrors abi.writeHeader."""
    assert mem_len >= len(code)
    crc = binascii.crc32(code) & 0xFFFFFFFF
    header = struct.pack(
        "<6I", abi["magic"], abi["version"], kind_val, len(code), mem_len, crc
    )
    return header + code


def compile_kudos(source, kind="app", name="app", abi=None):
    """Compile `source` (Zig text) into a .kudos blob.

    Returns a dict: {stage, ok, blob?, errors?}. `stage` is one of the STAGE_*
    constants so callers map cleanly to HTTP status.
    """
    abi = abi or parse_abi()
    if kind not in abi["kinds"]:
        return {"stage": STAGE_INTERNAL, "ok": False, "errors": "unknown kind %r" % kind}

    harness = "harness.zig" if kind == "app" else "harness_feature.zig"
    work = tempfile.mkdtemp(prefix="kudos-factory-")
    try:
        shutil.copy(ABI_ZIG, os.path.join(work, "abi.zig"))
        shutil.copy(os.path.join(HARNESS_DIR, harness), os.path.join(work, "harness.zig"))
        shutil.copy(os.path.join(HARNESS_DIR, "app.ld"), os.path.join(work, "app.ld"))
        with open(os.path.join(work, "app.zig"), "w") as f:
            f.write(source)

        elf = os.path.join(work, "app.elf")
        cmd = [
            ZIG, "build-exe", "harness.zig",
            "-target", "x86_64-freestanding", "-mcpu", "x86_64",
            # -fPIE (not -fPIC): the image is a position-independent executable, so
            # any ABSOLUTE address the code needs (a pointer-to-global, a
            # function-pointer table) becomes a load-time relocation we can see and
            # reject below. A fixed-address non-PIE link would instead bake those
            # absolute addresses in silently and break when loaded off VMA 0.
            "-O", "ReleaseSmall", "-fPIE", "-mno-red-zone", "-fno-stack-protector",
            "-T", "app.ld", "--name", "app", "-femit-bin=app.elf",
        ]
        try:
            proc = subprocess.run(
                cmd, cwd=work, capture_output=True, text=True, timeout=BUILD_TIMEOUT_S
            )
        except subprocess.TimeoutExpired:
            return {"stage": STAGE_COMPILE, "ok": False,
                    "errors": "compile timed out after %ds" % BUILD_TIMEOUT_S}
        if proc.returncode != 0 or not os.path.exists(elf):
            return {"stage": STAGE_COMPILE, "ok": False,
                    "errors": _strip_paths(proc.stderr.strip(), work)}

        # Position-independence is proven here, not fixed up in the kernel.
        if _readelf_has_relocations(elf):
            return {"stage": STAGE_RELOC, "ok": False,
                    "errors": "image has load-time relocations; avoid pointers to "
                              "globals / absolute addresses so the code is position-independent"}

        mem_len = _image_mem_len(elf)
        binpath = os.path.join(work, "app.bin")
        subprocess.check_call([ZIG, "objcopy", "-O", "binary", elf, binpath])
        code = open(binpath, "rb").read()
        if mem_len < len(code):
            mem_len = (len(code) + 15) & ~15
        blob = stamp(abi["kinds"][kind], code, mem_len, abi)
        return {"stage": STAGE_OK, "ok": True, "blob": blob}
    except (subprocess.CalledProcessError, OSError) as e:
        return {"stage": STAGE_INTERNAL, "ok": False, "errors": str(e)}
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ── HTTP surface ────────────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):
    abi = None        # set by serve()
    workspace = None  # dir persisting agent-authored sources; None = stateless
    token = None      # when set, POSTs must carry X-Factory-Token: <token>

    def log_message(self, *a):
        pass  # quiet; the caller has its own logging

    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def _chat(self):
        """Relay a chat-completions request to the LLM over TLS (the host does
        TLS; kudos speaks plain HTTP to us). The API key comes from the
        OPENROUTER_API_KEY environment or the `X-Api-Key` header; the upstream
        URL from OPENROUTER_URL (default OpenRouter). This is the interim path
        until the in-kernel HTTPS client lands."""
        import urllib.request
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        key = self.headers.get("X-Api-Key") or os.environ.get("OPENROUTER_API_KEY", "")
        url = os.environ.get("OPENROUTER_URL", "https://openrouter.ai/api/v1/chat/completions")
        req = urllib.request.Request(url, data=body, method="POST", headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
        })
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                out = r.read()
            self._send(200, out, "application/json")
        except Exception as e:  # noqa: BLE001
            self._json(502, {"error": "relay failed: %s" % e})

    def _source_entries(self):
        """The workspace's modules: [{"name","kind","bytes"}], sorted by name."""
        entries = []
        if self.workspace and os.path.isdir(self.workspace):
            for fn in sorted(os.listdir(self.workspace)):
                if not fn.endswith(".zig"):
                    continue
                name = fn[:-len(".zig")]
                kind = "app"
                meta = os.path.join(self.workspace, name + ".json")
                if os.path.exists(meta):
                    kind = json.load(open(meta)).get("kind", "app")
                entries.append({"name": name, "kind": kind,
                                "bytes": os.path.getsize(os.path.join(self.workspace, fn))})
        return entries

    def do_GET(self):
        """Read-only source visibility for the agent: the ABI contract and the
        sources it authored earlier. Plain-text bodies so the kernel can feed
        them to the model verbatim."""
        if self.path == "/abi":
            self._send(200, open(ABI_ZIG, "rb").read(), "text/plain")
        elif self.path == "/sources":
            self._json(200, self._source_entries())
        elif self.path.startswith("/sources/"):
            name = self.path[len("/sources/"):]
            if not NAME_RE.match(name):
                self._json(400, {"error": "bad module name"})
                return
            src = os.path.join(self.workspace or "", name + ".zig")
            if self.workspace and os.path.exists(src):
                self._send(200, open(src, "rb").read(), "text/plain")
            else:
                self._json(404, {"error": "no such source"})
        else:
            self._json(404, {"error": "unknown endpoint"})

    def _persist(self, name, kind, source):
        """Keep the source of a successful build so the agent can list, reread,
        and update its own modules later. Overwrite IS the update path."""
        os.makedirs(self.workspace, exist_ok=True)
        with open(os.path.join(self.workspace, name + ".zig"), "w") as f:
            f.write(source)
        with open(os.path.join(self.workspace, name + ".json"), "w") as f:
            json.dump({"kind": kind, "abi_version": self.abi["version"]}, f)

    def do_POST(self):
        if self.token and self.headers.get("X-Factory-Token") != self.token:
            self._json(401, {"error": "missing or bad token"})
            return
        if self.path == "/chat":
            return self._chat()
        if self.path != "/compile":
            self._json(404, {"error": "unknown endpoint"})
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
        except (ValueError, json.JSONDecodeError):
            self._json(400, {"error": "bad request body"})
            return

        if req.get("abi_version") != self.abi["version"]:
            self._json(409, {"error": "abi_version mismatch",
                             "factory_abi_version": self.abi["version"]})
            return

        name = req.get("name", "app")
        kind = req.get("kind", "app")
        if not NAME_RE.match(name):
            self._json(400, {"error": "bad module name"})
            return

        res = compile_kudos(req.get("source", ""), kind=kind, name=name, abi=self.abi)
        if res["ok"]:
            if self.workspace:
                self._persist(name, kind, req.get("source", ""))
            self._send(200, res["blob"], "application/octet-stream")
        elif res["stage"] in (STAGE_COMPILE, STAGE_RELOC):
            self._json(422, {"stage": res["stage"], "errors": res["errors"]})
        else:
            self._json(500, {"stage": res["stage"], "errors": res["errors"]})


def serve(host, port, workspace=None):
    abi = parse_abi()
    Handler.abi = abi
    Handler.workspace = workspace
    Handler.token = os.environ.get("FACTORY_TOKEN") or None
    httpd = http.server.HTTPServer((host, port), Handler)
    print("factory: serving /compile on %s:%d (abi v%d, magic %#x, workspace %s, auth %s)"
          % (host, port, abi["version"], abi["magic"],
             workspace or "none", "token" if Handler.token else "open"))
    httpd.serve_forever()


def main(argv=None):
    ap = argparse.ArgumentParser(description="kudos .kudos compile factory")
    sub = ap.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("compile", help="compile one source file to a .kudos")
    c.add_argument("source")
    c.add_argument("-o", "--out", required=True)
    c.add_argument("--kind", default="app", choices=["app", "feature"])
    c.add_argument("--name", default="app")

    s = sub.add_parser("serve", help="run the HTTP factory")
    s.add_argument("--host", default="0.0.0.0")
    s.add_argument("--port", type=int, default=8623)
    s.add_argument("--workspace", default=None,
                   help="dir persisting agent-authored sources (served at /sources)")

    args = ap.parse_args(argv)
    if args.cmd == "serve":
        serve(args.host, args.port, workspace=args.workspace)
        return 0

    # compile
    abi = parse_abi()
    src = open(args.source).read()
    res = compile_kudos(src, kind=args.kind, name=args.name, abi=abi)
    if res["ok"]:
        with open(args.out, "wb") as f:
            f.write(res["blob"])
        print("wrote %s (%d bytes, kind=%s)" % (args.out, len(res["blob"]), args.kind))
        return 0
    sys.stderr.write("[%s]\n%s\n" % (res["stage"], res["errors"]))
    return 1


if __name__ == "__main__":
    sys.exit(main())
