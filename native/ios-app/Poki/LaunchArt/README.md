# The launch screen's pictures

The launch screen is the home page's light with "Poki" over it and the bear looking up from the bottom
edge. iOS draws it from `LaunchScreen.storyboard` before Poki runs, so the storyboard can hold only
pictures: no mesh gradient, no Allo and no shadow. When Poki's first frame is up, `LaunchCurtain`
lays the same storyboard over it and lets it go: the bear sinks, the word fades, and the picture of the
light fades into the light itself.

| File | What | Made by |
| --- | --- | --- |
| `LaunchBackdrop.png`, `LaunchBackdropDark.png` | The home page's light at rest, in light and in dark, 402 by 874 points at one pixel a point | `scripts/make-launch-backdrop.sh`, which has a Debug build draw `HomeBackdrop` itself |
| `LaunchBear.png` | The bear cut out of the app icon, on a clear ground | The design's own cut-out |
| `LaunchScreen.storyboard` | The launch screen's template | By hand; `make-assets.sh` writes `Poki/LaunchScreen.storyboard` from it |

## Layers, so the worst case is still the right ground

The launch screen has failed twice before. In #520 a real iPhone drew only the plain ground: its 3x
bear, 1524 by 1010 pixels, was the one picture over 4 MiB decoded, and iOS draws the launch screen
before Poki runs, with less room than an app. In #536 the Simulator drew a blank ground after an older
Poki had been installed: SplashBoard looked the pictures up in an asset catalogue it had kept from the
older app and found none. So:

1. The storyboard's own ground is `systemGroupedBackgroundColor`, which iOS draws in the right
   appearance with no catalogue at all.
2. Over it, the paper (`LaunchGround`, 0xF5F7FA and 0x05070D), the light and the word come from the
   asset catalogue with a Dark Mode picture each. Their names end in the pictures' version, a hash
   `make-assets.sh` takes of the pictures and the paper's colours. A launch screen drawn from an older
   catalogue finds no picture of that name and shows the ground, never an older or a light picture.
3. The bear, the same in both appearances, is a loose PNG at 2x (1016 by 673), as the old launch screen's
   pictures were. Every launch picture is 4 MiB or less decoded (`LaunchScreenTests`).

`make-assets.sh` also keeps the loose word, dark word and light in `Poki/LaunchImages` for the welcome's
hello and the tests. The word's colour and weight are set once, at the top of `make-launch-art.swift`.
After a change to the home page's light, run `make-launch-backdrop.sh` again.

SplashBoard checks the launch screen's files against the app's code signature. An app with no sealed
resources (a Simulator build signed only at link time, `CODE_SIGNING_ALLOWED=NO`) gets no launch image
at all, "a bad launch image until it is updated", and launches on black. Sign a Simulator build
(`codesign --force --deep -s -`) before judging its launch screen.

## License

`LaunchBear.png` is the Poki bear, Poki's own character and its main brand asset. It is not covered by the AGPL-3.0-only license that applies to Poki's code. You can build and run Poki with it unchanged; any other use, including new versions of the bear made from it, needs written permission. See [BRAND.md](../../../../BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫). All rights reserved, to the extent the law protects these works.
