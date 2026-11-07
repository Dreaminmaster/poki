import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, value } from './fixture.mjs';
import sharp from 'sharp';
import { readScreen } from '../src/interaction.mjs';

test('opted-in input supplies post-action refs without an extra observation request', async t => {
  const f = await fixture(t);
  const response = await f.call('press_key', { key: 'return', return_observation: true });
  assert.ok(!response.isError);
  const receipt = value(response);
  assert.equal(receipt.sent, true);
  assert.equal(receipt.post_action_observation?.version, 1);
  assert.equal(receipt.post_action_observation?.action_receipt_id, receipt.receipt_id);
  assert.ok(receipt.post_action_observation.observation.structure_started_at >= receipt.input_completed_at);
  assert.equal(receipt.post_action_observation.observation.capture_started_at, undefined,
    'AX-only reuse must not fabricate image capture timestamps');
  assert.equal(receipt.post_action_observation.prompt.source, 'accessibility');
  assert.ok(receipt.post_action_observation.elements.every(e => /^e\d+$/.test(e.ref)));
  assert.equal(receipt.post_action_observation.prompt.status, 'checked');
});

test('optional image OCR captures AFTER the stable AX read', async t => {
  const f = await fixture(t);
  const result = await f.call('press_key', { key: 'return', return_observation: true, post_action_ocr: true });
  assert.ok(!result.isError);
  const value = JSON.parse(result.content.find(item => item.type === 'text').text);
  const data = value.post_action_observation;
  assert.equal(data.prompt.status, 'checked');
  assert.equal(data.prompt.source, 'ocr');
  assert.ok(data.observation.structure_completed_at <= data.observation.capture_started_at,
    'The screenshot must follow AX stabilization');
  assert.ok(data.observation.capture_started_at <= data.observation.capture_completed_at);
});

test('an AX-only ref remains usable without a redundant capture until input invalidates it', async t => {
  const f = await fixture(t);
  const result = await f.call('press_key', { key: 'return', return_observation: true });
  const receipt = value(result);
  const ref = receipt.post_action_observation?.elements?.find(e => e.role === 'Button')?.ref
    ?? receipt.post_action_observation?.elements?.[0]?.ref;
  assert.match(ref, /^e\d+$/);
  const tapped = await f.call('tap', { ref });
  assert.ok(!tapped.isError, 'Current action-bound AX refs must remain valid without an extra list_elements read');
});

test('a changed post-input image does not invalidate stable AX simply because the scene revision advances', async t => {
  const f = await fixture(t);
  // Establish a previous image, then supply a different image for the
  // post-action capture. observeFrame() is expected to advance its revision.
  const before = value(await f.call('take_screenshot'));
  await sharp({ create: { width: 100, height: 200, channels: 3, background: '#d31f43' } })
    .png().toFile(f.image);
  const response = await f.call('press_key', { key: 'return', return_observation: true, post_action_ocr: true });
  assert.ok(!response.isError);
  const after = value(response).post_action_observation;
  assert.ok(after, 'Expected post-input image changes must not masquerade as an intervening input');
  assert.ok(after.observation.revision > before.observation.revision);
  assert.ok(after.observation.structure_completed_at <= after.observation.capture_started_at);
});
