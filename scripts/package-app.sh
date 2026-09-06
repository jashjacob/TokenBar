#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/TokenBar"
DIST="$ROOT/dist/TokenBar.app"
ID="com.jashjacob.TokenBar"
INFO="$ROOT/Sources/TokenBar/AppInfo.swift"

plist_value() {
  sed -n "s/.*static let $1 = \"\\(.*\\)\".*/\\1/p" "$INFO" | head -1
}

VERSION="$(plist_value version)"
BUILD="$(plist_value build)"
AUTHOR="$(plist_value author)"
if [[ -z "$VERSION" || -z "$BUILD" || -z "$AUTHOR" ]]; then
  echo "could not read version/build/author from $INFO" >&2
  exit 1
fi

if [[ ! -x "$BIN" ]]; then
  echo "missing $BIN — run: swift build -c release" >&2
  exit 1
fi

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cat > "$DIST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>TokenBar</string>
  <key>CFBundleIdentifier</key>
  <string>${ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>TokenBar</string>
  <key>CFBundleDisplayName</key>
  <string>TokenBar</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD}</string>
  <key>NSHumanReadableCopyright</key>
  <string>Built by ${AUTHOR}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>localhost</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        <true/>
        <key>NSIncludesSubdomains</key>
        <true/>
      </dict>
      <key>127.0.0.1</key>
      <dict>
        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        <true/>
      </dict>
    </dict>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cp "$BIN" "$DIST/Contents/MacOS/TokenBar"
chmod +x "$DIST/Contents/MacOS/TokenBar"

ICONSET="$DIST/Contents/Resources/AppIcon.iconset"
"$BIN" --write-icon "$ICONSET"
iconutil -c icns -o "$DIST/Contents/Resources/AppIcon.icns" "$ICONSET"
rm -rf "$ICONSET"

/usr/bin/codesign --force --sign - --identifier "$ID" "$DIST" >/dev/null

echo "built $DIST  $VERSION ($BUILD)"
