import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { root } from '../src/config.mjs';

const exec = promisify(execFile);

test('phone update information uses the current request and refuses ambiguous public identity', { skip: process.platform !== 'darwin' }, async t => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-update-info-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const executable = join(dir, 'check');
  await exec('swiftc', [join(root, 'native/ios-app/Poki/Setup/PokiUpdateInfo.swift'), join(root, 'test/fixtures/update-info/main.swift'), '-o', executable]);
  const { stdout } = await exec(executable, [dir]);
  assert.match(stdout, /Public update snapshot checks passed/);
});
