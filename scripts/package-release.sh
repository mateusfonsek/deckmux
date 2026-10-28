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

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Deckmux.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Deckmux $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DIST/$NAME.dmg" >/dev/null

(cd "$DIST" && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS)
cat "$DIST/SHA256SUMS"
echo "Packaged $VERSION in $DIST"
