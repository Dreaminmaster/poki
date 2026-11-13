#!/usr/bin/env node
// What a new user's one-click install (skills/install-poki, bin/install-iphone.mjs) downloads after
// each step of a release plan, before anything is published. Read only: nothing is uploaded and no
// device or account is touched.
//
//   node scripts/install-path-check.mjs [--plan <plan.json>] --build <N> [--live]
//
// The plan is one of scripts/release/plans/*.json (default with-compat-releases.json). Its Beta
// (app-X.Y.Z-beta.K) is made a full release, as when it is marked Latest on GitHub. Per step this
// prints, for every channel the installer accepts:
//   - the Poki Setup DMG, from this checkout's own latestSetup() in src/install/setup-app.mjs, run
//     against the planned release list;
//   - the release and IPA Poki Setup's helper installs, from scripts/release/first-hop-check.mjs,
//     the port of desktop/core/src/release.rs (unchanged between Poki Setup 661 and main);
//   - the files the installer's own fallback (downloadIpa) fetches when the helper cannot download;
//   - which release GitHub's releases/latest then names, and what Poki MCP's update notice offers.
// Then it resolves every github.com/JosssphZhou/poki/releases link in the install entry points and
// docs against the last step, and runs the real installer against a GitHub that answers 403.
// Exit 1 when the default channel installs a Pre-alpha or nothing, a channel finds no Poki Setup,
// or a link points at a release that lacks what it promises.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = 'JosssphZhou/poki';
const CHANNELS = ['stable', 'beta', 'alpha', 'pre-alpha'];
const DEFAULT_CHANNEL = 'alpha';
const isBeta = tag => /^app-\d+\.\d+\.\d+-beta\.\d+$/.test(tag);
const isMcp = tag => /^v\d+\.\d+\.\d+$/.test(tag);

const { values } = parseArgs({ options: { plan: { type: 'string' }, build: { type: 'string' }, live: { type: 'boolean', default: false } } });
const build = Number(values.build);
if (!Number.isInteger(build)) {
  console.error('usage: install-path-check.mjs [--plan <plan.json>] --build <candidate build number> [--live]');
  process.exit(64);
}
const planFile = resolve(values.plan ?? join(root, 'scripts/release/plans/with-compat-releases.json'));
const work = mkdtempSync(join(tmpdir(), 'poki-install-path-'));
process.on('exit', () => rmSync(work, { recursive: true, force: true }));

// The same plan with its base made absolute and the Beta published as a full release.
const plan = JSON.parse(readFileSync(planFile, 'utf8'));
plan.base = resolve(dirname(planFile), plan.base);
for (const step of plan.steps) for (const put of step.releases ?? []) if (isBeta(put.tag)) put.prerelease = false;
writeFileSync(join(work, 'plan.json'), JSON.stringify(plan));

const picker = spawnSync(process.execPath, [join(root, 'scripts/release/first-hop-check.mjs'), join(work, 'plan.json'), '--build', String(build), ...(values.live ? ['--live'] : []), '--oracle-dir', join(work, 'states')], { encoding: 'utf8' });
if (picker.status === 2 || picker.status === 64 || picker.error) {
  console.error(picker.stderr || picker.error?.message);
  process.exit(2);
}
const stepNames = ['Today', ...plan.steps.map(s => s.name)];

function readState(name) {
  const releases = [];
  for (const line of readFileSync(join(work, 'states', `${name}.in`), 'utf8').trim().split('\n')) {
    const [kind, ...cells] = line.split('\t');
    if (kind === 'R') releases.push({ tag_name: cells[0], prerelease: cells[1] === '1', draft: false, published_at: cells[2], assets: [] });
    else releases.at(-1).assets.push(cells[0]);
  }
  const picks = {};
  for (const line of readFileSync(join(work, 'states', `${name}.port`), 'utf8').trim().split('\n')) {
    const [kind, channel, tag, file, version, buildNo] = line.split('\t');
    if (kind === 'app') picks[channel] = tag === 'none' ? null : { tag, file, version, build: buildNo };
  }
  return { releases, picks };
}

// A GitHub that serves this release list. Asset bytes are stand-ins whose SHA256SUMS match.
const fake = name => `stand-in for ${name}`;
const sha = text => createHash('sha256').update(text).digest('hex');
function latestOf(releases) {
  return releases.filter(r => !r.draft && !r.prerelease).sort((a, b) => (b.published_at > a.published_at ? 1 : b.published_at < a.published_at ? -1 : 0))[0] ?? null;
}
function serve(releases, requests) {
  const api = r => ({
    tag_name: r.tag_name, draft: r.draft, prerelease: r.prerelease, published_at: r.published_at, body: '',
    assets: r.assets.map(name => ({ name, browser_download_url: `https://github.com/${REPO}/releases/download/${r.tag_name}/${name}`, url: `https://api.github.com/repos/${REPO}/releases/assets/${r.tag_name}/${name}` })),
  });
  return async url => {
    url = String(url);
    requests.push(url);
    const json = value => new Response(JSON.stringify(value), { status: 200, headers: { 'content-type': 'application/json' } });
    if (url.startsWith(`https://api.github.com/repos/${REPO}/releases?`)) return json(releases.map(api));
    if (url === `https://api.github.com/repos/${REPO}/releases/latest`) { const l = latestOf(releases); return l ? json(api(l)) : new Response('{"message":"Not Found"}', { status: 404 }); }
    if (url === `https://api.github.com/repos/${REPO}/git/matching-refs/tags/v`) return json(releases.filter(r => r.tag_name.startsWith('v')).map(r => ({ ref: `refs/tags/${r.tag_name}` })));
    const byTag = url.match(/\/releases\/tags\/(.+)$/);
    if (byTag) { const r = releases.find(x => x.tag_name === decodeURIComponent(byTag[1])); return r ? json(api(r)) : new Response('{"message":"Not Found"}', { status: 404 }); }
    const file = url.match(/\/releases\/(?:download|assets)\/([^/]+)\/([^/]+)$/);
    if (file) {
      const [, tag, name] = file;
      const r = releases.find(x => x.tag_name === tag);
      if (!r?.assets.includes(name)) return new Response('', { status: 404 });
      if (name === 'SHA256SUMS' || name === 'SHA256SUMS-desktop.txt') return new Response(r.assets.filter(a => !a.startsWith('SHA256SUMS')).map(a => `${sha(fake(a))}  ${a}`).join('\n') + '\n');
      return new Response(fake(name));
    }
    return new Response('', { status: 404 });
  };
}

process.env.POKI_MCP_STATE_DIR = join(work, 'mcp-state');
mkdirSync(process.env.POKI_MCP_STATE_DIR, { recursive: true });
const { latestSetup, downloadIpa } = await import('../src/install/setup-app.mjs');
const { version: mcpVersion } = await import('../src/build-info.mjs');

let failed = false;
const fail = text => { failed = true; return `FAIL: ${text}`; };
const short = url => url.replace(`https://api.github.com/repos/${REPO}`, 'api').replace(`https://github.com/${REPO}`, 'github.com');

console.log(`# One-click install of a new user, step by step\n`);
console.log(`Plan: ${planFile.replace(`${root}/`, '')}, candidate build ${build}, releases today ${values.live ? 'read from GitHub now' : `from ${plan.base.replace(`${root}/`, '')}`}. The Beta is published as a full release and so becomes GitHub's Latest. Every later step is planned, not published.\n`);
console.log(`Installer default channel: ${DEFAULT_CHANNEL} (bin/install-iphone.mjs). Poki Setup's helper picks the IPA (release.rs port); this checkout's latestSetup() picks Poki Setup.\n`);

let last;
const states = readdirSync(join(work, 'states')).filter(f => f.endsWith('.in')).map(f => f.slice(0, -3)).sort((a, b) => Number(a.split('-')[1]) - Number(b.split('-')[1]));
for (const [index, name] of states.entries()) {
  const { releases, picks } = readState(name);
  last = { releases, picks };
  const isLast = index === states.length - 1;
  console.log(`## ${index}. ${stepNames[index]}\n`);
  console.log('| Channel | Poki Setup the installer downloads | Release the helper installs | IPA | Poki | Result |');
  console.log('| --- | --- | --- | --- | --- | --- |');
  for (const channel of CHANNELS) {
    const requests = [];
    globalThis.fetch = serve(releases, requests);
    let setup;
    try {
      const s = await latestSetup(channel);
      setup = `${s.name} from ${s.tag}`;
    } catch (error) {
      setup = channel === 'pre-alpha' ? `none: ${error.message}` : fail(`${error.message}`);
    }
    const app = picks[channel];
    let result = 'ok';
    if (!app) result = channel === 'pre-alpha' ? 'nothing to install' : fail('nothing to install');
    else if (channel === DEFAULT_CHANNEL && /prealpha/.test(app.tag)) result = fail('the default channel installs a Pre-alpha');
    else if (!/^\d+$/.test(app.build)) result = `installs; the file name carries ${app.build}, not the build number`;
    if (setup.startsWith('FAIL') && result === 'ok') result = 'FAIL';
    const mark = channel === DEFAULT_CHANNEL ? ' (default)' : '';
    console.log(`| ${channel}${mark} | ${setup} | ${app?.tag ?? ''} | ${app?.file ?? ''} | ${app ? `${app.version} (${app.build})` : ''} | ${result} |`);
  }

  const chosen = picks[DEFAULT_CHANNEL];
  if (chosen) {
    const requests = [];
    globalThis.fetch = serve(releases, requests);
    const downloads = join(work, `downloads-${index}`);
    try {
      const ipa = await downloadIpa(chosen.tag, downloads, chosen.file);
      console.log(`\nFallback when the helper cannot download (default channel): ${requests.map(short).join(', ')}; checks ${ipa.split('/').pop()} against that release's SHA256SUMS.`);
    } catch (error) {
      console.log(`\nFallback when the helper cannot download (default channel): ${fail(error.message)}`);
    }
  }

  const latest = latestOf(releases);
  rmSync(join(process.env.POKI_MCP_STATE_DIR, 'update-check.json'), { force: true });
  globalThis.fetch = serve(releases, []);
  const { updateNotice } = await import(`../src/update-check.mjs?step=${index}`);
  const notice = await updateNotice();
  console.log(`GitHub Latest: ${latest ? `${latest.tag_name} (${latest.assets.join(', ') || 'no files'})` : 'none'}. Poki MCP ${mcpVersion}'s update notice: ${notice ? `offers ${notice.version}` : `none (newest Poki MCP release ${releases.filter(r => isMcp(r.tag_name)).map(r => r.tag_name).sort().at(-1) ?? 'missing'})`}.\n`);
  if (isLast) {
    const app = picks[DEFAULT_CHANNEL];
    console.log(`Answer: a new user on the default channel gets ${app ? `${app.file} from ${app.tag}, Poki ${app.version} (${app.build})` : 'nothing'}${app && /prealpha/.test(app.tag) ? ', a Pre-alpha' : ', not a Pre-alpha'}.\n`);
  }
}

// Every releases link in the install entry points and docs, against the last step.
console.log('## Release links after the last step\n');
console.log('| Where | Link | Points at | Result |');
console.log('| --- | --- | --- | --- |');
const grep = execFileSync('git', ['grep', '-n', '-o', '-E', `(api\\.)?github\\.com/(repos/)?${REPO}/releases[^ )"'<>\`*,\\\\$]*`, '--', 'skills', 'bin', 'src', 'README*.md', 'AGENTS.md', 'docs', 'agent', 'desktop', 'native'], { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(Boolean);
const { releases: finalReleases } = last;
const latestFinal = latestOf(finalReleases);
const kinds = r => [
  r.assets.some(a => /^poki-v.+-macos-arm64\.tar\.gz$/.test(a)) && 'Poki MCP archive',
  r.assets.some(a => /^PokiSetup-.+-macos\.dmg$/.test(a)) && 'Poki Setup',
  r.assets.some(a => /^Poki-external-.+\.ipa$/.test(a)) && 'Poki IPA',
].filter(Boolean).join(', ') || 'no files';
for (const line of grep) {
  const [file, lineNo, ...rest] = line.split(':');
  const link = rest.join(':').replace(/[.]$/, '');
  if (/\/releases\/tag\/v\d|bluebubbles/i.test(link) || file.startsWith('desktop/core/src/release.rs')) continue;
  let target = '', result = 'ok';
  const tag = link.match(/\/releases\/(?:tag|download)\/([^/]+)/)?.[1];
  if (/\/releases\/latest$/.test(link)) {
    target = latestFinal ? `${latestFinal.tag_name}: ${kinds(latestFinal)}` : 'nothing';
    if (!latestFinal || !isMcp(latestFinal.tag_name)) result = link.startsWith('api.') ? 'note: Latest is an app release' : fail('Latest is not a Poki MCP release');
  } else if (tag) {
    const r = finalReleases.find(x => x.tag_name === tag);
    target = r ? `${tag}: ${kinds(r)}` : `${tag}: missing`;
    if (!r) result = fail('no such release');
  } else target = 'the release list';
  console.log(`| ${file}:${lineNo} | ${link} | ${target} | ${result} |`);
}

// The real installer against a GitHub that refuses anonymous requests (its hourly limit).
console.log('\n## GitHub answers 403\n');
const stub = join(work, 'rate-limited.mjs');
writeFileSync(stub, `const real = globalThis.fetch;
globalThis.fetch = async (url, options) => String(url).startsWith('https://api.github.com/')
  ? new Response(JSON.stringify({ message: 'API rate limit exceeded for 192.0.2.1.' }), { status: 403, headers: { 'x-ratelimit-limit': '60', 'x-ratelimit-remaining': '0' } })
  : real(url, options);
`);
mkdirSync(join(work, 'home'));
const limited = spawnSync(process.execPath, ['--import', stub, join(root, 'bin/install-iphone.mjs'), 'run', '--dry-run', '--json', '--state', join(work, 'rate-state')], { encoding: 'utf8', env: { ...process.env, HOME: join(work, 'home') } });
const events = limited.stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
const error = events.find(e => e.event === 'error');
const step = events.filter(e => e.event === 'step').at(-1)?.step;
console.log(`Stops at step ${step} with exit code ${limited.status}. Error ${error?.code}: ${error?.reason}`);
console.log(`agent_fix: ${error?.agent_fix}\n`);

console.log(failed ? 'RESULT: FAIL' : 'RESULT: PASS');
process.exit(failed ? 1 : 0);
