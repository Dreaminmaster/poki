#!/usr/bin/env bash
set -euo pipefail

mode=${1:?Usage: build.sh check|build|test [aarch64-apple-ios[-sim]|host]}
if [[ "$mode" == test ]]; then
    target=${2:-host}
    [[ "$target" == host ]] || exit 2
else
    target=${2:?Usage: build.sh check|build aarch64-apple-ios[-sim]}
    case "$target" in aarch64-apple-ios|aarch64-apple-ios-sim) ;; *) exit 2 ;; esac
fi
case "$mode" in check|build|test) ;; *) exit 2 ;; esac

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
if [[ "$target" != host ]] && ! rustup target list --toolchain stable --installed | grep -Fxq "$target"; then
    rustup target add --toolchain stable "$target"
fi

adapter_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$adapter_dir/../.." && pwd)
revision=6aaac694803004a63c6f393d153c96d22521a6b9
build_dir="$repo/build/codex-voice/$target"
source_dir="$build_dir/$revision"
mkdir -p "$build_dir"
if [[ "$target" == host && ! -f "$source_dir/.poki-prepared" ]]; then
    for existing in "$repo/build/codex-voice/aarch64-apple-ios-sim/$revision" "$repo/build/codex-voice/aarch64-apple-ios/$revision"; do
        if [[ -f "$existing/.poki-prepared" ]]; then
            source_dir="$existing"
            break
        fi
    done
fi
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
# Extend the pinned upstream lockfile in both fresh and previously prepared build trees.
python3 - "$workspace/Cargo.lock" <<'PY'
from pathlib import Path
import sys

lock = Path(sys.argv[1])
contents = lock.read_text()
header, *packages = contents.split('[[package]]\n')

def update_dependency(package, dependency):
    prefix = f'name = "{package}"\n'
    index = next(i for i, entry in enumerate(packages) if entry.startswith(prefix))
    entry = packages[index]
    if dependency not in entry:
        packages[index] = entry.replace('\n]\n', f'\n {dependency},\n]\n', 1)

update_dependency('poki-codex-voice', '"tokio-tungstenite"')
update_dependency('tokio-tungstenite', '"webpki-roots 0.26.11"')

roots = next(i for i, entry in enumerate(packages) if entry.startswith('name = "webpki-roots"\nversion = "1.0.10"\n'))
if not any(entry.startswith('name = "webpki-roots"\nversion = "0.26.11"\n') for entry in packages):
    # The connector's 0.26 package re-exports the 1.0.10 roots pinned in the upstream lockfile.
    for entry_index, entry in enumerate(packages):
        packages[entry_index] = entry.replace('\n "webpki-roots",\n', '\n "webpki-roots 1.0.10",\n')
    packages.insert(roots, '''name = "webpki-roots"
version = "0.26.11"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "521bc38abb08001b01866da9f51eb7c5d647a19260e00054a8c7fd5f9e57f7a9"
dependencies = [
 "webpki-roots 1.0.10",
]

''')

updated = '[[package]]\n'.join([header, *packages])
if updated != contents:
    lock.write_text(updated)
PY
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
if [[ "$mode" == test ]]; then
    cargo +stable test "${options[@]}" --lib -p poki-codex-voice -- --nocapture
else
    cargo +stable "$mode" "${options[@]}" --target "$target" -p poki-codex-voice
fi
