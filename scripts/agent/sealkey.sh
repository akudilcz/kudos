#!/usr/bin/env bash
# Seal the agent's OpenRouter credential into the image (spec AGT-017).
#
# The kernel carries the sealed envelope and opens it with the build's
# passphrase, so the agent works on a machine with no USB stick — every emulator
# run, and any laptop. The plaintext credential never touches the repository:
# what lands in secrets/ is ciphertext, and secrets/ is not tracked.
#
# WHAT THIS DOES AND DOES NOT BUY. It keeps the credential from being a string
# anybody can grep out of the source tree, the built kernel or a core dump. It
# does NOT keep out someone holding both the image and the passphrase — if the
# passphrase is baked into the same build (the default, -Dagent-password), the
# pair is openable by anyone with the ISO. Treat a shared image as a shared key.
#
#   seal   read the credential on stdin, write the sealed envelope
#   show   report what the current envelope is (never its plaintext)
#
# Usage:
#   scripts/agent/sealkey.sh seal [passphrase]   # credential on stdin
#   scripts/agent/sealkey.sh show
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/secrets/agent-key.b64"
DEFAULT_PASSPHRASE="welcome"

cmd_seal() {
    local passphrase="${1:-$DEFAULT_PASSPHRASE}"
    mkdir -p "$ROOT/secrets"
    # Build the sealer against the kernel's own keystore module: one definition
    # of the envelope format, not a host copy that drifts from it.
    local exe="${TMPDIR:-/tmp}/kudos_sealkey"
    zig build-exe -OReleaseSafe \
        --dep keystore \
        -Mroot="$ROOT/scripts/agent/sealkey.zig" \
        -Mkeystore="$ROOT/src/agent/keystore.zig" \
        -femit-bin="$exe" >/dev/null

    # 0600 BEFORE anything is written: the file is ciphertext, but a
    # world-readable secrets directory is a habit worth not forming.
    umask 077
    "$exe" "$passphrase" > "$OUT"
    echo "sealed -> ${OUT#"$ROOT"/}  ($(wc -c < "$OUT") bytes of base64)"
    echo "rebuild to embed it:  zig build -Dagent-key=\"\$(cat ${OUT#"$ROOT"/})\""
    echo "or just:              make iso   (build.zig reads secrets/agent-key.b64)"
}

cmd_show() {
    if [[ ! -f "$OUT" ]]; then
        echo "no sealed credential (${OUT#"$ROOT"/} does not exist)"
        echo "create one:  scripts/agent/sealkey.sh seal < key.txt"
        exit 1
    fi
    echo "envelope: ${OUT#"$ROOT"/}"
    echo "size:     $(wc -c < "$OUT") bytes of base64"
    echo "sha256:   $(sha256sum < "$OUT" | cut -d' ' -f1)"
}

case "${1:-}" in
    seal) shift; cmd_seal "$@" ;;
    show) cmd_show ;;
    *) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
