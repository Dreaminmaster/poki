#!/bin/bash
# make-launch-backdrop.sh SIMULATOR_UDID POKI_APP: draws the home page's light at rest with Poki's own
# HomeBackdrop, in a Debug build of Poki.app on a booted simulator, and writes it to
# Poki/LaunchArt/LaunchBackdrop.png for the launch screen. Run it again whenever the home page's light
# changes, then scripts/make-assets.sh.
set -euo pipefail
UDID="$1"
APP="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
OUT="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Caches/LaunchBackdrop.png"
rm -f "$OUT"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE" -pokiLaunchBackdrop YES >/dev/null
for _ in $(seq 30); do [ -s "$OUT" ] && break; sleep 1; done
[ -s "$OUT" ] || { echo "Poki wrote no LaunchBackdrop.png (a Debug build is needed)" >&2; exit 1; }
cp "$OUT" "$HERE/Poki/LaunchArt/LaunchBackdrop.png"
echo "wrote $HERE/Poki/LaunchArt/LaunchBackdrop.png"
