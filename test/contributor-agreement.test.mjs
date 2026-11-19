import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { agreementVersion, agrees, parseMarker, run } from '../.github/scripts/contributor-agreement.mjs';
import { createApi, withPaginate } from '../.github/scripts/github-api.mjs';
import * as published from '../.github/scripts/contributor-agreement.mjs';

// What contributors and the branch rules see. These are written out here, not imported, so that
// renaming one in the script fails a test.
const PHRASE = 'I agree to the Poki Contributor Agreement';
const STATUS = 'Contributor agreement';
const BRANCH = 'contributor-signatures';
const FILE = 'signatures.json';

const repo = 'o/r';
const alice = { login: 'alice', id: 7, type: 'User' };
const bob = { login: 'bob', id: 9, type: 'User' };
const pull = (number, user = alice, sha = `sha${number}`) => ({ number, state: 'open', user, head: { sha } });
const T0 = '2026-11-18T04:00:00Z';
const later = '2026-11-18T05:00:00Z';

// A small stand-in for the GitHub API: open pull requests, one signatures branch, and comments and
// statuses per pull request. List endpoints honor per_page and page.
function fakeGitHub({ pulls = [], signatures = null, saveConflict = null } = {}) {
  const gh = { pulls, file: signatures && JSON.stringify({ signatures }), branch: signatures !== null, comments: {}, statuses: {}, descriptions: {}, writes: [], nextId: 1, saveConflict };
  const page = (items, path) => {
    const q = new URL(path, 'https://x').searchParams;
    const [size, n] = [Number(q.get('per_page') || 30), Number(q.get('page') || 1)];
    return items.slice((n - 1) * size, n * size);
  };
  gh.comment = (number, user, body, created_at = later) => {
    (gh.comments[number] ||= []).push({ id: gh.nextId++, user, body, created_at, html_url: `https://github.com/o/r/pull/${number}#issuecomment-${gh.nextId}` });
  };
  gh.botComment = (number) => (gh.comments[number] || []).filter((c) => c.user.type === 'Bot');
  gh.signatures = () => JSON.parse(gh.file).signatures;
  gh.api = withPaginate(async (path, { method = 'GET', body, bot = false } = {}) => {
    if (method !== 'GET') gh.writes.push(`${method} ${path}`);
    let m;
    if (path.startsWith(`/repos/${repo}/contents/${FILE}`)) {
      if (method === 'GET') { assert.ok(path.endsWith(`?ref=${BRANCH}`)); return gh.file === null ? null : { sha: `v${gh.file.length}`, content: Buffer.from(gh.file).toString('base64') }; }
      assert.equal(body.branch, BRANCH);
      if (gh.saveConflict) {
        // Someone else's agreement lands between this run's read and its save.
        gh.file = JSON.stringify({ signatures: [...gh.signatures(), gh.saveConflict] });
        gh.saveConflict = null;
        throw Object.assign(new Error('conflict'), { status: 409 });
      }
      assert.equal(body.sha, `v${gh.file.length}`);
      gh.file = Buffer.from(body.content, 'base64').toString('utf8');
      return {};
    }
    if (path === `/repos/${repo}/git/ref/heads/${BRANCH}`) return gh.branch ? {} : null;
    if (path === `/repos/${repo}/git/trees`) { assert.equal(body.tree[0].path, FILE); gh.pendingFile = body.tree[0].content; return { sha: 'tree' }; }
    if (path === `/repos/${repo}/git/commits`) { assert.deepEqual(body.parents, []); return { sha: 'commit' }; }
    if (path === `/repos/${repo}/git/refs`) { assert.equal(body.ref, `refs/heads/${BRANCH}`); gh.branch = true; gh.file = gh.pendingFile; return {}; }
    if ((m = path.match(/\/statuses\/(.+)$/))) {
      assert.equal(body.context, STATUS);
      assert.equal(bot, false);
      assert.ok(body.description.length <= 140);
      gh.statuses[m[1]] = body.state;
      gh.descriptions[m[1]] = body.description;
      return {};
    }
    if ((m = path.match(/\/issues\/(\d+)\/comments/))) {
      if (method === 'GET') return page(gh.comments[m[1]] || [], path);
      assert.equal(bot, true);
      gh.comment(m[1], { type: 'Bot', id: 1 }, body.body);
      return {};
    }
    if ((m = path.match(/\/issues\/comments\/(\d+)$/))) {
      assert.equal(method, 'PATCH');
      Object.values(gh.comments).flat().find((c) => c.id === Number(m[1])).body = body.body;
      return {};
    }
    if ((m = path.match(/\/pulls\/(\d+)$/))) return gh.pulls.find((p) => p.number === Number(m[1])) || null;
    if (path.startsWith(`/repos/${repo}/pulls?state=open`)) return page(gh.pulls.filter((p) => p.state === 'open'), path);
    throw new Error(`unexpected ${method} ${path}`);
  });
  return gh;
}

const at = (iso) => () => new Date(iso);
const go = (gh, eventName, event, version = 1, now = at(T0)) => run({ eventName, event, repo, api: gh.api, version, now });
const opened = (gh, pr, ...rest) => go(gh, 'pull_request_target', { pull_request: { number: pr.number } }, ...rest);
const commented = (gh, pr, ...rest) => go(gh, 'issue_comment', { issue: { number: pr.number, pull_request: {} } }, ...rest);
const sweep = (gh, ...rest) => go(gh, 'push', {}, ...rest);

test('the published names have not changed', () => {
  assert.equal(published.PHRASE, PHRASE);
  assert.equal(published.STATUS_CONTEXT, STATUS);
  assert.equal(published.SIGNATURES_BRANCH, BRANCH);
  assert.equal(published.SIGNATURES_FILE, FILE);
  const agreement = readFileSync('CONTRIBUTOR_AGREEMENT.md', 'utf8');
  assert.ok(agreement.includes(`\`\`\`\n${PHRASE}\n\`\`\``));
  assert.ok(agreement.includes(`\`${BRANCH}\``) && agreement.includes(`\`${FILE}\``));
  assert.equal(agreementVersion(agreement), 1);
  assert.throws(() => agreementVersion('# No version here'));
});

test('only a comment that is the phrase and nothing else agrees', () => {
  assert.ok(agrees(PHRASE));
  assert.ok(agrees(`  ${PHRASE.toLowerCase()}.\n`));
  assert.ok(agrees(`**${PHRASE}**`));
  assert.ok(agrees(`\`\`\`\n${PHRASE}\n\`\`\``));
  assert.ok(!agrees(`> ${PHRASE}`));
  assert.ok(!agrees(`Do I have to post this?\n\n\`\`\`\n${PHRASE}\n\`\`\``));
  assert.ok(!agrees(`Read it.\n\n${PHRASE}`));
  assert.ok(!agrees(`I do not think ${PHRASE} applies`));
  assert.ok(!agrees(''));
});

test('a new contributor is asked once and the status waits', async () => {
  const pr = pull(1);
  const gh = fakeGitHub({ pulls: [pr] });
  await opened(gh, pr);
  assert.equal(gh.statuses.sha1, 'pending');
  assert.equal(gh.descriptions.sha1, '#1 alice: has not agreed to v1');
  const [ask] = gh.botComment(1);
  assert.deepEqual(parseMarker(ask.body), { version: 1, kind: 'ask', at: '2026-11-18T04:00:00.000Z' });
  assert.ok(ask.body.includes('@alice') && ask.body.includes(PHRASE));
  await opened(gh, pr, 1, at(later));
  assert.equal(gh.botComment(1).length, 1);
  assert.equal(gh.botComment(1)[0].body, ask.body);
});

test('agreeing starts the signatures branch and turns every open pull request of theirs green', async () => {
  const [first, second, other] = [pull(1), pull(2), pull(3, bob)];
  const gh = fakeGitHub({ pulls: [first, second, other] });
  await opened(gh, first);
  await opened(gh, second);
  await opened(gh, other);
  gh.comment(1, alice, PHRASE);
  await commented(gh, first);
  assert.deepEqual(gh.signatures(), [{ login: 'alice', id: 7, agreement_version: 1, signed_at: later, pull_request: 1, comment: gh.comments[1][1].html_url }]);
  assert.deepEqual(gh.statuses, { sha1: 'success', sha2: 'success', sha3: 'pending' });
  assert.equal(gh.descriptions.sha2, '#2 alice: agreed to v1');
  assert.equal(parseMarker(gh.botComment(1)[0].body).kind, 'signed');
  assert.equal(parseMarker(gh.botComment(2)[0].body).kind, 'signed');
  assert.equal(parseMarker(gh.botComment(3)[0].body).kind, 'ask');
});

test('a later pull request from someone who agreed passes without a comment', async () => {
  const pr = pull(5);
  const gh = fakeGitHub({ pulls: [pr], signatures: [{ login: 'alice-old-name', id: 7, agreement_version: 1 }] });
  await opened(gh, pr);
  assert.equal(gh.statuses.sha5, 'success');
  assert.equal(gh.comments[5], undefined);
  assert.deepEqual(gh.writes, [`POST /repos/${repo}/statuses/sha5`]);
});

test('an agreement comment whose own run never happened is picked up by the next run', async () => {
  const pr = pull(1);
  const gh = fakeGitHub({ pulls: [pr] });
  await opened(gh, pr);
  gh.comment(1, alice, PHRASE);
  // No issue_comment run: the next push to the pull request finds the comment in the history.
  await opened(gh, pr);
  assert.equal(gh.statuses.sha1, 'success');
  assert.deepEqual(gh.signatures().map((s) => s.login), ['alice']);
});

test('nobody can agree for the author', async () => {
  const pr = pull(1);
  const gh = fakeGitHub({ pulls: [pr] });
  await opened(gh, pr);
  gh.comment(1, { login: 'mallory', id: 66, type: 'User' }, PHRASE);
  await commented(gh, pr);
  assert.equal(gh.file, null);
  assert.equal(gh.statuses.sha1, 'pending');
});

test('two pull requests at one commit are green only when both authors have agreed', async () => {
  const [hers, his] = [pull(1, alice, 'shared'), pull(2, bob, 'shared')];
  const gh = fakeGitHub({ pulls: [hers, his], signatures: [{ login: 'alice', id: 7, agreement_version: 1 }] });
  await opened(gh, hers);
  assert.equal(gh.statuses.shared, 'pending');
  assert.equal(gh.descriptions.shared, '#1 alice: agreed to v1; #2 bob: has not agreed to v1');
  assert.equal(gh.botComment(2).length, 1);
  gh.comment(2, bob, PHRASE);
  await commented(gh, his);
  assert.equal(gh.statuses.shared, 'success');
  assert.equal(gh.descriptions.shared, '#1 alice: agreed to v1; #2 bob: agreed to v1');
});

test('the decision follows the pull request as it is now, not as the event saw it', async () => {
  const pr = pull(1, alice, 'new-head');
  const gh = fakeGitHub({ pulls: [pr] });
  await go(gh, 'pull_request_target', { pull_request: { number: 1, user: { login: 'JosssphZhou', id: 1, type: 'User' }, head: { sha: 'old-head' } } });
  assert.deepEqual(gh.statuses, { 'new-head': 'pending' });
});

test('a new agreement version turns open pull requests back to waiting and asks again', async () => {
  const [hers, his] = [pull(1), pull(2, bob)];
  const gh = fakeGitHub({ pulls: [hers, his] });
  await opened(gh, hers);
  await opened(gh, his);
  gh.comment(1, alice, PHRASE);
  await commented(gh, hers);
  assert.equal(gh.statuses.sha1, 'success');

  // The push to main that raises the version decides every open pull request again.
  const bumped = '2026-12-01T00:00:00Z';
  await sweep(gh, 2, at(bumped));
  assert.deepEqual(gh.statuses, { sha1: 'pending', sha2: 'pending' });
  assert.deepEqual(parseMarker(gh.botComment(1)[0].body), { version: 2, kind: 'ask', at: '2026-12-01T00:00:00.000Z' });
  assert.equal(parseMarker(gh.botComment(2)[0].body).version, 2);

  // The comment that agreed to version 1 does not count for version 2. A new one does.
  await commented(gh, hers, 2);
  assert.equal(gh.statuses.sha1, 'pending');
  gh.comment(1, alice, PHRASE, '2026-12-02T00:00:00Z');
  await commented(gh, hers, 2);
  assert.equal(gh.statuses.sha1, 'success');
  assert.deepEqual(gh.signatures().map((s) => [s.login, s.agreement_version]), [['alice', 1], ['alice', 2]]);
});

test('maintainers and bots are not asked', async () => {
  for (const user of [{ login: 'JosssphZhou', id: 1, type: 'User' }, { login: 'poki-repo-bot[bot]', id: 2, type: 'Bot' }]) {
    const pr = pull(1, user);
    const gh = fakeGitHub({ pulls: [pr] });
    await opened(gh, pr);
    assert.equal(gh.statuses.sha1, 'success');
    assert.equal(gh.comments[1], undefined);
  }
});

test('closed pull requests and comments on issues are left alone', async () => {
  const pr = { ...pull(1), state: 'closed' };
  const gh = fakeGitHub({ pulls: [pr] });
  assert.match(await opened(gh, pr), /^skip/);
  assert.match(await go(gh, 'issue_comment', { issue: { number: 1 } }), /^skip/);
  assert.deepEqual(gh.writes, []);
});

test('a save refused with 409 reads the file again and keeps the other signer', async () => {
  const pr = pull(1);
  const gh = fakeGitHub({ pulls: [pr], signatures: [], saveConflict: { login: 'bob', id: 9, agreement_version: 1 } });
  gh.comment(1, alice, PHRASE);
  await commented(gh, pr);
  assert.deepEqual(gh.signatures().map((s) => s.login), ['bob', 'alice']);
  assert.equal(gh.statuses.sha1, 'success');
});

test('more than a page of open pull requests and of comments are all read', async () => {
  const pulls = [pull(1)];
  for (let n = 2; n <= 130; n++) pulls.push(pull(n, { login: `user${n}`, id: 1000 + n, type: 'User' }));
  pulls.push(pull(131));
  const gh = fakeGitHub({ pulls });
  await opened(gh, pulls[0]);
  const ask = gh.botComment(1)[0];
  // The bot's comment and the agreement both end up past the first page of comments.
  gh.comments[1] = [];
  for (let i = 0; i < 120; i++) gh.comment(1, bob, `note ${i}`);
  gh.comments[1].push(ask);
  gh.comment(1, alice, PHRASE);
  await commented(gh, pulls[0]);
  assert.equal(gh.botComment(1).length, 1);
  assert.equal(gh.statuses.sha1, 'success');
  assert.equal(gh.statuses.sha131, 'success');
});

// The shared client, against a stand-in for fetch.
function fakeFetch(answers) {
  const calls = [];
  const send = async (url, init) => {
    const token = init.headers.authorization.replace('Bearer ', '');
    calls.push(`${token} ${init.method} ${url.replace('https://api.github.com', '')}`);
    const status = answers(token, init.method, url);
    return { status, ok: status >= 200 && status < 300, json: async () => ({ token }), text: async () => 'body' };
  };
  return { send, calls };
}

for (const refused of [401, 403]) {
  test(`a write the bot's token is refused with ${refused} is sent again with the workflow token`, async () => {
    const { send, calls } = fakeFetch((token) => (token === 'bot' ? refused : 201));
    const api = createApi({ token: 'actions', botToken: 'bot', fetch: send, log: () => {} });
    assert.deepEqual(await api('/x', { method: 'POST', bot: true, body: {} }), { token: 'actions' });
    assert.deepEqual(calls, ['bot POST /x', 'actions POST /x']);
  });
}

test('without a bot token, and for reads and status writes, the workflow token is used', async () => {
  const { send, calls } = fakeFetch(() => 200);
  await createApi({ token: 'actions', botToken: '', fetch: send })('/x', { method: 'POST', bot: true });
  await createApi({ token: 'actions', botToken: 'bot', fetch: send })('/y');
  await createApi({ token: 'actions', botToken: 'bot', fetch: send })('/z', { method: 'POST' });
  assert.deepEqual(calls, ['actions POST /x', 'actions GET /y', 'actions POST /z']);
});

test('a 404 is "not there" on a read and an error on a write', async () => {
  const { send } = fakeFetch(() => 404);
  const api = createApi({ token: 'actions', botToken: 'bot', fetch: send });
  assert.equal(await api('/missing'), null);
  for (const method of ['POST', 'PATCH', 'PUT', 'DELETE']) {
    await assert.rejects(api('/missing', { method, bot: true }), (e) => e.status === 404);
  }
});

test('other failures are errors and are not retried', async () => {
  const { send, calls } = fakeFetch(() => 500);
  await assert.rejects(createApi({ token: 'actions', botToken: 'bot', fetch: send })('/x', { method: 'POST', bot: true }), (e) => e.status === 500);
  assert.equal(calls.length, 1);
});
