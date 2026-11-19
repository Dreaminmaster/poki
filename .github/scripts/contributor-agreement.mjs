// One-time contributor sign-off. Runs from .github/workflows/contributor-agreement.yml.
//
// A pull request's author agrees to CONTRIBUTOR_AGREEMENT.md once, by commenting PHRASE on a pull
// request. The agreement is saved to signatures.json on the SIGNATURES_BRANCH branch and covers
// every later pull request, until the agreement's version number goes up.
//
// Every run decides again from current data: it reads the pull request and its author fresh, the
// saved agreements, and the pull request's comments. So an agreement comment whose own run was
// dropped is picked up by the next run.
//
// The result is the commit status STATUS_CONTEXT on the pull request's head commit. A status
// belongs to a commit, and two pull requests can point at the same commit, so it is green only
// when the author of every open pull request at that commit has agreed to the current version.
//
// This script reads only event data and the API. It never checks out or runs pull request code.
import { readFileSync } from 'node:fs';
import { createApi } from './github-api.mjs';

export const PHRASE = 'I agree to the Poki Contributor Agreement';
export const STATUS_CONTEXT = 'Contributor agreement';
export const SIGNATURES_BRANCH = 'contributor-signatures';
export const SIGNATURES_FILE = 'signatures.json';
export const AGREEMENT_FILE = 'CONTRIBUTOR_AGREEMENT.md';
// Maintainers, who are not asked. Bots are never asked.
const EXEMPT = new Set(['josssphzhou', 'zhehanzhang']);

// The "Version N" line of the agreement is the only place the version lives.
export function agreementVersion(text) {
  const m = String(text).match(/^Version (\d+)\s*$/m);
  if (!m) throw new Error(`${AGREEMENT_FILE} has no "Version N" line`);
  return Number(m[1]);
}

// True only when the whole comment is the phrase. A comment that quotes it, or shows it as an
// example next to other text, does not count.
export function agrees(body) {
  const text = String(body || '').trim().replace(/^[*_`]+|[*_`]+$/g, '').trim().replace(/[.!。]$/, '').replace(/\s+/g, ' ');
  return text.toLowerCase() === PHRASE.toLowerCase();
}

export const exempt = (user) => !user || user.type === 'Bot' || EXEMPT.has(String(user.login).toLowerCase());

export const hasSigned = (store, user, version) => store.signatures.some((s) => s.id === user.id && s.agreement_version === version);

// The bot's comment starts with a hidden line saying which agreement version it is about, whether
// it asks or thanks, and when it was written.
const MARKER = /^<!-- poki-contributor-agreement v(\d+) (ask|signed) (\S+) -->/;
const marker = (version, kind, at) => `<!-- poki-contributor-agreement v${version} ${kind} ${at} -->`;
export function parseMarker(body) {
  const m = String(body || '').match(MARKER);
  return m ? { version: Number(m[1]), kind: m[2], at: m[3] } : null;
}

const links = (repo) => ({
  agreement: `https://github.com/${repo}/blob/main/${AGREEMENT_FILE}`,
  record: `https://github.com/${repo}/blob/${SIGNATURES_BRANCH}/${SIGNATURES_FILE}`,
});

export function askBody(repo, login, version, at) {
  const { agreement } = links(repo);
  return `${marker(version, 'ask', at)}
Thanks for the pull request, @${login}. Before it can be merged, please agree once to the [Poki Contributor Agreement](${agreement}) (version ${version}). It says you have the right to submit your contributions and that you release them under AGPL-3.0-only. It covers this pull request and all your later ones, so you will not be asked again unless the agreement changes.

To agree, post a new comment on this pull request from your own account with this line and nothing else:

\`\`\`
${PHRASE}
\`\`\`

**If an AI agent opened this for you**, the agreement is still yours to give. Read it, then post the comment yourself or tell your agent to.

感谢你的贡献。合并前请先同意一次 [Poki 贡献者协议](${agreement})（第 ${version} 版）：你确认有权提交这些贡献，并以 AGPL-3.0-only 许可发布。只需同意一次，协议更新前不会再询问。请用你自己的账号在本 pull request 下新发一条评论，内容只写上面那一行英文原文。`;
}

export function thanksBody(repo, login, version, at) {
  const { agreement, record } = links(repo);
  return `${marker(version, 'signed', at)}
Thanks, @${login}. Your agreement to the [Poki Contributor Agreement](${agreement}) (version ${version}) is [on record](${record}) and covers your later pull requests too. 已记录你的同意，之后的 pull request 不会再询问。`;
}

// The store lives on its own branch, so saving an agreement never touches main.
export async function loadStore(api, repo) {
  const file = await api(`/repos/${repo}/contents/${SIGNATURES_FILE}?ref=${SIGNATURES_BRANCH}`);
  if (!file) return { sha: null, store: { agreement: AGREEMENT_FILE, signatures: [] } };
  return { sha: file.sha, store: JSON.parse(Buffer.from(file.content, 'base64').toString('utf8')) };
}

async function saveStore(api, repo, store, sha, message) {
  const text = JSON.stringify(store, null, 2) + '\n';
  if (sha || await api(`/repos/${repo}/git/ref/heads/${SIGNATURES_BRANCH}`)) {
    return api(`/repos/${repo}/contents/${SIGNATURES_FILE}`, { method: 'PUT', bot: true, body: { message, branch: SIGNATURES_BRANCH, content: Buffer.from(text).toString('base64'), ...(sha ? { sha } : {}) } });
  }
  // First agreement: start the branch with a commit that has no parent, so it holds only this file.
  const tree = await api(`/repos/${repo}/git/trees`, { method: 'POST', bot: true, body: { tree: [{ path: SIGNATURES_FILE, mode: '100644', type: 'blob', content: text }] } });
  const commit = await api(`/repos/${repo}/git/commits`, { method: 'POST', bot: true, body: { message, tree: tree.sha, parents: [] } });
  return api(`/repos/${repo}/git/refs`, { method: 'POST', bot: true, body: { ref: `refs/heads/${SIGNATURES_BRANCH}`, sha: commit.sha } });
}

// Adds one agreement. When someone else's agreement was saved in between, the save is refused
// (409, or 422 when the branch was just created); the file is read again and the entry added to
// that newer copy.
export async function record(api, repo, entry) {
  for (let attempt = 0; ; attempt++) {
    const { sha, store } = await loadStore(api, repo);
    if (store.signatures.some((s) => s.id === entry.id && s.agreement_version === entry.agreement_version)) return store;
    store.signatures.push(entry);
    try {
      await saveStore(api, repo, store, sha, `Record contributor agreement: ${entry.login}`);
      return store;
    } catch (e) {
      if (attempt >= 4 || ![409, 422].includes(e.status)) throw e;
    }
  }
}

export async function run({ eventName, event, repo, api, version, now = () => new Date() }) {
  const pullsPath = `/repos/${repo}/pulls`;
  let open = await api.paginate(`${pullsPath}?state=open`);
  let targets;
  if (eventName === 'pull_request_target' || eventName === 'issue_comment') {
    if (eventName === 'issue_comment' && !event.issue?.pull_request) return 'skip: not a pull request';
    // The event can be minutes old. Read the pull request again for its current author and head.
    const pr = await api(`${pullsPath}/${(event.pull_request || event.issue).number}`);
    if (!pr || pr.state !== 'open') return 'skip: pull request is not open';
    open = [...open.filter((p) => p.number !== pr.number), pr];
    targets = [pr];
  } else {
    // A push that changes the agreement, or a manual run: every open pull request is decided again.
    targets = open;
  }

  let { store } = await loadStore(api, repo);
  const verdicts = new Map();   // pull request number -> 'exempt' | 'signed' | 'waiting'
  const newSigners = new Set();

  // Decides one pull request and keeps the bot's comment on it in step.
  const decide = async (pr) => {
    if (verdicts.has(pr.number)) return verdicts.get(pr.number);
    const set = (verdict) => { verdicts.set(pr.number, verdict); return verdict; };
    const author = pr.user;
    if (exempt(author)) return set('exempt');
    const commentsPath = `/repos/${repo}/issues/${pr.number}/comments`;
    const comments = await api.paginate(commentsPath);
    const mine = comments.find((c) => c.user?.type === 'Bot' && parseMarker(c.body));
    const said = mine && parseMarker(mine.body);
    const write = async (body) => {
      if (mine) await api(`/repos/${repo}/issues/comments/${mine.id}`, { method: 'PATCH', bot: true, body: { body } });
      else await api(commentsPath, { method: 'POST', bot: true, body: { body } });
    };
    let signed = hasSigned(store, author, version);
    let fresh = false;
    if (!signed) {
      // An agreement counts when it is the author's own comment and, where the bot has already
      // asked, when it came after the bot asked for this version. A comment that agreed to an
      // older version never counts for a newer one.
      const agreement = comments.find((c) => c.user?.id === author.id && agrees(c.body)
        && (!said || (said.version === version && Date.parse(c.created_at) >= Date.parse(said.at))));
      if (agreement) {
        store = await record(api, repo, {
          login: author.login, id: author.id, agreement_version: version,
          signed_at: agreement.created_at, pull_request: pr.number, comment: agreement.html_url,
        });
        newSigners.add(author.id);
        signed = fresh = true;
      }
    }
    if (signed) {
      // A pull request that was never asked stays quiet.
      const current = said && said.kind === 'signed' && said.version === version;
      if ((mine || fresh) && !current) await write(thanksBody(repo, author.login, version, now().toISOString()));
      return set('signed');
    }
    if (!(said && said.kind === 'ask' && said.version === version)) await write(askBody(repo, author.login, version, now().toISOString()));
    return set('waiting');
  };

  for (const pr of targets) await decide(pr);
  // Someone who just agreed has their other open pull requests decided again too.
  if (newSigners.size) targets = [...targets, ...open.filter((p) => newSigners.has(p.user?.id) && !verdicts.has(p.number))];

  const done = [];
  for (const sha of new Set(targets.map((p) => p.head.sha))) {
    const sharing = open.filter((p) => p.head.sha === sha).sort((a, b) => a.number - b.number);
    const lines = [];
    let waiting = false;
    for (const pr of sharing) {
      const verdict = await decide(pr);
      waiting ||= verdict === 'waiting';
      lines.push(`#${pr.number} ${pr.user?.login}: ${{ exempt: 'not needed', signed: `agreed to v${version}`, waiting: `has not agreed to v${version}` }[verdict]}`);
    }
    const state = waiting ? 'pending' : 'success';
    await api(`/repos/${repo}/statuses/${sha}`, { method: 'POST', body: { state, context: STATUS_CONTEXT, description: lines.join('; ').slice(0, 140), target_url: links(repo).agreement } });
    done.push(`${sha.slice(0, 7)} ${state} (${lines.join('; ')})`);
  }
  return done.join('\n') || 'nothing to decide';
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const env = process.env;
  run({
    eventName: env.GITHUB_EVENT_NAME,
    event: JSON.parse(readFileSync(env.GITHUB_EVENT_PATH, 'utf8')),
    repo: env.GITHUB_REPOSITORY,
    api: createApi({ token: env.GITHUB_TOKEN, botToken: env.BOT_TOKEN }),
    version: agreementVersion(readFileSync(AGREEMENT_FILE, 'utf8')),
  }).then((result) => console.log(result)).catch((e) => { console.error(e); process.exit(1); });
}
