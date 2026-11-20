#!/bin/bash
# make-launch-backdrop.sh SIMULATOR_UDID POKI_APP: uses a Debug build of Poki.app to render the still
# home page backdrop for both appearances. Writes both PNGs to Poki/LaunchArt. Run make-assets.sh next.
set -euo pipefail
UDID="$1"
APP="$2"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl install "$UDID" "$APP"
CACHES="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Caches"
OUT="$CACHES/LaunchBackdropDark.png"
rm -f "$CACHES/LaunchBackdrop.png" "$OUT"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl launch "$UDID" "$BUNDLE" -pokiLaunchBackdrop YES >/dev/null
for _ in $(seq 30); do [ -s "$OUT" ] && break; sleep 1; done
for name in LaunchBackdrop LaunchBackdropDark; do
  [ -s "$CACHES/$name.png" ] || { echo "Poki wrote no $name.png (a Debug build is needed)" >&2; exit 1; }
done
for name in LaunchBackdrop LaunchBackdropDark; do
  cp "$CACHES/$name.png" "$HERE/Poki/LaunchArt/$name.png"
  echo "wrote $HERE/Poki/LaunchArt/$name.png"
done
