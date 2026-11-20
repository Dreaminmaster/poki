# The launch screen's pictures

The launch screen is the home page's light with "Poki" over it and the bear looking up from the bottom
edge. iOS draws it from `LaunchScreen.storyboard` before Poki runs, so the storyboard can hold only
pictures: no mesh gradient, no Geist and no shadow. When Poki's first frame is up, `LaunchCurtain`
lays the same storyboard over it and lets it go: the bear sinks, the word fades, and the picture of the
light fades into the light itself.

| File | What | Made by |
| --- | --- | --- |
| `LaunchBackdrop.png` | The home page's light at rest, light appearance, 402 by 874 points at one pixel a point | `scripts/make-launch-backdrop.sh`, which has a Debug build draw `HomeBackdrop` itself |
| `LaunchBear.png` | The bear cut out of the app icon, on a clear ground | The design's own cut-out |

`scripts/make-assets.sh` writes standalone PNGs to `Poki/LaunchImages`, including the word and the bear
with its shadow drawn by `scripts/make-launch-art.swift`. Xcode copies these files into the app bundle.
The storyboard names the PNG files explicitly so the system's launch-screen renderer does not depend
on an asset catalogue cached from an older installation. The app's curtain loads the same storyboard.
The word's colour and weight are set once,
at the top of that script. After a change to the home page's light, run `make-launch-backdrop.sh`
again; `LaunchScreenTests` checks the packaged PNGs, the layout, and the picture against the home page's light.

The light is drawn for one appearance only. In Dark Mode the launch screen is the same, and the
curtain fades it into the dark home page.

## License

`LaunchBear.png` is the Poki bear, Poki's own character and its main brand asset. It is not covered by the AGPL-3.0-only license that applies to Poki's code. You can build and run Poki with it unchanged; any other use, including new versions of the bear made from it, needs written permission. See [BRAND.md](../../../../BRAND.md).

Copyright (c) 2026 Joseph Zhou (周瑟夫). All rights reserved, to the extent the law protects these works.
