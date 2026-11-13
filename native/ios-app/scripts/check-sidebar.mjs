#!/usr/bin/env node
// check-sidebar.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR: drives Poki on a simulator through Poki MCP and
// checks that the conversation drawer holds only Poki's name, the reminder row while something needs fixing, the day
// headings, the conversations, New Conversation and Settings, and that switching, renaming and deleting (from the
// long-press menu) and starting a conversation still work from it.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, output] = process.argv.slice(2);
assert(clientRoot && device && output, 'Usage: check-sidebar.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR');
assert(device.startsWith('ESP-'), 'Use a dedicated task simulator (named ESP-…): the check deletes and renames conversations');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });

function call(name, args = {}) {
  const raw = execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(raw);
}
const pause = ms => execFileSync('sleep', [String(ms / 1000)]);
const elements = () => call('list_elements', { source: 'accessibility' }).elements;
const centre = e => ({ x: e.frame.x + e.frame.width / 2, y: e.frame.y + e.frame.height / 2 });
const byId = (list, id) => list.find(e => e.identifier === id);
const row = (list, name) => list.find(e => e.type === 'Button' && !e.identifier && (e.label === name || (e.label ?? '').startsWith(`${name}, `)));
const tap = e => { call('tap', centre(e)); pause(1200); };

function launch() {
  call('launch_app', { bundle_id: 'nz.zheha.poki', arguments: ['-pokiSessions', 'sample', '-pokiChat', 'empty',
    '-approvals.mode.v2', 'off', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'] });
  pause(2500);
}

function openDrawer() {
  const button = byId(elements(), 'chat.threads');
  assert(button, 'Home must offer the conversations button');
  tap(button);
  const list = elements();
  assert(byId(list, 'threads.newChat'), 'The drawer must open');
  return list;
}

const evidence = {};
try {
  launch();

  const drawer = openDrawer();
  call('save_screenshot', { path: join(directory, 'drawer.png'), overwrite: true });
  evidence.drawer = drawer.map(e => ({ type: e.type, identifier: e.identifier ?? null, label: e.label ?? null }));
  const furniture = new Set(['Poki', 'Today', 'Yesterday', 'Earlier', 'Close Conversations']);
  const furnitureIds = new Set(['threads.newChat', 'threads.settings', 'threads.issue']);
  const extra = drawer.filter(e => e.type !== 'Application' && !furnitureIds.has(e.identifier)
    && !furniture.has(e.label ?? '') && !(e.type === 'Button' && !e.identifier) && !(e.type === 'Group' && !e.label));
  assert.deepEqual(extra.map(e => `${e.type}: ${e.identifier ?? e.label}`), [], 'The drawer must list only conversations');
  assert(row(drawer, 'Codex') && row(drawer, 'What iOS version is this?'), 'The drawer must list the saved conversations');

  // In the drawer a sideways drag closes it, so Rename and Delete are in the long-press menu.
  const live = row(drawer, 'Claude → Poki');
  call('long_press', { ...centre(live), duration: 1 });
  pause(1000);
  const liveActions = elements();
  evidence.liveMenu = liveActions.filter(e => e.type === 'Button').map(e => e.label);
  assert(liveActions.some(e => e.label === 'Rename'), 'A running conversation must offer Rename');
  assert(!liveActions.some(e => e.label === 'Delete'), 'A running conversation must not offer Delete');

  launch();
  const fresh = openDrawer();
  call('long_press', { ...centre(row(fresh, 'Codex')), duration: 1 });
  pause(1000);
  const del = elements().find(e => e.label === 'Delete');
  assert(del, 'A finished conversation must offer Delete');
  tap(del);
  const afterDelete = elements();
  assert(!row(afterDelete, 'Codex'), 'Delete must remove the conversation from the drawer');
  evidence.deleted = 'Codex';

  call('long_press', { ...centre(row(afterDelete, 'Order my usual coffee')), duration: 1 });
  pause(1000);
  tap(elements().find(e => e.label === 'Rename'));
  call('type_text', { text: 'Coffee run', clear: true });
  tap(elements().find(e => e.type === 'Button' && e.label === 'Save'));
  const afterRename = elements();
  assert(row(afterRename, 'Coffee run') && !row(afterRename, 'Order my usual coffee'), 'Rename must show the new name in the drawer');
  evidence.renamed = 'Coffee run';

  tap(row(afterDelete, 'What iOS version is this?'));
  const session = elements();
  assert(!byId(session, 'threads.newChat'), 'Picking a conversation must close the drawer');
  assert(session.some(e => (e.label ?? '').includes('iOS 27.3')), 'Picking a conversation must show it');
  call('save_screenshot', { path: join(directory, 'switched.png'), overwrite: true });
  evidence.switched = 'What iOS version is this?';

  launch();
  tap(byId(openDrawer(), 'threads.newChat'));
  const home = elements();
  assert(!byId(home, 'threads.newChat') && byId(home, 'chat.threads'), 'New Conversation must close the drawer on the home page');
  evidence.newConversation = true;

  console.log('PASS: the drawer lists only conversations; switch, rename, delete and new conversation work');
} catch (error) {
  evidence.failure = error.message;
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
} finally {
  writeFileSync(join(directory, 'sidebar.json'), JSON.stringify(evidence, null, 2) + '\n');
}
