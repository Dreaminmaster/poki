import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('phone.sh stops before setup when Xcode or the selected iOS SDK is too old', t => {
  const root = mkdtempSync(join(tmpdir(), 'poki-phone-toolchain-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  const scripts = join(root, 'scripts');
  mkdirSync(bin);
  mkdirSync(scripts);
  const script = join(scripts, 'phone.sh');
  copyFileSync(new URL('../scripts/phone.sh', import.meta.url), script);
  writeFileSync(join(bin, 'xcrun'), '#!/bin/bash\nexit 1\n', { mode: 0o755 });

  const simulator = ['simulator', 'fixture-simulator'];
  const device = ['device', 'fixture-iphone', 'FIXTURE123', 'com.example.poki', 'group.com.example.poki'];
  const scenarios = [
    { label: 'Xcode 16', xcode: '16.4', sdk: '18.5', args: simulator },
    { label: 'iOS SDK 18.5', xcode: '26.0', sdk: '18.5', args: device },
    { label: 'iOS Simulator SDK missing', xcode: '27.3', sdk: '', args: simulator },
  ];
  const results = scenarios.map(({ label, xcode, sdk, args }) => {
    writeFileSync(join(bin, 'xcodebuild'), `#!/bin/bash
if [[ $# == 1 && $1 == -version ]]; then
  printf '%s\\n' 'Xcode ${xcode}' 'Build version Fixture'
elif [[ -n '${sdk}' ]]; then
  printf '%s\\n' '${sdk}'
else
  exit 1
fi
`, { mode: 0o755 });
    const result = spawnSync('/bin/bash', [script, ...args], {
      encoding: 'utf8',
      env: { PATH: `${bin}:/usr/bin:/bin` },
    });
    return { label, status: result.status, stdout: result.stdout.trim(), stderr: result.stderr.trim() };
  });
  for (const { label, status, stdout, stderr } of results) {
    assert.match(stderr, /Xcode 26 or later with the iOS 26 SDK or later/, label);
    assert.equal(status, 1, label);
    assert.equal(stdout, '', label);
  }
});
