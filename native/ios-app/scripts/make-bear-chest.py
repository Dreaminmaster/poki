#!/usr/bin/env python3
"""make-bear-chest.py [MODEL]: takes the paws' prints off the bear's chest, in the model's colour picture.

The body's colours were painted with the paws resting on the chest: where each paw lies, the chest has
a light oval, and between the two a darker crease. Under the paws nobody sees the ovals. Once the bear
lifts its arms (pleased, stretching, waving), the two ovals are left on the chest with the crease
between them, and read as two lumps.

This fills that part of the chest (what the two resting paws hide, and the crease between them) with
the chest's own colour from round it (the smooth surface through the colours at its edge), in the
colour picture inside Poki/Bear/Model/PokiBear.usdz, and packs the model again with every other file
as it was. Nothing of the bear's shape, rig or animation changes; standing, only the crease between
the paws is a little lighter. On a new round of the model, trace the outline again if the paws rest
elsewhere. It needs Pillow, NumPy and SciPy.
"""
import io
import struct
import sys
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.sparse import lil_matrix
from scipy.sparse.linalg import spsolve

MODEL = Path(__file__).resolve().parent.parent / "Poki" / "Bear" / "Model" / "PokiBear.usdz"
# The part of the chest to fill, as an outline in the 2048-pixel colour picture of the round 16 model:
# the half on the bear's right, from the chest's middle (x = AXIS) round what its right paw hides in
# every pose it stands in. The other half is the same shape on the other side of the middle.
SIZE = 2048
AXIS = 1757
HALF = [(1757, 358), (1688, 358), (1668, 345), (1644, 347), (1622, 355), (1592, 338), (1586, 377),
        (1586, 552), (1591, 592), (1620, 585), (1644, 584), (1667, 579), (1757, 579)]


def chest(size):
    """The part of the picture to fill, as a mask."""
    scale = size / SIZE
    outline = HALF + [(2 * AXIS - x, y) for x, y in reversed(HALF)]
    picture = Image.new("1", (size, size), 0)
    ImageDraw.Draw(picture).polygon([(x * scale, y * scale) for x, y in outline], fill=1)
    return np.asarray(picture, bool)


def fill(rgb, mask):
    """`rgb` with the masked part replaced by the smooth surface through the colours round it."""
    ys, xs = np.nonzero(mask)
    top, bottom, left, right = ys.min() - 1, ys.max() + 2, xs.min() - 1, xs.max() + 2
    part = rgb[top:bottom, left:right].astype(float)
    inside = mask[top:bottom, left:right]
    number = -np.ones(inside.shape, int)
    number[inside] = np.arange(inside.sum())
    count = int(inside.sum())
    matrix = lil_matrix((count, count))
    known = np.zeros((count, 3))
    for row, col in zip(*np.nonzero(inside)):
        i = number[row, col]
        matrix[i, i] = 4
        for r, c in ((row - 1, col), (row + 1, col), (row, col - 1), (row, col + 1)):
            if inside[r, c]:
                matrix[i, number[r, c]] = -1
            else:
                known[i] += part[r, c]
    matrix = matrix.tocsr()
    solved = np.stack([spsolve(matrix, known[:, channel]) for channel in range(3)], axis=-1)
    out = part.copy()
    out[inside] = solved
    result = np.array(rgb, float)
    result[top:bottom, left:right] = out
    return result


def patch(png):
    picture = Image.open(io.BytesIO(png))
    if picture.width != picture.height or picture.mode != "RGB":
        sys.exit(f"expected a square RGB colour picture, found {picture.mode} {picture.size}")
    rgb = np.asarray(picture)
    filled = fill(rgb, chest(picture.width))
    out = io.BytesIO()
    Image.fromarray(np.clip(filled.round(), 0, 255).astype(np.uint8), "RGB").save(out, "PNG", optimize=True)
    return out.getvalue(), np.abs(filled - rgb).max()


def pack(files, path):
    """A usdz: a zip with nothing compressed and every file's data starting on a 64-byte boundary."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as archive:
        for info, data in files:
            entry = zipfile.ZipInfo(info.filename, info.date_time)
            entry.compress_type = zipfile.ZIP_STORED
            entry.external_attr = info.external_attr
            start = archive.fp.tell() + 30 + len(entry.filename.encode())
            padding = (64 - (start + 4) % 64) % 64
            entry.extra = struct.pack("<HH", 0x1986, padding) + bytes(padding)
            archive.writestr(entry, data)


def main():
    model = Path(sys.argv[1]) if len(sys.argv) > 1 else MODEL
    with zipfile.ZipFile(model) as archive:
        files = [(info, archive.read(info)) for info in archive.infolist()]
    colours = [i for i, (info, _) in enumerate(files) if info.filename.endswith("_color.png") and "eyepad" not in info.filename]
    if len(colours) != 1:
        sys.exit(f"expected one body colour picture, found {len(colours)}")
    info, png = files[colours[0]]
    patched, changed = patch(png)
    files[colours[0]] = (info, patched)
    pack(files, model)
    print(f"{model.name}: {info.filename} filled, the largest change {changed:.0f} of 255")


if __name__ == "__main__":
    main()
