#!/usr/bin/env node
// check-shortcut-editor-language.mjs POKI_MCP_ROOT SIMULATOR POKI_APP OUTPUT_DIR: installs a Debug Poki on a
// simulator and, through Poki MCP, opens a home pill's Edit popup with Poki set to one language and the
// iPhone to another. The app row's choices begin with None in Poki's language, and picking None shows
// that word on the row. The popup is cancelled, so no shortcut changes.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const [clientRoot, device, app, output] = process.argv.slice(2);
assert(clientRoot && device && app && output, 'Usage: check-shortcut-editor-language.mjs POKI_MCP_ROOT SIMULATOR POKI_APP OUTPUT_DIR');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });
const bundle = 'nz.zheha.poki';

function call(name, args = {}) {
  const raw = execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 120000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(raw);
}
const pause = ms => execFileSync('sleep', [String(ms / 1000)]);
const elements = () => call('list_elements', { source: 'accessibility' }).elements;
const centre = e => ({ x: e.frame.x + e.frame.width / 2, y: e.frame.y + e.frame.height / 2 });
function waitFor(what, test) {
  for (let i = 0; i < 16; i++) {
    const found = elements().find(test);
    if (found) return found;
    pause(500);
  }
  throw new Error(`${what} never showed`);
}

// The iPhone in one language and Poki in another, with what Poki calls Edit and None in its own.
const cases = [
  { iphone: 'zh-Hans', locale: 'zh_CN', poki: 'en', edit: 'Edit', none: 'None' },
  { iphone: 'en', locale: 'en_US', poki: 'zh-Hans', edit: '修改', none: '无' },
  { iphone: 'en', locale: 'en_US', poki: 'zh-Hant', edit: '修改', none: '無' },
];
const anyNone = new Set(cases.map(c => c.none));
const evidence = [];
try {
  execFileSync('xcrun', ['simctl', 'install', device, resolve(app)]);
  for (const c of cases) {
    const seen = { poki: c.poki, iphone: c.iphone };
    evidence.push(seen);
    try { call('terminate_app', { bundle_id: bundle }); } catch {}
    // The pills stand still so one can be pressed. Any -poki argument also skips the welcome pages.
    call('launch_app', { bundle_id: bundle, arguments: ['-pokiPerf', 'pillsStill', '-uiLanguage', c.poki,
      '-AppleLanguages', `(${c.iphone})`, '-AppleLocale', c.locale] });
    pause(3000);
    const allow = elements().find(e => e.type === 'Button' && /^(允许|Allow)$/.test(e.label ?? ''));
    if (allow) { call('tap', centre(allow)); pause(1000); }

    const pill = waitFor('A pill in the middle of the screen', e => (e.identifier ?? '').startsWith('home.idea.')
      && centre(e).x > 80 && centre(e).x < 322);
    call('long_press', { ...centre(pill), duration: 1.2 });
    call('tap', centre(waitFor(`${c.edit} in the pill's menu`, e => e.type === 'Button' && e.label === c.edit)));
    const row = waitFor("The Edit popup's app row", e => e.identifier === 'shortcut.edit.app');
    call('tap', centre(row));
    pause(800);
    // The card grows and moves up as the choices open under the row, at the pill's app. None is the
    // first choice, so scroll up until the first one stays the same.
    const open = waitFor('The open app row', e => e.identifier === 'shortcut.edit.app');
    const top = open.frame.y + open.frame.height;
    const shown = () => elements().filter(e => e.type === 'Button' && e.frame.y >= top - 1 && e.frame.y < top + 220)
      .sort((a, b) => a.frame.y - b.frame.y);
    let choices = shown();
    for (let i = 0; i < 30; i++) {
      call('swipe', { from_x: 200, from_y: top + 30, to_x: 200, to_y: top + 210, duration_ms: 200 });
      pause(300);
      const now = shown();
      if (now[0]?.label === choices[0]?.label) break;
      choices = now;
    }
    seen.firstChoice = choices[0]?.label;
    call('save_screenshot', { path: join(directory, `${c.poki}-on-${c.iphone}-choices.png`), overwrite: true });
    assert(choices[0] && anyNone.has(choices[0].label), `The first choice is None in some language, got ${seen.firstChoice}`);
    assert.equal(seen.firstChoice, c.none, `None is in Poki's language (${c.poki}) on a ${c.iphone} iPhone`);

    call('tap', centre(choices[0]));
    pause(800);
    seen.rowValue = waitFor('The app row after picking None', e => e.identifier === 'shortcut.edit.app').value;
    call('save_screenshot', { path: join(directory, `${c.poki}-on-${c.iphone}-picked.png`), overwrite: true });
    assert.equal(seen.rowValue, c.none, `The app row shows None in Poki's language (${c.poki})`);
    call('tap', centre(waitFor('Cancel', e => e.identifier === 'shortcut.edit.cancel')));
    pause(800);
  }
  console.log("PASS: the Edit popup's None follows Poki's language, not the iPhone's");
} catch (error) {
  evidence.push({ failure: error.message });
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
} finally {
  try { call('terminate_app', { bundle_id: bundle }); } catch {}
  writeFileSync(join(directory, 'shortcut-editor-language.json'), JSON.stringify(evidence, null, 2) + '\n');
}
