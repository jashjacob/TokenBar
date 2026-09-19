# TokenBar — agent notes

Touch Bar companion. Polls TokenTracker on `127.0.0.1`. Don’t clone TokenTracker.

See **For coding agents** in [README.md](README.md).

1. Touch Bar Mac, macOS 13+.
2. TokenTracker HTTP 200 on `http://127.0.0.1:7680/functions/tokentracker-usage-limits` first.
3. Don’t use the GitHub DMG.
4. `./scripts/install.sh` (needs `swift` from Command Line Tools).
5. `pgrep -x TokenBar` and `~/Library/Logs/TokenBar.log`.

Keep ad-hoc signing. Don’t vendor TokenTracker.

Chip layout: `TouchBarStripView.swift`, `ChipLayout.swift`. Stay inside the strip (`clipsToBounds`).
