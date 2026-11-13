import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { latestSetup, downloadIpa } from '../src/install/setup-app.mjs';
import { releaseSource } from './release-source.mjs';

const NAME = 'PokiSetup-0.2.2-700-macos.dmg';
const dmg = source => source.asset(NAME, `/releases/1/${NAME}`, 'dmg');
// A Beta release accepted by the installer once the catalog is verified.
const setupRelease = (source, installer) => source.release('app-0.4.2-beta.700', [installer, source.asset('SHA256SUMS-desktop.txt', '/releases/1/SHA256SUMS-desktop.txt', 'sums')]);
const refused = message => ({ code: 'setup_download_failed', message });

test('a release source without a verification key refuses before any request', async t => {
  const source = await releaseSource(t);
  source.publish([setupRelease(source, dmg(source))]);
  source.use('/catalog.json', '');
  await assert.rejects(latestSetup('alpha'), refused(/verification key is not configured/));
  assert.deepEqual(source.asked, []);
});

test('a file on another origin is refused', async t => {
  const source = await releaseSource(t);
  const other = await releaseSource(t);
  source.publish([setupRelease(source, dmg(other))]);
  source.use();
  await assert.rejects(latestSetup('alpha'), refused(/outside the release source/));
});

test('a file path outside /releases/ is refused', async t => {
  const source = await releaseSource(t);
  source.use();
  for (const path of [`/other/${NAME}`, `/releases/1/../${NAME}`]) {
    source.publish([setupRelease(source, source.asset(NAME, `/releases/${NAME}`, 'dmg', source.origin + path))]);
    await assert.rejects(latestSetup('alpha'), refused(/outside the release source/), path);
  }
});

test('a redirect is refused for the catalog and for a file', async t => {
  const source = await releaseSource(t);
  const sums = source.asset('SHA256SUMS', '/releases/1/moved-SHA256SUMS', 'sums');
  sums.browser_download_url = `${source.origin}/releases/1/SHA256SUMS`;
  source.redirect('/releases/1/SHA256SUMS', '/releases/1/moved-SHA256SUMS');
  const files = ['Poki-external-0.4.0-700.ipa', 'Poki-signing.zip'].map(name => source.asset(name, `/releases/1/${name}`, name));
  source.publish([setupRelease(source, dmg(source)), source.release('ios-alpha-latest', [sums, ...files])], '/moved.json');
  source.redirect('/catalog.json', '/moved.json');

  source.use('/catalog.json');
  await assert.rejects(latestSetup('alpha'), refused(/redirect/));

  source.use('/moved.json');
  const downloads = await mkdtemp(join(tmpdir(), 'poki-catalog-'));
  t.after(() => rm(downloads, { recursive: true, force: true }));
  await assert.rejects(downloadIpa('ios-alpha-latest', downloads), refused(/redirect/));
});

test('R2 serves Beta with GitHub blocked, and an unavailable catalog falls back with a notice', async t => {
  const source = await releaseSource(t);
  const installer = dmg(source);
  const beta = source.release('app-0.4.2-beta.700', [installer]);
  source.publish([beta]);
  source.use();
  const original = globalThis.fetch;
  let githubCalls = 0;
  let githubAvailable = false;
  const notices = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    if (String(url).startsWith(source.origin)) return original(url, options);
    githubCalls++;
    if (!githubAvailable) throw new Error('GitHub is blocked');
    return Response.json([{ ...beta, assets: [installer, { name: 'SHA256SUMS-desktop.txt', browser_download_url: 'https://github.com/example/sums' }] }]);
  });
  const primary = await latestSetup('alpha', note => notices.push(note));
  assert.equal(primary.source, 'r2');
  assert.equal(primary.tag, beta.tag_name);
  assert.equal(githubCalls, 0);
  source.use('/unavailable.json');
  githubAvailable = true;
  const fallback = await latestSetup('stable', note => notices.push(note));
  assert.equal(fallback.source, 'github');
  assert.match(fallback.source_notice, /R2 is unavailable/);
  assert.equal(githubCalls, 1);
  assert.deepEqual(notices, [fallback.source_notice]);
});

test('a modified catalog cannot trigger a GitHub fallback', async t => {
  const source = await releaseSource(t);
  source.publish([setupRelease(source, dmg(source))]);
  source.put('/catalog.json', JSON.stringify({ payload: Buffer.from(JSON.stringify({schema:1,releases:[setupRelease(source,dmg(source))]})).toString('base64'), signature: Buffer.alloc(64).toString('base64') }));
  source.use();
  const original = globalThis.fetch;
  t.mock.method(globalThis, 'fetch', (url, options) => {
    assert.ok(String(url).startsWith(source.origin), 'invalid signatures must never request GitHub');
    return original(url, options);
  });
  await assert.rejects(latestSetup(), /signature is invalid/);
});

test('an interrupted R2 asset uses the same GitHub release and signed integrity', async t => {
  const source = await releaseSource(t);
  const files = ['Poki-external-0.4.2-700.ipa', 'Poki-signing.zip'].map(name => source.asset(name, `/releases/700/${name}`, name));
  const sums = source.asset('SHA256SUMS', '/releases/700/SHA256SUMS', '');
  const beta = source.release('app-0.4.2-beta.700', [sums, ...files]);
  source.publish([beta]);
  source.use();
  const original = globalThis.fetch;
  const downloads = await mkdtemp(join(tmpdir(), 'poki-r2-fallback-'));
  t.after(() => rm(downloads, { recursive: true, force: true }));
  const notices = [];
  let corrupt = false;
  let corruptPrimary = false;
  let mirrorRequests = 0;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    const address = String(url);
    if (address === files[0].browser_download_url) {
      if (corruptPrimary) return new Response('bad');
      throw new TypeError('Connection refused');
    }
    if (address.startsWith(source.origin)) return original(url, options);
    if (address.endsWith(`/releases/tags/${beta.tag_name}`)) return Response.json({ assets: [{ name: files[0].name, browser_download_url: 'https://github.com/example/mirror' }] });
    assert.equal(address, 'https://github.com/example/mirror');
    mirrorRequests++;
    return new Response(corrupt ? 'modified' : files[0].name);
  });
  const path = await downloadIpa(beta.tag_name, downloads, files[0].name, note => notices.push(note));
  const { readFile } = await import('node:fs/promises');
  assert.equal(await readFile(path, 'utf8'), files[0].name);
  assert.match(notices[0], /R2 is unavailable/);
  corrupt = true;
  await assert.rejects(downloadIpa(beta.tag_name, downloads, files[0].name), { code: 'setup_checksum_mismatch' });
  assert.equal(await readFile(path, 'utf8'), files[0].name);
  corruptPrimary = true;
  const before = mirrorRequests;
  await assert.rejects(downloadIpa(beta.tag_name, downloads, files[0].name), { code: 'setup_checksum_mismatch' });
  assert.equal(mirrorRequests, before, 'a corrupt R2 asset must not fall back');
});
