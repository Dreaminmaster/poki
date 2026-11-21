#!/usr/bin/env bash
set -euo pipefail

mode=${1:?Usage: build.sh check|build aarch64-apple-ios[-sim]}
target=${2:?Usage: build.sh check|build aarch64-apple-ios[-sim]}
case "$mode" in check|build) ;; *) exit 2 ;; esac
case "$target" in aarch64-apple-ios|aarch64-apple-ios-sim) ;; *) exit 2 ;; esac

adapter_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$adapter_dir/../.." && pwd)
revision=6aaac694803004a63c6f393d153c96d22521a6b9
build_dir="$repo/build/codex-voice/$target"
source_dir="$build_dir/$revision"
mkdir -p "$build_dir"
if [[ ! -f "$source_dir/.poki-prepared" ]]; then
    mkdir -p "$source_dir"
    curl -fsSL "https://codeload.github.com/openai/codex/tar.gz/$revision" \
        | tar -xz -C "$source_dir" --strip-components 1
    python3 - "$source_dir/codex-rs" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def change(relative_path, old, new):
    path = root / relative_path
    content = path.read_text()
    if old not in content:
        raise SystemExit(f"Codex source no longer matches {relative_path}")
    path.write_text(content.replace(old, new, 1))

change("Cargo.toml", "members = [\n", 'members = [\n    "poki-codex-voice",\n')
change("mxc-sandbox/Cargo.toml", "mxc-sdk = { workspace = true }\n", "")
windows = "[target.'cfg(windows)'.dependencies]"
change("mxc-sandbox/Cargo.toml", windows, '''[target.'cfg(not(target_os = "ios"))'.dependencies]
mxc-sdk = { workspace = true }

''' + windows)
windows = '''[target.'cfg(target_os = "windows")'.dependencies]'''
change("keyring-store/Cargo.toml", windows, '''[target.'cfg(target_os = "ios")'.dependencies]
keyring = { workspace = true, features = ["apple-native"] }

''' + windows)

# This upstream release archive stamps its members at 0.164.0 but keeps the dev lock versions.
lock = root / "Cargo.lock"
content = lock.read_text().replace('version = "0.0.0"', 'version = "0.164.0"')
package = '''[[package]]
name = "poki-codex-voice"
version = "0.164.0"
dependencies = [
 "anyhow",
 "codex-app-server",
 "codex-app-server-protocol",
 "codex-config",
 "codex-core",
 "codex-exec-server",
 "codex-feedback",
 "codex-protocol",
 "serde_json",
 "tokio",
 "toml 0.9.11+spec-1.1.0",
]

'''
header, first_package = content.split("[[package]]", 1)
lock.write_text(header + package + "[[package]]" + first_package)
PY
    touch "$source_dir/.poki-prepared"
fi

workspace="$source_dir/codex-rs"
mkdir -p "$workspace/poki-codex-voice/src"
for file in Cargo.toml src/lib.rs; do
    cmp -s "$adapter_dir/$file" "$workspace/poki-codex-voice/$file" \
        || cp "$adapter_dir/$file" "$workspace/poki-codex-voice/$file"
done

options=(--locked)
if [[ "$mode" == build ]]; then
    options+=(--release)
fi
cd "$workspace"
export CARGO_TARGET_DIR="$build_dir/target"
export CARGO_PROFILE_RELEASE_DEBUG=0
cargo +stable "$mode" "${options[@]}" --target "$target" -p poki-codex-voice
