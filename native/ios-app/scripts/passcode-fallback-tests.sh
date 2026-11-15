#!/bin/bash
set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
OUT="${1:?Pass an absolute evidence directory}"
NATIVE="${2:?Pass the simulator directory containing libpoki_launcher.a}"
PACKAGES="${3:?Pass the shared SourcePackages directory}"
mkdir -p "$OUT"
SRC="$(mktemp -d "${TMPDIR:-/tmp}/poki-passcode-fallback.XXXXXX")"
printf '%s\n' "$SRC" > "$OUT/source-location.txt"
git -C "$ROOT" archive HEAD | tar -x -C "$SRC"
git -C "$ROOT" diff --binary HEAD > "$OUT/source.patch"
if [ -s "$OUT/source.patch" ]; then git -C "$SRC" apply "$OUT/source.patch"; fi
python3 - "$SRC" "$OUT" <<'PY'
from pathlib import Path
import difflib
import sys
source, out = map(Path, sys.argv[1:])
p = source / 'native/ios-app/Poki/App/AppModel.swift'
before = p.read_text()
after = before
for condition in [
    'if passcodeExpected, passcodeHeadsUpSeen != BootClock.current, inFront, !Self.onSimulator, !inProcessWarming {',
    'if passcodeExpected, passcodeHeadsUpSeen != BootClock.current, inFront, !Self.onSimulator {'
]:
    if after.count(condition) != 1:
        raise SystemExit('The simulator passcode gate changed; inspect it before updating this runner.')
    after = after.replace(condition, condition.replace(', !Self.onSimulator', ''))
p.write_text(after)
(out / 'simulator-gates.patch').write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='original/AppModel.swift', tofile='simulator/AppModel.swift')))
PY
UDID="$(xcrun simctl create Poki-passcode-fallback com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)"
printf '%s\n' "$UDID" > "$OUT/simulator-id.txt"
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID"
  printf 'deleted %s\n' "$UDID" > "$OUT/simulator-cleanup.txt"
  rm -rf "$SRC/DerivedData"
}
trap cleanup EXIT
xcrun simctl bootstatus "$UDID" -b
cd "$SRC"
xcodegen generate --spec native/ios-app/project.yml > "$OUT/project.log" 2>&1
xcodebuild -quiet build-for-testing -project native/ios-app/Poki.xcodeproj -scheme Poki \
  -destination "id=$UDID" -derivedDataPath "$SRC/DerivedData" -clonedSourcePackagesDirPath "$PACKAGES" \
  LIBRARY_SEARCH_PATHS="$NATIVE" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= > "$OUT/build.log" 2>&1
APP="$SRC/DerivedData/Build/Products/Debug-iphonesimulator/Poki.app"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
X="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
xcrun simctl install "$UDID" "$APP"
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$X/usr/lib/libXCTestBundleInject.dylib" \
SIMCTL_CHILD_XCTestBundlePath="$APP/PlugIns/PokiTests.xctest" \
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$X/Library/Frameworks:$X/Library/PrivateFrameworks" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$X/usr/lib" \
  timeout 60 xcrun simctl launch --console-pty "$UDID" "$BUNDLE" \
    -XCTest AutomationStartupTests/testConnectionCanContinueOrCancelWhenPasscodeAlertIsAbsent \
    -passcodeFallbackGate YES -AppleLanguages '(en)' -AppleLocale en_US > "$OUT/test-run.log" 2>&1 || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
if [ -d "$CONTAINER/Documents/AutomationStartupEvidence" ]; then
  mkdir -p "$OUT/screenshots"
  cp "$CONTAINER/Documents/AutomationStartupEvidence/"* "$OUT/screenshots/"
fi
rg '^Test Suite|^Test Case|error:|Executed|Passcode fallback' "$OUT/test-run.log" || true
rg -q 'testConnectionCanContinueOrCancelWhenPasscodeAlertIsAbsent.*passed' "$OUT/test-run.log"
rg -q 'Executed 1 test, with 0 failures' "$OUT/test-run.log"
