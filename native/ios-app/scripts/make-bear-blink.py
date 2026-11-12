#!/usr/bin/env python3
"""make-bear-blink.py: makes the blinking bear's pictures from the bear's own cutouts (ESP-468).

For every face with open eyes, it finds the two dark pupils in Poki/Bear/PokiBearCutSmall-<face>.png,
fills them with the eye's own white from around them (PokiBearLids-<face>.png), and prints where
the pupils are, as the Swift table `BearEyes.table` in Poki/Bear/BearPortrait.swift. The portrait
draws the filled picture and lays the pupils back over it from the original, so it can squeeze
them shut for a blink. Run it again when the cutouts change; it needs Pillow, NumPy and SciPy.
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
# How far past the pupil's edge the fill reaches, so no dark fringe is left.
MARGIN = 3


def pupils(rgba):
    dark = (rgba[..., :3].mean(-1) < 90) & (rgba[..., 3] > 200)
    labels, count = ndimage.label(dark)
    sizes = ndimage.sum(dark, labels, range(1, count + 1))
    boxes = ndimage.find_objects(labels)
    found = [boxes[i] for i, size in enumerate(sizes) if size >= PUPIL]
    if len(found) != 2:
        sys.exit(f"expected two pupils, found {len(found)}")
    return sorted(found, key=lambda box: box[1].start)


def ellipse(shape, box, grow):
    ys, xs = np.mgrid[0:shape[0], 0:shape[1]]
    cy = (box[0].start + box[0].stop - 1) / 2
    cx = (box[1].start + box[1].stop - 1) / 2
    ry = (box[0].stop - box[0].start) / 2 + grow
    rx = (box[1].stop - box[1].start) / 2 + grow
    return ((ys - cy) / ry) ** 2 + ((xs - cx) / rx) ** 2 <= 1


def fill(rgb, hole):
    """Fills the hole from its edge inward, each pixel the mean of its known neighbours, then smooths."""
    rgb = rgb.copy()
    known = ~hole
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
        rgb[hole] = blurred[hole]
    return rgb


def main():
    rows = []
    for face in FACES:
        image = Image.open(BEAR / f"PokiBearCutSmall-{face}.png").convert("RGBA")
        rgba = np.asarray(image).astype(float)
        side = rgba.shape[0]
        boxes = pupils(rgba)
        hole = ellipse(rgba.shape[:2], boxes[0], MARGIN) | ellipse(rgba.shape[:2], boxes[1], MARGIN)
        out = rgba.copy()
        out[..., :3] = fill(rgba[..., :3], hole)
        Image.fromarray(out.round().clip(0, 255).astype(np.uint8)).save(BEAR / f"PokiBearLids-{face}.png", optimize=True)
        rects = []
        for box in boxes:
            x, y = box[1].start - MARGIN, box[0].start - MARGIN
            w, h = box[1].stop - box[1].start + 2 * MARGIN, box[0].stop - box[0].start + 2 * MARGIN
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
