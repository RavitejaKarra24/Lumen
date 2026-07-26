#!/usr/bin/env bash
# Generates the ICNS used by the packaged app from the tracked SVG source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${ICON_SOURCE:-$ROOT/Assets/AppIcon.svg}"
OUTPUT="${1:-$ROOT/Icon.icns}"

if [[ ! -f "$SOURCE" ]]; then
  echo "ERROR: Icon source not found: $SOURCE" >&2
  exit 1
fi

for tool in sips iconutil; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool is required to build the app icon. Install Xcode Command Line Tools with: xcode-select --install" >&2
    exit 1
  }
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/Lumen-icon.XXXXXX")"
iconset="$temporary_directory/Lumen.iconset"
mkdir -p "$iconset"
trap 'rm -rf "$temporary_directory"' EXIT

# `sips` can rasterize SVG, but cannot always resize during that conversion.
# Create one lossless PNG first, then resize that image for each icon slot.
sips -s format png "$SOURCE" --out "$iconset/master.png" >/dev/null

sizes=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for entry in "${sizes[@]}"; do
  size="${entry%%:*}"
  filename="${entry#*:}"
  sips --resampleHeightWidth "$size" "$size" "$iconset/master.png" --out "$iconset/$filename" >/dev/null
done

mkdir -p "$(dirname "$OUTPUT")"
rm "$iconset/master.png"
iconutil --convert icns --output "$OUTPUT" "$iconset"
echo "Created $OUTPUT"
