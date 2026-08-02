#!/usr/bin/env python3
"""netdebug CLI — remote-control a running kudos.

Usage:
  netdebug.py shot  [dir] [--ip GUEST_IP]           full-res screenshot -> download -> print path (default assets/screenshots/)
  netdebug.py key   <text> [--ip GUEST_IP]          type text (one keystroke per char, ASCII)
  netdebug.py mouse <dx> <dy> [--buttons N] [--ip GUEST_IP]   relative motion + button mask

Protocol + client: scripts/tools/netdebug-mcp/kmir.py.
Exit code 0 only on full success.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "netdebug-mcp"))
import kmir  # noqa: E402


def main():
    ap = argparse.ArgumentParser(prog="netdebug.py")
    ap.add_argument("--ip", default=None, help="guest IP (default: auto-discover)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_shot = sub.add_parser("shot", help="screenshot -> download -> print path")
    p_shot.add_argument("dir", nargs="?", default="assets/screenshots")

    p_key = sub.add_parser("key", help="type text into kudos")
    p_key.add_argument("text")

    p_mouse = sub.add_parser("mouse", help="relative pointer motion")
    p_mouse.add_argument("dx", type=int)
    p_mouse.add_argument("dy", type=int)
    p_mouse.add_argument("--buttons", type=int, default=0,
                         help="button mask: bit0 L, bit1 R, bit2 M (default 0)")

    args = ap.parse_args()
    client = kmir.Client(kmir.discover_ip(args.ip))

    if args.cmd == "shot":
        path = client.screenshot(args.dir)
        print(path)
        return 0

    if args.cmd == "key":
        for ch in args.text:
            client.inject_key(ord(ch))
        print(f"typed {len(args.text)} key(s)")
        return 0

    if args.cmd == "mouse":
        client.inject_mouse(args.dx, args.dy, args.buttons)
        print(f"mouse dx={args.dx} dy={args.dy} buttons={args.buttons:#05b}")
        return 0

    raise AssertionError("unreachable")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except kmir.KmirError as e:
        print(f"netdebug: {e}", file=sys.stderr)
        sys.exit(1)
