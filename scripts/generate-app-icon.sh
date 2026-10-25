#!/bin/zsh
# Rebuild the macOS icon from the checked-in, transparent 1024px master.
set -eu
cd "$(dirname "$0")/.."
source="$PWD/Assets/AppIcon.png"
[[ -f "$source" ]] || { print -u2 "Missing icon master: $source"; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/lighttable-icon.XXXXXX")
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for points in 16 32 128 256 512; do
    sips -z "$points" "$points" "$source" --out "$iconset/icon_${points}x${points}.png" >/dev/null
    pixels=$((points * 2))
    sips -z "$pixels" "$pixels" "$source" --out "$iconset/icon_${points}x${points}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$PWD/Assets/AppIcon.icns"
printf '%s\n' "$PWD/Assets/AppIcon.icns"
