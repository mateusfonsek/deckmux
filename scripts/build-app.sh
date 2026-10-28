#!/usr/bin/env bash
# Builds Deckmux with SwiftPM and assembles build/app.noindex/Deckmux.app (ad-hoc signed).
# Usage: scripts/build-app.sh [debug|release] [--open]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
"$ROOT/scripts/ensure-ghosttykit.sh"

swift build --package-path "$ROOT" -c "$CONFIG"
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/Deckmux"

# Spotlight (and so Launchpad and the Apps list) skips folders ending in
# .noindex, so this copy never shows up next to the installed one in
# /Applications.
APP="$ROOT/build/app.noindex/Deckmux.app"
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Deckmux"
# SwiftPM resource bundles (Bonsplit's localized strings and assets).
for bundle in "$(dirname "$BIN")"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon (Icon Composer document) and the neutral accent color
# → Assets.car + AppIcon.icns.
xcrun actool "$ROOT/Resources/AppIcon/AppIcon.icon" "$ROOT/Resources/Assets.xcassets" \
  --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --accent-color AccentColor \
  --output-partial-info-plist "$ROOT/build/icon-partial.plist" >/dev/null
# actool's AppIcon.icns only carries 16–256 px. Stage Manager, the app
# switcher and Finder previews read the .icns at 512–1024 px and showed no icon,
# so it is rebuilt with every size from the same Icon Composer document.
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [ -x "$ICTOOL" ]; then
  ICONSET="$ROOT/build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  "$ICTOOL" "$ROOT/Resources/AppIcon/AppIcon.icon" --export-image --output-file "$ROOT/build/AppIcon-1024.png" \
    --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
cp -R "$ROOT/Resources/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$ROOT/Resources/shell-integration" "$APP/Contents/Resources/shell-integration"
# The claude wrapper and the `deckmux` CLI its hooks call.
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT/Resources/bin/claude" "$APP/Contents/Resources/bin/claude"
cp "$(dirname "$BIN")/DeckmuxCLI" "$APP/Contents/Resources/bin/deckmux"
# libghostty sets TERMINFO to the directory next to its resources dir.
cp -R "$ROOT/Resources/terminfo" "$APP/Contents/Resources/terminfo"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${2:-}" = "--open" ]; then
  open "$APP"
fi
