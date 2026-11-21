#!/bin/bash
# Makes the asset catalogs from docs/images/poki-app-icon.png (macOS, needs swift): the app icon (a finished
# full-bleed 1024 image; iOS applies its own corner mask) and the round Bear image for the app and the Live Activity.
# They are generated, not checked in, so the source images in docs/images stay the only copies. The icon is the
# same picture in light and dark: it is listed again for the dark appearance, because iOS makes its own darker
# version of an icon that has no dark entry. Run before xcodegen.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ICON="$ROOT/docs/images/poki-app-icon.png"
COMPOSE="$ROOT/native/ios-runner/branding/compose.swift"
meta='{"info":{"version":1,"author":"poki"}}'

catalog() { rm -rf "$1"; mkdir -p "$1"; echo "$meta" > "$1/Contents.json"; }
bear() {
  mkdir -p "$1/Bear.imageset"
  swift "$COMPOSE" "$ICON" "$1/Bear.imageset/bear@3x.png" 360 1.0
  echo '{"images":[{"filename":"bear@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"poki"}}' > "$1/Bear.imageset/Contents.json"
}

APP="$HERE/Poki/Assets.xcassets"
catalog "$APP"
mkdir -p "$APP/AppIcon.appiconset"
cp "$ICON" "$APP/AppIcon.appiconset/icon-1024.png"
echo '{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"version":1,"author":"poki"}}' > "$APP/AppIcon.appiconset/Contents.json"
mkdir -p "$APP/AccentColor.colorset"
echo '{"colors":[{"idiom":"universal","color":{"color-space":"srgb","components":{"red":"0x20","green":"0x84","blue":"0xFD","alpha":"1.000"}}}],"info":{"version":1,"author":"poki"}}' > "$APP/AccentColor.colorset/Contents.json"
bear "$APP"
# The app icon as a picture for the app's own pages (the conversations' header), small: 64 points at 3x.
mkdir -p "$APP/PokiIcon.imageset"
sips -Z 192 "$ICON" --out "$APP/PokiIcon.imageset/icon@3x.png" >/dev/null
echo '{"images":[{"filename":"icon@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"poki"}}' > "$APP/PokiIcon.imageset/Contents.json"
# Provider logos (Poki/ProviderIcons, see its README) as vector template images.
logos() {
  for svg in "$HERE"/Poki/ProviderIcons/*.svg; do
    name="Provider-$(basename "$svg" .svg)"
    mkdir -p "$1/$name.imageset"
    cp "$svg" "$1/$name.imageset/logo.svg"
    echo '{"images":[{"filename":"logo.svg","idiom":"universal"}],"info":{"version":1,"author":"poki"},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"template"}}' > "$1/$name.imageset/Contents.json"
  done
}
logos "$APP"
# Connectors' own marks (Poki/ConnectorIcons) in their colours, as vectors: name.svg, with
# name-dark.svg for Dark Mode where the company draws the mark for a dark ground.
for svg in "$HERE"/Poki/ConnectorIcons/*.svg; do
  base="$(basename "$svg" .svg)"
  case "$base" in *-dark) continue ;; esac
  set="$APP/Connector-$base.imageset"
  mkdir -p "$set"
  cp "$svg" "$set/mark.svg"
  if [ -f "$HERE/Poki/ConnectorIcons/$base-dark.svg" ]; then
    cp "$HERE/Poki/ConnectorIcons/$base-dark.svg" "$set/mark-dark.svg"
    echo '{"images":[{"filename":"mark.svg","idiom":"universal"},{"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"mark-dark.svg","idiom":"universal"}],"info":{"version":1,"author":"poki"},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"original"}}' > "$set/Contents.json"
  else
    echo '{"images":[{"filename":"mark.svg","idiom":"universal"}],"info":{"version":1,"author":"poki"},"properties":{"preserves-vector-representation":true,"template-rendering-intent":"original"}}' > "$set/Contents.json"
  fi
done
# Proxy apps' own App Store icons (Poki/ProxyIcons, see its README) beside their names in Setup.
for png in "$HERE"/Poki/ProxyIcons/*.png; do
  name="Proxy-$(basename "$png" .png)"
  mkdir -p "$APP/$name.imageset"
  cp "$png" "$APP/$name.imageset/icon@3x.png"
  echo '{"images":[{"filename":"icon@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"poki"}}' > "$APP/$name.imageset/Contents.json"
done
# Apps' own App Store icons (Poki/AppIcons) are not in the catalogue: the build copies the PNGs into
# the app and AppIconStore reads them there, so a stale catalogue cannot drop one.

# The Live Activity's bears (Poki/ActivityBears, see its README), one per pose, for the app's preview
# and the widget. In a catalogue, so the Live Activity's archive names them instead of carrying them.
bears() {
  for png in "$HERE"/Poki/ActivityBears/*.png; do
    name="$(basename "$png" .png)"
    mkdir -p "$1/$name.imageset"
    # Dedicated compact assets keep the source resolution within the small presentation.
    for spec in Compact:81 Small:66; do
      suffix="${spec%:*}"
      pixels="${spec#*:}"
      mkdir -p "$1/${name}${suffix}.imageset"
      sips -Z "$pixels" "$png" --out "$1/${name}${suffix}.imageset/bear@3x.png" >/dev/null
      echo '{"images":[{"filename":"bear@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"poki"}}' > "$1/${name}${suffix}.imageset/Contents.json"
    done
    cp "$png" "$1/$name.imageset/bear@3x.png"
    echo '{"images":[{"filename":"bear@3x.png","idiom":"universal","scale":"3x"}],"info":{"version":1,"author":"poki"}}' > "$1/$name.imageset/Contents.json"
  done
}
bears "$APP"

# The launch screen (Poki/LaunchArt/README.md). Layered so the worst case is still the right ground:
# - the storyboard's own ground is a system colour, which iOS draws in the right appearance with no
#   asset catalogue at all;
# - over it, the paper (LaunchGround), the light and the word come from the catalogue with a Dark
#   Mode version each, under names that carry the pictures' version. SplashBoard has drawn a launch
#   screen from an app's older catalogue after an update (#536): a versioned name it does not find
#   leaves the ground, never an older or a light picture;
# - the bear, the same in both appearances, stays a loose PNG, at 2x.
# The loose word, dark word and light stay for the welcome's hello and the tests.
LAUNCH="$HERE/Poki/LaunchArt"
LAUNCH_IMAGES="$HERE/Poki/LaunchImages"
rm -rf "$LAUNCH_IMAGES"
mkdir -p "$LAUNCH_IMAGES"
cp "$LAUNCH/LaunchBackdrop.png" "$LAUNCH_IMAGES/LaunchBackdrop.png"
swift "$HERE/scripts/make-launch-art.swift" "$HERE/Shared/Fonts/AlloRounded-Medium.ttf" "$LAUNCH/LaunchBear.png" \
  "$LAUNCH_IMAGES/LaunchWordmark@3x.png" "$LAUNCH_IMAGES/LaunchBear@2x.png" "$LAUNCH_IMAGES/LaunchWordmarkDark@3x.png"
LAUNCH_GROUND='"red":"0xF5","green":"0xF7","blue":"0xFA"'
LAUNCH_GROUND_DARK='"red":"0x05","green":"0x07","blue":"0x0D"'
LAUNCH_VERSION="$(cat "$LAUNCH/LaunchBackdrop.png" "$LAUNCH/LaunchBackdropDark.png" "$LAUNCH_IMAGES/LaunchWordmark@3x.png" \
  "$LAUNCH_IMAGES/LaunchWordmarkDark@3x.png" <(echo "$LAUNCH_GROUND $LAUNCH_GROUND_DARK") | shasum | cut -c1-10)"
dark='"appearances":[{"appearance":"luminosity","value":"dark"}],'
mkdir -p "$APP/LaunchBackdrop-$LAUNCH_VERSION.imageset" "$APP/LaunchWord-$LAUNCH_VERSION.imageset" "$APP/LaunchGround-$LAUNCH_VERSION.colorset"
cp "$LAUNCH/LaunchBackdrop.png" "$APP/LaunchBackdrop-$LAUNCH_VERSION.imageset/light.png"
cp "$LAUNCH/LaunchBackdropDark.png" "$APP/LaunchBackdrop-$LAUNCH_VERSION.imageset/dark.png"
echo "{\"images\":[{\"filename\":\"light.png\",\"idiom\":\"universal\",\"scale\":\"1x\"},{$dark\"filename\":\"dark.png\",\"idiom\":\"universal\",\"scale\":\"1x\"}],\"info\":{\"version\":1,\"author\":\"poki\"}}" > "$APP/LaunchBackdrop-$LAUNCH_VERSION.imageset/Contents.json"
cp "$LAUNCH_IMAGES/LaunchWordmark@3x.png" "$APP/LaunchWord-$LAUNCH_VERSION.imageset/light@3x.png"
cp "$LAUNCH_IMAGES/LaunchWordmarkDark@3x.png" "$APP/LaunchWord-$LAUNCH_VERSION.imageset/dark@3x.png"
echo "{\"images\":[{\"filename\":\"light@3x.png\",\"idiom\":\"universal\",\"scale\":\"3x\"},{$dark\"filename\":\"dark@3x.png\",\"idiom\":\"universal\",\"scale\":\"3x\"}],\"info\":{\"version\":1,\"author\":\"poki\"}}" > "$APP/LaunchWord-$LAUNCH_VERSION.imageset/Contents.json"
echo "{\"colors\":[{\"idiom\":\"universal\",\"color\":{\"color-space\":\"srgb\",\"components\":{$LAUNCH_GROUND,\"alpha\":\"1.000\"}}},{$dark\"idiom\":\"universal\",\"color\":{\"color-space\":\"srgb\",\"components\":{$LAUNCH_GROUND_DARK,\"alpha\":\"1.000\"}}}],\"info\":{\"version\":1,\"author\":\"poki\"}}" > "$APP/LaunchGround-$LAUNCH_VERSION.colorset/Contents.json"
sed "s/__V__/$LAUNCH_VERSION/g" "$LAUNCH/LaunchScreen.storyboard" > "$HERE/Poki/LaunchScreen.storyboard"
echo "launch pictures version $LAUNCH_VERSION"

WIDGET="$HERE/PokiWidgets/Assets.xcassets"
catalog "$WIDGET"
bear "$WIDGET"
bears "$WIDGET"
# The calling agent's logo on the Live Activity.
logos "$WIDGET"
echo "assets in $APP and $WIDGET"
