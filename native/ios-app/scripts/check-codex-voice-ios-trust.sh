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
if ! grep -Eq '^codex-http-client v' <<< "$dependencies"; then
    echo "FAIL: $target codex-http-client does not resolve webpki-roots 1.0.10 for Responses WebSocket TLS" >&2
    exit 1
fi
if ! grep -Fq 'webpki_roots::TLS_SERVER_ROOTS' http-client/src/native_roots.rs; then
    echo "FAIL: $target codex-http-client native_roots.rs does not load webpki_roots::TLS_SERVER_ROOTS" >&2
    exit 1
fi
echo "PASS: $target realtime and responses WebSockets resolve webpki-roots 1.0.10"
