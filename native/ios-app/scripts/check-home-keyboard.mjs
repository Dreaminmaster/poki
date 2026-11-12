#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, output] = process.argv.slice(2);
assert(clientRoot && device && output, 'Usage: check-home-keyboard.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR');
assert(device.startsWith('ESP-447 '), 'Use the dedicated ESP-447 simulator');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });
function call(name, args = {}) {
  const raw = execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(raw);
}
const ideas = elements => elements.filter(e => /Messages|Starbucks|Instagram|Slack|Notes/.test(e.label ?? e.text ?? ''));
const input = elements => elements.find(e => /TextArea|TextField/.test(e.type) && /Poki/.test(e.label ?? ''));
try {
  call('launch_app', { bundle_id: 'nz.zheha.poki', arguments: ['-pokiChat', 'empty', '-approvals.mode', 'off',
    '-AppleLanguages', '(zh-Hans)', '-AppleLocale', 'zh_CN'] });
  const before = call('list_elements', { source: 'ocr' });
  assert(ideas(before.elements).length > 0, 'Home must show suggestions before typing');
  const resting = input(call('list_elements', { source: 'accessibility' }).elements);
  assert(resting, 'Home composer must be accessible');
  call('tap_text', { text: 'capsule.field' });
  const raised = input(call('list_elements', { source: 'accessibility' }).elements);
  assert(raised && raised.frame.y < resting.frame.y - 100, 'Software keyboard must raise the composer');
  const after = call('list_elements', { source: 'ocr' });
  call('save_screenshot', { path: join(directory, 'keyboard.png'), overwrite: true });
  const evidence = { restingInput: resting.frame, raisedInput: raised.frame,
    remainingSuggestions: ideas(after.elements).map(e => ({ text: e.text ?? e.label, frame: e.frame })) };
  writeFileSync(join(directory, 'keyboard.json'), JSON.stringify(evidence, null, 2) + '\n');
  assert.equal(evidence.remainingSuggestions.length, 0, 'Home suggestions must yield while typing');
  console.log('PASS: keyboard raised the composer and home suggestions yielded');
} catch (error) {
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
}
