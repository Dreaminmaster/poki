#!/usr/bin/env node
// check-testing-options.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR: drives Poki on a simulator through Poki MCP and
// checks that General › Testing Options still has 752's Diagnostics tools: the automation path switch with its
// probes and the Background Hold experiment, and that the switch moves Poki to Poki Runner after a restart.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, output] = process.argv.slice(2);
assert(clientRoot && device && output, 'Usage: check-testing-options.mjs POKI_MCP_ROOT SIMULATOR_NAME OUTPUT_DIR');
assert(device.startsWith('ESP-460 '), 'Use the dedicated ESP-460 simulator');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });
const bundle = 'nz.zheha.poki';

const pause = ms => execFileSync('sleep', [String(ms / 1000)]);
/// One Poki MCP call. A read can fail while a menu is still closing, so reads try again twice.
function call(name, args = {}) {
  const tries = ['list_elements', 'save_screenshot'].includes(name) ? 3 : 1;
  for (let attempt = 1; ; attempt++) {
    try {
      return JSON.parse(execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
        JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] }));
    } catch (error) {
      if (attempt >= tries) throw new Error(`${name} failed: ${String(error.stderr || error.message).trim().split('\n').at(-1)}`);
      pause(1500);
    }
  }
}
const elements = () => call('list_elements', { source: 'accessibility' }).elements;
const centre = e => ({ x: e.frame.x + e.frame.width / 2, y: e.frame.y + e.frame.height / 2 });
const tap = e => { call('tap', centre(e)); pause(1200); };
const named = (list, text) => list.find(e => [e.label, e.value, e.identifier].some(s => (s ?? '').includes(text)));
const shot = name => call('save_screenshot', { path: join(directory, `${name}.png`), overwrite: true });

const devices = JSON.parse(execFileSync('xcrun', ['simctl', 'list', 'devices', '-j'], { encoding: 'utf8' })).devices;
const udid = Object.values(devices).flat().find(d => d.name === device && d.state === 'Booted')?.udid;
assert(udid, `${device} must be booted`);
// The simulator's preferences daemon keeps the app's own view of its settings, so changing the plist from
// outside does not reach Poki. The check reads the saved value and sets the path through the app itself.
const preferences = join(execFileSync('xcrun', ['simctl', 'get_app_container', udid, bundle, 'data'], { encoding: 'utf8' }).trim(),
  'Library/Preferences', bundle);
const savedPath = () => {
  try { return execFileSync('xcrun', ['simctl', 'spawn', udid, 'defaults', 'read', preferences, 'automationPath'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
  catch { return null; }
};
// Quits Poki and waits for it, so the next launch reads the path afresh.
const quit = () => { try { execFileSync('xcrun', ['simctl', 'terminate', udid, bundle], { stdio: 'ignore' }); } catch {} pause(1000); };
const note = 'Takes effect when Poki starts again.';
const pickerText = () => { const p = named(elements(), 'actions go through'); return `${p?.label ?? ''} ${p?.value ?? ''}`; };
/// Chooses a path on the open Testing Options page.
function choose(label) {
  const picker = named(elements(), 'actions go through');
  assert(picker, 'Testing Options must have the automation path switch');
  tap(picker);
  const item = elements().find(e => e.label === label);
  assert(item, `The switch must offer ${label}`);
  tap(item);
}
/// Starts Poki on its own path, as a new install does, whatever an earlier run left.
function startOnPokiItself() {
  quit();
  openTestingOptions();
  if (/Poki itself/.test(pickerText())) return;
  choose('Poki itself');
  quit();
  openTestingOptions();
}

function openTestingOptions() {
  call('launch_app', { bundle_id: bundle, arguments: ['-pokiScreen', 'health', '-AppleLanguages', '(en)', '-AppleLocale', 'en_US'] });
  pause(3000);
  const alert = elements().find(e => e.type === 'Button' && /^(Allow|允许)$/.test(e.label ?? ''));
  if (alert) tap(alert);
  const row = elements().find(e => e.identifier === 'moreSettings.testingOptions');
  assert(row, 'General must offer Testing Options');
  tap(row);
}

/// The rows below the first screen: scrolls until every text is found or the page stops moving.
function find(texts) {
  const found = {};
  for (let round = 0; round < 6 && texts.some(t => !found[t]); round++) {
    const list = elements();
    for (const t of texts) if (!found[t] && named(list, t)) found[t] = named(list, t);
    if (texts.every(t => found[t])) break;
    call('swipe', { from_x: 200, from_y: 650, to_x: 200, to_y: 250 });
    pause(800);
  }
  return found;
}

const evidence = {};
try {
  startOnPokiItself();
  evidence.pickerBefore = pickerText();
  assert.match(evidence.pickerBefore, /Poki itself/, 'Poki must start on its own path');
  assert(!named(elements(), note), 'Poki must be running on the path the switch shows');
  shot('testing-options');
  const tools = ['actions go through', 'Port 8100', 'Compare both paths (5 rounds)', 'Self test', 'Background Hold', 'Start Hold'];
  const found = find(tools);
  evidence.tools = Object.fromEntries(tools.map(t => [t, Boolean(found[t])]));
  assert.deepEqual(tools.filter(t => !found[t]), [], 'Testing Options must keep 752’s Diagnostics tools');
  shot('testing-options-hold');

  // Back to the top by opening the page again: a downward swipe on this sheet would close it.
  quit();
  openTestingOptions();
  choose('Poki Runner');
  shot('switched-to-runner');
  evidence.savedAfterTap = savedPath();
  assert.equal(evidence.savedAfterTap, 'runner', 'Choosing Poki Runner must save it');
  assert(named(elements(), note), 'The switch must say it takes effect on the next start');

  quit();
  openTestingOptions();
  evidence.pickerAfterRestart = pickerText();
  assert.match(evidence.pickerAfterRestart, /Poki Runner/, 'After a restart the switch must read Poki Runner');
  assert(!named(elements(), note), 'After a restart Poki must run on Poki Runner');
  shot('runner-after-restart');
  console.log('PASS: Testing Options has the path switch, its probes and Background Hold; Poki Runner takes over after a restart');
} catch (error) {
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
} finally {
  try { startOnPokiItself(); } catch {}
  quit();
  evidence.savedAfterCleanup = savedPath();
  writeFileSync(join(directory, 'testing-options.json'), JSON.stringify(evidence, null, 2) + '\n');
}
