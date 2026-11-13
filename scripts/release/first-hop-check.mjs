#!/usr/bin/env node
// What a Poki that is already installed does with a set of GitHub releases, before anything is
// published. Poki 0.3.1 (build 752) and Poki Setup 0.2.2 (build 661) share one release picker and
// cannot be changed any more, so a release has to be laid out for them. This reads a plan (the
// releases as they are today, then one step per publish or withdrawal), and after each step prints, per client
// and channel: the release it picks, whether it can install it, and whether it would pair the
// build with a Poki-signing.zip it cached earlier.
//
//   node scripts/release/first-hop-check.mjs <plan.json> --build <N> [--entitlements <digest>] [--live]
//
// N is the candidate's build number, `git rev-list --count <candidate commit>`. --live reads the
// releases from GitHub (read only, through gh) in place of the plan's saved copy; with
// plans/as-published.json it shows where a release stands after each real publish. Exit 1 when a
// client ends up without the candidate or stuck on an update it cannot install; exit 2 when this
// port no longer matches the old picker. scripts/release/oracle.sh runs the old picker itself.
//
// Line numbers below are in the source at tag app-0.3.1-alpha.752. desktop/ did not change between
// build 661 and that tag, so both clients run this code.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const CHANNELS = ['stable', 'beta', 'alpha', 'pre-alpha'];
const rank = channel => CHANNELS.indexOf(channel);

// desktop/core/src/release.rs:105-118
function channelOfTag(product, tag, prerelease) {
  if (!tag.startsWith(`${product}-`)) return null;
  const rest = tag.slice(product.length + 1);
  if (rest.startsWith('prealpha-')) return 'pre-alpha';
  if (rest.startsWith('alpha-')) return 'alpha';
  if (rest.startsWith('beta-')) return 'beta';
  if (rest.startsWith('v')) return prerelease ? 'beta' : 'stable';
  return null;
}

// release.rs:125-142
function channelOfAppTag(tag, prerelease) {
  if (!tag.startsWith('app-')) return null;
  const rest = tag.slice(4);
  if (rest === 'prealpha-latest') return 'pre-alpha';
  if (rest === 'alpha-latest') return 'alpha';
  if (!/^[0-9]/.test(rest)) return null;
  const dash = rest.indexOf('-');
  if (dash < 0) return prerelease ? 'beta' : 'stable';
  const suffix = rest.slice(dash + 1);
  if (suffix.startsWith('prealpha.')) return 'pre-alpha';
  if (suffix.startsWith('alpha.')) return 'alpha';
  return 'beta';
}

// release.rs:145-147 and 311-313
const channelOfAppRelease = (tag, prerelease) => channelOfTag('ios', tag, prerelease) ?? channelOfAppTag(tag, prerelease);
const channelOfAnyRelease = (tag, prerelease) => channelOfTag('desktop', tag, prerelease) ?? channelOfAppRelease(tag, prerelease);

const trimStart = (text, prefix) => { while (text.startsWith(prefix)) text = text.slice(prefix.length); return text; };
const trimEnd = (text, suffix) => { while (text.endsWith(suffix)) text = text.slice(0, -suffix.length); return text; };
const asU64 = text => (/^\+?[0-9]+$/.test(text) && BigInt(text) < 2n ** 64n ? BigInt(text) : null);

// release.rs:205-230. The version and build come from the IPA's file name, never from the IPA.
function installable(release) {
  const channel = channelOfAppRelease(release.tag_name, release.prerelease);
  if (!channel) return null;
  const ipa = release.assets.find(a => a.name.startsWith('Poki-external-') && a.name.endsWith('.ipa'));
  if (!ipa) return null;
  const stem = trimEnd(trimStart(ipa.name, 'Poki-external-'), '.ipa');
  const cut = stem.lastIndexOf('-');
  const [version, build] = cut > 0
    ? [stem.slice(0, cut), stem.slice(cut + 1)]
    : [['app-', 'ios-v', 'ios-prealpha-', 'ios-alpha-', 'ios-beta-'].reduce(trimStart, release.tag_name), ''];
  return { channel, tag: release.tag_name, version, build, published_at: release.published_at ?? '', ipa_name: ipa.name, hasSigningZip: release.assets.some(a => a.name === 'Poki-signing.zip') };
}

// release.rs:503-512. [numbers before the first '-', 0 pre-release / 1 plain / 2 build, suffix parts]
function versionKey(text) {
  const cut = text.indexOf('-');
  const [core, suffix] = cut < 0 ? [text, ''] : [text.slice(0, cut), text.slice(cut + 1)];
  const numbers = core.split('.').map(part => asU64(part) ?? 0n);
  if (!suffix) return [numbers, 1, []];
  const parts = suffix.split(/[.-]/).map(part => asU64(part) ?? part.toLowerCase());
  return [numbers, parts.every(part => typeof part === 'bigint') ? 2 : 0, parts];
}

// Rust's derived ordering: numbers sort before words (release.rs:491-495), lists compare item by
// item and a prefix is smaller.
function compareIdent(a, b) {
  if (typeof a !== typeof b) return typeof a === 'bigint' ? -1 : 1;
  return a < b ? -1 : a > b ? 1 : 0;
}
function compareLists(a, b, compare) {
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const order = compare(a[i], b[i]);
    if (order) return order;
  }
  return a.length - b.length;
}
function compareVersionKeys(a, b) {
  return compareLists(a[0], b[0], compareIdent) || a[1] - b[1] || compareLists(a[2], b[2], compareIdent);
}

// release.rs:515-517
const full = (version, build) => (build ? `${version}-${build}` : version);

// Iterator::max_by keeps the last of equal items.
function maxBy(items, compare) {
  let best = null;
  for (const item of items) if (best === null || compare(item, best) >= 0) best = item;
  return best;
}

// release.rs:198-200
const visible = releases => releases.filter(r => !r.draft).map((r, i) => [r, i])
  .sort(([a, i], [b, j]) => ((b.published_at ?? '') < (a.published_at ?? '') ? -1 : (b.published_at ?? '') > (a.published_at ?? '') ? 1 : i - j))
  .map(([r]) => r);

// release.rs:235-244
function pickExact(list, channel) {
  const offered = list.map(installable).filter(r => r && rank(r.channel) <= rank(channel));
  return maxBy(offered, (a, b) =>
    compareVersionKeys(versionKey(full(a.version, a.build)), versionKey(full(b.version, b.build)))
    || (a.channel === channel) - (b.channel === channel)
    || (a.published_at < b.published_at ? -1 : a.published_at > b.published_at ? 1 : 0));
}

// release.rs:98 and 248-250
const fallbacks = channel => CHANNELS.filter(c => rank(c) >= rank(channel));
function pick(releases, channel) {
  const list = visible(releases);
  for (const c of fallbacks(channel)) {
    const found = pickExact(list, c);
    if (found) return found;
  }
  return null;
}

// release.rs:306-323. Poki Setup's own update.
function setupVersion(name, suffix) {
  if (!name.startsWith('PokiSetup-') || !name.endsWith(suffix)) return null;
  const version = name.slice('PokiSetup-'.length, name.length - suffix.length);
  return /^[0-9]/.test(version) ? version : null;
}
function pickSetup(releases, channel, suffix = '-macos.dmg') {
  const list = visible(releases);
  for (const want of fallbacks(channel)) {
    const offered = list
      .filter(r => { const c = channelOfAnyRelease(r.tag_name, r.prerelease); return c && rank(c) <= rank(want); })
      .flatMap(r => r.assets.map(a => ({ tag: r.tag_name, name: a.name, version: setupVersion(a.name, suffix) })).filter(a => a.version));
    const found = maxBy(offered, (a, b) => compareVersionKeys(versionKey(a.version), versionKey(b.version)));
    if (found) return found;
  }
  return null;
}

// native/ios-app/Poki/Signing/SelfSigner.swift:264-273. String.compare(_:options: .numeric) on
// dotted versions, then the build as an integer, with anything that is not one counting as 0.
function phoneSeesNewer(offered, installed) {
  const runs = text => text.match(/[0-9]+|[^0-9]+/g) ?? [];
  const order = compareLists(runs(offered.version), runs(installed.version), (a, b) =>
    (/^[0-9]/.test(a) && /^[0-9]/.test(b) ? compareIdent(BigInt(a), BigInt(b)) : compareIdent(a, b)));
  if (order) return order > 0;
  const int = text => (/^[+-]?[0-9]+$/.test(text) ? Number(text) : 0);
  return int(offered.build) > int(installed.build);
}

// The old picker's own tests (release.rs:641-809), so a later edit here cannot drift unnoticed.
function selfCheck() {
  const gh = (tag_name, prerelease, published_at, ...names) => ({ tag_name, prerelease, draft: false, published_at, assets: names.map(name => ({ name })) });
  const failures = [];
  // got is a function, so a pick that finds nothing is reported like any other difference.
  const same = (label, got, want) => {
    let value;
    try { value = typeof got === 'function' ? got() : got; } catch { value = 'nothing'; }
    if (value !== want) failures.push(`${label}: got ${value}, the old picker gives ${want}`);
  };
  const order = ['0.2.9-630', '0.3.0-beta.1', '0.3.0-beta.2', '0.3.0-rc.1', '0.3.0', '0.3.0-700', '0.3.1-beta.1'];
  order.slice(1).forEach((v, i) => same(`${order[i]} < ${v}`, compareVersionKeys(versionKey(order[i]), versionKey(v)) < 0, true));
  same('beta.10 > beta.9', compareVersionKeys(versionKey('0.3.0-beta.10'), versionKey('0.3.0-beta.9')) > 0, true);
  same('0.2.2 > 0.2.1-5', compareVersionKeys(versionKey('0.2.2'), versionKey('0.2.1-5')) > 0, true);
  for (const [tag, pre, want] of [
    ['app-0.2.9-prealpha.640', true, 'pre-alpha'], ['app-prealpha-latest', true, 'pre-alpha'], ['app-0.2.9-alpha.640', true, 'alpha'],
    ['app-alpha-latest', true, 'alpha'], ['app-0.3.0-beta.1', true, 'beta'], ['app-0.3.0', false, 'stable'], ['app-0.3.0', true, 'beta'],
    ['app-latest', false, null], ['desktop-v0.3.0', false, null], ['ios-prealpha-latest', true, 'pre-alpha'], ['ios-alpha-0.2.8-501', true, 'alpha'],
    ['ios-v0.3.0-beta.1', true, 'beta'], ['ios-beta-0.3.0-600', true, 'beta'], ['ios-v0.2.7', false, 'stable'], ['v0.1.1', false, null],
  ]) same(`channel of ${tag}`, channelOfAppRelease(tag, pre), want);
  const rolling = [
    gh('ios-beta-0.2.9-520', true, '2026-11-10T05:00:00Z', 'Poki-external-0.2.9-520.ipa'),
    gh('ios-prealpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.9-540.ipa'),
    gh('ios-alpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.9-530.ipa'),
  ];
  same('rolling pre-alpha', () => pick(rolling, 'pre-alpha').build, '540');
  same('rolling alpha', () => pick(rolling, 'alpha').build, '530');
  same('rolling beta', () => pick(rolling, 'beta').tag, 'ios-beta-0.2.9-520');
  const tie = [
    gh('ios-alpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.8-501.ipa'),
    gh('ios-prealpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.8-501.ipa'),
  ];
  same('tie on pre-alpha', () => pick(tie, 'pre-alpha').tag, 'ios-prealpha-latest');
  same('tie on alpha', () => pick(tie, 'alpha').tag, 'ios-alpha-latest');
  const both = [
    gh('app-0.3.0', false, '2026-11-14T05:00:00Z', 'Poki-external-0.3.0.ipa'),
    gh('app-0.3.0-beta.1', true, '2026-11-12T05:00:00Z', 'Poki-external-0.3.0-beta.1.ipa'),
    gh('app-alpha-latest', true, '2026-11-09T06:00:00Z', 'Poki-external-0.2.9-650.ipa'),
    gh('app-prealpha-latest', true, '2026-11-09T06:00:00Z', 'Poki-external-0.2.9-660.ipa'),
    gh('ios-alpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.9-650.ipa'),
    gh('ios-prealpha-latest', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.9-660.ipa'),
  ];
  same('stable pick', () => { const stable = pick(both, 'stable'); return `${stable.tag} ${stable.version} (${stable.build})`; }, 'app-0.3.0 0.3.0 ()');
  same('beta pick', () => pick(both.slice(1), 'beta').tag, 'app-0.3.0-beta.1');
  same('alpha pick', () => pick(both.slice(2), 'alpha').build, '650');
  same('pre-alpha pick', () => pick(both.slice(2), 'pre-alpha').build, '660');
  same('old scheme alone', () => pick(both.slice(4), 'pre-alpha').tag, 'ios-prealpha-latest');
  const stepping = [
    gh('ios-prealpha-0.2.8-260', true, '2026-11-08T05:00:00Z', 'Poki-external-0.2.8-260.ipa'),
    gh('ios-v0.2.7', true, '2026-11-07T05:00:00Z', 'Poki-external-0.2.7-12.ipa'),
    gh('v0.1.1', false, '2026-11-08T06:00:00Z'),
  ];
  same('stable steps down to beta', () => pick(stepping, 'stable').tag, 'ios-v0.2.7');
  same('stable steps down to pre-alpha', () => pick([stepping[0], stepping[2]], 'stable').tag, 'ios-prealpha-0.2.8-260');
  same('nothing installable', pick([stepping[2]], 'stable'), null);
  const setup = [gh('app-alpha-latest', true, '2026-11-09T06:00:00Z', 'PokiSetup-0.2.2-640-macos.dmg')];
  same('setup on an app release', () => pickSetup(setup, 'alpha').version, '0.2.2-640');
  same('setup steps down', () => pickSetup(setup, 'stable').version, '0.2.2-640');
  if (failures.length) {
    console.error(`This port no longer matches the old picker:\n  ${failures.join('\n  ')}`);
    process.exit(2);
  }
}

// ---- The plan: today's releases, then what each publish step leaves on GitHub. ----

const SUPPORT_FILES = ['Poki-signing.zip', 'SHA256SUMS', 'poki-relay-worker.js'];

function loadPlan(file, { build, entitlements, live }) {
  const text = readFileSync(file, 'utf8').replaceAll('{N+1}', String(build + 1)).replaceAll('{N}', String(build));
  const plan = JSON.parse(text);
  const saved = JSON.parse(readFileSync(resolve(dirname(file), plan.base), 'utf8'));
  const base = live
    ? JSON.parse(execFileSync('gh', ['api', '--paginate', `repos/${plan.repo}/releases?per_page=100`, '--jq', '[.[] | {tag_name, prerelease, draft, published_at, assets: [.assets[] | {name, digest}]}]'], { encoding: 'utf8' }))
    : saved;
  const candidate = { ...plan.candidate, entitlements: entitlements ?? plan.publishedEntitlements };
  // A rolling build is published under its own version and build (publish-rolling.sh), so the
  // name of a file that is already out says what is inside it. A file under another name is the
  // candidate when GitHub reports the same sha256 for it.
  const candidateDigest = base.flatMap(r => r.assets).find(a => a.name === `Poki-external-${candidate.version}-${candidate.build}.ipa`)?.digest;
  const releases = base.map(r => {
    const found = installable(r);
    const digest = found && r.assets.find(a => a.name === found.ipa_name).digest;
    const content = !found ? null : digest && digest === candidateDigest ? candidate : { version: found.version, build: found.build, entitlements: plan.publishedEntitlements };
    return { ...r, content };
  });
  const published = releases.map(r => Number(r.content?.build)).filter(Number.isFinite);
  if (plan.steps.length && published.some(b => b >= build)) {
    console.error(`--build ${build} is not above every published build (${Math.max(...published)}); a candidate is always a newer commit of main. To look at releases that are already out, use plans/as-published.json --live.`);
    process.exit(64);
  }
  // Tags an installed client may hold a Poki-signing.zip for: the ones that were out before this release.
  return { plan, releases, candidate, alreadyThere: new Set(saved.filter(r => r.assets.some(a => a.name === 'Poki-signing.zip')).map(r => r.tag_name)) };
}

function applyStep(releases, step, candidate, clock) {
  // A release taken back to a draft, or deleted: no client is shown it any more (release.rs:198).
  let next = releases.filter(r => !(step.withdraw ?? []).includes(r.tag_name)).map(r => ({ ...r, assets: [...r.assets] }));
  for (const put of step.releases ?? []) {
    const content = put.content === 'candidate' ? candidate : { entitlements: candidate.entitlements, ...put.content };
    const existing = next.find(r => r.tag_name === put.tag);
    if (existing) {
      // publish-rolling.sh: new files in, the previous build's IPA out, the date as it was.
      existing.assets = [...existing.assets.filter(a => !/^Poki-.*\.ipa$/.test(a.name) && !SUPPORT_FILES.includes(a.name)), { name: put.ipa }, ...SUPPORT_FILES.map(name => ({ name }))];
      existing.content = content;
      continue;
    }
    const setup = put.setupFrom ? next.find(r => r.tag_name === put.setupFrom).assets.filter(a => /^PokiSetup-|^SHA256SUMS-desktop\.txt$/.test(a.name)) : [];
    next = [{ tag_name: put.tag, prerelease: put.prerelease ?? true, draft: false, published_at: clock(), assets: [{ name: put.ipa }, ...SUPPORT_FILES.map(name => ({ name })), ...setup], content }, ...next];
  }
  return next;
}

const sameBuild = (a, b) => a && b && a.version === b.version && a.build === b.build;

// One row: what one client on one channel does with these releases.
function outcome(client, channel, releases, { plan, candidate, alreadyThere, last }) {
  const found = pick(releases, channel);
  const required = plan.requiredChannels.includes(channel);
  const row = { client: client.name, channel, tag: '', file: '', inside: '', install: '', cache: '', result: required ? 'FAIL' : 'info', why: '' };
  if (!found) return { ...row, install: 'nothing to install', why: 'no installable release' };
  const inside = releases.find(r => r.tag_name === found.tag).content;
  row.tag = found.tag;
  row.file = found.ipa_name;
  row.inside = `${inside.version} (${inside.build})`;
  const isCandidate = sameBuild(inside, candidate);

  // release.rs:520-549: the cache folder is named after the tag, and a Poki-signing.zip already in
  // it is used as it is.
  const reused = found.hasSigningZip && alreadyThere.has(found.tag);
  const changed = reused && inside.entitlements !== plan.publishedEntitlements;
  row.cache = !found.hasSigningZip ? 'no zip' : !reused ? 'new folder' : changed ? 'earlier zip, DIFFERENT entitlements' : 'earlier zip, same entitlements';

  let installs = true;
  if (client.kind === 'phone') {
    if (!phoneSeesNewer(found, plan.installed)) {
      installs = false;
      row.install = 'shown as up to date';
    } else if (found.version !== inside.version || found.build !== inside.build) {
      // SelfSigner.swift:106-110 and 258-262: the signed copy carries the IPA's own build
      // (signer.rs:309-310), the offer carries the one in the file name, and Install waits for
      // them to be equal.
      installs = false;
      row.install = `STUCK: offered as (${found.build}), signed copy says (${inside.build})`;
    } else row.install = 'installs';
  } else row.install = 'installs on Renew';

  if (!required) return row;
  if (!installs) return { ...row, why: client.kind === 'phone' && row.install.startsWith('STUCK') ? 'the update never becomes ready to install' : 'not offered' };
  if (changed) return { ...row, why: 'new build signed with entitlements cached from an earlier build' };
  if (!isCandidate) return last ? { ...row, why: 'ends on another build' } : { ...row, result: 'wait' };
  return { ...row, result: reused ? 'warn' : 'ok', why: reused ? 'pairs the build with an earlier Poki-signing.zip when one is cached' : '' };
}

function table(rows) {
  const columns = [['client', 'Client'], ['channel', 'Channel'], ['tag', 'Picks'], ['file', 'File'], ['inside', 'Inside'], ['install', 'Install'], ['cache', 'Signing zip'], ['result', 'Result']];
  const line = cells => `| ${cells.join(' | ')} |`;
  return [line(columns.map(([, title]) => title)), line(columns.map(() => '---')), ...rows.map(row => line(columns.map(([key]) => row[key] || '')))].join('\n');
}

function oracleFiles(dir, name, releases) {
  mkdirSync(dir, { recursive: true });
  const input = releases.filter(r => !r.draft).flatMap(r => [`R\t${r.tag_name}\t${r.prerelease ? 1 : 0}\t${r.published_at ?? ''}`, ...r.assets.map(a => `A\t${a.name}`)]);
  const port = CHANNELS.flatMap(channel => {
    const app = pick(releases, channel);
    const setup = pickSetup(releases, channel);
    return [
      app ? `app\t${channel}\t${app.tag}\t${app.ipa_name}\t${app.version}\t${app.build}` : `app\t${channel}\tnone`,
      setup ? `setup\t${channel}\t${setup.tag}\t${setup.name}\t${setup.version}` : `setup\t${channel}\tnone`,
    ];
  });
  writeFileSync(join(dir, `${name}.in`), `${input.join('\n')}\n`);
  writeFileSync(join(dir, `${name}.port`), `${port.join('\n')}\n`);
}

function main() {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { build: { type: 'string' }, entitlements: { type: 'string' }, live: { type: 'boolean', default: false }, 'oracle-dir': { type: 'string' } } });
  const build = Number(values.build);
  if (positionals.length !== 1 || !Number.isInteger(build)) {
    console.error('usage: first-hop-check.mjs <plan.json> --build <candidate build number> [--entitlements <digest>] [--live] [--oracle-dir <dir>]');
    process.exit(64);
  }
  selfCheck();
  const loaded = loadPlan(positionals[0], { build, entitlements: values.entitlements, live: values.live });
  const { plan, candidate } = loaded;
  const clients = [{ name: `Poki ${plan.installed.version} (${plan.installed.build}) on the iPhone`, kind: 'phone' }, { name: `Poki Setup ${plan.installed.setup} on the computer`, kind: 'setup' }];
  let tick = 0;
  const start = Date.parse(plan.firstPublishAt);
  const clock = () => new Date(start + 60000 * tick++).toISOString().replace('.000Z', 'Z');

  console.log(`# ${plan.title}\n`);
  console.log(`Candidate: Poki ${candidate.version} (${candidate.build}). Releases today: ${values.live ? 'read from GitHub now' : `saved copy ${plan.base}`}. Every later step is planned, not published.`);
  console.log(`Entitlements in the candidate's Poki-signing.zip: ${candidate.entitlements === plan.publishedEntitlements ? 'assumed the same as' : 'DIFFERENT from'} builds 752, 1130 and 1174 (${plan.publishedEntitlements.slice(0, 12)}).\n`);

  let releases = loaded.releases;
  let failed = false;
  let warned = false;
  const steps = [{ name: 'Today', releases: [] }, ...plan.steps];
  steps.forEach((step, index) => {
    releases = applyStep(releases, step, candidate, clock);
    const last = index === steps.length - 1;
    const rows = clients.flatMap(client => CHANNELS.map(channel => outcome(client, channel, releases, { ...loaded, last })));
    if (values['oracle-dir']) oracleFiles(values['oracle-dir'], `step-${index}`, releases);
    console.log(`## ${index}. ${step.name}\n`);
    console.log(table(rows));
    const setup = pickSetup(releases, 'pre-alpha');
    const newer = setup && compareVersionKeys(versionKey(setup.version), versionKey(plan.installed.setup)) > 0;
    console.log(`\nPoki Setup's own update: ${newer ? `offers ${setup.name} from ${setup.tag}` : `none offered on any channel (newest installer is ${setup?.version ?? 'missing'})`}.`);
    const problems = rows.filter(row => row.result === 'FAIL' || row.result === 'warn');
    for (const row of problems) console.log(`- ${row.result === 'FAIL' ? 'FAIL' : 'warn'}: ${row.client}, ${row.channel}: ${row.why}.`);
    console.log('');
    failed ||= rows.some(row => row.result === 'FAIL');
    warned = last && rows.some(row => row.result === 'warn');
  });
  console.log(failed
    ? 'RESULT: FAIL. At least one required channel does not end on the candidate, or is offered an update it cannot install.'
    : `RESULT: PASS. Stable, Beta and Alpha end on the candidate on both clients${warned ? ', but some pick a release whose Poki-signing.zip an old client may have cached.' : ', each from a release no old client has cached.'}`);
  process.exit(failed ? 1 : 0);
}

main();
