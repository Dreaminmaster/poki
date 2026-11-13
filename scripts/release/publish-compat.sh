#!/usr/bin/env bash
# Publishes one already-built Poki under a name that installed clients can install, next to the
# releases the workflows make. Poki offers an update by the build number in the IPA's
# file name and installs it only when the signed copy reports the same number, so a Beta named
# Poki-external-0.4.0-beta.1.ipa never installs from the iPhone; and both Poki and Poki Setup keep
# one Poki-signing.zip per release tag, so a rolling tag can pair a new build with an old zip.
# See docs/release-channels.md, "Installed clients".
#
#   publish-compat.sh alpha <version> <build> [check|draft|public]
#       The Alpha as a release of its own, on the tag Promote to Alpha made: app-<version>-alpha.<build>.
#   publish-compat.sh beta <version> <build> [check|draft|public]
#       The Beta under its build number: ios-beta-<version>-<build>. Make it public just before the
#       Beta itself is approved, so Stable and Beta users are never offered the beta-named file alone.
#
# check (the default) downloads the Pre-alpha run's files, verifies them and prints what would be
# published. draft uploads a draft release, which no client can see. public publishes that draft.
# draft and public are the repository owner's to run, or to ask for: they are not behind an
# environment approval. Needs gh, unzip, python3 and a checkout that has the tag.
set -euo pipefail
KIND="${1:-}" VERSION="${2:-}" BUILD="${3:-}" MODE="${4:-check}"
REPO="${GH_REPO:-JosssphZhou/poki}"
# The external entitlements of builds 752, 1130 and 1174, as old clients read them from the zip.
KNOWN_ENTITLEMENTS="c38bcbe3e3e0915c27edc11f8ab59a4fcf7b995b0b78f6ed0195d439a0b5de93"
ALPHA_TAG="app-$VERSION-alpha.$BUILD"
case "$KIND" in
  alpha) TAG="$ALPHA_TAG"; TITLE="Poki v$VERSION ($BUILD) Alpha"; WHAT="Alpha build $BUILD" ;;
  beta) TAG="ios-beta-$VERSION-$BUILD"; TITLE="Poki v$VERSION Beta (build $BUILD)"; WHAT="the Beta of Poki $VERSION, build $BUILD" ;;
  *) sed -n '2,20p' "$0"; exit 64 ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ && "$MODE" =~ ^(check|draft|public)$ ]] || { sed -n '2,20p' "$0"; exit 64; }
IPA="Poki-external-$VERSION-$BUILD.ipa"

if [ "$MODE" = public ]; then
  [ "$(gh release view "$TAG" -R "$REPO" --json isDraft --jq .isDraft)" = true ] || { echo "$TAG is not a draft; run draft first"; exit 1; }
  gh release edit "$TAG" -R "$REPO" --draft=false --prerelease --latest=false
  echo "Public: https://github.com/$REPO/releases/tag/$TAG"
  exit 0
fi

SHA="$(gh api "repos/$REPO/commits/$ALPHA_TAG" --jq .sha)" || { echo "No $ALPHA_TAG yet: promote the build to Alpha first"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RUN="$(gh run list -R "$REPO" --workflow prealpha.yml --commit "$SHA" --status success --json databaseId --jq '.[0].databaseId')"
[ -n "$RUN" ] || { echo "No successful Pre-alpha run built $SHA"; exit 1; }
gh run download "$RUN" -R "$REPO" --name Poki-unsigned --dir "$WORK/src"
mkdir "$WORK/dist"
cp "$WORK/src/Poki-external-unsigned.ipa" "$WORK/dist/$IPA"
cp "$WORK/src/Poki-signing.zip" "$WORK/dist/"
git show "$SHA:deploy/cf-relay/worker.js" > "$WORK/dist/poki-relay-worker.js"
(cd "$WORK/dist" && shasum -a 256 "$IPA" poki-relay-worker.js > SHA256SUMS)

# The file name has to say what the IPA says about itself.
inside="$(unzip -p "$WORK/dist/$IPA" 'Payload/*.app/Info.plist' | python3 -c 'import plistlib, sys; p = plistlib.loads(sys.stdin.buffer.read()); print(p["CFBundleShortVersionString"], p["CFBundleVersion"])')"
[ "$inside" = "$VERSION $BUILD" ] || { echo "The IPA is Poki $inside, not $VERSION $BUILD"; exit 1; }

# The same bytes the Alpha channel already carries, so this is a second name, not a second build.
sum="$(shasum -a 256 "$WORK/dist/$IPA" | cut -d' ' -f1)"
rolling="$(gh api "repos/$REPO/releases/tags/app-alpha-latest" --jq ".assets[] | select(.name == \"$IPA\") | .digest")"
[ "$rolling" = "sha256:$sum" ] || { echo "app-alpha-latest does not carry $IPA with sha256 $sum (it has: ${rolling:-another build})"; exit 1; }

zip="$WORK/dist/Poki-signing.zip"
entitlements="$(unzip -Z1 "$zip" | grep -E '(^|/)external/[^/]+\.entitlements$' | LC_ALL=C sort | while read -r f; do printf '%s ' "$(basename "$f")"; unzip -p "$zip" "$f" | shasum -a 256 | cut -d' ' -f1; done | shasum -a 256 | cut -d' ' -f1)"

cat > "$WORK/notes.md" <<EOF
This is $WHAT (commit ${SHA:0:7}), the same file as on the Alpha channel, published under its build number so that a Poki that is already installed can update to it from the iPhone.

If Poki stays on "Finishing the update" after it installs, swipe Poki away in the app switcher and open it again, then read the version in Settings. If the version did not change, update from Poki Setup on your computer. Do not delete Poki: deleting it removes your chats.
EOF

echo "Release: $TAG ($TITLE), prerelease, at $SHA"
echo "Files:"; (cd "$WORK/dist" && ls -l | sed 1d | awk '{print "  " $NF " (" $5 " bytes)"}')
echo "IPA: Poki $inside, sha256 $sum, the same as on app-alpha-latest"
echo "Entitlements digest: $entitlements$([ "$entitlements" = "$KNOWN_ENTITLEMENTS" ] && echo ' (unchanged since builds 752, 1130 and 1174)' || echo ' (CHANGED: pass it to first-hop-check.mjs --entitlements)')"
echo "Notes:"; sed 's/^/  /' "$WORK/notes.md"
[ "$MODE" = draft ] || { echo "Checked only; nothing was uploaded."; exit 0; }

if [ "$KIND" = alpha ]; then where=(--verify-tag); else where=(--target "$SHA"); fi
gh release create "$TAG" -R "$REPO" "$WORK"/dist/* "${where[@]}" --draft --prerelease --latest=false --title "$TITLE" --notes-file "$WORK/notes.md"
have="$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets | length')"
[ "$have" -eq 4 ] || { echo "The draft has $have files, expected 4; left as a draft"; exit 1; }
echo "Draft made. Publish it with: $0 $KIND $VERSION $BUILD public"
