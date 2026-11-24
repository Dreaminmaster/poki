#!/bin/bash
# Run the auto-unlock tests against a build-for-testing app on a disposable simulator.
set -euo pipefail
UDID="$1"
APP="$2"
OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
X="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
mkdir -p "$OUT"
FIXTURE="$OUT/auto-unlock-delete-error.dylib"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -dynamiclib \
  -framework Security -framework CoreFoundation "$HERE/fixtures/auto-unlock-delete-error.c" -o "$FIXTURE"
codesign --force --sign - "$FIXTURE"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
trap 'xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true' EXIT
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$FIXTURE:$X/usr/lib/libXCTestBundleInject.dylib" \
SIMCTL_CHILD_XCTestBundlePath="$APP/PlugIns/PokiTests.xctest" \
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$X/Library/Frameworks:$X/Library/PrivateFrameworks" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$X/usr/lib" \
  timeout 55 xcrun simctl launch --terminate-running-process --console-pty "$UDID" "$BUNDLE" \
    -XCTest AutoUnlockTests -AppleLanguages '(en)' -AppleLocale en_US > "$OUT/test-run.log" 2>&1 || true
rg '^Test Suite|^Test Case|error:|Executed' "$OUT/test-run.log" || true
rg -q 'testFailedPasscodeDeletionKeepsAutomaticUnlockOnUntilRetrySucceeds.*passed' "$OUT/test-run.log"
rg -q 'testFailedPasscodeUpdateKeepsTheSavedPasscodeAndSwitchOn.*passed' "$OUT/test-run.log"
rg -q 'testSavingAndTurningOffAutomaticUnlockUpdatesThePrivateKeychain.*passed' "$OUT/test-run.log"
