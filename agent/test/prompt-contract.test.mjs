import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '../..');
const read = rel => readFileSync(resolve(root, rel), 'utf8');
const words = text => text.trim().split(/\s+/).filter(Boolean).length;

const harnessTools = new Set([
  'look', 'do', 'skills', 'status',
  'web_open', 'web_read', 'web_click', 'web_type', 'web_handoff',
  'report_plan', 'finish_task',
]);

test('App Harness prompts preserve personal-assistant voice, tool, routing, evidence, and safety contracts', () => {
  const agentSystem = read('native/ios-app/Poki/Chat/Harness/agent-system.md');
  const harnessSwift = read('native/ios-app/Poki/Chat/Harness/Harness.swift');
  const combined = `${agentSystem}\n${harnessSwift}`;

  const firstParagraph = agentSystem.trim().split(/\n\s*\n/)[0];
  assert.match(firstParagraph, /personal assistant/i);
  assert.match(firstParagraph, /operate their iPhone directly/i);

  const snakeNames = [...agentSystem.matchAll(/\b[a-z]+(?:_[a-z]+)+\b/g)].map(m => m[0]);
  const unknownTools = [...new Set(snakeNames)].filter(name => !harnessTools.has(name));
  assert.deepEqual(unknownTools, [], `agent-system.md names unknown snake_case tools: ${unknownTools.join(', ')}`);

  assert.match(agentSystem, /latest message/i);
  assert.match(agentSystem, /Markdown table/);
  assert.match(combined, /web_open/);
  assert.match(combined, /web_handoff/);
  assert.match(combined, /report_plan/);
  assert.match(combined, /currentStep/);
  assert.match(combined, /finish_task\(success=true\)/);
  assert.match(combined, /finish_task\(success=false\)/);
  assert.match(combined, /screen:\s*locked/);
  assert.match(combined, /handoff:\s*\{kind:\s*"password"/);
  assert.match(agentSystem, /password manager/i);
  assert.match(agentSystem, /approval/i);
  assert.match(agentSystem, /Stop on the checkout or payment page/);
  assert.match(combined, /Messages or notifications/);
  assert.match(combined, /Return/);
  assert.match(combined, /scrolling down|scroll down/i);
  assert.match(combined, /no longer changes|stops changing/i);
  assert.match(combined, /purchase/);
  assert.match(harnessSwift, /swipe down on the Home Screen to search/);
  assert.match(harnessSwift, /Say an app is not installed only after find_app says so/);
  assert.match(harnessSwift, /skills \{action: \\"save\\"/);

  assert.ok(words(agentSystem) < 559, `agent-system.md grew to ${words(agentSystem)} words`);

  for (const text of [agentSystem, harnessSwift]) {
    assert.doesNotMatch(text, /[—–]/, 'Public prompt files avoid em and en dashes');
    assert.doesNotMatch(text, /ESP-\d+/i, 'Public prompt files avoid internal ticket IDs');
  }
  // The result card's description gives Chinese examples on purpose, for a Chinese conversation.
  assert.doesNotMatch(agentSystem, /\p{Script=Han}/u, 'agent-system.md stays in English');
});

test('Agent prompts preserve personal-assistant voice, device execution, verification, and safety contracts', () => {
  assert.equal(existsSync(resolve(root, 'agent/prompts/system.md')), false, 'Unused duplicate system.md stays removed');

  const piApp = read('agent/prompts/pi-app.md');
  const callDraft = read('agent/prompts/call-draft.md');
  const taskRunner = read('agent/task-runner.mjs');
  const combined = `${piApp}\n${callDraft}`;

  const firstParagraph = piApp.trim().split(/\n\s*\n/)[0];
  assert.match(firstParagraph, /personal assistant/i);
  assert.match(firstParagraph, /operate their iPhone directly/i);
  assert.match(taskRunner, /\[\s*await readFile\(new URL\('\.\/prompts\/pi-app\.md'/);

  assert.match(piApp, /latest message/i);
  assert.match(piApp, /report_plan/);
  assert.match(piApp, /currentStep/);
  assert.match(piApp, /unlock_device/);
  assert.match(piApp, /password manager/i);
  assert.match(piApp, /approval/i);
  assert.match(piApp, /Stop on the checkout or payment page/);
  assert.match(combined, /handle_alert/);
  assert.match(combined, /Messages or notifications/);
  assert.match(combined, /purchase/);
  assert.match(combined, /text_verified/);
  assert.match(combined, /Return/);
  assert.match(combined, /scrolling down|scroll down/i);
  assert.match(combined, /no longer changes|stops changing/i);
  assert.match(combined, /finish_task\(success=true\)/);
  assert.match(combined, /finish_task\(success=false\)/);
  assert.match(callDraft, /bundle_id/);
  assert.match(callDraft, /failed_step/);
  assert.match(callDraft, /remaining_steps/);

  assert.ok(words(piApp) + words(callDraft) < 618, `Agent prompts grew to ${words(piApp) + words(callDraft)} words`);

  for (const text of [piApp, callDraft]) {
    assert.doesNotMatch(text, /[—–]/);
    assert.doesNotMatch(text, /ESP-\d+/i);
    assert.doesNotMatch(text, /\p{Script=Han}/u);
  }
});
