// A signed release source on loopback for tests: one reply per path, and a log of the paths asked for.
import { createHash, generateKeyPairSync, sign } from 'node:crypto';
import { createServer } from 'node:http';

export async function releaseSource(t) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const replies = new Map();
  const asked = [];
  const previous = Object.fromEntries(['POKI_RELEASE_CATALOG_URL', 'POKI_RELEASE_PUBLIC_KEY'].map(name => [name, process.env[name]]));
  t.after(() => {
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  });
  const server = createServer((req, res) => {
    asked.push(req.url);
    const reply = replies.get(req.url);
    if (!reply) res.writeHead(404).end();
    else if (reply.redirect) res.writeHead(302, { Location: reply.redirect }).end();
    else res.writeHead(200, { 'Content-Length': reply.length }).end(reply);
  });
  await new Promise(ok => server.listen(0, '127.0.0.1', ok));
  t.after(() => { server.closeAllConnections(); return new Promise(ok => server.close(ok)); });
  const origin = `http://127.0.0.1:${server.address().port}`;
  const source = {
    origin,
    asked,
    publicKey: publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex'),
    put(path, body) { replies.set(path, Buffer.from(body)); },
    redirect(path, to) { replies.set(path, { redirect: to }); },
    // A catalog asset entry whose size and digest describe `body`; served at `path` unless `url` points elsewhere.
    asset(name, path, body, url = origin + path) {
      source.put(path, body);
      return { name, browser_download_url: url, sha256: createHash('sha256').update(body).digest('hex'), size: Buffer.byteLength(body) };
    },
    release(tag, assets) {
      return { tag_name: tag, prerelease: true, draft: false, published_at: '2026-11-13T10:00:00Z', body: '', assets };
    },
    publish(releases, path = '/catalog.json') {
      const payload = Buffer.from(JSON.stringify({ schema: 1, releases }));
      source.put(path, JSON.stringify({ payload: payload.toString('base64'), signature: sign(null, payload, privateKey).toString('base64') }));
    },
    // Points the installer at this source for the rest of the test.
    use(path = '/catalog.json', key = source.publicKey) {
      process.env.POKI_RELEASE_CATALOG_URL = origin + path;
      process.env.POKI_RELEASE_PUBLIC_KEY = key;
    },
  };
  return source;
}
