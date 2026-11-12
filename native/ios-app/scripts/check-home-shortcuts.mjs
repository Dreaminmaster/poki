#!/usr/bin/env node
// check-home-shortcuts.mjs POKI_MCP_ROOT SIMULATOR_NAME POKI_APP OUTPUT_DIR: installs Poki fresh on a
// simulator, runs made-up tasks against the scripted model (mock-model.py), and checks the home page's
// quick actions through Poki MCP: the examples for a new owner, the owner's repeated requests after,
// Forget surviving a restart, and a tap on a quick action starting a task.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const [clientRoot, device, app, output] = process.argv.slice(2);
assert(clientRoot && device && app && output, 'Usage: check-home-shortcuts.mjs POKI_MCP_ROOT SIMULATOR_NAME POKI_APP OUTPUT_DIR');
assert(device.startsWith('ESP-447 '), 'Use the dedicated ESP-447 simulator');
const directory = resolve(output);
mkdirSync(directory, { recursive: true });
const bundle = 'nz.zheha.poki';
const model = spawn('python3', [join(dirname(fileURLToPath(import.meta.url)), 'mock-model.py'), '--port', '8765',
  '--log', join(directory, 'model-requests.jsonl')], { stdio: 'ignore' });

function call(name, args = {}) {
  const raw = execFileSync(process.execPath, [join(clientRoot, 'bin/call.mjs'), name,
    JSON.stringify({ device, ...args })], { encoding: 'utf8', timeout: 180000, stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(raw);
}
const pause = ms => execFileSync('sleep', [String(ms / 1000)]);
const elements = () => call('list_elements', { source: 'accessibility' }).elements;
const centre = e => ({ x: e.frame.x + e.frame.width / 2, y: e.frame.y + e.frame.height / 2 });
const pills = () => elements().filter(e => (e.identifier ?? '').startsWith('home.idea.')).map(e => ({ ...e, text: e.label }));
// The rows move, so wait until the pill is well inside the screen before touching it.
function onScreen(text) {
  for (let i = 0; i < 20; i++) {
    const pill = pills().find(p => p.text === text && centre(p).x > 60 && centre(p).x < 342);
    if (pill) return centre(pill);
    pause(700);
  }
  throw new Error(`${text} never came on screen`);
}
const shot = name => call('save_screenshot', { path: join(directory, `${name}.png`), overwrite: true });

function launch(language = 'zh') {
  const locale = language === 'zh' ? ['-AppleLanguages', '(zh-Hans)', '-AppleLocale', 'zh_CN'] : ['-AppleLanguages', '(en)', '-AppleLocale', 'en_US'];
  const args = { bundle_id: bundle, arguments: ['-chat.provider', 'custom', '-chat.customURL', 'http://127.0.0.1:8765/v1',
    '-chat.customModel', 'poki-mock', '-approvals.mode', 'off', ...locale] };
  // A launch while the simulator is still closing the last one can time out; one more try settles it.
  try { call('launch_app', args); } catch { pause(3000); call('launch_app', args); }
  pause(3000);
  // Poki reopens the last conversation; the new-conversation button goes back to the home page.
  const list = elements();
  const back = list.find(e => e.identifier === 'home.newChat');
  if (back && !list.some(e => (e.identifier ?? '').startsWith('home.idea.'))) { call('tap', centre(back)); pause(1500); }
}

// The simulator types Chinese by pasting; iOS asks once per paste whether Poki may.
function type(words) {
  try { call('type_text', { text: words }); } catch (error) {
    if (!/paste|粘贴/i.test(String(error.stdout ?? ''))) throw error;
    call('tap_text', { text: /允许粘贴/.test(error.stdout) ? '允许粘贴' : 'Allow Paste' });
    pause(800);
  }
}

function ask(words) {
  call('tap_text', { text: 'capsule.field' });
  type(words);
  call('tap', centre(elements().find(e => e.identifier === 'composer.main')));
  pause(20000);
  // The first finished task asks whether Poki may send notifications.
  const allow = elements().find(e => e.type === 'Button' && /^(允许|Allow)$/.test(e.label ?? ''));
  if (allow) call('tap', centre(allow));
  launch();
}

const evidence = {};
try {
  execFileSync('xcrun', ['simctl', 'uninstall', device, bundle], { stdio: 'ignore' });
  execFileSync('xcrun', ['simctl', 'install', device, resolve(app)]);
  execFileSync('xcrun', ['simctl', 'privacy', device, 'grant', 'location-always', bundle]);
  launch();

  evidence.newOwner = pills().map(p => p.text);
  shot('01-new-zh');
  assert(evidence.newOwner.length >= 3 && evidence.newOwner.every(t => /Slack|信息|Uber|Starbucks|备忘录|Instagram|Messages|Notes/.test(t)),
    'A new owner sees the default examples');

  for (const words of ['打开设置看看电池', '打开设置，看看电池。', '帮我打开设置看看电池', '查一下明天的天气', '查一下今天的天气',
    '给妈妈发消息说我到了', '给妈妈发消息说我到了']) ask(words);
  launch();
  evidence.withHistory = pills().map(p => p.text);
  shot('02-history-zh');
  // The rows go by on their own, so the order on screen changes; the top row holds the first three.
  const shown = pills();
  const top = shown.filter(p => p.frame.y === Math.min(...shown.map(q => q.frame.y))).map(p => p.text);
  evidence.topRow = [...new Set(top)];
  assert(top.includes('帮我打开设置看看电池'), 'A request made three times is in the top row, in its latest words');
  assert(top.includes('查一下今天的天气'), 'Dates do not split a request in two: the weather, asked twice, is in the top row');
  assert(!evidence.withHistory.some(t => ['打开设置看看电池', '打开设置，看看电池。', '查一下明天的天气'].includes(t)), 'Similar requests make one pill');
  assert(!evidence.withHistory.includes('给妈妈发消息说我到了'), 'A message to a contact never becomes a pill');

  call('long_press', { ...onScreen('查一下今天的天气'), duration: 1.2 });
  pause(1200);
  shot('03-forget-menu-zh');
  call('tap_text', { text: '忘记' });
  pause(1500);
  assert(!pills().some(p => p.text === '查一下今天的天气'), 'Forget takes the pill away');
  execFileSync('xcrun', ['simctl', 'terminate', device, bundle], { stdio: 'ignore' });
  launch();
  evidence.afterForget = pills().map(p => p.text);
  shot('04-forgotten-zh');
  assert(!evidence.afterForget.includes('查一下今天的天气'), 'Forget lasts across a restart');

  launch('en');
  shot('05-history-en');
  evidence.english = pills().map(p => p.text);

  launch();
  call('tap', onScreen('帮我打开设置看看电池'));
  pause(800);
  const field = elements().find(e => /TextArea|TextField/.test(e.type) && (e.value ?? '').includes('打开设置看看电池'));
  assert(field, 'A tap puts the quick action in the message field');
  call('tap', centre(elements().find(e => e.identifier === 'composer.main')));
  pause(6000);
  shot('06-task-started-zh');
  const started = elements().some(e => /打开设置|Open Settings|Look at Settings/.test(e.label ?? ''));
  evidence.taskStarted = started;
  assert(started, 'The task starts: the scripted plan shows');
  console.log('PASS: examples, repeated requests first, private ones left out, Forget lasts, a tap starts the task');
} catch (error) {
  evidence.failure = error.message;
  console.error(error.message.replace(/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/gi, '<device>'));
  process.exitCode = 1;
} finally {
  model.kill();
  writeFileSync(join(directory, 'shortcuts.json'), JSON.stringify(evidence, null, 2) + '\n');
}
