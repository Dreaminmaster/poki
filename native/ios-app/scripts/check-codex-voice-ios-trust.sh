#!/usr/bin/env bash
set -euo pipefail

workspace=${1:?Usage: check-codex-voice-ios-trust.sh PREPARED_CODEX_WORKSPACE IOS_TARGET}
target=${2:?Pass the iOS Rust target}
case "$target" in aarch64-apple-ios|aarch64-apple-ios-sim) ;; *) exit 2 ;; esac

export PATH="$HOME/.cargo/bin:$PATH"
cd "$workspace"
dependencies=$(cargo +stable tree --locked --offline --target "$target" \
    --package poki-codex-voice --invert webpki-roots@1.0.10 --prefix none)
if ! grep -Eq '^tokio-tungstenite v' <<< "$dependencies"; then
    echo "FAIL: $target realtime WebSocket does not resolve the bundled public roots" >&2
    exit 1
fi
echo "PASS: $target realtime WebSocket resolves webpki-roots 1.0.10"
