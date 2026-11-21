#!/usr/bin/env python3
"""Check still outfit previews on a booted iPhone 17 Pro simulator with Debug Poki installed.

Requires AXe, Pillow, and the Poki simulator helper (built from native/simulator.m).
Use a dedicated simulator: the flow clears its outfit selection.
"""

import argparse
import json
from pathlib import Path
import subprocess
from time import monotonic, sleep

from PIL import Image


BUNDLE = "nz.zheha.poki"
WIDTH, HEIGHT = 402, 874


def until(reason, read, matches=bool):
    deadline = monotonic() + 8
    while monotonic() < deadline:
        value = read()
        if matches(value):
            return value
        sleep(0.1)
    raise AssertionError(reason)


def simctl(device, *args, check=True):
    subprocess.run(["xcrun", "simctl", args[0], device, *args[1:]],
                   check=check, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)


def pixels(image, box):
    data = iter(image.crop(box).tobytes())
    return zip(data, data, data)


def exercise(device, helper, output, strain):
    def screen_elements():
        raw = subprocess.check_output([helper], input=json.dumps({"id": device, "op": "ax"}),
                                      text=True, timeout=15)
        screen = json.loads(raw)
        return screen["elements"] if screen.get("bundle_id") == BUNDLE else []

    def element(identifier):
        return next((e for e in screen_elements() if e.get("identifier") == identifier
                     and e["width"] > 1 and 0 <= e["x"] <= WIDTH - e["width"]
                     and 0 <= e["y"] < HEIGHT), None)

    def control(identifier):
        return until(f"Missing {identifier}", lambda: element(identifier))

    def selected(identifier):
        until(f"{identifier} was not selected", lambda: element(identifier),
              lambda e: e and e["selected"])

    def tap(identifier):
        e = control(identifier)
        x = e["x"] + e["width"] / 2
        y = e["y"] + e["height"] / 2
        subprocess.run(["axe", "tap", "--udid", device, "--tap-style", "physical", "-x", str(x), "-y", str(y)],
                       check=True, timeout=20)

    def tap_button(identifier):
        subprocess.run(["axe", "tap", "--udid", device, "--tap-style", "physical",
                        "--id", identifier, "--wait-timeout", "8"], check=True, timeout=20)

    def preview(name):
        path = output / f"{name}.png"
        simctl(device, "io", "screenshot", str(path))
        with Image.open(path) as image:
            return image.convert("RGB").resize((WIDTH, HEIGHT), Image.Resampling.BOX)

    simctl(device, "launch", BUNDLE, "-pokiChat", "working", "-uiLanguage", "en",
           "-AppleLanguages", "(en)", "-pokiStrain", strain)
    tap_button("chat.header.avatar")
    control("wardrobe.pieces")
    navigation = control("Customize Poki")
    portrait_top = round(navigation["y"] + navigation["height"] + 8)

    def gold(image):
        return sum(r > 120 and r > 1.08 * g and g > 1.24 * b
                   for r, g, b in pixels(image, (140, portrait_top, 262, portrait_top + 78)))

    def cape(image):
        return sum(r > 85 and r > 1.35 * g and r > 1.30 * b
                   for r, g, b in pixels(image, (141, portrait_top + 111, 261, portrait_top + 176)))

    def cardigan(image):
        return sum(b > 1.3 * r and b > 1.1 * g and r < 95
                   for r, g, b in pixels(image, (141, portrait_top + 136, 261, portrait_top + 176)))

    tap_button("wardrobe.tab.set")
    expected_tiles = {f"wardrobe.set.{number}" for number in range(13)}
    until("Outfits must keep all thirteen tiles", screen_elements,
          lambda elements: expected_tiles <= {e.get("identifier") for e in elements})
    tap("wardrobe.set.0")
    selected("wardrobe.set.0")
    bare_set = preview("set-bare")
    tap("wardrobe.set.7")
    selected("wardrobe.set.7")
    assert control("wardrobe.equipped.headwear")["label"] == "Remove Crown"
    assert control("wardrobe.equipped.clothes")["label"] == "Remove Royal Cape"
    until("Little King is selected but its crown or cape is missing from the preview",
          lambda: preview("set-king"),
          lambda image: gold(image) > gold(bare_set) + 50 and cape(image) > cape(bare_set) + 50)
    tap("wardrobe.set.0")
    selected("wardrobe.set.0")
    until("The preview still wears Little King after selecting No Outfit", lambda: preview("set-removed"),
          lambda image: gold(image) <= gold(bare_set) + 10 and cape(image) <= cape(bare_set) + 10)
    tap_button("wardrobe.tab.headwear")
    selected("wardrobe.headwear.0")
    bare = preview("bare")
    tap("wardrobe.headwear.7")
    selected("wardrobe.headwear.7")
    crown = until("Crown is selected but missing from the preview", lambda: preview("crown"),
                  lambda image: gold(image) > gold(bare) + 50)
    tap_button("wardrobe.tab.clothes")
    tap("wardrobe.clothes.4")
    selected("wardrobe.clothes.4")
    until("Mixed preview does not show both the crown and the cardigan", lambda: preview("mixed"),
          lambda image: gold(image) > gold(bare) + 50 and cardigan(image) > cardigan(crown) + 50)
    tap_button("wardrobe.removeAll")
    selected("wardrobe.clothes.0")
    until("The preview still shows an outfit after Remove All", lambda: preview("removed"),
          lambda image: gold(image) <= gold(bare) + 10 and cardigan(image) <= cardigan(crown) + 10)
    tap_button("wardrobe.close")
    control("chat.header.avatar")
    print(f"PASS ({strain}). The avatar opens Customize Poki. A preset applies both pieces, and mixed pieces still render.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device", help="dedicated, booted simulator UDID")
    parser.add_argument("helper", type=Path, help="path to the Poki simulator executable")
    parser.add_argument("output", type=Path, help="directory for screenshots")
    parser.add_argument("--strain", choices=("lowPower", "hot"), default="lowPower")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    simctl(args.device, "terminate", BUNDLE, check=False)
    try:
        exercise(args.device, args.helper.resolve(), args.output, args.strain)
    finally:
        simctl(args.device, "terminate", BUNDLE, check=False)
