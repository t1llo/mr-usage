#!/bin/sh
# Generate a Finder-compatible icon using only the tools included with macOS.
set -eu
cd "$(dirname "$0")/.."
RESOURCES="${1:?Pass the app Resources directory}"
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET" "$RESOURCES"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" docs/assets/app-icon-light.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" docs/assets/app-icon-light.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
cp docs/assets/app-icon-light.png docs/assets/app-icon-dark.png "$RESOURCES/"
rm -rf "$ICONSET"
