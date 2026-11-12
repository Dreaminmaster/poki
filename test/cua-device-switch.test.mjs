import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, value } from './fixture.mjs';

const text = result => result.content.find(item => item.type === 'text')?.text ?? '';

test('CUA cannot use a screen element number from iPhone A after switching to iPhone B', { timeout: 35000 }, async t => {
  const f = await fixture(t, { toolsProfile: 'cua' });
  await f.set({ twoPhones: true, label: 'Ready' });
  assert.equal(value(await f.call('select_device', { device: 'fixture-phone' })).selected, 'fixture-phone');
  const onA = await f.call('look');
  assert.match(text(onA), /1 (?:Button|StaticText) "Ready"/);
  assert.equal(value(await f.call('select_device', { device: 'fixture-phone-2' })).selected, 'fixture-phone-2');
  const result = await f.call('do', { actions: [{ tap: 1 }] });
  assert.equal(result.isError, true, text(result));
  assert.match(text(result), /element 1 is not in the latest read; nothing was sent/i);
  const inputs = (await f.events()).filter(e => e.op === 'tap');
  assert.equal(inputs.length, 0, 'switching devices must not dispatch a tap using another device’s coordinates');
  const fresh = await f.call('look');
  assert.match(text(fresh), /1 (?:Button|StaticText) "Ready"/);
  const onB = await f.call('do', { actions: [{ tap: 1 }] });
  assert.match(text(onB), /did: tap 1 \(sent,/);
  assert.equal((await f.events()).filter(e => e.op === 'tap').length, 1, 'a fresh observation on iPhone B permits its own elements');
});
