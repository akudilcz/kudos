#!/usr/bin/env bash
# Bless the render-oracle frames: copy the freshly rendered
# build/renders/*.ppm over the committed goldens in test/ui/assets/fixtures/renders/.
#
# Run this ONLY after inspecting the fresh frames (they are P6 PPM — any
# image viewer opens them): the goldens ARE the reference renderings the
# host suite holds the pipeline to (spec TEST-006), so blessing an
# uninspected frame turns a rendering bug into the standard.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/build/renders"
DST="$ROOT/test/ui/assets/fixtures/renders"
[ -d "$SRC" ] || { echo "bless_renders: no $SRC — run: zig build test" >&2; exit 1; }
mkdir -p "$DST"
# Only the regression-pose frames are goldens; the *.conformance.ppm frames are
# judged against the PUBLISHED Khronos screenshots (test/ui/assets/fixtures/reference)
# and must never be blessed.
for f in "$SRC"/*.ppm; do
    case "$f" in *.conformance.ppm) continue ;; esac
    cp -v "$f" "$DST"/
done
echo "bless_renders: done — review 'git diff --stat $DST' and commit."
