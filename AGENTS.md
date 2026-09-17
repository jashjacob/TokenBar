# TokenBar — agent notes

Native macOS Touch Bar companion. Polls TokenTracker on `127.0.0.1`; do not clone TokenTracker.

## Install and setup

Follow **For coding agents** in [README.md](README.md). Short version:

1. Confirm a Touch Bar Mac and macOS 13+.
2. TokenTracker must return HTTP 200 on `http://127.0.0.1:7680/functions/tokentracker-usage-limits` before TokenBar.
3. Do **not** use the GitHub DMG (ad-hoc signed; Gatekeeper blocks downloads).
4. From this repo: `./scripts/install.sh` (needs `swift` from Xcode Command Line Tools, not full Xcode).
5. Check `pgrep -x TokenBar` and `~/Library/Logs/TokenBar.log`.

Do not change `codesign` to an Apple Development identity. Do not vendor TokenTracker.

## Layout

Quota chips live in `Sources/TokenBar/TouchBarStripView.swift` and `ChipLayout.swift`. Widths hug each chip’s text and must stay within the strip bounds (`clipsToBounds`).
