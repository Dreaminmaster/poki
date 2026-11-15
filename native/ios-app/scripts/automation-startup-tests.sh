#!/bin/bash
# Run against an app built with build-for-testing. Only the developer-framework dlopen boundary is faked.
set -euo pipefail
UDID="$1"
APP="$2"
OUT="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
X="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
mkdir -p "$OUT"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios18.0-simulator -dynamiclib \
  "$HERE/fixtures/unavailable-developer-frameworks.c" -o "$OUT/unavailable-developer-frameworks.dylib"
codesign --force --sign - "$OUT/unavailable-developer-frameworks.dylib"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
trap 'xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true' EXIT
SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$OUT/unavailable-developer-frameworks.dylib:$X/usr/lib/libXCTestBundleInject.dylib" \
SIMCTL_CHILD_XCTestBundlePath="$APP/PlugIns/PokiTests.xctest" \
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$X/Library/Frameworks:$X/Library/PrivateFrameworks" \
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$X/usr/lib" \
  timeout 90 xcrun simctl launch --console-pty "$UDID" "$BUNDLE" \
    -XCTest AutomationStartupTests -AppleLanguages '(en)' -AppleLocale en_US > "$OUT/test-run.log" 2>&1 || true
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
if [ -d "$CONTAINER/Documents/AutomationStartupEvidence" ]; then
  mkdir -p "$OUT/screenshots"
  cp "$CONTAINER/Documents/AutomationStartupEvidence/"*.png "$OUT/screenshots/"
fi
grep -E '^Test Suite|^Test Case|error:|Executed' "$OUT/test-run.log" || true
grep -q "Test Suite 'AutomationStartupTests' passed" "$OUT/test-run.log"
grep -q 'testDownloadedImageIsNotReadyWithoutLoadableDeveloperFrameworks.*passed' "$OUT/test-run.log"
grep -q 'testPasscodeExplanationAppearsOverConnectionSettings.*passed' "$OUT/test-run.log"
