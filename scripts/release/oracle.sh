#!/usr/bin/env bash
# Runs the release picker of an old Poki build itself, cut out of that build's source, over the
# same releases first-hop-check.mjs reads, and fails when the port in that script answers
# differently. Needs rustc; nothing is downloaded or published.
#
#   oracle.sh <plan.json> [first-hop-check.mjs options]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_TAG="${OLD_CLIENT_TAG:-app-0.3.1-alpha.752}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The picker's types and functions, by line, from desktop/core/src/release.rs at that tag. Only the
# serde attributes are dropped, so the file compiles without the crate's dependencies.
{
  echo '#![allow(dead_code)]'
  git -C "$HERE" show "$SOURCE_TAG:desktop/core/src/release.rs" \
    | sed -n -e '11,42p' -e '49,148p' -e '204,250p' -e '300,323p' -e '490,517p' \
    | sed -e '/#\[serde/d' -e 's/, Serialize, Deserialize//' -e 's/#\[derive(Deserialize, Clone)\]/#[derive(Clone)]/'
  cat "$HERE/oracle-main.rs"
} > "$WORK/oracle.rs"
rustc --edition 2021 -O -o "$WORK/oracle" "$WORK/oracle.rs" 2> "$WORK/rustc.log" || { cat "$WORK/rustc.log" >&2; exit 1; }

node "$HERE/first-hop-check.mjs" "$@" --oracle-dir "$WORK/states" > /dev/null || true
status=0
for input in "$WORK"/states/*.in; do
  name="$(basename "$input" .in)"
  if "$WORK/oracle" < "$input" | diff -u - "$WORK/states/$name.port" > "$WORK/$name.diff"; then
    echo "same picks as $SOURCE_TAG: $name"
  else
    echo "DIFFERENT picks from $SOURCE_TAG: $name"; cat "$WORK/$name.diff"; status=1
  fi
done
exit $status
