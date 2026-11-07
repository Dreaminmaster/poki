import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ReplyLedger } from '../reply-ledger.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'poki-ledger-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return new ReplyLedger(directory, 'test-chat');
}

test('A failed ledger write does not poison later operations or record a phantom reply', async t => {
  const ledger = await fixture(t);
  // A directory at the target file path makes the atomic rename fail reliably,
  // including when tests run with elevated filesystem privileges.
  await ledger.record('previously saved');
  await rm(ledger.path);
  await mkdir(ledger.path);
  await assert.rejects(ledger.record('not saved'));
  assert.deepEqual(ledger.entries.map(row => row.text), ['previously saved'], 'A rejected update must roll back in-memory state');
  await rm(ledger.path, { recursive: true });
  await ledger.record('saved after recovery');
  const rows = JSON.parse(await readFile(ledger.path, 'utf8'));
  assert.deepEqual(rows.map(row => row.text), ['previously saved', 'saved after recovery']);
});

test('Failed echo consumption rolls back mutations to existing entries', async t => {
  const ledger = await fixture(t);
  await ledger.record('reply');
  await rm(ledger.path);
  await mkdir(ledger.path);
  await assert.rejects(ledger.consume([{ id: 99, text: 'reply' }]));
  assert.equal(ledger.entries[0].receivedId, null, 'A failed persistence must not consume the echo');
  await rm(ledger.path, { recursive: true });
  const consumed = await ledger.consume([{ id: 99, text: 'reply' }]);
  assert.equal(consumed[0].text, '');
  assert.equal(ledger.entries[0].receivedId, 99);
  assert.equal(JSON.parse(await readFile(ledger.path, 'utf8'))[0].receivedId, 99);
});

test('A repaired invalid ledger can be loaded without restarting the ReplyLedger object', async t => {
  const ledger = await fixture(t);
  await writeFile(ledger.path, '{bad JSON');
  await assert.rejects(ledger.record('first'), /Cannot read the reply ledger/);
  await writeFile(ledger.path, '[]');
  await ledger.record('after repair');
  assert.equal(JSON.parse(await readFile(ledger.path, 'utf8'))[0].text, 'after repair');
});
