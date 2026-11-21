#!/usr/bin/env python3
"""Send one authorized iPhone passcode attempt. The caller holds the Poki lease."""

import argparse
import getpass
import json
from pathlib import Path
import subprocess
import sys


def main():
    skill = Path(__file__).resolve().parents[1]
    root = skill.parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Exact UDID of the reserved iPhone")
    parser.add_argument("--keypad", type=Path, default=skill / "references/iphone-402x874.json")
    parser.add_argument("--native", type=Path, default=root / "build/native-target/release/examples/unlock_iphone")
    parser.add_argument("--stdin", action="store_true", help="Read passcode from the host through stdin")
    args = parser.parse_args()
    if not args.native.is_file():
        parser.error("Build the unlock_iphone example first; see SKILL.md.")
    if not args.keypad.is_file():
        parser.error("Keypad file does not exist.")
    if not args.stdin and not sys.stdin.isatty():
        parser.error("Use an interactive terminal for hidden passcode input.")
    pin = sys.stdin.read().rstrip("\r\n") if args.stdin else getpass.getpass("Passcode (hidden; not saved): ")
    # Any passcode iOS allows. The helper enters one that is not 4 or 6 digits only after the
    # accessibility tree shows the lock screen's passcode entry, empty.
    if not 4 <= len(pin) <= 128 or not all(" " <= c <= "~" for c in pin):
        print("Expected a passcode of 4 to 128 characters typed on a US keyboard; nothing sent.", file=sys.stderr)
        return 2
    try:
        result = subprocess.run(
            [str(args.native.resolve()), "--udid", args.device, "--keypad", str(args.keypad.resolve())],
            input=pin, text=True, capture_output=True, timeout=60,
        )
    except subprocess.TimeoutExpired:
        print("Input timed out. Inspect the phone; do not automatically retry.", file=sys.stderr)
        return 1
    finally:
        del pin
    if result.returncode:
        # The helper's own reason names no passcode (only why nothing or not everything was entered).
        why = next((line for line in result.stderr.splitlines() if "Nothing was entered" in line), "")
        print(why.split("Error: ", 1)[-1].strip('" ') or "Input did not complete. Inspect the phone; do not automatically retry.", file=sys.stderr)
        return 1
    print(json.dumps(json.loads(result.stdout)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
