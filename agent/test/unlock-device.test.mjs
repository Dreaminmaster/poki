import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { unlockDevice } from '../unlock-device.mjs';

test('Unlock host sends the configured passcode only on stdin and hides helper errors', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-unlock-'));
  const before = { passcode: process.env.POKI_IPHONE_PASSCODE, native: process.env.POKI_UNLOCK_NATIVE };
  t.after(async () => {
    for (const [name, value] of [['POKI_IPHONE_PASSCODE', before.passcode], ['POKI_UNLOCK_NATIVE', before.native]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    await rm(dir, { recursive: true, force: true });
  });
  delete process.env.POKI_IPHONE_PASSCODE;
  await assert.rejects(unlockDevice('synthetic-device'), /No iPhone passcode/);
  const helper = join(dir, 'fake-native');
  process.env.POKI_UNLOCK_NATIVE = helper;
  process.env.POKI_IPHONE_PASSCODE = '813790';
  await writeFile(helper, '#!/usr/bin/env python3\nimport sys,os,json\npin=sys.stdin.read()\nassert pin=="813790"\nassert pin not in " ".join(sys.argv)\nassert "POKI_IPHONE_PASSCODE" not in os.environ\nprint(json.dumps({"input_sent":True}))\n', { mode: 0o700 });
  await unlockDevice('synthetic-device');
  await writeFile(helper, '#!/usr/bin/env python3\nimport sys\nprint(sys.stdin.read(),file=sys.stderr)\nsys.exit(1)\n');
  await assert.rejects(unlockDevice('synthetic-device'), error => !error.message.includes('813790') && /did not complete/.test(error.message));
});

test('Unlock host takes any passcode iOS allows and refuses the rest before sending', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-unlock-'));
  const before = { passcode: process.env.POKI_IPHONE_PASSCODE, native: process.env.POKI_UNLOCK_NATIVE };
  t.after(async () => {
    for (const [name, value] of [['POKI_IPHONE_PASSCODE', before.passcode], ['POKI_UNLOCK_NATIVE', before.native]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    delete process.env.EXPECT;
    await rm(dir, { recursive: true, force: true });
  });
  const helper = join(dir, 'fake-native');
  process.env.POKI_UNLOCK_NATIVE = helper;
  await writeFile(helper, '#!/usr/bin/env python3\nimport sys,os,json\nassert sys.stdin.read()==os.environ["EXPECT"]\nprint(json.dumps({"input_sent":True}))\n', { mode: 0o700 });
  for (const passcode of ['1234', '813790', '12345678', 'Bear 2 honey!', ' padded ']) {
    process.env.POKI_IPHONE_PASSCODE = passcode;
    process.env.EXPECT = passcode;
    await unlockDevice('synthetic-device');
  }
  for (const passcode of ['123', 'x'.repeat(129), 'café1234', 'line\nbreak']) {
    process.env.POKI_IPHONE_PASSCODE = passcode;
    await assert.rejects(unlockDevice('synthetic-device'), error => !error.message.includes(passcode) && /not sent/.test(error.message));
  }
});

test('Unlock host passes on the helper refusal reason, never the passcode', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-unlock-'));
  const before = { passcode: process.env.POKI_IPHONE_PASSCODE, native: process.env.POKI_UNLOCK_NATIVE };
  t.after(async () => {
    for (const [name, value] of [['POKI_IPHONE_PASSCODE', before.passcode], ['POKI_UNLOCK_NATIVE', before.native]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
    await rm(dir, { recursive: true, force: true });
  });
  const helper = join(dir, 'fake-native');
  process.env.POKI_UNLOCK_NATIVE = helper;
  process.env.POKI_IPHONE_PASSCODE = 'Bear 2 honey!';
  await writeFile(helper, '#!/usr/bin/env python3\nimport sys\nsys.stdin.read()\nprint(\'Error: "Nothing was entered: the app in front is not the lock screen. Inspect the phone; do not automatically retry."\', file=sys.stderr)\nsys.exit(1)\n', { mode: 0o700 });
  await assert.rejects(unlockDevice('synthetic-device'), error => /not sent\. Nothing was entered: the app in front is not the lock screen/.test(error.message) && !error.message.includes('Bear 2 honey!'));
  await writeFile(helper, '#!/usr/bin/env python3\nimport sys\npin=sys.stdin.read()\nprint("Nothing was entered: " + pin, file=sys.stderr)\nsys.exit(1)\n');
  await assert.rejects(unlockDevice('synthetic-device'), error => !error.message.includes('Bear 2 honey!') && /did not complete/.test(error.message));
});
