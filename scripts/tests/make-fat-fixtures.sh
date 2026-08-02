#!/usr/bin/env bash
# Regenerate test/drivers/storage/fixtures/fat32.img.gz + fat16.img.gz — the REAL FAT volumes
# the fat.zig host tests run against. Root not required:
# sfdisk writes the MBR into a plain file, mkfs.vfat formats at the partition
# offset, mtools populates it. Content is deterministic where it matters
# (file bytes); run from the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
FIX=test/drivers/storage/fixtures

# The standard content set fat_test.zig's checkVolume expects: 8.3 name,
# multi-slot LFN, a subdirectory tree, a real .glb (the duck — end-to-end
# show path), and a >500-cluster patterned file for chain-walk integrity.
populate() { # $1 img@@offset  $2 hello_text
    echo "hello from $2" > /tmp/fatfix_hello.txt
    python3 - <<'EOF'
open('/tmp/fatfix_pattern.bin','wb').write(bytes((i*7 + (i>>8)*13) & 0xff for i in range(300*1024)))
EOF
    MTOOLS_SKIP_CHECK=1 mcopy -i "$1" /tmp/fatfix_hello.txt ::HELLO.TXT
    MTOOLS_SKIP_CHECK=1 mcopy -i "$1" /tmp/fatfix_hello.txt "::a-much-longer-file-name.txt"
    MTOOLS_SKIP_CHECK=1 mcopy -i "$1" /tmp/fatfix_pattern.bin ::pattern.bin
    MTOOLS_SKIP_CHECK=1 mmd   -i "$1" ::models
    MTOOLS_SKIP_CHECK=1 mcopy -i "$1" src/ui/assets/duck.glb ::models/rabbit.glb
    MTOOLS_SKIP_CHECK=1 mmd   -i "$1" ::models/deep
    MTOOLS_SKIP_CHECK=1 mcopy -i "$1" /tmp/fatfix_hello.txt ::models/deep/nested.txt
    rm -f /tmp/fatfix_hello.txt /tmp/fatfix_pattern.bin
}

make_image() { # $1 img  $2 size_mib  $3 mbr_type  $4 mkfs_args
    local img=$1 size=$2 type=$3 mkfs_args=$4
    rm -f "$img"
    truncate -s "${size}M" "$img"
    printf 'label: dos\nstart=2048, type=%s\n' "$type" | sfdisk -q "$img"
    # shellcheck disable=SC2086
    mkfs.vfat $mkfs_args --offset 2048 "$img" >/dev/null
    populate "$img@@$((2048 * 512))" "$type"
    gzip -9 -n -f "$img"
}

# GPT layout mirroring the real kudos boot stick: a
# FAT-formatted EFI System partition (the DECOY the type-GUID selection must
# skip) followed by the Microsoft-basic-data FAT32 data volume.
make_gpt_image() { # $1 img  $2 size_mib
    local img=$1 size=$2
    rm -f "$img"
    truncate -s "${size}M" "$img"
    printf 'label: gpt\nstart=2048, size=32768, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\nstart=34816, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7\n' | sfdisk -q "$img"
    mkfs.vfat -F 16 -n EFIBOOT --offset 2048 "$img" 16384 >/dev/null
    echo "this is the EFI decoy" > /tmp/fatfix_efi.txt
    MTOOLS_SKIP_CHECK=1 mcopy -i "$img@@$((2048 * 512))" /tmp/fatfix_efi.txt ::EFIBOOT.TXT
    rm -f /tmp/fatfix_efi.txt
    mkfs.vfat -F 32 -n KUDOSGPT --offset 34816 "$img" >/dev/null
    populate "$img@@$((34816 * 512))" "gpt"
    gzip -9 -n -f "$img"
}

mkdir -p "$FIX"
make_image "$FIX/fat32.img" 64 0c "-F 32 -n KUDOS32"
make_image "$FIX/fat16.img" 16 06 "-F 16 -n KUDOS16"
make_gpt_image "$FIX/fatgpt.img" 80
ls -la "$FIX"/fat*.gz
