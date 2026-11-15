#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, output] = process.argv.slice(2);
assert(clientRoot && device && output, 'Usage: check-composer-row.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR');
assert(device.startsWith('ESP-735 '), 'Use the dedicated ESP-735 simulator');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });
function call(name, args = {}) {
  return JSON.parse(execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000 }));
}
function composer() {
  const { elements } = call('list_elements', { source: 'accessibility' });
  return Object.fromEntries(['capsule.field', 'composer.plus', 'composer.main'].map(id => {
    const element = elements.find(e => e.identifier === id);
    assert(element?.visible, `${id} must be visible`);
    return [id, { frame: element.frame, focused: element.focused }];
  }));
}
function inline(elements) {
  const field = elements['capsule.field'].frame;
  return ['composer.plus', 'composer.main'].every(id => {
    const button = elements[id].frame;
    return Math.min(field.y + field.height, button.y + button.height) > Math.max(field.y, button.y);
  });
}
try {
  call('launch_app', { bundle_id: 'nz.zheha.poki', arguments: ['-pokiChat', 'empty',
    '-appInterfaceSize', 'system', '-AppleLanguages', '(zh-Hans)', '-AppleLocale', 'zh_CN'] });
  const resting = composer();
  call('save_screenshot', { path: join(directory, 'resting.png'), overwrite: true });
  call('tap_text', { text: 'capsule.field' });
  const focused = composer();
  call('save_screenshot', { path: join(directory, 'focused.png'), overwrite: true });
  writeFileSync(join(directory, 'geometry.json'), JSON.stringify({ resting, focused }, null, 2) + '\n');
  assert(focused['capsule.field'].focused, 'The message field must have keyboard focus');
  assert(focused['capsule.field'].frame.y < resting['capsule.field'].frame.y - 100,
    'The software keyboard must raise the composer');
  assert(inline(resting), 'The resting default-size composer must use one row');
  assert(inline(focused), 'Focusing an empty default-size composer must keep the field and buttons in one row');
  console.log('PASS: default-size composer stays in one row before and after keyboard focus');
} catch (error) {
  console.error(`FAIL: ${error.message}`);
  process.exitCode = 1;
}
