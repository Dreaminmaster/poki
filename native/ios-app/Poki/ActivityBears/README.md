# The Live Activity's bears

One picture per pose, on a clear ground, 408 pixels square (136 points at 3x, the largest the Live
Activity draws). They are the ESP-344 design's own cut-outs (`bears-clean`, made from ESP-319's
renders with the corner badges removed), scaled down with `sips -Z 408`. `scripts/make-assets.sh` puts them
into the app's and the widget extension's asset catalogues. When the 3D model's own clear renders exist (ESP-319), replace these files and
keep the names; where the head sits in each picture is in `ActivityBear` (ActivityFace.swift).

`ActivityBear-turn` (and `PokiBear-your-turn`, `PokiBearSmall-your-turn` and `PokiBearCutSmall-your-turn` in
`Bear/`) is the one pose edited after the renders: its paws are larger and reach up to the brow, so they cover
the whole eye sockets and no white rim shows round them. The edit was made once on the 1024-pixel render and
every size was exported from it, each keeping its own outline, ground and transparency.
