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

test('a channel without its own Poki Setup takes the next less stable channel, as release.rs does', async t => {
  const release = (tag_name, ...names) => ({ tag_name, prerelease: true, draft: false, assets: names.map(name => ({ name, browser_download_url: `https://github.com/x/${tag_name}/${name}`, url: `https://api.github.com/x/${tag_name}/${name}` })) });
  t.mock.method(globalThis, 'fetch', async () => Response.json([
    release('ios-beta-0.4.0-1226', 'Poki-external-0.4.0-1226.ipa', 'SHA256SUMS'),
    release('app-prealpha-latest', 'PokiSetup-0.2.3-700-macos.dmg', 'SHA256SUMS-desktop.txt'),
    release('app-alpha-latest', 'PokiSetup-0.2.2-661-macos.dmg', 'SHA256SUMS-desktop.txt'),
  ]));
  for (const channel of ['stable', 'beta', 'alpha']) {
    const setup = await latestSetup(channel);
    assert.deepEqual([setup.tag, setup.name], ['app-alpha-latest', 'PokiSetup-0.2.2-661-macos.dmg'], channel);
  }
  assert.equal((await latestSetup('pre-alpha')).name, 'PokiSetup-0.2.3-700-macos.dmg');
});
