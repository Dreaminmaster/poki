#!/usr/bin/env bash
# Run against Poki installed on a dedicated, booted iOS 27 iPhone simulator.
set -euo pipefail

simulator="$1"
evidence="$2"
bundle=nz.zheha.poki
mkdir -p "$evidence"

read_screen() {
    local screenshot="$evidence/$1.png"
    local label="$2"
    local recognized
    for attempt in {1..8}; do
        xcrun simctl io "$simulator" screenshot "$screenshot" >/dev/null 2>&1
        recognized=$(xcrun swift - "$screenshot" <<'SWIFT'
import Foundation
import Vision

let image = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["en-US"]
try VNImageRequestHandler(url: image).perform([request])
for line in request.results ?? [] {
    if let candidate = line.topCandidates(1).first {
        print(candidate.string)
    }
}
SWIFT
        )
        printf '%s\n' "$recognized" > "$evidence/$1.log"
        if [[ "$recognized" == *"$label"* ]]; then
            return
        fi
    done
    printf 'Missing visible text: %s\n' "$label" >&2
    return 1
}

expect_pairing_page() {
    if ! grep -Fq 'Pair This iPhone' "$evidence/$1.log"; then
        printf 'The pairing page is no longer visible.\n' >&2
        return 1
    fi
}

xcrun simctl terminate "$simulator" "$bundle" 2>/dev/null || true
xcrun simctl launch "$simulator" "$bundle" -pokiScreen chat -uiLanguage en -AppleLanguages '(en)' -AppleLocale en_US
read_screen '聊天起点' 'Message Poki'

checksum=$(printf '%064d' 0)
xcrun simctl openurl "$simulator" "poki://pairing?url=https%3A%2F%2Fpairing.invalid%2Fpairing.plist&sha256=$checksum"
read_screen '首条配对链接' 'Use This Pairing File?'
expect_pairing_page '首条配对链接'

# Wait for Poki to process the second URL before reading the page behind the alert.
container=$(xcrun simctl get_app_container "$simulator" "$bundle" data)
log="$container/Library/Caches/poki-log.txt"
discarded_count() {
    awk '/a link came while another waits for the owner/ { count++ } END { print count + 0 }' "$log"
}
previous=$(discarded_count)
xcrun simctl openurl "$simulator" 'poki://setup?relay=https%3A%2F%2Frelay.invalid'
deadline=$((SECONDS + 15))
until [[ "$(discarded_count)" -gt "$previous" ]]; do
    if ((SECONDS >= deadline)); then
        printf 'Poki did not handle the second link.\n' >&2
        exit 1
    fi
    sleep 0.2
done
read_screen '后到中继链接' 'Use This Pairing File?'
expect_pairing_page '后到中继链接'
printf 'The first confirmation and its pairing page are still visible.\n'
