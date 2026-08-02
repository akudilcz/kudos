#!/usr/bin/env bash
# Validate every glTF asset kudos ships against the Khronos glTF Validator
# (spec R123). The validator is the reference spec-conformance checker; run it
# over assets/models/*.glb and the in-kernel seed models so a malformed file is
# caught before it ships.
#
# Two layers, both REQUIRED:
#   1. glbcheck — the kernel's OWN parser (src/ui/assets/glb.zig) over every
#      asset. This is what actually loads models on the device, so a pass here
#      means the shipped parser accepts the asset; a fail blocks. On-target load
#      is exercised separately by the model sweep and boot-2.
#   2. gltf_validator — Khronos' reference spec validator, the standards
#      authority TEST-007 names. REQUIRED: a missing validator is a setup
#      failure (scripts/setup.sh installs it), never a silent skip — a gate
#      that waves assets through when its checker is absent is not a gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# Both container forms ship: binary .glb, and self-contained .gltf (JSON with
# data-URI buffers — the geometry-tier Triangle/SimpleMeshes models upstream
# provide no .glb). Both load through the same kudos parser and both must
# validate. `nullglob` so a form with no files contributes nothing, not a
# literal unexpanded pattern.
shopt -s nullglob
ASSETS=(assets/models/*.glb assets/models/*.gltf src/ui/assets/*.glb)
shopt -u nullglob

# 1. glbcheck — build it if needed, then vet every asset through the real loader.
echo "gltf-validate: glbcheck (the kernel's own parser) over every asset ..."
zig build glbcheck -p build --cache-dir build/.zig-cache >/dev/null
if ! build/bin/glbcheck "${ASSETS[@]}"; then
    echo "gltf-validate: FAIL — an asset does not parse through the kudos loader" >&2
    exit 1
fi

# 2. gltf_validator — the Khronos spec validator. REQUIRED.
VALIDATOR="$(command -v gltf_validator || command -v gltf-validator || true)"
if [ -z "$VALIDATOR" ]; then
    echo "gltf-validate: FAIL — the Khronos gltf_validator is not installed." >&2
    echo "  It is the spec-conformance authority TEST-007 requires. Install it:" >&2
    echo "      scripts/setup.sh    (fetches the pinned, checksum-verified release)" >&2
    exit 1
fi

echo "gltf-validate: Khronos gltf_validator ($VALIDATOR) over every asset ..."
fail=0
for f in "${ASSETS[@]}"; do
    # -a: assert no errors (issues.numErrors must be 0); -o -: report to stdout.
    if ! "$VALIDATOR" -a "$f" >/dev/null 2>&1; then
        echo "gltf-validate: FAIL — $f has glTF validation errors:" >&2
        "$VALIDATOR" "$f" 2>&1 | grep -iE "error|severity" | head -5 >&2 || true
        fail=1
    fi
done
[ "$fail" -eq 0 ] || exit 1
echo "gltf-validate: PASS — every shipped glTF asset validates."
