#!/usr/bin/env bash
# Publishes one already-built Poki under a name that installed clients can install, next to the
# releases the workflows make. Poki offers an update by the build number in the IPA's
# file name and installs it only when the signed copy reports the same number, so a Beta named
# Poki-external-0.4.0-beta.1.ipa never installs from the iPhone; and both Poki and Poki Setup keep
# one Poki-signing.zip per release tag, so a rolling tag can pair a new build with an old zip.
# See docs/release-channels.md, "Installed clients".
#
#   publish-compat.sh alpha <version> <build> [check|draft|public] [--confirm <tag>]
#       The Alpha as a release of its own, on the tag Promote to Alpha made: app-<version>-alpha.<build>.
#   publish-compat.sh beta <version> <build> [check|draft|public] [--confirm <tag>]
#       The Beta under its build number: ios-beta-<version>-<build>. Make it public just before the
#       Beta itself is approved, so Stable and Beta users are never offered the beta-named file alone.
#
# check (the default) downloads the Pre-alpha run's files, verifies them and prints what would be
# published; before Promote to Alpha it checks the Pre-alpha build. draft uploads a draft release,
# which no client can see. public checks that draft again, file by file, against the same Pre-alpha
# files, and makes it public only with --confirm <the release's tag>; without it, it prints what
# would become public and stops.
#
# draft and public write to GitHub outside any environment approval. Only the repository owner runs
# them, or someone the owner has told to in so many words for this build; a draft that exists is not
# that permission. Needs gh, unzip, python3 and a checkout that has the commit.
set -euo pipefail
usage() { sed -n '2,23p' "$0"; exit 64; }
KIND="${1:-}" VERSION="${2:-}" BUILD="${3:-}" MODE=check CONFIRM=""
[ $# -ge 3 ] || usage
shift 3
while [ $# -gt 0 ]; do
  case "$1" in
    check|draft|public) MODE="$1"; shift ;;
    --confirm) [ $# -ge 2 ] || usage; CONFIRM="$2"; shift 2 ;;
    *) usage ;;
  esac
done
REPO="${GH_REPO:-JosssphZhou/poki}"
# The external entitlements of builds 752, 1130 and 1174, as old clients read them from the zip.
KNOWN_ENTITLEMENTS="c38bcbe3e3e0915c27edc11f8ab59a4fcf7b995b0b78f6ed0195d439a0b5de93"
ALPHA_TAG="app-$VERSION-alpha.$BUILD"
case "$KIND" in
  alpha) TAG="$ALPHA_TAG"; TITLE="Poki v$VERSION ($BUILD) Alpha"; WHAT="Alpha build $BUILD" ;;
  beta) TAG="ios-beta-$VERSION-$BUILD"; TITLE="Poki v$VERSION Beta (build $BUILD)"; WHAT="the Beta of Poki $VERSION, build $BUILD" ;;
  *) usage ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || usage
IPA="Poki-external-$VERSION-$BUILD.ipa"
commit_of() { gh api "repos/$REPO/commits/$1" --jq .sha 2>/dev/null; }

# ---- The four files, rebuilt from the Pre-alpha run every time, whatever the mode. ----

ROLLING=app-alpha-latest
if ! SHA="$(commit_of "$ALPHA_TAG")"; then
  [ "$MODE" = check ] || { echo "No $ALPHA_TAG yet: promote the build to Alpha first"; exit 1; }
  ROLLING=app-prealpha-latest
  SHA="$(commit_of "app-$VERSION-prealpha.$BUILD")" || { echo "Neither $ALPHA_TAG nor app-$VERSION-prealpha.$BUILD exists: is $BUILD the build?"; exit 1; }
  echo "Not promoted to Alpha yet: this checks the Pre-alpha build, so a changed Poki-signing.zip shows before Alpha users get it."
fi
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

# The same bytes the channel already carries, so this is a second name, not a second build.
sum="$(shasum -a 256 "$WORK/dist/$IPA" | cut -d' ' -f1)"
rolling="$(gh api "repos/$REPO/releases/tags/$ROLLING" --jq ".assets[] | select(.name == \"$IPA\") | .digest")"
[ "$rolling" = "sha256:$sum" ] || { echo "$ROLLING does not carry $IPA with sha256 $sum (it has: ${rolling:-another build})"; exit 1; }

zip="$WORK/dist/Poki-signing.zip"
entitlements="$(unzip -Z1 "$zip" | grep -E '(^|/)external/[^/]+\.entitlements$' | LC_ALL=C sort | while read -r f; do printf '%s ' "$(basename "$f")"; unzip -p "$zip" "$f" | shasum -a 256 | cut -d' ' -f1; done | shasum -a 256 | cut -d' ' -f1)"

# One line per file, as GitHub has to report it for the release to be what was checked here.
(cd "$WORK/dist" && for f in *; do printf '%s\tuploaded\tsha256:%s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; done | LC_ALL=C sort) > "$WORK/expected"
[ "$(wc -l < "$WORK/expected" | tr -d ' ')" -eq 4 ] || { echo "Expected four files to publish, have: $(ls "$WORK/dist" | tr '\n' ' ')"; exit 1; }

cat > "$WORK/notes.md" <<EOF
This is $WHAT (commit ${SHA:0:7}), the same file as on the Alpha channel, published under its build number so that a Poki that is already installed can update to it from the iPhone.

If Poki stays on "Finishing the update" after it installs, swipe Poki away in the app switcher and open it again, then read the version in Settings. If the version did not change, update from Poki Setup on your computer. Do not delete Poki: deleting it removes your chats.
EOF

echo "Release: $TAG ($TITLE), prerelease, at $SHA"
echo "Files:"; (cd "$WORK/dist" && ls -l | sed 1d | awk '{print "  " $NF " (" $5 " bytes)"}')
echo "IPA: Poki $inside, sha256 $sum, the same as on $ROLLING"
echo "Entitlements digest: $entitlements$([ "$entitlements" = "$KNOWN_ENTITLEMENTS" ] && echo ' (unchanged since builds 752, 1130 and 1174)' || echo ' (CHANGED: pass it to first-hop-check.mjs --entitlements, and tell the owner before Alpha moves)')"
[ "$MODE" != check ] || { echo "Notes:"; sed 's/^/  /' "$WORK/notes.md"; echo "Checked only; nothing was uploaded."; exit 0; }

# ---- The release on GitHub. ----

# A tag that is already there has to be on this commit: --target does not move it.
if [ "$KIND" = beta ] && there="$(commit_of "$TAG")" && [ "$there" != "$SHA" ]; then
  echo "The tag $TAG already exists on $there, not on $SHA"; exit 1
fi

# Fails unless the release is a draft that holds exactly the four files above, byte for byte.
verify_draft() {
  gh release view "$TAG" -R "$REPO" --json isDraft,isPrerelease,name,tagName,targetCommitish,assets > "$WORK/release.json" || { echo "No release $TAG to check; run draft first"; return 1; }
  KIND="$KIND" TAG="$TAG" TITLE="$TITLE" SHA="$SHA" python3 - "$WORK/release.json" "$WORK/expected" <<'PY'
import json, os, sys
release = json.load(open(sys.argv[1]))
expected = open(sys.argv[2]).read().splitlines()
problems = []
if release.get("isDraft") is not True: problems.append("it is not a draft")
if release.get("isPrerelease") is not True: problems.append("it is not marked as a prerelease")
if release.get("tagName") != os.environ["TAG"]: problems.append(f"its tag is {release.get('tagName')}")
if release.get("name") != os.environ["TITLE"]: problems.append(f"its title is {release.get('name')!r}")
if os.environ["KIND"] == "beta" and release.get("targetCommitish") != os.environ["SHA"]: problems.append(f"it targets {release.get('targetCommitish')}")
have = sorted("\t".join([a.get("name") or "", a.get("state") or "", a.get("digest") or "no digest"]) for a in release.get("assets", []))
for line in expected:
    if line not in have: problems.append("missing or different: " + line.split("\t")[0])
for line in have:
    if line not in expected: problems.append("not from this build: " + " ".join(line.split("\t")))
if problems:
    print(f"The release {os.environ['TAG']} is not the checked build:")
    for p in problems: print("  " + p)
    sys.exit(1)
PY
}

if [ "$MODE" = draft ]; then
  if [ "$KIND" = alpha ]; then where=(--verify-tag); else where=(--target "$SHA"); fi
  gh release create "$TAG" -R "$REPO" "$WORK"/dist/* "${where[@]}" --draft --prerelease --latest=false --title "$TITLE" --notes-file "$WORK/notes.md"
  verify_draft || { echo "Left as a draft. Delete it (gh release delete $TAG -R $REPO) and run draft again."; exit 1; }
  echo "Draft made and checked. The owner publishes it with: $0 $KIND $VERSION $BUILD public --confirm $TAG"
  exit 0
fi

verify_draft || { echo "Nothing was published."; exit 1; }
echo "To be made public: $TAG ($TITLE). The draft holds exactly these files:"
cut -f1,3 "$WORK/expected" | sed 's/^/  /'
if [ "$CONFIRM" != "$TAG" ]; then
  echo "Nothing was published. To publish, the repository owner runs this again with: --confirm $TAG"
  exit 2
fi
gh release edit "$TAG" -R "$REPO" --draft=false --prerelease --latest=false
echo "Public: https://github.com/$REPO/releases/tag/$TAG"
