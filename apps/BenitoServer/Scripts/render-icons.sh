#!/usr/bin/env bash
# Regenerate the app icon PNGs and the menu bar image from Resources/Design/*.svg.
# Needs rsvg-convert (brew install librsvg). Run after changing either SVG or the iPhone app's icon.
set -euo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
DESIGN="$APP/Resources/Design"
ASSETS="$APP/Resources/Assets.xcassets"
IOS_ICON="$APP/../Benito/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

# rsvg-convert only loads images that sit next to the SVG.
cp "$IOS_ICON" "$DESIGN/benito-ios-icon.png"
trap 'rm -f "$DESIGN/benito-ios-icon.png"' EXIT

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" "$DESIGN/AppIcon.svg" -o "$ASSETS/AppIcon.appiconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" "$DESIGN/AppIcon.svg" -o "$ASSETS/AppIcon.appiconset/icon_${size}x${size}@2x.png"
done
cp "$DESIGN/MenuBarIcon.svg" "$ASSETS/MenuBarIcon.imageset/MenuBarIcon.svg"
