import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, value } from './fixture.mjs';
import { readScreen } from '../src/interaction.mjs';

test('opted-in input supplies post-action refs without an extra observation request', async t => {
  const f = await fixture(t);
  const response = await f.call('press_key', { key: 'return', return_observation: true });
  assert.ok(!response.isError);
  const receipt = value(response);
  assert.equal(receipt.sent, true);
  assert.equal(receipt.post_action_observation?.version, 1);
  assert.equal(receipt.post_action_observation?.action_receipt_id, receipt.receipt_id);
  assert.ok(receipt.post_action_observation.observation.capture_started_at >= receipt.input_completed_at);
  assert.ok(receipt.post_action_observation.elements.every(e => /^e\d+$/.test(e.ref)));
  assert.equal(receipt.post_action_observation.prompt.status, 'checked');
});

test('failure of optional post-input capture preserves ordinary AX text readback', async () => {
  const observed = { device: 'fixture-phone', signature: 'steady',
    foreground: { bundle_id: 'org.example' },
    elements: [{ role: 'Button', label: 'Continue', visible: true }],
    structure_completed_at: new Date().toISOString() };
  let captures = 0;
  const ctx = { lastInputCompletedAt: new Date().toISOString(),
    settle: async () => {}, capture: async () => { captures++; throw new Error('Optional screenshot unavailable'); },
    structure: async () => observed };
  const result = await readScreen(ctx, { structured: true });
  assert.equal(captures, 1);
  assert.equal(result.structuredObservation, undefined);
  assert.ok(result.screen.text.some(item => item.includes('Continue')));
});
