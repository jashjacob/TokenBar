#!/bin/zsh
set -euo pipefail

# Build TokenBar on this Mac and install it to /Applications.
# Local builds are not quarantined, so Gatekeeper does not block them.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null; then
  echo "Swift is missing. Install Xcode Command Line Tools:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

swift build -c release
./scripts/package-app.sh

if pgrep -x TokenBar >/dev/null; then
  killall TokenBar 2>/dev/null || true
  sleep 0.3
fi

rm -rf /Applications/TokenBar.app
ditto "$ROOT/dist/TokenBar.app" /Applications/TokenBar.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/TokenBar.app >/dev/null
open /Applications/TokenBar.app

echo "installed /Applications/TokenBar.app"
echo "TokenTracker must already be running on http://127.0.0.1:7680"
