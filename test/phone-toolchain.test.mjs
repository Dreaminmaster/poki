import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const simulator = ['simulator', 'fixture-simulator'];
const device = ['device', 'fixture-iphone', 'FIXTURE123', 'com.example.poki', 'group.com.example.poki'];

function assertToolchainRejected(t, { xcode, iphoneos, iphonesimulator, args }) {
  const root = mkdtempSync(join(tmpdir(), 'poki-phone-toolchain-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  const scripts = join(root, 'scripts');
  mkdirSync(bin);
  mkdirSync(scripts);
  const script = join(scripts, 'phone.sh');
  copyFileSync(new URL('../scripts/phone.sh', import.meta.url), script);
  writeFileSync(join(bin, 'xcrun'), '#!/bin/bash\nexit 1\n', { mode: 0o755 });

  writeFileSync(join(bin, 'xcodebuild'), `#!/bin/bash
case "$*" in
  '-version')
    printf '%s\\n' 'Xcode ${xcode}' 'Build version Fixture'
    exit 0
    ;;
  '-version -sdk iphoneos SDKVersion') sdk='${iphoneos}' ;;
  '-version -sdk iphonesimulator SDKVersion') sdk='${iphonesimulator}' ;;
  *) exit 1 ;;
esac
[[ -n $sdk ]] || exit 1
printf '%s\\n' "$sdk"
`, { mode: 0o755 });
  const result = spawnSync('/bin/bash', [script, ...args], {
    encoding: 'utf8',
    env: { PATH: `${bin}:/usr/bin:/bin` },
  });
  assert.match(result.stderr, /Xcode 26 or later with the iOS 26 SDK or later/);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '');
}

test('phone.sh rejects Xcode older than 26 with a supported iOS SDK', t => {
  assertToolchainRejected(t, {
    xcode: '16.4', iphoneos: '26.0', iphonesimulator: '26.0', args: simulator,
  });
});

test('phone.sh rejects an unsupported SDK for the selected target', async t => {
  await t.test('device SDK is too old while the simulator SDK is supported', t => {
    assertToolchainRejected(t, {
      xcode: '26.0', iphoneos: '18.5', iphonesimulator: '26.0', args: device,
    });
  });
  await t.test('simulator SDK is missing while the device SDK is supported', t => {
    assertToolchainRejected(t, {
      xcode: '27.3', iphoneos: '27.3', iphonesimulator: '', args: simulator,
    });
  });
});
