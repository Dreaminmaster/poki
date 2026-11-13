// scripts/release/publish-compat.sh makes a release public outside any workflow approval, so its
// public step is checked here against a stand-in for gh: no request leaves this machine. The
// stand-in answers reads from files and records every call; "published" below means the script
// asked GitHub to take the release out of draft.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const script = process.env.PUBLISH_COMPAT_SCRIPT ?? join(root, 'scripts/release/publish-compat.sh');
const TAG = 'ios-beta-0.4.0-1175';
const IPA = 'Poki-external-0.4.0-1175.ipa';
const sha = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const digest = bytes => `sha256:${createHash('sha256').update(bytes).digest('hex')}`;

const GH = `#!/usr/bin/env node
const { appendFileSync, cpSync, existsSync, readFileSync } = require('node:fs');
const { join } = require('node:path');
const dir = process.env.GH_STUB, args = process.argv.slice(2);
appendFileSync(join(dir, 'calls'), args.join(' ') + '\\n');
const out = text => process.stdout.write(text + '\\n');
const file = name => join(dir, name);
if (args[0] === 'api' && args[1].includes('/commits/')) {
  const at = file('commit-' + args[1].split('/').pop());
  if (!existsSync(at)) process.exit(1);
  out(readFileSync(at, 'utf8').trim());
} else if (args[0] === 'api') out(readFileSync(file('rolling-digest'), 'utf8').trim());
else if (args[0] === 'run' && args[1] === 'list') out('1');
else if (args[0] === 'run' && args[1] === 'download') cpSync(file('artifact'), args[args.indexOf('--dir') + 1], { recursive: true });
else if (args[0] === 'release' && args[1] === 'view') {
  const at = file('release-' + args[2] + '.json');
  if (!existsSync(at)) process.exit(1);
  const release = JSON.parse(readFileSync(at, 'utf8'));
  const jq = args.indexOf('--jq');
  out(jq < 0 ? JSON.stringify(release) : String(release[args[jq + 1].slice(1)]));
}
`;

// A draft as GitHub reports it once all four files of the checked build are uploaded.
function setUp(t) {
  const dir = mkdtempSync(join(tmpdir(), 'publish-compat-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'bin'));
  mkdirSync(join(dir, 'artifact'));
  writeFileSync(join(dir, 'bin/gh'), GH);
  chmodSync(join(dir, 'bin/gh'), 0o755);
  execFileSync('python3', ['-c', `
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1] + "/Poki-external-unsigned.ipa", "w") as z:
    z.writestr("Payload/Poki.app/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "1175"}))
with zipfile.ZipFile(sys.argv[1] + "/Poki-signing.zip", "w") as z:
    z.writestr("external/Poki.entitlements", "<plist/>")
`, join(dir, 'artifact')]);
  const ipa = readFileSync(join(dir, 'artifact/Poki-external-unsigned.ipa'));
  const worker = execFileSync('git', ['show', `${sha}:deploy/cf-relay/worker.js`], { cwd: root });
  const sums = `${digest(ipa).slice(7)}  ${IPA}\n${digest(worker).slice(7)}  poki-relay-worker.js\n`;
  writeFileSync(join(dir, 'commit-app-0.4.0-alpha.1175'), sha);
  writeFileSync(join(dir, 'rolling-digest'), digest(ipa));
  const asset = (name, bytes) => ({ name, state: 'uploaded', digest: digest(bytes) });
  const release = {
    isDraft: true, isPrerelease: true, name: 'Poki v0.4.0 Beta (build 1175)', tagName: TAG, targetCommitish: sha,
    assets: [asset(IPA, ipa), asset('Poki-signing.zip', readFileSync(join(dir, 'artifact/Poki-signing.zip'))), asset('poki-relay-worker.js', worker), asset('SHA256SUMS', sums)],
  };
  const save = () => writeFileSync(join(dir, `release-${TAG}.json`), JSON.stringify(release));
  save();
  return {
    release, save,
    run(...extra) {
      const done = spawnSync('bash', [script, 'beta', '0.4.0', '1175', 'public', ...extra], { cwd: root, encoding: 'utf8', env: { ...process.env, GH_STUB: dir, GH_REPO: 'example/poki', PATH: `${join(dir, 'bin')}:${process.env.PATH}` } });
      const calls = existsSync(join(dir, 'calls')) ? readFileSync(join(dir, 'calls'), 'utf8').split('\n') : [];
      return { status: done.status, output: done.stdout + done.stderr, published: calls.filter(call => call.startsWith('release edit')) };
    },
  };
}

test('public publishes a draft that holds the four checked files, once confirmed', t => {
  const draft = setUp(t);
  const done = draft.run('--confirm', TAG);
  assert.equal(done.status, 0, done.output);
  assert.equal(done.published.length, 1, done.output);
  assert.match(done.published[0], new RegExp(`^release edit ${TAG} .*--draft=false`));
});

test('public leaves a draft with a file missing as a draft', t => {
  const draft = setUp(t);
  draft.release.assets = draft.release.assets.filter(asset => asset.name !== 'Poki-signing.zip');
  draft.save();
  const done = draft.run('--confirm', TAG);
  assert.notEqual(done.status, 0, done.output);
  assert.deepEqual(done.published, [], done.output);
  assert.match(done.output, /Poki-signing\.zip/);
});

test('public leaves a draft whose IPA is not the Pre-alpha build as a draft', t => {
  const draft = setUp(t);
  draft.release.assets[0].digest = digest('another build');
  draft.save();
  const done = draft.run('--confirm', TAG);
  assert.notEqual(done.status, 0, done.output);
  assert.deepEqual(done.published, [], done.output);
});

test('public without the confirmation names the tag and the files, and publishes nothing', t => {
  const draft = setUp(t);
  for (const extra of [[], ['--confirm', 'app-0.4.0-alpha.1175']]) {
    const done = draft.run(...extra);
    assert.notEqual(done.status, 0, done.output);
    assert.deepEqual(done.published, [], done.output);
    for (const shown of [TAG, IPA, 'Poki-signing.zip', 'poki-relay-worker.js', 'SHA256SUMS']) assert.ok(done.output.includes(shown), `${shown} is not shown:\n${done.output}`);
  }
});
