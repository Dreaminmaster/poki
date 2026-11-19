import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture, value } from './fixture.mjs';

test('Remote clipboard reads use the paired tunnel only after approval', async t => {
  const sample = 'https://example.invalid/article';
  const f = await fixture(t, { beforeStart: async dir => {
    await mkdir(join(dir, 'state'));
    await writeFile(join(dir, 'state/remote-devices.json'), JSON.stringify([{ id: 'remote-phone', config_path: join(dir, 'remote.json') }]));
    await writeFile(join(dir, 'bin/osascript'), `#!/usr/bin/env node
import { readFileSync } from 'node:fs';
const state = JSON.parse(readFileSync(process.env.FIXTURE_STATE, 'utf8'));
console.log(state.approveClipboard ? 'done' : 'cancelled');
`, { mode: 0o755 });
    await writeFile(join(dir, 'build/simulator'), `#!/usr/bin/env node
import { readFileSync } from 'node:fs';
const request = JSON.parse(readFileSync(0, 'utf8'));
if (request.op !== 'image_types') process.exit(1);
console.log(JSON.stringify({ contains_image: request.types.includes('public.png') }));
`, { mode: 0o755 });
    await writeFile(join(dir, 'build/poki-native'), `#!/usr/bin/env node
import { createServer } from 'node:net';
import { createInterface } from 'node:readline';
import { appendFileSync } from 'node:fs';
if (process.argv[2] !== '--remote-server') process.exit(1);
const server = createServer(socket => {
  socket.write(JSON.stringify({pid:process.pid})+'\\n');
  createInterface({input:socket}).once('line', line => {
    const { op, action } = JSON.parse(line);
    appendFileSync(process.env.FIXTURE_LOG, JSON.stringify({op, action})+'\\n');
    const reply = op === 'disconnect' ? {disconnected:true}
      : op === 'pasteboard' && action === 'get' ? {text:${JSON.stringify(sample)}}
      : op === 'pasteboard' && action === 'items' ? {items:[{uti:'public.utf8-plain-text'},{uti:'public.png'}]}
      : {transport_error:true,error:'Unexpected native request'};
    socket.end(JSON.stringify(reply)+'\\n');
    if (op === 'disconnect') server.close();
  });
});
server.listen(process.argv[4], () => console.log(JSON.stringify({ready:true})));
`, { mode: 0o755 });
  }});
  const args = { device: 'remote-phone' };
  try {
    const denied = await f.call('get_clipboard', args);
    assert.equal(denied.isError, true);
    assert.equal(value(denied).executed, false);
    const clipboardCalls = async () => (await f.events()).filter(e => e.op === 'pasteboard').map(e => e.action);
    assert.deepEqual(await clipboardCalls(), []);
    await f.set({ approveClipboard: true });
    const allowed = await f.call('get_clipboard', args);
    assert.ok(!allowed.isError, JSON.stringify(allowed));
    assert.deepEqual(value(allowed), {
      text: sample, contains_image: true, types: ['public.utf8-plain-text', 'public.png'],
      approval: { mode: 'ask-human', approved_by: 'human' },
    });
    const write = await f.call('set_clipboard', { ...args, text: 'fixture' });
    assert.equal(write.isError, true);
    assert.match(JSON.stringify(write), /unavailable over RemotePairing/);
    assert.deepEqual(await clipboardCalls(), ['get', 'items']);
    assert.ok(!(await f.events()).some(e => e.args?.includes('pasteboard')), 'no local pasteboard fallback');
  } finally {
    await f.call('disconnect_device', args);
  }
});

test('Remote screen capture survives observation cancellation and daemon restart after new connections are refused', async t => {
  const f = await fixture(t, { beforeStart: async dir => {
    await mkdir(join(dir, 'state'));
    await writeFile(join(dir, 'state/remote-devices.json'), JSON.stringify([{ id: 'remote-phone', config_path: join(dir, 'remote.json') }]));
    await writeFile(join(dir, 'build/poki-native'), `#!/usr/bin/env node
import { createInterface } from 'node:readline';
import { createServer } from 'node:net';
import { appendFileSync, copyFileSync, existsSync, writeFileSync } from 'node:fs';
const gate = process.env.FIXTURE_STATE + '.connected';
if (process.argv[2] !== '--remote-server' || existsSync(gate)) process.exit(1);
writeFileSync(gate, 'new connections refused');
writeFileSync(process.env.FIXTURE_STATE + '.pid', String(process.pid));
const server = createServer(socket => {
  socket.write(JSON.stringify({pid:process.pid})+'\\n');
  createInterface({input:socket}).once('line', line => {
    const request = JSON.parse(line);
    appendFileSync(process.env.FIXTURE_LOG, JSON.stringify({op:request.op})+'\\n');
    let response;
    if (request.op === 'screenshot') { copyFileSync(process.env.FIXTURE_IMAGE, request.path); response={saved:true}; }
    else if (request.op === 'ax_tree') return;
    else if (request.op === 'device_info') response={scale:1,properties:{}};
    else if (request.op === 'disconnect') { response={disconnected:true}; server.close(); }
    else response={isError:true,error:'Unsupported fixture request'};
    socket.end(JSON.stringify(response)+'\\n');
  });
});
server.listen(process.argv[4], () => console.log(JSON.stringify({ready:true})));
`, { mode: 0o755 });
  }});
  t.after(async () => {
    const pid = Number(await readFile(join(f.dir, 'fixture.json.pid'), 'utf8').catch(() => ''));
    if (pid > 1) { try { process.kill(pid, 'SIGTERM'); } catch {} }
  });
  const args = { device: 'remote-phone' };
  const first = await f.call('take_screenshot', args);
  assert.ok(!first.isError, JSON.stringify(first));
  assert.ok(first.content.some(c => c.type === 'image'));
  const timedOut = await f.call('wait_for', { ...args, text: 'Missing text', timeout: 1 });
  assert.equal(timedOut.isError, true);
  assert.match(JSON.stringify(timedOut), /Observation deadline exceeded/);
  assert.ok((await f.events()).some(e => e.op === 'ax_tree'), 'the deadline interrupts an accessibility request');
  const afterTimeout = await f.call('take_screenshot', args);
  assert.ok(!afterTimeout.isError, JSON.stringify(afterTimeout));
  assert.ok(afterTimeout.content.some(c => c.type === 'image'));
  await f.a.close();
  await f.daemon.stop();
  await f.startDaemon();
  const secondClient = await f.connect();
  const second = await secondClient.callTool({ name: 'take_screenshot', arguments: args });
  assert.ok(!second.isError, JSON.stringify(second));
  assert.ok(second.content.some(c => c.type === 'image'));
  const closed = await secondClient.callTool({ name: 'disconnect_device', arguments: args });
  assert.ok(!closed.isError, JSON.stringify(closed));
});
