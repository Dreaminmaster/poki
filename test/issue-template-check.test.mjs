import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadForms, matchForm, areaLabel, AREA_LABELS, AREA_HEADING } from '../.github/scripts/check-issue-template.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = join(root, '.github/ISSUE_TEMPLATE');

test('the four issue forms exist with the required fields of the label scheme', () => {
  const forms = loadForms(dir);
  assert.deepEqual(forms.map((f) => f.file).sort(), ['bug_report.yml', 'feature_request.yml', 'install-failure.yml', 'task_failure.yml']);
  const required = Object.fromEntries(forms.map((f) => [f.file, f.required.length]));
  assert.deepEqual(required, { 'bug_report.yml': 6, 'feature_request.yml': 3, 'install-failure.yml': 6, 'task_failure.yml': 6 });
});

test('every Affected area option either maps to an area label or is the unlabeled catch-all', async () => {
  for (const file of ['bug_report.yml', 'feature_request.yml']) {
    const text = await readFile(join(dir, file), 'utf8');
    const block = text.split(`label: ${AREA_HEADING}`)[1].split('validations:')[0];
    const options = [...block.matchAll(/^\s+- (.+)$/gm)].map((m) => m[1]);
    assert.ok(options.length >= 5, `${file} lists the areas`);
    for (const o of options) {
      assert.ok(AREA_LABELS.has(o) || o === 'Other or not sure', `${file}: "${o}" has an area label`);
    }
  }
});

test('an issue body is matched to its form and its area label', () => {
  const forms = loadForms(dir);
  const body = '### Goal or use case\n\nOpen Maps\n\n### Current limitation\n\nNot supported\n\n### Affected area in Poki\n\nPoki Agent, iMessage, or Telegram\n\n### Impact\n\n_No response_\n';
  assert.equal(matchForm(body, forms)?.file, 'feature_request.yml');
  assert.equal(areaLabel(body), 'area:agent');
  assert.equal(matchForm('### Problem description\n\nbroken', forms), null);
  assert.equal(areaLabel('### Affected area in Poki\n\nOther or not sure\n'), null);
});
