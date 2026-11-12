#!/usr/bin/env node
// check-drawer-drag.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR: drives Poki on a simulator through Poki MCP with
// real touches and checks the conversation drawer's gestures: a short drag from the leading edge that is let go
// early falls back closed; a full drag opens it; a conversation picked from it opens with its messages and
// closes the drawer; a drag back on the uncovered strip closes it again.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, output] = process.argv.slice(2);
assert(clientRoot && device && output, 'Usage: check-drawer-drag.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });

function call(name, args = {}) {
  const raw = execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(raw);
}
const elements = () => call('list_elements', { source: 'accessibility' }).elements;
const byId = (list, id) => list.find(e => e.identifier === id);
const centre = e => ({ x: e.frame.x + e.frame.width / 2, y: e.frame.y + e.frame.height / 2 });
const row = (list, name) => list.find(e => e.type === 'Button' && !e.identifier && (e.label ?? '').startsWith(`${name}, `));
// The drawer's state settles within its spring; wait for what the screen shows, not for a fixed time.
function until(what, test) {
  for (let attempt = 0; attempt < 20; attempt++) {
    const list = elements();
    if (test(list)) return list;
    execFileSync('sleep', ['0.25']);
  }
  assert.fail(what);
}
const open = list => Boolean(byId(list, 'threads.newChat'));

const evidence = {};
try {
  call('launch_app', { bundle_id: 'nz.zheha.poki', arguments: ['-pokiSessions', 'sample', '-pokiChat', 'empty',
    '-approvals.mode', 'off', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'] });
  const home = until('Home must offer the conversations button', list => Boolean(byId(list, 'chat.threads')));
  const { width, height } = home.find(e => e.type === 'Application').frame;
  const y = Math.round(height * 0.55);

  // Let go a fifth of the way, slowly: it must fall back closed.
  call('swipe', { from_x: 3, from_y: y, to_x: Math.round(width * 0.2), to_y: y, duration_ms: 900 });
  until('A short, slow drag must leave the drawer closed', list => !open(list) && Boolean(byId(list, 'chat.threads')));
  evidence.shortDrag = 'closed';

  call('swipe', { from_x: 3, from_y: y, to_x: Math.round(width * 0.75), to_y: y, duration_ms: 600 });
  const drawer = until('A drag from the leading edge must open the drawer', open);
  call('save_screenshot', { path: join(directory, 'dragged-open.png'), overwrite: true });
  evidence.dragOpen = 'open';

  const notes = row(drawer, 'Add oat milk to my shopping list');
  assert(notes, 'The drawer must list the Notes conversation');
  call('tap', centre(notes));
  const chat = until('Picking a conversation must close the drawer and show it',
    list => !open(list) && list.some(e => (e.label ?? '').includes('oat milk')));
  call('save_screenshot', { path: join(directory, 'picked.png'), overwrite: true });
  evidence.picked = chat.filter(e => (e.label ?? '').includes('oat milk')).map(e => e.label).slice(0, 3);

  call('swipe', { from_x: 3, from_y: y, to_x: Math.round(width * 0.75), to_y: y, duration_ms: 600 });
  until('A drag must open the drawer over a conversation', open);
  call('swipe', { from_x: width - 12, from_y: y, to_x: width - 200, to_y: y, duration_ms: 300 });
  until('A drag on the uncovered chat must close the drawer', list => !open(list));
  call('save_screenshot', { path: join(directory, 'closed.png'), overwrite: true });
  evidence.dragClosed = 'closed';

  console.log('PASS: a short drag falls back, a full drag opens the drawer, a conversation opens from it, a drag on the strip closes it');
} catch (error) {
  evidence.failure = error.message;
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
} finally {
  writeFileSync(join(directory, 'drawer-drag.json'), JSON.stringify(evidence, null, 2) + '\n');
}
