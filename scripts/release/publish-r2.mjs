#!/usr/bin/env node
import { createHash, createPrivateKey, createPublicKey, randomUUID, sign, verify } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';

const { values } = parseArgs({ options: {
  release: { type: 'string' }, assets: { type: 'string' }, output: { type: 'string' },
  config: { type: 'string', default: 'config/release-source.json' },
  previous: { type: 'string' }, publish: { type: 'boolean', default: false },
  'verify-upload': { type: 'boolean', default: false },
  'cleanup-verification': { type: 'boolean', default: false },
} });

function command(program, args) {
  const result = spawnSync(program, args, { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`${program} failed; publication stopped`);
  return result.stdout;
}

async function digest(file) {
  const hash = createHash('sha256');
  let size = 0;
  for await (const chunk of createReadStream(file)) { hash.update(chunk); size += chunk.length; }
  return { sha256: hash.digest('hex'), size };
}

function decode(bytes, key) {
  const envelope = JSON.parse(bytes);
  const payload = Buffer.from(envelope.payload, 'base64');
  if (!verify(null, payload, key, Buffer.from(envelope.signature, 'base64'))) throw new Error('Previous catalog signature is invalid');
  const catalog = JSON.parse(payload);
  if (catalog.schema !== 1 || !Array.isArray(catalog.releases)) throw new Error('Unsupported previous catalog');
  return catalog;
}

async function sourceSettings() {
  const config = JSON.parse(await readFile(values.config, 'utf8'));
  const address = new URL(config.url);
  if (address.protocol !== 'https:' || address.username || address.password || address.search || address.hash || address.pathname !== '/catalog.json') throw new Error('The production catalog must use HTTPS at /catalog.json');
  if (!/^[a-f0-9]{64}$/i.test(config.public_key)) throw new Error('Invalid verification key');
  const key = createPrivateKey(process.env.POKI_RELEASE_SIGNING_KEY ?? '');
  const publicKey = createPublicKey(key);
  if (publicKey.asymmetricKeyType !== 'ed25519' || publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('hex') !== config.public_key.toLowerCase()) throw new Error('Signing key does not match the reviewed public key');
  return { address, key, publicKey };
}

function storageSettings() {
  for (const name of ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'POKI_R2_ENDPOINT', 'POKI_R2_BUCKET']) {
    if (!process.env[name]) throw new Error(`Missing publication credential or setting: ${name}`);
  }
  const endpoint = new URL(process.env.POKI_R2_ENDPOINT);
  if (endpoint.protocol !== 'https:' || !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(endpoint.hostname) || endpoint.pathname !== '/' || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) throw new Error('Invalid R2 S3 endpoint');
  if (!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(process.env.POKI_R2_BUCKET)) throw new Error('Invalid R2 bucket');
  return { bucket: process.env.POKI_R2_BUCKET, aws: ['--endpoint-url', endpoint.href, '--region', 'auto'] };
}

function upload(storage, file, object, options = []) {
  command('aws', [...storage.aws, 's3', 'cp', resolve(file), `s3://${storage.bucket}/${object}`, ...options, '--only-show-errors']);
}

async function readback(address, expected, publicKey) {
  const response = await fetch(address, { redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
  if (!response.ok) throw new Error(`Catalog readback failed (${response.status})`);
  const bytes = await response.text();
  decode(bytes, publicKey);
  if (bytes !== expected) throw new Error('Published catalog readback differs; inspect the retained previous catalog');
}

async function cleanupVerification() {
  const receiptFile = join(values.output, 'verification-object.json');
  let receipt;
  try { receipt = JSON.parse(await readFile(receiptFile, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  if (!/^_verification\/[a-f0-9-]{36}\/catalog\.json$/.test(receipt.object)) throw new Error('Cleanup is restricted to a verification catalog');
  const config = JSON.parse(await readFile(values.config, 'utf8'));
  const address = new URL(receipt.object, new URL(config.url).origin + '/');
  const storage = storageSettings();
  command('aws', [...storage.aws, 's3', 'rm', `s3://${storage.bucket}/${receipt.object}`, '--only-show-errors']);
  const response = await fetch(address, { redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
  if (response.status !== 404) throw new Error(`Verification object still readable after cleanup (${response.status})`);
  await writeFile(join(values.output, 'cleanup.json'), JSON.stringify({ object: receipt.object, deleted: true, publicStatus: response.status }, null, 2));
  console.log('Verification object deleted; public readback returned 404.');
}

async function verifyUpload() {
  const { address, key, publicKey } = await sourceSettings();
  const storage = storageSettings();
  const production = await fetch(address, { redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
  if (!production.ok && production.status !== 404) throw new Error('Cannot snapshot the production catalog');
  const before = await production.text();
  const object = `_verification/${randomUUID()}/catalog.json`;
  const testAddress = new URL(object, address.origin + '/');
  const payload = Buffer.from(JSON.stringify({ schema: 1, releases: [] }));
  const signature = sign(null, payload, key);
  const envelope = JSON.stringify({ payload: payload.toString('base64'), signature: signature.toString('base64') });
  await mkdir(values.output, { recursive: true });
  await writeFile(join(values.output, 'verification-object.json'), JSON.stringify({ object }));
  const file = join(values.output, 'verification-catalog.json');
  const options = ['--content-type', 'application/json', '--cache-control', 'no-store'];
  try {
    await writeFile(file, envelope);
    upload(storage, file, object, options);
    await readback(testAddress, envelope, publicKey);
    console.log(`Signed verification catalog uploaded and verified: ${testAddress.href}`);
    signature[0] ^= 1;
    const corrupt = JSON.stringify({ payload: payload.toString('base64'), signature: signature.toString('base64') });
    const corruptFile = join(values.output, 'invalid-signature-catalog.json');
    await writeFile(corruptFile, corrupt);
    upload(storage, corruptFile, object, options);
    let rejected = false;
    try { await readback(testAddress, corrupt, publicKey); }
    catch (error) { if (error.message !== 'Previous catalog signature is invalid') throw error; rejected = true; }
    if (!rejected) throw new Error('Invalid remote signature was accepted');
    console.log('Invalid signature downloaded from the isolated test object was rejected.');
    const after = await fetch(address, { redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
    if (after.status !== production.status || (production.ok && await after.text() !== before)) throw new Error('Production catalog changed during verification');
    await writeFile(join(values.output, 'verification.json'), JSON.stringify({ url: testAddress.href, signatureVerified: true, invalidSignatureRejected: true, productionStatus: production.status, productionUnchanged: true, installersUploaded: false }, null, 2));
  } finally {
    await cleanupVerification();
  }
}

async function main() {
  if (values['verify-upload'] || values['cleanup-verification']) {
    if (!values.output || values.publish || values.release || values.assets || values.previous || (values['verify-upload'] && values['cleanup-verification'])) throw new Error('Verification cannot be combined with release publication inputs');
    if (values['cleanup-verification']) return cleanupVerification();
    return verifyUpload();
  }
  if (!values.release || !values.assets || !values.output) throw new Error('Required: --release <GitHub release JSON> --assets <directory> --output <directory>');
  const { address, key, publicKey } = await sourceSettings();

  const release = JSON.parse(await readFile(values.release, 'utf8'));
  const tag = release.tag_name;
  if (!/^(app-\d+\.\d+\.\d+-beta\.\d+|ios-beta-\d+\.\d+\.\d+-\d+)$/.test(tag) || release.draft || !release.prerelease) throw new Error('Only published, numbered Beta releases may enter the catalog');
  if (release.html_url !== `https://github.com/JosssphZhou/poki/releases/tag/${tag}`) throw new Error('Release must belong to the Poki repository');
  if (!Array.isArray(release.assets) || !release.assets.length) throw new Error('Release has no assets');
  const names = new Set();
  const assets = [];
  for (const asset of release.assets) {
    const name = asset.name;
    if (typeof name !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || names.has(name)) throw new Error('Invalid or duplicate release asset name');
    names.add(name);
    if (asset.state !== 'uploaded') throw new Error(`GitHub has not finished uploading ${name}`);
    const expectedUrl = `https://github.com/JosssphZhou/poki/releases/download/${tag}/${name}`;
    if (asset.browser_download_url !== expectedUrl) throw new Error(`Unexpected GitHub source for ${name}`);
    const actual = await digest(join(values.assets, name));
    if (actual.size !== asset.size || asset.digest !== `sha256:${actual.sha256}`) throw new Error(`${name} does not match the published GitHub asset`);
    assets.push({ name, ...actual, browser_download_url: `${address.origin}/releases/${tag}/${name}` });
  }
  if (!assets.some(a => /^Poki-external-\d+\.\d+\.\d+-\d+\.ipa$/.test(a.name)) || !names.has('Poki-signing.zip') || !names.has('SHA256SUMS') || !names.has('poki-relay-worker.js')) throw new Error('Beta needs a numeric-build IPA, signing archive, checksums and relay');
  if (assets.some(a => a.name.startsWith('PokiSetup-')) && !names.has('SHA256SUMS-desktop.txt')) throw new Error('Poki Setup needs desktop checksums');

  let previousBytes;
  if (values.publish) {
    if (values.previous) throw new Error('--previous is for offline preparation only');
    storageSettings();
    const response = await fetch(address, { redirect: 'error', signal: AbortSignal.timeout(15000), cache: 'no-store' });
    if (response.ok) previousBytes = await response.text();
    else if (response.status !== 404) throw new Error(`Cannot read current catalog (${response.status})`);
  } else if (values.previous) previousBytes = await readFile(values.previous, 'utf8');
  const previous = previousBytes ? decode(previousBytes, publicKey) : { schema: 1, releases: [] };
  const entry = { tag_name: tag, name: release.name, html_url: release.html_url, published_at: release.published_at, draft: false, prerelease: true, assets };
  const old = previous.releases.find(r => r.tag_name === tag);
  if (old && JSON.stringify(old.assets) !== JSON.stringify(assets)) throw new Error('An existing release is immutable; publish a new build');
  const payload = Buffer.from(JSON.stringify({ schema: 1, releases: [entry, ...previous.releases.filter(r => r.tag_name !== tag)] }));
  const envelope = JSON.stringify({ payload: payload.toString('base64'), signature: sign(null, payload, key).toString('base64') });
  if (Buffer.byteLength(envelope) > 4 * 1024 * 1024) throw new Error('Catalog exceeds the client size limit');
  await mkdir(values.output, { recursive: true });
  if (previousBytes) await writeFile(join(values.output, 'previous-catalog.json'), previousBytes);
  const catalogFile = join(values.output, 'catalog.json');
  await writeFile(catalogFile, envelope);
  await writeFile(join(values.output, 'release.json'), JSON.stringify(entry, null, 2));
  console.log(`Prepared ${tag}: ${assets.length} verified files. Source: ${address.origin}`);
  if (!values.publish) { console.log('Prepared only; nothing uploaded.'); return; }

  const storage = storageSettings();
  for (const asset of assets) {
    const object = `releases/${tag}/${asset.name}`;
    upload(storage, resolve(values.assets, asset.name), object, ['--cache-control', 'public,max-age=31536000,immutable']);
    const response = await fetch(asset.browser_download_url, { redirect: 'error', signal: AbortSignal.timeout(120000) });
    if (!response.ok) throw new Error(`Public R2 file is unavailable: ${asset.name} (${response.status})`);
    const hash = createHash('sha256');
    let size = 0;
    for await (const chunk of response.body) { size += chunk.length; hash.update(chunk); }
    if (size !== asset.size || hash.digest('hex') !== asset.sha256) throw new Error(`Public R2 verification failed: ${asset.name}`);
    console.log(`Verified R2 download: ${asset.browser_download_url} (${size} bytes)`);
  }
  // Keep the previous signed catalog recoverable before changing discovery.
  if (previousBytes) upload(storage, resolve(values.output, 'previous-catalog.json'), `catalog-history/before-${tag}.json`, ['--content-type', 'application/json']);
  upload(storage, resolve(catalogFile), basename(address.pathname), ['--content-type', 'application/json', '--cache-control', 'no-store']);
  await readback(address, envelope, publicKey);
  console.log(`Published and read back signed catalog: ${address.href}`);
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
