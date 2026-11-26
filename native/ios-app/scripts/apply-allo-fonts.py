#!/usr/bin/env python3
"""Moves the app's system text styles onto Allo (Shared/Typeface.swift).

    python3 scripts/apply-allo-fonts.py            # rewrite Poki/ and Shared/
    python3 scripts/apply-allo-fonts.py --check    # list what would change, exit 1 if anything

Safe to run again after a merge brings in views with system fonts: only `.font(...)` calls with a
plain text style are rewritten, so monospaced text, fixed-size symbols and fonts held in variables
keep the system font.

    .font(.footnote)                          -> .font(.allo(.footnote))
    .font(.body.weight(.semibold))            -> .font(.allo(.body, .semibold))
    .font(.title2.bold())                     -> .font(.alloRounded(.title2, .bold))
    .font(.system(.title3, design: .rounded, weight: .bold)) -> .font(.alloRounded(.title3, .bold))

Titles (largeTitle, title, title2, title3) and SF Rounded become Allo Rounded; the rest Allo Text.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FOLDERS = ["Poki", "Shared"]
SKIP = {"Shared/Typeface.swift"}
STYLES = "largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2"
TITLES = {"largeTitle", "title", "title2", "title3"}


def face(style):
    return "alloRounded" if style in TITLES else "allo"


RULES = [
    # .font(.system(.title3, design: .rounded, weight: .bold)), also with a conditional style.
    (re.compile(r"\.font\(\.system\(([^()]*?), design: \.rounded, weight: (\.\w+)\)\)"),
     lambda m: f".font(.alloRounded({m[1]}, {m[2]}))"),
    (re.compile(r"\.font\(\.system\(([^()]*?), design: \.rounded\)\.weight\((\.\w+)\)\)"),
     lambda m: f".font(.alloRounded({m[1]}, {m[2]}))"),
    (re.compile(rf"\.font\(\.({STYLES})\.weight\((\.\w+)\)\)"),
     lambda m: f".font(.{face(m[1])}(.{m[1]}, {m[2]}))"),
    (re.compile(rf"\.font\(\.({STYLES})\.bold\(\)\)"),
     lambda m: f".font(.{face(m[1])}(.{m[1]}, .bold))"),
    (re.compile(rf"\.font\(\.({STYLES})\)"),
     lambda m: f".font(.{face(m[1])}(.{m[1]}))"),
]


def rewrite(text):
    for pattern, replace in RULES:
        text = pattern.sub(replace, text)
    return text


def main():
    check = "--check" in sys.argv
    changed = 0
    for folder in FOLDERS:
        for path in sorted((ROOT / folder).rglob("*.swift")):
            relative = path.relative_to(ROOT).as_posix()
            if relative in SKIP:
                continue
            before = path.read_text()
            after = rewrite(before)
            if after == before:
                continue
            count = sum(a != b for a, b in zip(before.splitlines(), after.splitlines()))
            changed += count
            print(f"{relative}: {count} line(s)")
            if not check:
                path.write_text(after)
    print(f"{changed} line(s) {'to change' if check else 'changed'}")
    sys.exit(1 if check and changed else 0)


if __name__ == "__main__":
    main()
