#!/usr/bin/env bash
set -euo pipefail

# Run after Test Connection reports Responses for an unchanged saved address. Cancel the editor first.
#   check-custom-provider-settings.sh SIMULATOR detected
# Run on Models immediately after adding a second custom account. The two names must differ.
#   check-custom-provider-settings.sh SIMULATOR accounts ACTIVE_ACCOUNT INACTIVE_ACCOUNT
simulator="$1"
check="$2"
labels=$(axe describe-ui --udid "$simulator" | jq -r '.. | objects | .AXLabel? // empty')

expect_label() {
    if ! grep -Fx -- "$1" <<< "$labels"; then
        printf 'Expected accessibility label: %s\n' "$1" >&2
        return 1
    fi
}

case "$check" in
    detected)
        expect_label 'Automatic, uses Responses'
        ;;
    accounts)
        expect_label "$3, Text Chat"
        expect_label "$4, Not in use"
        ;;
    *)
        printf 'Unknown check: %s\n' "$check" >&2
        exit 2
        ;;
esac
