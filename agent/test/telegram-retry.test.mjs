import test from 'node:test';
import assert from 'node:assert/strict';
import { tmpdir } from 'node:os';
import { TelegramSource } from '../telegram-source.mjs';

function mockSource(t, handler) {
  const token = process.env.TELEGRAM_BOT_TOKEN, endpoint = process.env.TELEGRAM_API_URL;
  const previousFetch = globalThis.fetch;
  process.env.TELEGRAM_BOT_TOKEN = '12345:test-token';
  process.env.TELEGRAM_API_URL = 'http://127.0.0.1:8765';
  globalThis.fetch = handler;
  t.after(() => {
    globalThis.fetch = previousFetch;
    if (token === undefined) delete process.env.TELEGRAM_BOT_TOKEN;
    else process.env.TELEGRAM_BOT_TOKEN = token;
    if (endpoint === undefined) delete process.env.TELEGRAM_API_URL;
    else process.env.TELEGRAM_API_URL = endpoint;
  });
  return new TelegramSource({ allowedUsers: [123], stateDirectory: tmpdir() });
}

const reply = (status, body) => new Response(JSON.stringify(body), {
  status, headers: { 'content-type': 'application/json' },
});

test('Telegram message sends are not retried on HTTP 5xx; delivery may be uncertain', async t => {
  let attempts = 0;
  const source = mockSource(t, async () => {
    attempts++;
    return reply(500, { ok: false, error_code: 500, description: 'Internal Server Error' });
  });
  await assert.rejects(source.request('sendMessage', { chat_id: 123, text: 'one message' }), /delivery may be uncertain/);
  assert.equal(attempts, 1, 'A write that may have reached Telegram must not be replayed');
});

test('Telegram edits are not replayed after HTTP 5xx', async t => {
  let attempts = 0;
  const source = mockSource(t, async () => {
    attempts++;
    return reply(502, { ok: false, error_code: 502 });
  });
  await assert.rejects(source.request('editMessageText', { chat_id: 123, message_id: 42, text: 'edited' }), /delivery may be uncertain/);
  assert.equal(attempts, 1);
});

test('Telegram read-only requests still retry transient HTTP 5xx', async t => {
  let attempts = 0;
  const source = mockSource(t, async () => {
    attempts++;
    return attempts === 1
      ? reply(503, { ok: false, error_code: 503 })
      : reply(200, { ok: true, result: [] });
  });
  assert.deepEqual(await source.request('getUpdates', { offset: 0 }), []);
  assert.equal(attempts, 2);
});

test('Explicit Telegram 429 rejection can still retry a send after retry_after', async t => {
  let attempts = 0;
  const source = mockSource(t, async () => {
    attempts++;
    return attempts === 1
      ? reply(429, { ok: false, error_code: 429, parameters: { retry_after: 0 } })
      : reply(200, { ok: true, result: { message_id: 99 } });
  });
  assert.deepEqual(await source.request('sendMessage', { chat_id: 123, text: 'rate-limited' }), { message_id: 99 });
  assert.equal(attempts, 2);
});
