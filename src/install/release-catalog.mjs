// Signatures cover the exact decoded catalog bytes.
import { createHash, createPublicKey, verify } from 'node:crypto';
import { readFile } from 'node:fs/promises';

export class ReleaseUnavailable extends Error {}

async function source() {
  const config = JSON.parse(await readFile(new URL('../../config/release-source.json', import.meta.url), 'utf8'));
  const address = process.env.POKI_RELEASE_CATALOG_URL ?? config.url;
  const publicKey = process.env.POKI_RELEASE_PUBLIC_KEY ?? config.public_key;
  if (!address && !publicKey) throw new ReleaseUnavailable('R2 is not configured in this build. Using GitHub.');
  if (!address) throw new Error('The release source has no catalog address');
  if (!/^[a-fA-F0-9]{64}$/.test(publicKey)) throw new Error('Release catalog verification key is not configured; nothing was downloaded');
  return { url: sourceUrl(address), publicKey };
}

function sourceUrl(value) {
  const url = new URL(value);
  if (url.username || url.password || url.hash || url.search || !(
    url.protocol === 'https:' || (url.protocol === 'http:' && ['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname))
  )) throw new Error('Release source must use HTTPS (or loopback HTTP for local exploration)');
  if (/%2e|%2f|%5c/i.test(value) || value.includes('\\') || value.split('/').some(part => part === '.' || part === '..')) {
    throw new Error('Asset is outside the release source: unsafe path');
  }
  return url;
}

async function response(url, timeout = 120000) {
  let res;
  try {
    res = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(timeout), headers: { 'User-Agent': 'poki-install-iphone' } });
  } catch {
    throw new ReleaseUnavailable('R2 is unavailable. Using GitHub for this update.');
  }
  if (res.ok) return res;
  if (res.status >= 500 || [404, 408, 429].includes(res.status)) throw new ReleaseUnavailable('R2 is unavailable. Using GitHub for this update.');
  throw new Error(res.status >= 300 && res.status < 400
    ? `The release source answered with a redirect (${res.status}); redirects are not followed`
    : `Release download answered ${res.status}`);
}

async function bytes(response, limit) {
  const chunks = [];
  let size = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      let part;
      try { part = await reader.read(); }
      catch { throw new ReleaseUnavailable('R2 download was interrupted. Using GitHub.'); }
      if (part.done) break;
      size += part.value.length;
      if (size > limit) throw new Error('Release download exceeds its allowed size');
      chunks.push(Buffer.from(part.value));
    }
    return Buffer.concat(chunks);
  } finally {
    await reader.cancel().catch(() => {});
  }
}

export async function releaseCatalog() {
  const { url, publicKey } = await source();
  const envelope = JSON.parse((await bytes(await response(url, 10000), 4 * 1024 * 1024)).toString('utf8'));
  if (typeof envelope.payload !== 'string' || typeof envelope.signature !== 'string') throw new Error('Invalid signed catalog');
  const payload = Buffer.from(envelope.payload, 'base64');
  const signature = Buffer.from(envelope.signature, 'base64');
  const key = createPublicKey({ key: Buffer.from(`302a300506032b6570032100${publicKey}`, 'hex'), format: 'der', type: 'spki' });
  if (signature.length !== 64 || !verify(null, payload, key, signature)) throw new Error('Release catalog signature is invalid');
  const catalog = JSON.parse(payload.toString('utf8'));
  if (catalog.schema !== 1 || !Array.isArray(catalog.releases)) throw new Error('Unsupported release catalog');
  const tags = new Set();
  const urls = new Map();
  for (const release of catalog.releases) {
    if (typeof release.tag_name !== 'string' || !release.tag_name || /[\\/\x00-\x1f\x7f]/.test(release.tag_name) || ['.', '..'].includes(release.tag_name) || tags.has(release.tag_name) || !Array.isArray(release.assets)) throw new Error('Invalid release entry');
    tags.add(release.tag_name);
    const names = new Set();
    for (const asset of release.assets) {
      if (typeof asset.name !== 'string' || !asset.name || /[\\/\r\n]/.test(asset.name) || ['.', '..'].includes(asset.name) || names.has(asset.name)) throw new Error('Invalid release asset name');
      names.add(asset.name);
      const target = sourceUrl(asset.browser_download_url);
      if (target.origin !== url.origin || target.search || !target.pathname.startsWith('/releases/') ||
        /(?:^|\/)\.\.(?:\/|$)/.test(decodeURIComponent(asset.browser_download_url))) throw new Error('Asset is outside the release source');
      if (!/^[a-fA-F0-9]{64}$/.test(asset.sha256) || !Number.isSafeInteger(asset.size) || asset.size < 0) throw new Error('Asset integrity metadata is missing');
      const identity = `${asset.sha256.toLowerCase()}:${asset.size}`;
      if (urls.has(target.href) && urls.get(target.href) !== identity) throw new Error('Conflicting integrity metadata for one asset URL');
      urls.set(target.href, identity);
    }
  }
  return catalog.releases;
}

export async function downloadCatalogAsset(asset) {
  const body = await bytes(await response(asset.browser_download_url), asset.size);
  if (body.length !== asset.size || createHash('sha256').update(body).digest('hex') !== asset.sha256.toLowerCase()) {
    throw Object.assign(new Error(`Release asset ${asset.name} does not match the signed catalog`), { code: 'setup_checksum_mismatch' });
  }
  return body;
}
