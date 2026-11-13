import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);

test('an installed update gives restart instructions when the old process survives', { skip: process.platform !== 'darwin' }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-update-finish-'));
  try {
    const source = await readFile(new URL('../native/ios-app/Poki/Signing/SelfSigner.swift', import.meta.url), 'utf8');
    // Compile the real signer with platform adapters; the C bridge and iOS process are simulated.
    await writeFile(join(dir, 'SelfSigner.swift'), source.slice(0, source.indexOf('enum SignerBridge {'))
      .replace('import UIKit', 'import Observation').replace('import UserNotifications', ''));
    await exec('swiftc', ['-parse-as-library', join(dir, 'SelfSigner.swift'),
      fileURLToPath(new URL('./fixtures/update-finish/Runtime.swift', import.meta.url)),
      '-o', join(dir, 'check')]);
    const result = await exec(join(dir, 'check'));
    process.stdout.write(result.stdout);
    assert.match(result.stdout, /PASS: timeout shows restart instructions/);
  } catch (error) {
    if (error.stdout) process.stdout.write(error.stdout);
    if (error.stderr) process.stderr.write(error.stderr);
    throw error;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
