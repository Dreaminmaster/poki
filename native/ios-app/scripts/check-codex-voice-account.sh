#!/usr/bin/env bash
set -euo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d -t poki-codex-voice-test)
trap 'unlink "$work/probe.swift"; rmdir "$work"' EXIT

if [[ $# == 1 ]]; then
    git -C "$scripts" show "$1:native/ios-app/Poki/Voice/CodexVoice.swift" > "$work/probe.swift"
else
    cat "$scripts/../Poki/Voice/CodexVoice.swift" > "$work/probe.swift"
fi
cat "$scripts/fixtures/codex-voice-account.swift" >> "$work/probe.swift"
xcrun swift -swift-version 5 "$work/probe.swift"
