// The GitHub API client shared by the scripts in this directory.
//
// Writes marked `bot` go out as the Poki Repo Bot GitHub App when its token is there. If GitHub
// rejects that token (401: the key or token is no longer valid, 403: the app lacks a permission),
// the same write is sent again with the workflow's own token. Everything else uses the workflow's
// token.
//
// A 404 means "not there" only on a read, which returns null. On a write it is an error like any
// other, so a label or comment that was not created never looks done.

// Adds api.paginate(path): every item of a list endpoint, 100 a page.
export function withPaginate(api) {
  api.paginate = async (path) => {
    const all = [];
    for (let page = 1; ; page++) {
      const items = (await api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`)) || [];
      all.push(...items);
      if (items.length < 100) return all;
    }
  };
  return api;
}

export function createApi({ token, botToken = '', fetch: send = fetch, log = console.log }) {
  const call = (auth, path, method, body) => send(`https://api.github.com${path}`, {
    method,
    headers: { authorization: `Bearer ${auth}`, accept: 'application/vnd.github+json', 'content-type': 'application/json', 'x-github-api-version': '2022-11-28' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return withPaginate(async (path, { method = 'GET', body, bot = false } = {}) => {
    const asBot = Boolean(bot && botToken);
    let res = await call(asBot ? botToken : token, path, method, body);
    if (asBot && (res.status === 401 || res.status === 403)) {
      log(`Poki Repo Bot's token got ${res.status} on ${method} ${path}; using the workflow token`);
      res = await call(token, path, method, body);
    }
    if (res.status === 404 && method === 'GET') return null;
    if (!res.ok) throw Object.assign(new Error(`${method} ${path}: ${res.status} ${await res.text()}`), { status: res.status });
    return res.status === 204 ? null : res.json();
  });
}
