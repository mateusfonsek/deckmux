#!/usr/bin/env bash
# Downloads the pinned prebuilt GhosttyKit.xcframework, verifies its checksum
# and layout, and extracts it to Frameworks/. Adapted from cmux's
# scripts/download-prebuilt-ghosttykit.sh (GPL-3.0-or-later).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/ghostty.env"

OUT="$ROOT/Frameworks/GhosttyKit.xcframework"
STAMP="$OUT/.deckmux-sha256"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/deckmux/ghosttykit"
ARCHIVE="$CACHE_DIR/$GHOSTTYKIT_SHA256.tar.gz"
URL="https://github.com/manaflow-ai/ghostty/releases/download/xcframework-$GHOSTTY_SHA-$GHOSTTYKIT_FLAVOR/GhosttyKit.xcframework.tar.gz"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$GHOSTTYKIT_SHA256" ]; then
  echo "GhosttyKit up to date ($GHOSTTY_SHA)"
  exit 0
fi

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$CACHE_DIR"
if [ ! -f "$ARCHIVE" ] || [ "$(sha_of "$ARCHIVE")" != "$GHOSTTYKIT_SHA256" ]; then
  echo "Downloading GhosttyKit for ghostty $GHOSTTY_SHA"
  partial="$ARCHIVE.partial"
  for attempt in 1 2 3 4 5; do
    # --continue-at resumes a partial download instead of starting over.
    if curl --fail --show-error --location --connect-timeout 10 \
        --speed-limit 262144 --speed-time 15 --continue-at - \
        -o "$partial" "$URL"; then
      break
    fi
    [ "$attempt" -eq 5 ] && { echo "Download failed" >&2; exit 1; }
    sleep 5
  done
  mv -f "$partial" "$ARCHIVE"
fi

actual="$(sha_of "$ARCHIVE")"
if [ "$actual" != "$GHOSTTYKIT_SHA256" ]; then
  rm -f "$ARCHIVE"
  echo "Checksum mismatch: expected $GHOSTTYKIT_SHA256, got $actual" >&2
  exit 1
fi
python3 -I "$ROOT/scripts/validate-xcframework-archive.py" "$ARCHIVE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tar --no-same-owner -xzf "$ARCHIVE" -C "$tmp"
xcf="$tmp/GhosttyKit.xcframework"
# Keep only the macOS slice, and give its archive the "lib" prefix SwiftPM requires.
python3 -I - "$xcf" <<'PY'
import plistlib, shutil, sys
from pathlib import Path
xcf = Path(sys.argv[1])
info_path = xcf / "Info.plist"
info = plistlib.loads(info_path.read_bytes())
kept = []
for lib in info["AvailableLibraries"]:
    slice_dir = xcf / lib["LibraryIdentifier"]
    if lib["SupportedPlatform"] != "macos":
        shutil.rmtree(slice_dir)
        continue
    name = lib["LibraryPath"]
    if not name.startswith("lib"):
        (slice_dir / name).rename(slice_dir / ("lib" + name))
        lib["LibraryPath"] = lib["BinaryPath"] = "lib" + name
    kept.append(lib)
info["AvailableLibraries"] = kept
info_path.write_bytes(plistlib.dumps(info))
PY
# Xcode 26's linker rejects the archive's symbol table until it is re-indexed.
find "$xcf" -name '*.a' -exec ranlib {} \;
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$tmp/GhosttyKit.xcframework" "$OUT"
printf '%s' "$GHOSTTYKIT_SHA256" > "$STAMP"
echo "GhosttyKit ready at Frameworks/GhosttyKit.xcframework"
