import assert from 'node:assert/strict';
import test from 'node:test';
import { channelOf, latestSetup } from '../src/install/setup-app.mjs';

test('app-* tags map to channels', () => {
  assert.equal(channelOf('app-0.2.9-prealpha.640', true), 'pre-alpha');
  assert.equal(channelOf('app-prealpha-latest', true), 'pre-alpha');
  assert.equal(channelOf('app-0.2.9-alpha.640', true), 'alpha');
  assert.equal(channelOf('app-alpha-latest', true), 'alpha');
  assert.equal(channelOf('app-0.3.0-beta.1', true), 'beta');
  assert.equal(channelOf('app-0.3.0', false), 'stable');
  assert.equal(channelOf('app-0.3.0', true), 'beta');
  assert.equal(channelOf('app-latest', false), null);
});

test('ios-* and desktop-* tags keep their channels', () => {
  assert.equal(channelOf('ios-prealpha-latest', true), 'pre-alpha');
  assert.equal(channelOf('ios-alpha-0.2.8-501', true), 'alpha');
  assert.equal(channelOf('ios-beta-0.2.9-520', true), 'beta');
  assert.equal(channelOf('ios-v0.3.0-beta.1', true), 'beta');
  assert.equal(channelOf('desktop-v0.3.0', false), 'stable');
  assert.equal(channelOf('v0.1.1', false), null);
});

test('every saved channel selects Beta and never a newer preview', async t => {
  const release = (tag_name, prerelease, name) => ({ tag_name, prerelease, draft: false, assets: [name, 'SHA256SUMS-desktop.txt'].map(name => ({ name, browser_download_url: `https://github.com/example/${tag_name}/${name}` })) });
  t.mock.method(globalThis, 'fetch', async url => new URL(url).hostname !== 'api.github.com' ? new Response('', { status: 503 }) : Response.json([
    release('app-0.4.0', false, 'PokiSetup-0.4.0-100-macos.dmg'),
    release('app-0.4.2-beta.200', true, 'PokiSetup-0.4.2-200-macos.dmg'),
    release('app-0.5.0-alpha.300', true, 'PokiSetup-0.5.0-300-macos.dmg'),
    release('app-0.6.0-prealpha.400', true, 'PokiSetup-0.6.0-400-macos.dmg'),
  ]));
  for (const channel of ['stable', 'beta', 'alpha', 'pre-alpha']) {
    assert.equal((await latestSetup(channel)).name, 'PokiSetup-0.4.2-200-macos.dmg', channel);
  }
});

test('a missing Beta installer does not silently install a preview', async t => {
  t.mock.method(globalThis, 'fetch', async url => new URL(url).hostname !== 'api.github.com' ? new Response('', { status: 503 }) : Response.json([
    { tag_name: 'app-alpha-latest', prerelease: true, assets: [
      { name: 'PokiSetup-0.5.0-300-macos.dmg', browser_download_url: 'https://github.com/example/installer' },
      { name: 'SHA256SUMS-desktop.txt', browser_download_url: 'https://github.com/example/sums' },
    ] },
  ]));
  await assert.rejects(latestSetup('beta'), /No Poki Setup/);
});
