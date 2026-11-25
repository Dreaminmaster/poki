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

adapter_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$adapter_dir/../.." && pwd)
revision=6aaac694803004a63c6f393d153c96d22521a6b9
build_dir="$repo/build/codex-voice/$target"
source_dir="$build_dir/$revision"

# Upstream codex-rs enables cross-crate thin LTO (lto = "thin", opt-level = 3, codegen-units = 4),
# which spikes rustc to ~14 GB RSS and 18+ CPU-minutes when linking the staticlib on CI runners.
# Default to local-only LTO (lto = false) and size optimization (opt-level = "s") to cut peak
# memory, compile time, and archive size while keeping caller overrides intact.
release_lto="${CARGO_PROFILE_RELEASE_LTO:-false}"
release_opt_level="${CARGO_PROFILE_RELEASE_OPT_LEVEL:-s}"
release_codegen_units="${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-8}"
output_lib="$build_dir/target/$target/release/libpoki_codex_voice.a"
stamp_file="${output_lib}.sha256"

if [[ "$mode" == build ]]; then
    fingerprint=$(python3 - "$target" "$revision" "$release_lto" "$release_opt_level" "$release_codegen_units" \
        "$adapter_dir/build.sh" \
        "$adapter_dir/Cargo.toml" \
        "$adapter_dir/src/lib.rs" \
        "$adapter_dir/poki_codex_voice.h" <<'PY'
import hashlib, pathlib, sys
h = hashlib.sha256()
for meta in sys.argv[1:6]:
    h.update(meta.encode())
    h.update(b"\0")
for file_path in sys.argv[6:]:
    h.update(pathlib.Path(file_path).read_bytes())
    h.update(b"\0")
print(h.hexdigest())
PY
    )
    if [[ -s "$output_lib" && -f "$stamp_file" ]] && [[ "$(cat "$stamp_file")" == "$fingerprint" ]]; then
        echo "Codex Voice ($target) is up to date (cached)."
        exit 0
    fi
fi

if [[ "$target" != host ]] && ! rustup target list --toolchain stable --installed | grep -Fxq "$target"; then
    rustup target add --toolchain stable "$target"
fi

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
# Extend the pinned upstream lockfile and apply iOS runtime patches in both fresh and previously prepared build trees.
python3 - "$workspace" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
lock = root / "Cargo.lock"
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

update_dependency('codex-http-client', '"webpki-roots 1.0.10"')

updated = '[[package]]\n'.join([header, *packages])
if updated != contents:
    lock.write_text(updated)

def ensure_patch(relative_path, marker, old, new):
    path = root / relative_path
    text = path.read_text()
    if marker in text:
        return
    if old not in text:
        raise SystemExit(f"Codex source no longer matches {relative_path}")
    path.write_text(text.replace(old, new, 1))

# Responses WebSocket uses WebSocketTlsMode::ExplicitCodexTls, which builds a rustls RootCertStore
# from codex-http-client::native_roots::load(). On iOS, rustls-native-certs probes Unix paths that
# do not exist in the app sandbox, leaving an empty trust store. Include Mozilla's webpki-roots.
ensure_patch(
    "http-client/Cargo.toml",
    '[target.\'cfg(target_os = "ios")\'.dependencies]',
    '[target.\'cfg(target_os = "macos")\'.dependencies]',
    '[target.\'cfg(target_os = "ios")\'.dependencies]\nwebpki-roots = "1.0.10"\n\n[target.\'cfg(target_os = "macos")\'.dependencies]',
)
ensure_patch(
    "http-client/src/native_roots.rs",
    'webpki_roots::TLS_SERVER_ROOTS',
    '    let mut roots = RootCertStore::empty();\n    let _ = roots.add_parsable_certificates(certs);',
    '    let mut roots = RootCertStore::empty();\n    #[cfg(target_os = "ios")]\n    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());\n    let _ = roots.add_parsable_certificates(certs);',
)
# Models configured as code_mode_only fail closed when no codex-code-mode-host executable is
# available (which is always true on iOS and in embedded voice). Fall back to direct tool calls so
# dynamic phone tools remain directly callable.
ensure_patch(
    "core/src/tools/mod.rs",
    'matches!(requested_tool_mode, ToolMode::CodeMode | ToolMode::CodeModeOnly)',
    '    if !turn_context.code_mode_available\n        && requested_tool_mode == ToolMode::CodeMode\n        && !turn_context.config.code_mode.disable_in_process_fallback',
    '    if !turn_context.code_mode_available\n        && matches!(requested_tool_mode, ToolMode::CodeMode | ToolMode::CodeModeOnly)\n        && !turn_context.config.code_mode.disable_in_process_fallback',
)
# ChatGPT sign-in must use the Codex client's http loopback redirect URI. On iOS, the callback
# server hands the browser back to Poki's ASWebAuthenticationSession after the token exchange,
# so the sheet closes and Poki shows its own result instead of Codex's localhost pages.
ensure_patch(
    "login/src/success_page.rs",
    'poki-chatgpt://signed-in',
    ') -> LoginSuccessRedirect {\n    let token_claims = jwt_auth_claims(id_token);\n',
    ') -> LoginSuccessRedirect {\n    if cfg!(target_os = "ios") {\n        return LoginSuccessRedirect::Hosted("poki-chatgpt://signed-in".to_string());\n    }\n    let token_claims = jwt_auth_claims(id_token);\n',
)
ensure_patch(
    "login/src/server.rs",
    'poki-chatgpt://signed-in?error=1',
    '    let body = render_login_error_page(message, error_code, error_description);\n',
    '    let body = if cfg!(target_os = "ios") {\n        br#"<!doctype html><meta name="color-scheme" content="light dark"><meta http-equiv="refresh" content="0;url=poki-chatgpt://signed-in?error=1">"#.to_vec()\n    } else {\n        render_login_error_page(message, error_code, error_description)\n    };\n',
)
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
export CARGO_PROFILE_RELEASE_LTO="$release_lto"
export CARGO_PROFILE_RELEASE_OPT_LEVEL="$release_opt_level"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS="$release_codegen_units"
if [[ "$mode" == test ]]; then
    cargo +stable test "${options[@]}" --lib -p poki-codex-voice -- --nocapture
else
    cargo +stable "$mode" "${options[@]}" --target "$target" -p poki-codex-voice
    if [[ "$mode" == build && -s "$output_lib" ]]; then
        printf '%s\n' "$fingerprint" > "$stamp_file"
    fi
fi
