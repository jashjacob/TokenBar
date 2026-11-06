# For coding agents

Don’t download the DMG. Don’t clone TokenTracker unless asked, and don’t copy it into this repo. Keep the ad-hoc signature.

1. Touch Bar Mac, macOS 13+.
2. TokenTracker must return `200` from `http://127.0.0.1:7680/functions/tokentracker-usage-limits` before you install TokenBar.
3. `./scripts/install.sh`
4. Check `pgrep -x TokenBar` and `~/Library/Logs/TokenBar.log`.

Chip layout lives in `TouchBarStripView.swift` and `ChipLayout.swift`. Stay inside the strip (`clipsToBounds`).

The README and the site are for the person using TokenBar. Don’t put thresholds, sort rules, or file layout there.
