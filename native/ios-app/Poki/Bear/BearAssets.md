# The Poki bear's artwork

The pictures (`.png`) in this folder and its subfolders, the 3D model `Model/PokiBear.usdz`, and the outfit models in `Model/Outfits/` are Poki's own character artwork. They are not covered by the AGPL-3.0-only license that applies to Poki's code, and they are not licensed for use outside Poki.

You can build and run Poki with them unchanged. You cannot use them in another app or product, ship them in a fork, or make new versions of the bear from them without written permission. See [BRAND.md](../../../../BRAND.md) for what is allowed and how to ask.

The code and animation data next to them (`.swift`, `.json`) are part of Poki's code and stay under the AGPL.

Copyright (c) 2026 Joseph Zhou (周瑟夫). All rights reserved, to the extent the law protects these works.

## Outfit models

Each set has two USDZ files, one for headwear and one for clothes. Both use the joint names from `PokiBear.usdz`. The headwear follows the head joint. The sleeves and cuffs use weights from the matching arm mesh. The torso and hem use weights from the bear's torso, including the shoulder joints. The garments are fitted in the relaxed standing pose and exported in the bear's bind pose. Mesh names that start with `Primary_` or `Accent_` identify the garment colors the app can change.
