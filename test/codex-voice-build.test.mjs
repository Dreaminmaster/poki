import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

function makeFixtureRepo(t) {
  const root = mkdtempSync(join(tmpdir(), 'poki-codex-voice-build-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const binDir = join(root, 'bin');
  const adapterDir = join(root, 'native', 'codex-voice');
  const adapterSrc = join(adapterDir, 'src');
  mkdirSync(binDir, { recursive: true });
  mkdirSync(adapterSrc, { recursive: true });

  copyFileSync(join(repoRoot, 'native', 'codex-voice', 'build.sh'), join(adapterDir, 'build.sh'));
  copyFileSync(join(repoRoot, 'native', 'codex-voice', 'Cargo.toml'), join(adapterDir, 'Cargo.toml'));
  copyFileSync(join(repoRoot, 'native', 'codex-voice', 'poki_codex_voice.h'), join(adapterDir, 'poki_codex_voice.h'));
  writeFileSync(join(adapterSrc, 'lib.rs'), '// fixture\n');

  const revision = readFileSync(join(adapterDir, 'build.sh'), 'utf8').match(/^revision=([0-9a-f]+)$/m)?.[1];
  assert.ok(revision, 'build.sh must pin an upstream codex revision');

  const workspace = join(root, 'build', 'codex-voice', 'aarch64-apple-ios', revision, 'codex-rs');
  mkdirSync(join(workspace, 'http-client', 'src'), { recursive: true });
  mkdirSync(join(workspace, 'core', 'src', 'tools'), { recursive: true });
  mkdirSync(join(workspace, 'login', 'src'), { recursive: true });
  writeFileSync(join(root, 'build', 'codex-voice', 'aarch64-apple-ios', revision, '.poki-prepared'), '');
  writeFileSync(join(workspace, 'Cargo.lock'), [
    'version = 4',
    '',
    '[[package]]',
    'name = "poki-codex-voice"',
    'version = "0.164.0"',
    'dependencies = [',
    ' "tokio-tungstenite",',
    ']',
    '',
    '[[package]]',
    'name = "tokio-tungstenite"',
    'version = "0.28.0"',
    'dependencies = [',
    ' "webpki-roots 0.26.11",',
    ']',
    '',
    '[[package]]',
    'name = "codex-http-client"',
    'version = "0.164.0"',
    'dependencies = [',
    ' "webpki-roots 1.0.10",',
    ']',
    '',
    '[[package]]',
    'name = "webpki-roots"',
    'version = "0.26.11"',
    'dependencies = [',
    ' "webpki-roots 1.0.10",',
    ']',
    '',
    '[[package]]',
    'name = "webpki-roots"',
    'version = "1.0.10"',
    '',
  ].join('\n'));
  writeFileSync(
    join(workspace, 'http-client', 'Cargo.toml'),
    '[target.\'cfg(target_os = "ios")\'.dependencies]\nwebpki-roots = "1.0.10"\n',
  );
  writeFileSync(
    join(workspace, 'http-client', 'src', 'native_roots.rs'),
    '// webpki_roots::TLS_SERVER_ROOTS\n',
  );
  writeFileSync(
    join(workspace, 'core', 'src', 'tools', 'mod.rs'),
    '// matches!(requested_tool_mode, ToolMode::CodeMode | ToolMode::CodeModeOnly)\n',
  );

  writeFileSync(
    join(workspace, 'login', 'src', 'success_page.rs'),
    'fn compose_success_url(\n) -> LoginSuccessRedirect {\n    let token_claims = jwt_auth_claims(id_token);\n}\n',
  );
  writeFileSync(
    join(workspace, 'login', 'src', 'server.rs'),
    'fn login_error_response() {\n    let body = render_login_error_page(message, error_code, error_description);\n}\n',
  );

  const cargoLog = join(root, 'cargo.log');
  writeFileSync(join(binDir, 'rustup'), [
    '#!/usr/bin/env bash',
    'echo "aarch64-apple-ios"',
  ].join('\n'), { mode: 0o755 });
  writeFileSync(join(binDir, 'cargo'), [
    '#!/usr/bin/env bash',
    'set -euo pipefail',
    `printf 'ARGS=%s LTO=%s OPT=%s CGU=%s DEBUG=%s\\n' "$*" "\${CARGO_PROFILE_RELEASE_LTO:-}" "\${CARGO_PROFILE_RELEASE_OPT_LEVEL:-}" "\${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-}" "\${CARGO_PROFILE_RELEASE_DEBUG:-}" >> "${cargoLog}"`,
    'out="$CARGO_TARGET_DIR/aarch64-apple-ios/release"',
    'mkdir -p "$out"',
    'printf "fake-archive" > "$out/libpoki_codex_voice.a"',
  ].join('\n'), { mode: 0o755 });

  return { root, binDir, adapterDir, adapterSrc, cargoLog, workspace };
}

test('codex-voice build.sh disables cross-crate ThinLTO by default and skips rebuilds on matching stamp', t => {
  const { root, binDir, adapterDir, adapterSrc, cargoLog, workspace } = makeFixtureRepo(t);
  const env = {
    PATH: `${binDir}:/usr/bin:/bin`,
    HOME: join(root, 'empty-home'),
  };
  mkdirSync(env.HOME, { recursive: true });

  const first = spawnSync('/bin/bash', [join(adapterDir, 'build.sh'), 'build', 'aarch64-apple-ios'], {
    encoding: 'utf8',
    env,
  });
  assert.equal(first.status, 0, first.stderr);

  const firstLog = readFileSync(cargoLog, 'utf8').trim().split('\n');
  assert.equal(firstLog.length, 1);
  assert.match(firstLog[0], /LTO=false\b/);
  assert.match(firstLog[0], /OPT=s\b/);
  assert.match(firstLog[0], /CGU=8\b/);
  assert.match(firstLog[0], /DEBUG=0\b/);

  // On iOS the Codex sign-in server hands the browser back to Poki instead of its localhost pages.
  const successPage = readFileSync(join(workspace, 'login', 'src', 'success_page.rs'), 'utf8');
  assert.match(successPage, /if cfg!\(target_os = "ios"\) \{\n        return LoginSuccessRedirect::Hosted\("poki-chatgpt:\/\/signed-in"/);
  const server = readFileSync(join(workspace, 'login', 'src', 'server.rs'), 'utf8');
  assert.match(server, /url=poki-chatgpt:\/\/signed-in\?error=1/);
  assert.match(server, /render_login_error_page\(message, error_code, error_description\)/);

  // Second build with unchanged inputs must hit the stamp fast path without invoking cargo.
  const second = spawnSync('/bin/bash', [join(adapterDir, 'build.sh'), 'build', 'aarch64-apple-ios'], {
    encoding: 'utf8',
    env,
  });
  assert.equal(second.status, 0, second.stderr);
  assert.equal(readFileSync(cargoLog, 'utf8').trim().split('\n').length, 1);

  // Editing an adapter source file must invalidate the stamp and invoke cargo again.
  writeFileSync(join(adapterSrc, 'lib.rs'), '// fixture updated\n');
  const third = spawnSync('/bin/bash', [join(adapterDir, 'build.sh'), 'build', 'aarch64-apple-ios'], {
    encoding: 'utf8',
    env,
  });
  assert.equal(third.status, 0, third.stderr);
  assert.equal(readFileSync(cargoLog, 'utf8').trim().split('\n').length, 2);
});

test('build-ipa and release workflows cache Codex Voice and expose Xcode script phases', () => {
  const buildIpa = readFileSync(join(repoRoot, '.github/actions/build-ipa/action.yml'), 'utf8');
  const prealpha = readFileSync(join(repoRoot, '.github/workflows/prealpha.yml'), 'utf8');
  const iosIpa = readFileSync(join(repoRoot, '.github/workflows/ios-ipa.yml'), 'utf8');

  assert.match(buildIpa, /codex-voice-key:/);
  assert.match(buildIpa, /codex-voice-hit:/);
  assert.match(buildIpa, /native\/codex-voice\/build\.sh build aarch64-apple-ios/);
  assert.match(buildIpa, /libpoki_codex_voice\.a\.sha256/);
  assert.match(buildIpa, /\^PhaseScriptExecution /);

  assert.match(prealpha, /steps\.build\.outputs\.codex-voice-hit != 'true'/);
  assert.match(prealpha, /steps\.build\.outputs\.codex-voice-key/);
  assert.match(iosIpa, /steps\.build\.outputs\.codex-voice-hit != 'true'/);
  assert.match(iosIpa, /steps\.build\.outputs\.codex-voice-key/);
});
