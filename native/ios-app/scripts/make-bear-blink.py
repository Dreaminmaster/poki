#!/usr/bin/env python3
"""make-bear-blink.py: makes the blinking bear's pictures from the bear's own cutouts (ESP-468).

For every face with open eyes, it finds the two dark pupils in Poki/Bear/PokiBearCutSmall-<face>.png
and the white eye round each, fills both eyes with the face's own colour from around them
(PokiBearLids-<face>.png), and prints where the eyes are, as the Swift table `BearEyes.table` in
Poki/Bear/BlinkingFace.swift. The face draws the filled picture and lays each whole eye, white and
pupil, back over it from the original, so the eye can be squeezed shut for a blink without leaving
its white behind. Run it again when the cutouts change; it needs Pillow, NumPy and SciPy.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

BEAR = Path(__file__).resolve().parent.parent / "Poki" / "Bear"
FACES = ["hello", "ready", "thinking", "on-your-phone", "checking", "needs-you",
         "tripped", "cant-reach", "listening", "speaking"]
# A pupil is a dark blob of at least this many pixels; the smile is smaller.
PUPIL = 500
# How far past the eye's edge the fill reaches, so no light fringe is left.
MARGIN = 3
# The eye's white: light and nearly grey, unlike the face's periwinkle.
WHITE_LUMA = 226
WHITE_CHROMA = 34


def pupils(rgba):
    """The two pupils, left first, each as a mask."""
    dark = (rgba[..., :3].mean(-1) < 90) & (rgba[..., 3] > 200)
    labels, count = ndimage.label(dark)
    sizes = ndimage.sum(dark, labels, range(1, count + 1))
    found = [i + 1 for i, size in enumerate(sizes) if size >= PUPIL]
    if len(found) != 2:
        sys.exit(f"expected two pupils, found {len(found)}")
    masks = [labels == i for i in found]
    return sorted(masks, key=lambda mask: np.nonzero(mask)[1].min())


def eye(rgba, pupil):
    """The whole eye round a pupil: the white touching it, the pupil, and what they enclose, grown by MARGIN."""
    rgb = rgba[..., :3]
    white = (rgb.mean(-1) > WHITE_LUMA) & (rgb.max(-1) - rgb.min(-1) < WHITE_CHROMA) & (rgba[..., 3] > 250)
    labels, _ = ndimage.label(white | pupil)
    touching = set(np.unique(labels[ndimage.binary_dilation(pupil, iterations=4) & (white | pupil)])) - {0}
    whole = ndimage.binary_fill_holes(np.isin(labels, list(touching)))
    return ndimage.binary_dilation(whole, iterations=MARGIN)


def cover(mask):
    """The rectangle whose inscribed ellipse holds every pixel of the mask: the view masks each eye with that
    ellipse, so a filled pixel outside it would show while the eye is open."""
    ys, xs = np.nonzero(mask)
    x0, x1, y0, y1 = xs.min() - 1.0, xs.max() + 2.0, ys.min() - 1.0, ys.max() + 2.0
    while True:
        cx, cy, rx, ry = (x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2
        if (((xs + 0.5 - cx) / rx) ** 2 + ((ys + 0.5 - cy) / ry) ** 2).max() <= 0.97:
            return x0, y0, x1 - x0, y1 - y0
        x0, x1, y0, y1 = x0 - 1, x1 + 1, y0 - 1, y1 + 1


def fill(rgba, hole):
    """Fills the hole from its edge inward, each pixel the mean of its known neighbours, then smooths.
    Only the face's own colour feeds it: a mouth or blush touching an eye would otherwise bleed in."""
    rgb = rgba[..., :3].copy()
    face = (rgb[..., 2] > rgb[..., 0]) & (rgb.mean(-1) > 150) & (rgba[..., 3] > 250)
    near = ndimage.binary_dilation(hole, iterations=12)
    work = hole | (near & ~face)
    known = ~work
    kernel = np.ones((3, 3))
    while not known.all():
        weight = ndimage.convolve(known.astype(float), kernel, mode="nearest")
        edge = (~known) & (weight > 0)
        for c in range(3):
            total = ndimage.convolve(rgb[..., c] * known, kernel, mode="nearest")
            rgb[..., c][edge] = total[edge] / weight[edge]
        known = known | edge
    for _ in range(40):
        blurred = ndimage.uniform_filter(rgb, size=(3, 3, 1), mode="nearest")
        rgb[work] = blurred[work]
    out = rgba[..., :3].copy()
    out[hole] = rgb[hole]
    return out


def main():
    rows = []
    for face in FACES:
        image = Image.open(BEAR / f"PokiBearCutSmall-{face}.png").convert("RGBA")
        rgba = np.asarray(image).astype(float)
        side = rgba.shape[0]
        eyes = [eye(rgba, pupil) for pupil in pupils(rgba)]
        out = rgba.copy()
        out[..., :3] = fill(rgba, eyes[0] | eyes[1])
        Image.fromarray(out.round().clip(0, 255).astype(np.uint8)).save(BEAR / f"PokiBearLids-{face}.png", optimize=True)
        rects = []
        for mask in eyes:
            x, y, w, h = cover(mask)
            rects.append(f"CGRect(x: {x / side:.4f}, y: {y / side:.4f}, width: {w / side:.4f}, height: {h / side:.4f})")
        rows.append(f'        .{camel(face)}: [{", ".join(rects)}],')
    print("    static let table: [PokiMood: [CGRect]] = [")
    print("\n".join(rows))
    print("    ]")


def camel(face):
    head, *rest = face.split("-")
    return head + "".join(word.capitalize() for word in rest)


if __name__ == "__main__":
    main()
