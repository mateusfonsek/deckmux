#!/usr/bin/env bash
# Builds the release app and packages it for download: a .dmg (drag to
# Applications) and a .zip, plus SHA256SUMS, in dist/.
# Usage: scripts/package-release.sh [--universal]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/build-app.sh" release "$@"

APP="$ROOT/build/app.noindex/Deckmux.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
# "universal" when the binary carries both Apple Silicon and Intel.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Deckmux")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ARCH=universal ;;
  *) ARCH="$ARCHS" ;;
esac
NAME="Deckmux-$VERSION-$ARCH"
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# ditto keeps the bundle's symlinks, extended attributes and signature intact.
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

# The window with the Deckmux background, built by dmgbuild (no Finder
# scripting, so it works the same in CI). DMGBUILD may point at it; else
# dmgbuild on the PATH, else uvx.
if [ -n "${DMGBUILD:-}" ]; then
  dmgbuild=("$DMGBUILD")
elif command -v dmgbuild >/dev/null; then
  dmgbuild=(dmgbuild)
elif command -v uvx >/dev/null; then
  dmgbuild=(uvx --from "dmgbuild==1.6.7" dmgbuild)
else
  echo "dmgbuild not found: pip install dmgbuild==1.6.7 (or install uv)" >&2
  exit 1
fi
"${dmgbuild[@]}" -s "$ROOT/scripts/dmg-settings.py" -D app="$APP" -D background="$ROOT/Resources/dmg/background.tiff" \
  "Deckmux $VERSION" "$DIST/$NAME.dmg" >/dev/null

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
cat "$DIST/SHA256SUMS"
echo "Packaged $VERSION in $DIST"
