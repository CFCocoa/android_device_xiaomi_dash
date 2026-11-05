#!/bin/bash
#
# SPDX-License-Identifier: Apache-2.0
#
# Extract the stock inputs listed in proprietary-files.txt from an unpacked
# fastboot ROM into vendor/xiaomi/dash.
#
# Usage: ./extract-files.sh [--force] <fastboot-rom-images-dir> [vendor-dir]
#
#   <fastboot-rom-images-dir>  the ROM's images/ directory (vendor_boot.img, super.img)
#   [vendor-dir]               default: <android-root>/vendor/xiaomi/dash
#   --force                    install files whose SHA-1 differs from the pin
#
# Needs unpack_bootimg, lz4, 7z (with LP/sparse support) and dump.erofs (with --cat).
# Set TMPDIR to put the temporary copies of the partitions (a few GB) elsewhere.

set -euo pipefail

MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${MY_DIR}/proprietary-files.txt"

FORCE=false
if [ "${1:-}" = "--force" ]; then
    FORCE=true
    shift
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n '8,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
fi

IMAGES="$(cd "$1" && pwd)"
VENDOR="${2:-${MY_DIR}/../../../vendor/xiaomi/dash}"

for tool in unpack_bootimg lz4 7z dump.erofs sha1sum; do
    command -v "$tool" > /dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
[ -d "$VENDOR" ] || { echo "Vendor directory not found: $VENDOR" >&2; exit 1; }
VENDOR="$(cd "$VENDOR" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dash-extract.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE"

# Read the list once: one "source|destination|sha1" record per entry.
ENTRIES=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [ -n "$line" ] || continue
    spec="${line%%|*}"
    sha1=""
    [ "$spec" != "$line" ] && sha1="${line#*|}"
    src="${spec%%:*}"
    dst="proprietary/$src"
    [ "$src" != "$spec" ] && dst="${spec#*:}"
    ENTRIES+=("$src|$dst|$sha1")
done < "$LIST"

needs() {
    local e
    for e in "${ENTRIES[@]}"; do
        case "$e" in "$1"/*) return 0 ;; esac
    done
    return 1
}

if needs vendor_boot || needs vendor_ramdisk00; then
    echo "Unpacking vendor_boot.img"
    unpack_bootimg --boot_img "$IMAGES/vendor_boot.img" --out "$WORK/vendor_boot" > /dev/null
fi
if needs vendor_ramdisk00; then
    lz4 -dcf "$WORK/vendor_boot/vendor_ramdisk00" > "$WORK/vendor_ramdisk00.cpio"
fi

PARTITIONS=()
for p in odm system_ext; do
    needs "$p" && PARTITIONS+=("$p")
done
if [ ${#PARTITIONS[@]} -gt 0 ]; then
    echo "Extracting ${PARTITIONS[*]} from super.img"
    names=()
    for p in "${PARTITIONS[@]}"; do names+=("${p}_a.img"); done
    (cd "$IMAGES" && 7z x -y -o"$WORK" super.img "${names[@]}" > /dev/null)
fi

extract() {
    local src="$1" out="$2" image="${1%%/*}" path="${1#*/}"
    mkdir -p "$(dirname "$out")"
    case "$image" in
        vendor_boot)
            cp "$WORK/vendor_boot/$path" "$out" ;;
        vendor_ramdisk00)
            7z x -y -o"$WORK/vendor_ramdisk00" "$WORK/vendor_ramdisk00.cpio" "$path" > /dev/null
            mv "$WORK/vendor_ramdisk00/$path" "$out" ;;
        odm|system_ext)
            dump.erofs --cat --path="/$path" "$WORK/${image}_a.img" > "$out" ;;
        *)
            echo "Unknown source image in $src" >&2; return 1 ;;
    esac
    [ -s "$out" ]
}

changed=0
for e in "${ENTRIES[@]}"; do
    IFS='|' read -r src dst sha1 <<< "$e"
    if ! extract "$src" "$STAGE/$dst"; then
        echo "FAILED  $src" >&2
        exit 1
    fi
    got="$(sha1sum < "$STAGE/$dst" | cut -c1-40)"
    if [ -n "$sha1" ] && [ "$got" != "$sha1" ]; then
        echo "CHANGED $src (pinned $sha1, got $got)"
        changed=$((changed + 1))
    fi
done

if [ $changed -gt 0 ] && ! $FORCE; then
    echo "$changed file(s) differ from their pins; nothing installed. Review them, then update" >&2
    echo "proprietary-files.txt or rerun with --force." >&2
    exit 1
fi

cp -r "$STAGE/." "$VENDOR/"
echo "Installed ${#ENTRIES[@]} files into $VENDOR"
