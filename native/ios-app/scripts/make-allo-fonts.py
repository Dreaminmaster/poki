#!/usr/bin/env python3
"""Cut Poki's two Allo faces from Allo's variable font (SIL OFL 1.1, github.com/joshpuckett/allo).

    python3 -m pip install fonttools==4.60.2
    python3 make-allo-fonts.py AlloVariable.ttf ../Shared/Fonts

Allo Text is the body face: the designer's default roundness (ROND 50) at the Text optical size.
Allo Rounded is for the Poki name, titles and prominent text: a little rounder (ROND 70, short of
the fully round 100) at a larger optical size. Static fonts keep SwiftUI's Font.custom(_:size:
relativeTo:) working with Dynamic Type, and give each weight a name of its own.

The em is enlarged so that Allo's cap height and line height equal SF Pro's at every point size.
Allo then sits beside PingFang, and the other fonts iOS falls back to for scripts Allo has no
letters for, exactly as SF Pro does, and replacing SF does not move any layout.
"""

import sys
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

# SF Pro's proportions of the em (2048 units): cap height 1443, ascender 1950, descender 494, no gap.
SF_CAP = 1443 / 2048
SF_ASCENT = 1950 / 2048
SF_DESCENT = 494 / 2048

FACES = {
    "Text": {"ROND": 50, "opsz": 14, "weights": [400, 500, 600, 700, 800]},
    "Rounded": {"ROND": 70, "opsz": 24, "weights": [500, 600, 700, 800, 900]},
}
WEIGHT_NAMES = {400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black"}


def set_name(font, name_id, text):
    font["name"].setName(text, name_id, 3, 1, 0x409)
    font["name"].setName(text, name_id, 1, 0, 0)


def cut(source, face, settings, weight, out_dir):
    font = TTFont(source)
    font = instantiateVariableFont(font, {"wght": weight, "ROND": settings["ROND"], "opsz": settings["opsz"]})
    for table in ("STAT", "MVAR", "HVAR", "avar", "fvar", "gvar"):
        if table in font:
            del font[table]

    # Same cap height as SF Pro: a larger em scales every outline, advance and kerning value at once.
    os2 = font["OS/2"]
    upm = round(os2.sCapHeight / SF_CAP)
    font["head"].unitsPerEm = upm
    ascent, descent = round(SF_ASCENT * upm), round(SF_DESCENT * upm)
    hhea = font["hhea"]
    hhea.ascent, hhea.descent, hhea.lineGap = ascent, -descent, 0
    os2.sTypoAscender, os2.sTypoDescender, os2.sTypoLineGap = ascent, -descent, 0
    os2.usWinAscent = max(ascent, font["head"].yMax)
    os2.usWinDescent = max(descent, -font["head"].yMin)
    os2.fsSelection |= 1 << 7  # USE_TYPO_METRICS

    family = f"Allo {face}"
    style = WEIGHT_NAMES[weight]
    postscript = f"Allo{face}-{style}"
    os2.usWeightClass = weight
    bold = weight == 700
    os2.fsSelection &= ~((1 << 0) | (1 << 5) | (1 << 6))
    os2.fsSelection |= (1 << 5) if bold else (1 << 6) if weight == 400 else 0
    font["head"].macStyle = 1 if bold else 0

    name = font["name"]
    keep = {0, 7, 8, 9, 11, 12, 13, 14}
    name.names = [record for record in name.names if record.nameID in keep]
    ribbi = weight in (400, 700)
    set_name(font, 1, family if ribbi else f"{family} {style}")
    set_name(font, 2, style if ribbi else "Regular")
    set_name(font, 3, f"1.0.3;POKI;{postscript}")
    set_name(font, 4, f"{family} {style}")
    set_name(font, 5, "Version 1.0.3; cut for Poki")
    set_name(font, 6, postscript)
    set_name(font, 16, family)
    set_name(font, 17, style)

    path = Path(out_dir) / f"{postscript}.ttf"
    font.save(path)
    return path


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: make-allo-fonts.py AlloVariable.ttf OUT_DIR")
    source, out_dir = sys.argv[1], sys.argv[2]
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    for face, settings in FACES.items():
        for weight in settings["weights"]:
            print(cut(source, face, settings, weight, out_dir))


if __name__ == "__main__":
    main()
