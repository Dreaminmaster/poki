import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { fixture, value } from './fixture.mjs';
import { installPokiBuild, pokiStuckInstallError } from '../src/platform.mjs';

const pokiBundle = 'nz.zheha.poki.TEST000000';
const pokiApp = { bundle_id: pokiBundle, name: 'Poki', system: false, version: '1', path: '/private/var/containers/Bundle/Application/POKI/Poki.app' };

async function pokiPackage(f) {
  const app = `${f.dir}/InstallFixture.app`;
  await mkdir(app);
  await writeFile(`${app}/Info.plist`, `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${pokiBundle}</string></dict></plist>`);
  return app;
}

// On a phone iOS holds the update while the app runs; the fixture's installer then never answers.
test('install_app ends a running Poki first, so the update is not held until the helper times out', async t => {
  const f = await fixture(t, { approvalMode: 'allow' });
  await f.set({ apps: [pokiApp], pokiRunning: true, pokiPath: pokiApp.path });
  const installed = await f.call('install_app', { path: await pokiPackage(f) });
  assert.ok(!installed.isError, JSON.stringify(installed));
  assert.equal(value(installed).installed, true);
  assert.equal(value(installed).bundle_id, pokiBundle);
  const order = (await f.events()).flatMap(e => e.args?.includes('terminate') ? ['terminate'] : e.op === 'install_app' ? ['install'] : []);
  assert.deepEqual(order, ['terminate', 'install']);
});

test('an install that makes no progress is retried once after ending Poki, then reported as stuck', async () => {
  const steps = [];
  const stuck = { isError: true, outcome: 'unknown', stop_reason: 'timeout', recovery_record: '/state/first.json' };
  const retried = await installPokiBuild({
    stop: async () => { steps.push('stop'); return {}; },
    attempt: async () => { steps.push('install'); return steps.filter(s => s === 'install').length === 1 ? stuck : { outcome: 'completed', installed: true }; },
  });
  assert.deepEqual(steps, ['stop', 'install', 'stop', 'install']);
  assert.equal(retried.installed, true);
  assert.equal(retried.install_retried, true);

  steps.length = 0;
  const failed = await installPokiBuild({
    stop: async () => { steps.push('stop'); return {}; },
    attempt: async () => { steps.push('install'); return { ...stuck, recovery_record: `/state/${steps.length}.json` }; },
  });
  assert.deepEqual(steps, ['stop', 'install', 'stop', 'install']);
  assert.equal(failed.isError, true);
  assert.equal(failed.error, pokiStuckInstallError);
  assert.equal(failed.earlier_recovery_record, '/state/2.json');
});

test('an install the phone already confirmed is not repeated when reading the app list back timed out', async () => {
  let attempts = 0;
  const result = await installPokiBuild({
    stop: async () => ({}),
    attempt: async () => { attempts++; return { isError: true, outcome: 'completed', stop_reason: 'timeout', verification_outcome: 'unknown' }; },
  });
  assert.equal(attempts, 1);
  assert.equal(result.outcome, 'completed');
});

test('a rejected install is not retried', async () => {
  let attempts = 0;
  const result = await installPokiBuild({
    stop: async () => ({}),
    attempt: async () => { attempts++; return { isError: true, outcome: 'rejected', error: 'Signature invalid' }; },
  });
  assert.equal(attempts, 1);
  assert.equal(result.outcome, 'rejected');
});
