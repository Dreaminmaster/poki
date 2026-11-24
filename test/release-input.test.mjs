import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from './fixture.mjs';

const opsSince = async (f, start) => (await f.events()).slice(start).filter(event => event.op).map(event => event.op);

test('remote input operations reuse the input session within a group and release it when the group ends', async t => {
  const f = await fixture(t);

  const beforeRead = (await f.events()).length;
  const shot = await f.call('take_screenshot');
  assert.notEqual(shot.isError, true, JSON.stringify(shot));
  assert.equal((await opsSince(f, beforeRead)).includes('release_input'), false, 'read-only observation must not send release_input');

  const beforeBatch = (await f.events()).length;
  const batch = await f.call('batch_commands', {
    verify: false,
    commands: [
      { tool: 'tap', arguments: { x: 10, y: 10 } },
      { tool: 'tap', arguments: { x: 20, y: 20 } },
    ],
  });
  assert.notEqual(batch.isError, true, JSON.stringify(batch));
  assert.deepEqual(
    await opsSince(f, beforeBatch),
    ['tap', 'tap', 'release_input', 'ax_tree'],
    'batch_commands must reuse input media across steps and release it before final readback',
  );

  const beforeTap = (await f.events()).length;
  const single = await f.call('tap', { x: 10, y: 10 });
  assert.notEqual(single.isError, true, JSON.stringify(single));
  const tapOps = await opsSince(f, beforeTap);
  const tapIndex = tapOps.indexOf('tap');
  const releaseIndex = tapOps.indexOf('release_input');
  assert.ok(tapIndex >= 0, `expected tap in ${JSON.stringify(tapOps)}`);
  assert.equal(releaseIndex, tapIndex + 1, `expected release_input right after tap, got ${JSON.stringify(tapOps)}`);
  assert.equal(tapOps.filter(op => op === 'release_input').length, 1);

  const beforeCode = (await f.events()).length;
  const scripted = await f.call('run_code', {
    code: `
      await tools.tap({ x: 10, y: 10, verify: false });
      await tools.tap({ x: 20, y: 20, verify: false });
      return { ok: true };
    `,
  });
  assert.notEqual(scripted.isError, true, JSON.stringify(scripted));
  assert.deepEqual(
    await opsSince(f, beforeCode),
    ['tap', 'tap', 'release_input'],
    'run_code must reuse input media across script steps and release it when finished',
  );

  const beforeFailedBatch = (await f.events()).length;
  const failedBatch = await f.call('batch_commands', {
    verify: false,
    commands: [
      { tool: 'tap', arguments: { x: 10, y: 10 } },
      { tool: 'type_text', arguments: { text: '' } },
    ],
  });
  assert.equal(failedBatch.isError, true);
  const failedOps = await opsSince(f, beforeFailedBatch);
  const lastTap = failedOps.lastIndexOf('tap');
  assert.ok(lastTap >= 0 && failedOps.indexOf('release_input', lastTap) > lastTap, `failed batch must still release input: ${JSON.stringify(failedOps)}`);
});

test('CUA do reuses the input session across actions and releases it before reading the screen', async t => {
  const f = await fixture(t, { toolsProfile: 'cua' });
  const looked = await f.call('look');
  assert.notEqual(looked.isError, true, JSON.stringify(looked));

  const beforeDo = (await f.events()).length;
  const acted = await f.call('do', {
    actions: [{ tap: [10, 10] }, { tap: [20, 20] }],
  });
  assert.notEqual(acted.isError, true, JSON.stringify(acted));
  const ops = await opsSince(f, beforeDo);
  const firstTap = ops.indexOf('tap');
  const secondTap = ops.indexOf('tap', firstTap + 1);
  const release = ops.indexOf('release_input');
  const readAfter = ops.indexOf('ax_tree', secondTap);
  assert.ok(firstTap >= 0 && secondTap > firstTap, `expected two taps in ${JSON.stringify(ops)}`);
  assert.equal(release, secondTap + 1, `expected release_input right after the last action, got ${JSON.stringify(ops)}`);
  assert.ok(readAfter > release, `expected post-action read after release_input, got ${JSON.stringify(ops)}`);
});
