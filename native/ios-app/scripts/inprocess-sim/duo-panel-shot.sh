#!/bin/bash
# Run against this checkout or an older native source directory, using a booted iOS simulator.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NATIVE="${2:-$HERE/../../Poki/Native}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios26.0-simulator -isysroot "$SDK" \
  -fobjc-arc -fmodules -Wall -Werror -Wno-deprecated-declarations -I "$NATIVE" \
  "$HERE/duo-panel-shot.m" "$NATIVE/InProcess.m" "$NATIVE/RecoveredNative.m" \
  -framework UIKit -o "$WORK/duo-panel-shot"
SIMCTL_CHILD_SIMULATOR_MODEL_IDENTIFIER=iPhone19,4 xcrun simctl spawn "${1:?supply a booted simulator UDID}" "$WORK/duo-panel-shot"
