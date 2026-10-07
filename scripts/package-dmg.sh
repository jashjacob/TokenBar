#!/bin/zsh
set -euo pipefail

# Drag-and-drop disk image: TokenBar.app + Applications shortcut.
# Run after ./scripts/package-app.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist.noindex/TokenBar.app"
INFO="$ROOT/Sources/TokenBar/AppInfo.swift"
STAGE="$ROOT/dist.noindex/dmg"
TMP="$ROOT/dist.noindex/TokenBar.rw.dmg"

plist_value() {
  sed -n "s/.*static let $1 = \"\\(.*\\)\".*/\\1/p" "$INFO" | head -1
}

VERSION="$(plist_value version)"
BUILD="$(plist_value build)"
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
  echo "could not read version/build from $INFO" >&2
  exit 1
fi

if [[ ! -d "$APP" ]]; then
  echo "missing $APP — run: swift build -c release && ./scripts/package-app.sh" >&2
  exit 1
fi

DMG="$ROOT/dist.noindex/TokenBar-${VERSION}.dmg"
VOL="TokenBar ${VERSION}"

rm -rf "$STAGE" "$TMP" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/TokenBar.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

rm -rf "$STAGE"
echo "built $DMG  $VERSION ($BUILD)"
ls -lh "$DMG"
