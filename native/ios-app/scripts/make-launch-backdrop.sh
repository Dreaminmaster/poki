#!/bin/bash
# make-launch-backdrop.sh SIMULATOR_UDID POKI_APP: draws the home page's light at rest with Poki's own
# HomeBackdrop, in light and in dark, in a Debug build of Poki.app on a booted simulator, and writes
# Poki/LaunchArt/LaunchBackdrop.png and LaunchBackdropDark.png for the launch screen. Run it again
# whenever the home page's light changes, then scripts/make-assets.sh.
set -euo pipefail
UDID="$1"
APP="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
CACHES="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Caches"
rm -f "$CACHES/LaunchBackdrop.png" "$CACHES/LaunchBackdropDark.png"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE" -pokiLaunchBackdrop YES >/dev/null
for _ in $(seq 30); do [ -s "$CACHES/LaunchBackdropDark.png" ] && break; sleep 1; done
for name in LaunchBackdrop LaunchBackdropDark; do
  [ -s "$CACHES/$name.png" ] || { echo "Poki wrote no $name.png (a Debug build is needed)" >&2; exit 1; }
  cp "$CACHES/$name.png" "$HERE/Poki/LaunchArt/$name.png"
  echo "wrote $HERE/Poki/LaunchArt/$name.png"
done
