#!/bin/bash
# Convert the provided logo to all standard macOS icon sizes, preserving its design.
set -euo pipefail
cd "$(dirname "$0")/.."
ICONSET="build/logo.iconset"
mkdir -p build
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" ProxyBridge/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size*2))
    sips -z "$doubled" "$doubled" ProxyBridge/Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o ProxyBridge/Resources/ProxyBridge.icns
