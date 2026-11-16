import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { parse } from 'acorn';

test('fixture requests keyboard dismissal after returning before dragging lower controls', async () => {
  const ast = parse(await readFile(new URL('../bin/verify-fixture.mjs', import.meta.url), 'utf8'), { ecmaVersion: 'latest', sourceType: 'module' });
  const requests = [];
  const visit = node => {
    if (!node || typeof node !== 'object') return;
    if (node.type === 'AwaitExpression' && node.argument.type === 'CallExpression') {
      const value = node.argument.arguments[0]?.value;
      if (typeof value === 'string') requests.push({ value, start: node.start });
    }
    for (const child of Object.values(node)) {
      if (Array.isArray(child)) child.forEach(visit);
      else if (child && typeof child === 'object') visit(child);
    }
  };
  visit(ast);
  requests.sort((a, b) => a.start - b.start);
  const back = requests.findIndex(({ value }) => value === 'go_back');
  const drag = requests.findIndex(({ value }, i) => i > back && value === 'drag');
  assert.ok(back >= 0 && drag > back);
  assert.ok(requests.slice(back + 1, drag).some(({ value }) => value === 'hide_keyboard'), 'returning from Detail must dismiss the restored keyboard before slider input');
});
