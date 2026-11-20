import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createInterface } from 'node:readline';
import { copyFile, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fixture } from './fixture.mjs';
import { root } from '../src/config.mjs';

async function sessionBridge(t) {
  const dir = await mkdtemp(join(tmpdir(), 'poki-voice-token-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const preload = `
    import { writeFile } from 'node:fs/promises';
    import { join } from 'node:path';
    globalThis.fetch = async (url, options) => {
      await writeFile(join(process.env.POKI_MCP_STATE_DIR, 'request.json'), JSON.stringify({ url, body: JSON.parse(options.body) }));
      if (url === 'https://api.openai.com/v1/realtime/client_secrets') return Response.json({ value: 'ek_test' });
      if (url === 'https://api.openai.com/v1/live/sessions') return Response.json({ transport: { sdp: 'sdp-answer' } }, { status: 201 });
      if (url === 'https://api.openai.com/v1/responses') return Response.json({ output: [{
        type: 'message', content: [{ type: 'output_text', text: 'Screen description' }],
      }] });
      throw new Error('Unexpected upstream URL');
    };
  `;
  const child = spawn(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(preload)}`, join(root, 'bin/voice-bridge.mjs'), '--port', '0', '--host', '127.0.0.1'], {
    env: { ...process.env, POKI_MCP_STATE_DIR: dir, POKI_VOICE_MODEL: '', OPENAI_API_KEY: 'unused' }, stdio: ['ignore', 'pipe', 'inherit'],
  });
  const exited = once(child, 'exit');
  t.after(async () => { child.kill(); await exited; });
  const lines = createInterface({ input: child.stdout });
  const [line] = await Promise.race([once(lines, 'line'), exited.then(() => { throw new Error('Voice bridge exited before it was ready'); })]);
  const { port } = JSON.parse(line);
  const { secret } = JSON.parse(await readFile(join(dir, 'voice-bridge.json'), 'utf8'));
  return {
    base: `http://127.0.0.1:${port}/voice/${secret}`,
    request: async () => JSON.parse(await readFile(join(dir, 'request.json'), 'utf8')),
  };
}

test('legacy voice token requests hint Chinese transcription for each interface language', async t => {
  const { base, request } = await sessionBridge(t);
  for (const language of ['', 'zh-Hans', 'en']) {
    const response = await fetch(`${base}/token?language=${language}`);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).value, 'ek_test');
    const { body: { session } } = await request();
    assert.equal(session.audio.input.transcription.language, 'zh');
  }
});

test('the voice bridge exchanges a Live offer and returns only the SDP answer', async t => {
  const { base, request } = await sessionBridge(t);
  const token = await fetch(`${base}/token?transport=live`);
  assert.deepEqual(await token.json(), {
    model: 'gpt-live-1.1', live: true, local_tools: ['get_ios_version', 'look', 'open_app', 'do'],
  });
  const response = await fetch(`${base}/session?language=zh-Hans`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ sdp: 'sdp-offer' }),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { sdp: 'sdp-answer' });
  const upstream = await request();
  assert.equal(upstream.url, 'https://api.openai.com/v1/live/sessions');
  assert.deepEqual(upstream.body.transport, { type: 'webrtc', sdp: 'sdp-offer' });
  const { session } = upstream.body;
  assert.equal(session.model, 'gpt-live-1.1');
  assert.equal(session.delegation.type, 'responses');
  assert.ok(session.delegation.responses.tools.some(tool => tool.name === 'do'));
  assert.match(session.instructions, /Chinese/i);
  assert.match(session.instructions, /Act first, then talk\./);
  assert.match(session.instructions, /Say nothing before or between tool calls\./);
  assert.match(session.instructions, /Give the verified result in one short sentence\./);
});

test('each Live screenshot uses its own unsaved vision request', async t => {
  const { base, request } = await sessionBridge(t);
  for (const [screen, previous] of [['first', 'second'], ['second', 'first']]) {
    const url = name => `data:image/jpeg;base64,${Buffer.from(`synthetic ${name} screenshot`).toString('base64')}`;
    const response = await fetch(`${base}/screen`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ image: url(screen) }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { text: 'Screen description' });
    const upstream = await request();
    assert.equal(upstream.url, 'https://api.openai.com/v1/responses');
    assert.equal(upstream.body.store, false);
    assert.equal(upstream.body.previous_response_id, undefined);
    assert.equal(upstream.body.conversation, undefined);
    const images = upstream.body.input.flatMap(item => item.content).filter(part => part.type === 'input_image');
    assert.deepEqual(images.map(image => image.image_url), [url(screen)]);
    assert.ok(!JSON.stringify(upstream.body).includes(url(previous)));
  }
});

// The voice bridge in front of a fixture daemon and phone, as the Poki app reaches it.
async function bridge(t, f) {
  await copyFile(join(root, 'bin/voice-bridge.mjs'), join(f.dir, 'bin/voice-bridge.mjs'));
  const child = spawn(process.execPath, [join(f.dir, 'bin/voice-bridge.mjs'), '--port', '0', '--host', '127.0.0.1', '--mac-tools'], { env: { ...f.env, OPENAI_API_KEY: 'unused' }, stdio: ['ignore', 'pipe', 'inherit'] });
  const exited = once(child, 'exit');
  t.after(async () => { child.kill(); await exited; });
  const lines = createInterface({ input: child.stdout });
  const [line] = await once(lines, 'line');
  const { port } = JSON.parse(line);
  const { secret } = JSON.parse(await readFile(join(f.env.POKI_MCP_STATE_DIR, 'voice-bridge.json'), 'utf8'));
  return body => fetch(`http://127.0.0.1:${port}/voice/${secret}/tool`, { method: 'POST', body: JSON.stringify(body) }).then(r => r.json());
}

test('a voice tap_text the phone has not checked taps nothing; once checked it taps once', async t => {
  const f = await fixture(t);
  await f.set({ label: 'Send' });
  const tool = await bridge(t, f);
  const taps = async () => (await f.events()).filter(e => e.op === 'tap').length;

  // "tap Send", as the model asks for it: the bridge says what it would tap and where, and taps nothing.
  const check = await tool({ call_id: 'c1', name: 'tap_text', arguments: { text: 'Send' } });
  assert.equal(await taps(), 0, JSON.stringify(check));
  assert.equal(check.state, 'check', JSON.stringify(check));
  assert.equal(check.target.text, 'Send');

  // The phone cleared it (its rules, or the owner's OK): the same call taps that element once.
  const done = await tool({ call_id: 'c1', name: 'tap_text', arguments: { text: 'Send' }, checked: { app: check.app.bundle_id, text: check.target.text } });
  assert.equal(done.state, 'done', JSON.stringify(done));
  assert.equal(await taps(), 1);
});

test('a voice tap_text with Poki in front taps nothing, checked or not', async t => {
  const f = await fixture(t);
  await f.set({ label: 'Allow', bundleId: 'nz.zheha.poki', appName: 'Poki' });
  const tool = await bridge(t, f);
  const taps = async () => (await f.events()).filter(e => e.op === 'tap').length;

  // The approval card is in Poki: "tap Allow" is refused before the phone is asked.
  const check = await tool({ call_id: 'c1', name: 'tap_text', arguments: { text: 'Allow' } });
  assert.equal(check.state, 'failed', JSON.stringify(check));
  assert.match(check.output, /only the phone's owner/);

  // A call that says Poki was checked is refused too.
  const done = await tool({ call_id: 'c2', name: 'tap_text', arguments: { text: 'Allow' }, checked: { app: 'nz.zheha.poki', text: 'Allow' } });
  assert.equal(done.state, 'failed', JSON.stringify(done));
  assert.equal(await taps(), 0);
});

test('a voice tap_text on an element known only by its identifier shows the phone that name', async t => {
  const f = await fixture(t);
  await f.set({ elements: [{ role: 'Button', identifier: 'Send', frame: { x: 10, y: 10, width: 40, height: 20 } }] });
  const tool = await bridge(t, f);

  // The phone checks what it is told the element says: the identifier the tap matches, not nothing.
  const check = await tool({ call_id: 'c1', name: 'tap_text', arguments: { text: 'Send' } });
  assert.equal(check.state, 'check', JSON.stringify(check));
  assert.match(check.target.says, /\bSend\b/);
  assert.equal((await f.events()).filter(e => e.op === 'tap').length, 0);
});
