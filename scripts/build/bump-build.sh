#!/usr/bin/env bash
# Increment the build number and print "<number> <githash> <utc-iso8601>" on one
# line. The number lives in BUILD_NUMBER (single source of truth); the hash is the
# current git commit with a trailing '+' when the working tree is dirty; the
# timestamp is the moment this build was configured (UTC), captured ONCE here so
# the kernel carries the true compile time (a later read-only reporter cannot
# reconstruct it). Invoked by build.zig before compiling the kernel.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
file="$root/BUILD_NUMBER"

if [[ ! -f "$file" ]]; then
    echo "bump-build: $file not found (expected the build-number file)" >&2
    exit 1
fi

cur="$(tr -d '[:space:]' < "$file")"
if ! [[ "$cur" =~ ^[0-9]+$ ]]; then
    echo "bump-build: $file does not contain an integer (found: '$cur')" >&2
    exit 1
fi

next=$((cur + 1))
printf '%s\n' "$next" > "$file"

hash="$(git -C "$root" rev-parse --short HEAD)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
    hash="${hash}+"
fi

stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '%s %s %s\n' "$next" "$hash" "$stamp"
