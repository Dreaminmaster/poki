import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, generateKeyPairSync, sign, verify } from 'node:crypto';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../scripts/release/publish-r2.mjs', import.meta.url));

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'poki-publish-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const keys = generateKeyPairSync('ed25519');
  const config = { url: 'https://releases.example.com/catalog.json', public_key: keys.publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex') };
  const tag = 'app-0.4.1-beta.1';
  const release = { tag_name: tag, name: 'Poki Beta', html_url: `https://github.com/JosssphZhou/poki/releases/tag/${tag}`, published_at: '2026-01-01T00:00:00Z', draft: false, prerelease: true, assets: [] };
  await mkdir(join(root, 'assets'));
  await mkdir(join(root, 'output'));
  for (const name of ['Poki-external-0.4.1-1300.ipa', 'Poki-signing.zip', 'SHA256SUMS', 'poki-relay-worker.js']) {
    const body = Buffer.from(`synthetic publication fixture: ${name}`);
    await writeFile(join(root, 'assets', name), body);
    release.assets.push({ name, size: body.length, state: 'uploaded', digest: `sha256:${createHash('sha256').update(body).digest('hex')}`, browser_download_url: `https://github.com/JosssphZhou/poki/releases/download/${tag}/${name}` });
  }
  await writeFile(join(root, 'source.json'), JSON.stringify(config));
  await writeFile(join(root, 'release.json'), JSON.stringify(release));
  return { root, keys, release,
    run(extra = [], key = keys.privateKey) {
      return spawnSync(process.execPath, [script, '--release', join(root, 'release.json'), '--assets', join(root, 'assets'), '--output', join(root, 'output'), '--config', join(root, 'source.json'), ...extra], {
        encoding: 'utf8', env: { ...process.env, POKI_RELEASE_SIGNING_KEY: key.export({ type: 'pkcs8', format: 'pem' }) },
      });
    },
  };
}

test('the release CLI produces a verifiable catalog and retains historical releases', async t => {
  const f = await fixture(t);
  const history = { tag_name: 'ios-beta-0.4.0-1260', draft: false, prerelease: true, assets: [] };
  const payload = Buffer.from(JSON.stringify({ schema: 1, releases: [history] }));
  const previous = JSON.stringify({ payload: payload.toString('base64'), signature: sign(null, payload, f.keys.privateKey).toString('base64') });
  const previousFile = join(f.root, 'previous.json');
  await writeFile(previousFile, previous);
  const result = f.run(['--previous', previousFile]);
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /nothing uploaded/);
  const envelope = JSON.parse(await readFile(join(f.root, 'output/catalog.json'), 'utf8'));
  const bytes = Buffer.from(envelope.payload, 'base64');
  assert.ok(verify(null, bytes, f.keys.publicKey, Buffer.from(envelope.signature, 'base64')));
  const catalog = JSON.parse(bytes);
  assert.deepEqual(catalog.releases.map(r => r.tag_name), ['app-0.4.1-beta.1', 'ios-beta-0.4.0-1260']);
  assert.equal(catalog.releases[0].assets[0].browser_download_url, 'https://releases.example.com/releases/app-0.4.1-beta.1/Poki-external-0.4.1-1300.ipa');
  assert.equal(catalog.releases[0].assets[0].sha256, f.release.assets[0].digest.slice(7));
  assert.equal(await readFile(join(f.root, 'output/previous-catalog.json'), 'utf8'), previous);
});

test('untrusted publication inputs cannot replace a prepared catalog', async t => {
  for (const failure of ['key', 'file', 'draft', 'preview', 'path', 'previous-signature']) {
    await t.test(failure, async t => {
      const f = await fixture(t);
      const target = join(f.root, 'output/catalog.json');
      await writeFile(target, 'existing catalog');
      let key = f.keys.privateKey;
      const extra = [];
      if (failure === 'key') key = generateKeyPairSync('ed25519').privateKey;
      if (failure === 'file') await writeFile(join(f.root, 'assets/Poki-signing.zip'), 'corrupt archive');
      if (failure === 'draft') f.release.draft = true;
      if (failure === 'preview') f.release.tag_name = 'app-0.4.1-alpha.1300';
      if (failure === 'path') f.release.assets[0].name = '../outside.ipa';
      if (failure === 'previous-signature') {
        const file = join(f.root, 'previous.json');
        await writeFile(file, JSON.stringify({ payload: Buffer.from('{"schema":1,"releases":[]}').toString('base64'), signature: Buffer.alloc(64).toString('base64') }));
        extra.push('--previous', file);
      }
      await writeFile(join(f.root, 'release.json'), JSON.stringify(f.release));
      const result = f.run(extra, key);
      assert.equal(result.status, 1);
      const reasons = { key: /does not match/, file: /does not match/, draft: /Only published/, preview: /Only published/, path: /Invalid or duplicate/, 'previous-signature': /signature is invalid/ };
      assert.match(result.stderr, reasons[failure]);
      assert.equal(await readFile(target, 'utf8'), 'existing catalog');
    });
  }
});

test('a published release cannot be replaced with different bytes under the same tag', async t => {
  const f = await fixture(t);
  assert.equal(f.run().status, 0);
  const original = await readFile(join(f.root, 'output/catalog.json'), 'utf8');
  const previousFile = join(f.root, 'previous.json');
  await writeFile(previousFile, original);
  const changed = Buffer.from('a different but GitHub-matching signing archive');
  const asset = f.release.assets.find(a => a.name === 'Poki-signing.zip');
  asset.size = changed.length;
  asset.digest = `sha256:${createHash('sha256').update(changed).digest('hex')}`;
  await writeFile(join(f.root, 'assets', asset.name), changed);
  await writeFile(join(f.root, 'release.json'), JSON.stringify(f.release));
  const result = f.run(['--previous', previousFile]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /immutable/);
  assert.equal(await readFile(join(f.root, 'output/catalog.json'), 'utf8'), original);
});
