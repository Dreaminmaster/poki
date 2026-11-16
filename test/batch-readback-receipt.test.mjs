import test from 'node:test';
import assert from 'node:assert/strict';
import { runBatch } from '../src/batch.mjs';

const command = { tool: 'press_key', arguments: { key: 'return' } };
const receipt = result => JSON.parse(result.content.at(-1).text);
function mockCtx({ failStep = false } = {}) {
  const dispatched = [];
  return {
    dispatched,
    async dispatch(tool) {
      dispatched.push(tool);
      return failStep && dispatched.length === 2
        ? { isError: true, content: [{ type: 'text', text: 'Second action failed' }] }
        : { content: [{ type: 'text', text: JSON.stringify({ sent: true, outcome: 'delivered' }) }] };
    },
    async readback() { throw new Error('Synthetic final-screen read failed'); },
  };
}

test('batch preserves executed input receipt when final screen read fails', async () => {
  const ctx = mockCtx();
  const result = await runBatch(ctx, { commands: [command] });
  assert.equal(result.isError, true);
  assert.deepEqual(ctx.dispatched, ['press_key']);
  assert.equal(receipt(result).completed_steps, 1);
  assert.equal(receipt(result).stop_reason, 'readback_failed');
  assert.equal(receipt(result).readback_error, 'Synthetic final-screen read failed');
  assert.deepEqual(receipt(result).remaining_steps, []);
  assert.match(receipt(result).next, /already ran|do not repeat/i);
  assert.match(result.content[0].text, /"step":1/);
  assert.match(result.content[1].text, /"sent":true/);
});

test('batch retains failed step and pending commands despite final readback failure', async () => {
  const ctx = mockCtx({ failStep: true });
  const commands = [command, command, command];
  const result = await runBatch(ctx, { commands });
  assert.equal(result.isError, true);
  assert.equal(ctx.dispatched.length, 2);
  const data = receipt(result);
  assert.equal(data.completed_steps, 2);
  assert.equal(data.stop_reason, 'error', 'original action failure is not rewritten');
  assert.equal(data.failed_step.step, 2);
  assert.deepEqual(data.remaining_steps, commands.slice(1));
  assert.equal(data.readback_error, 'Synthetic final-screen read failed');
  assert.match(data.next, /readback|screen/i);
});
