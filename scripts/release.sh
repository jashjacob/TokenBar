#!/bin/zsh
set -euo pipefail

# Build the .app and a drag-and-drop .dmg for a GitHub Release.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
./scripts/package-app.sh
./scripts/package-dmg.sh
