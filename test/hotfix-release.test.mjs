import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sha = '1234567890abcdef1234567890abcdef12345678';
const tag = 'app-0.4.7-prealpha.9969';
const gh = [
  '#!/usr/bin/env node',
  'const { appendFileSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } = require("node:fs");',
  'const { execFileSync } = require("node:child_process");',
  'const a = process.argv.slice(2);',
  'const { RELEASE_STATE } = process.env;',
  'const records = JSON.parse(process.env.RUN_RECORDS || "[]");',
  'appendFileSync(process.env.CALLS, "gh " + a.join(" ") + "\\n");',
  'const endpoint = a.find(arg => arg.startsWith("repos/")) ?? "";',
  'if (a[0] === "api" && endpoint.includes("/actions/workflows/prealpha.yml/runs?")) {',
  '  console.log(JSON.stringify({ workflow_runs: records.slice(0, 2) }));',
  '  console.log(JSON.stringify({ workflow_runs: records.slice(2) }));',
  '} else if (a[0] === "api" && endpoint.endsWith("/actions/workflows/prealpha.yml")) console.log(123);',
  'else if (a[0] === "api" && endpoint.includes("/actions/runs/")) console.log(JSON.stringify(records.find(run => run.id === Number(endpoint.split("/").pop()))));',
  'else if (a[0] === "api" && endpoint.includes("/git/ref/heads/")) {',
  '  const ref = "refs/heads/" + endpoint.split("/git/ref/heads/")[1].split("/").map(decodeURIComponent).join("/");',
  '  const sha = execFileSync("git", ["-C", process.env.HOTFIX_REPO, "rev-parse", "--verify", ref], { encoding: "utf8" }).trim();',
  '  console.log(JSON.stringify({ ref, object: { type: "commit", sha } }));',
  '}',
  'else if (a[0] === "api" && endpoint.includes("/commits/")) console.log(process.env.SOURCE_SHA);',
  'else if (a[0] === "api" && a[1].includes("/releases/tags/")) console.log(process.env.SIGNING_DIGEST);',
  'else if (a[0] === "api") process.exit(1);',
  'else if (a[0] === "release" && a[1] === "view") {',
  '  if (a.includes(".assets | length")) console.log(4);',
  '  else if (a.includes(".assets[].name")) console.log("Poki-external-0.4.7-1926.ipa");',
  '  else if (RELEASE_STATE && existsSync(RELEASE_STATE) && a.includes("isDraft")) console.log(JSON.parse(readFileSync(RELEASE_STATE)).draft);',
  '  else if (a[2] === process.env.HOTFIX_TAG && a.includes("isDraft")) console.log(false);',
  '  else process.exit(1);',
  '} else if (a[0] === "release" && RELEASE_STATE && ["create", "upload", "edit"].includes(a[1])) {',
  '  if (a[1] === "edit" && process.env.FAIL_DRAFT_PUBLISH) process.exit(1);',
  '  const state = a[1] === "create" ? { draft: true } : JSON.parse(readFileSync(RELEASE_STATE));',
  '  if (a.includes("--notes-file")) state.notes = readFileSync(a[a.indexOf("--notes-file") + 1], "utf8");',
  '  if (a[1] === "create" || a[1] === "upload") state.ipa = readFileSync(a.find(arg => arg.endsWith(".ipa")), "utf8");',
  '  if (a.includes("--draft=false")) state.draft = false;',
  '  writeFileSync(RELEASE_STATE, JSON.stringify(state));',
  '} else if (a[0] === "run" && a[1] === "list") {',
  '  if (a.includes("prealpha.yml")) console.log(a[a.indexOf("--event") + 1] === "push" && a[a.indexOf("--branch") + 1] === "main" ? "700" : "800");',
  '} else if (a[0] === "run" && a[1] === "download") {',
  '  const dir = a[a.indexOf("--dir") + 1];',
  '  mkdirSync(dir, { recursive: true });',
  '  if (a.includes("Poki-hotfix-source")) {',
  '    const record = records.find(run => run.id === Number(a[2]));',
  '    if (!record?.provenance) process.exit(1);',
  '    writeFileSync(dir + "/poki-hotfix-source.json", JSON.stringify(record.provenance));',
  '  } else {',
  '    copyFileSync(process.env.FIXTURE_IPA, dir + "/Poki-external-unsigned.ipa");',
  '    if (process.env.FIXTURE_SIGNING) copyFileSync(process.env.FIXTURE_SIGNING, dir + "/Poki-signing.zip");',
  '  }',
  '} else if (a[0] === "release" && a[1] === "download" && a[2] === process.env.HOTFIX_TAG) {',
  '  const dir = a[a.indexOf("--dir") + 1];',
  '  for (const name of ["Poki-external-0.4.7-9969.ipa", "Poki-signing.zip", "SHA256SUMS"]) copyFileSync(process.env.HOTFIX_FILES + "/" + name, dir + "/" + name);',
  '} else if (!(a[0] === "release" && ["create", "edit"].includes(a[1]))) process.exit(1);',
].join('\n');
const git = [
  '#!/usr/bin/env bash',
  'echo "git $*" >> "$CALLS"',
  'case "$1" in',
  '  rev-parse) echo "$SOURCE_SHA" ;;',
  '  config|ls-remote|tag|push|log) ;;',
  '  *) exit 1 ;;',
  'esac',
].join('\n');

function mock(t, { realGit = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'poki-hotfix-release-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'bin'));
  for (const [name, contents] of Object.entries(realGit ? { gh } : { gh, git })) {
    const path = join(dir, 'bin', name);
    writeFileSync(path, contents);
    chmodSync(path, 0o755);
  }
  const calls = join(dir, 'calls');
  const outputs = join(dir, 'outputs');
  writeFileSync(calls, '');
  return {
    dir, outputs, calls: () => readFileSync(calls, 'utf8').split('\n'),
    run(command, options = {}) {
      return spawnSync('bash', ['-e', '-c', command], {
        cwd: options.cwd ?? dir, encoding: 'utf8',
        env: {
          ...process.env, GITHUB_REPOSITORY: 'example/poki', GITHUB_RUN_ID: '861', GH_REPO: 'example/poki',
          GITHUB_OUTPUT: outputs, GITHUB_STEP_SUMMARY: join(dir, 'summary'),
          CALLS: calls, SOURCE_SHA: sha, PATH: join(dir, 'bin') + ':' + process.env.PATH,
          WANT: '', HOTFIX: 'false', RUN_ID: '861', VERSION: '0.4.7', BUILD: '9969', ...options.env,
        },
      });
    },
  };
}

function workflow(name) {
  return readFileSync(join(root, '.github/workflows', name + '.yml'), 'utf8');
}

function commands(step) {
  const run = step.match(/^        run: (.+)$/m);
  assert.ok(run, 'workflow step has a shell command');
  return run[1] === '|' ? step.slice(run.index + run[0].length).trimEnd() : run[1];
}

function makeIpa(path, version, build) {
  execFileSync('python3', ['-c', [
    'import plistlib, sys, zipfile',
    'with zipfile.ZipFile(sys.argv[1], "w") as archive:',
    '    info = {"CFBundleShortVersionString": sys.argv[2], "CFBundleVersion": sys.argv[3]}',
    '    archive.writestr("Payload/Poki.app/Info.plist", plistlib.dumps(info))',
  ].join('\n'), path, version, build]);
}

function hotfixPublisher(dir) {
  mkdirSync(join(dir, 'app'));
  mkdirSync(join(dir, 'source/deploy/cf-relay'), { recursive: true });
  symlinkSync(root, join(dir, 'pipeline'), 'dir');
  writeFileSync(join(dir, 'source/deploy/cf-relay/worker.js'), '// fixture\n');
  writeFileSync(join(dir, 'app/Poki-external-unsigned.ipa'), 'fixture ipa');
  writeFileSync(join(dir, 'app/Poki-signing.zip'), 'fixture signing archive');
  const publishJob = workflow('prealpha').split('\n  publish-hotfix:\n')[1];
  return commands(publishJob.slice(publishJob.lastIndexOf('\n      - name: Publish')));
}

function jobSteps(source, id) {
  const job = source.split(`\n  ${id}:\n`)[1]?.split(/\n  \S/, 1)[0];
  assert.ok(job, `Missing workflow job ${id}`);
  return job.split('\n      - ').slice(1);
}

function checkoutInput(step, key) {
  return step.match(new RegExp(`^          ${key}: (.+)$`, 'm'))?.[1].replace(/^(['"])(.*)\1$/, '$2');
}

test('the hotfix build checks out the resolved commit with full history', async t => {
  const { dir, run, outputs } = mock(t, { realGit: true });
  const source = join(dir, 'source');
  const build = join(dir, 'build');
  mkdirSync(source);
  mkdirSync(build);
  const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, ...args], { encoding: 'utf8' }).trim();
  const commit = message => git(source, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
    '-c', 'commit.gpgSign=false', 'commit', '--allow-empty', '-qm', message);
  git(source, 'init', '-q', '-b', 'main');
  commit('common ancestor');
  const sourceRef = 'hotfix/candidate';
  git(source, 'branch', sourceRef);
  commit('main change');
  const main = git(source, 'rev-parse', 'HEAD');
  git(source, 'switch', '-q', sourceRef);
  commit('candidate');
  const pinned = git(source, 'rev-parse', 'HEAD');

  const prealpha = workflow('prealpha');
  const [resolveSource] = jobSteps(prealpha, 'resolve-hotfix');
  const resolution = run(commands(resolveSource), { env: { SOURCE_REF: sourceRef, HOTFIX_REPO: source } });
  assert.equal(resolution.status, 0, resolution.stdout + resolution.stderr);
  const resolved = Object.fromEntries(readFileSync(outputs, 'utf8').trim().split('\n').map(line => line.split('=')));
  commit('branch moves after resolution');

  const steps = jobSteps(prealpha, 'build-hotfix');
  const checkout = steps.find(step => /^(?: {8})?uses: actions\/checkout@/m.test(step));
  assert.ok(checkout, 'The build job checks out its source');
  const refInput = checkoutInput(checkout, 'ref');
  const expression = refInput?.match(/^\$\{\{\s*(.*?)\s*\}\}$/)?.[1];
  const context = {
    'needs.resolve-hotfix.outputs.sha': resolved.sha,
    'github.sha': main,
    'github.ref': 'refs/heads/main',
    'inputs.ref': sourceRef,
  };
  const ref = expression ? context[expression] : (refInput ?? main);
  assert.ok(ref, `Cannot resolve checkout ref ${refInput}`);
  const depth = checkoutInput(checkout, 'fetch-depth') ?? '1';

  // Replay the checkout inputs against a real Git repository without a hosted runner.
  git(build, 'init', '-q');
  git(build, 'fetch', '--quiet', '--no-tags', ...(depth === '0' ? [] : [`--depth=${depth}`]), source, ref);
  git(build, 'switch', '-q', '--detach', 'FETCH_HEAD');
  assert.equal(git(build, 'rev-parse', 'HEAD'), pinned, 'The build uses the commit selected before the branch moved');

  const count = steps.find(step => /^(?: {8})?id: number$/m.test(step));
  assert.ok(count, 'The build job supplies its build number');
  writeFileSync(outputs, '');
  const result = run(commands(count), { cwd: build });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(readFileSync(outputs, 'utf8').trim(), 'build=2');

  await t.test('rejects depth 2 even when the visible count matches', () => {
    const shallow = join(dir, 'shallow');
    mkdirSync(shallow);
    git(shallow, 'init', '-q');
    git(shallow, 'fetch', '--quiet', '--no-tags', '--depth=2', source, pinned);
    git(shallow, 'switch', '-q', '--detach', 'FETCH_HEAD');
    assert.equal(git(shallow, 'rev-parse', 'HEAD'), pinned);
    assert.equal(git(shallow, 'rev-parse', '--is-shallow-repository'), 'true');
    assert.equal(git(shallow, 'rev-list', '--count', 'HEAD'), '2');

    writeFileSync(outputs, '');
    const rejected = run(commands(count), { cwd: shallow });
    assert.equal(rejected.status, 1, rejected.stdout + rejected.stderr);
    assert.match(rejected.stdout, /requires full Git history/);
    assert.equal(readFileSync(outputs, 'utf8'), '');
  });
});

test('a hotfix publishes only its versioned pre-alpha and leaves both rolling releases alone', t => {
  const { dir, run, calls } = mock(t);
  const result = run(hotfixPublisher(dir), { cwd: join(dir, 'source') });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const released = calls().filter(line => /^gh release create /.test(line)).map(line => line.split(' ')[3]);
  assert.deepEqual(released, [tag]);
  assert.ok(calls().some(line => line === 'git push origin refs/tags/' + tag));
  assert.ok(calls().every(line => !/app-prealpha-latest|ios-prealpha-latest/.test(line)));
});

test('a hotfix retry publishes its own run in the notes and Alpha selects the newest successful matching run', t => {
  const { dir, run, outputs } = mock(t);
  const publish = hotfixPublisher(dir);
  const stateFile = join(dir, 'release.json');
  const sourceDir = join(dir, 'source');
  const failed = run(publish, { cwd: sourceDir, env: { RELEASE_STATE: stateFile, FAIL_DRAFT_PUBLISH: '1' } });
  assert.notEqual(failed.status, 0, failed.stdout + failed.stderr);
  assert.equal(JSON.parse(readFileSync(stateFile)).draft, true);
  const retryIpa = 'IPA from the successful retry';
  writeFileSync(join(dir, 'app/Poki-external-unsigned.ipa'), retryIpa);
  const retry = run(publish, { cwd: sourceDir, env: { RELEASE_STATE: stateFile, GITHUB_RUN_ID: '862' } });
  assert.equal(retry.status, 0, retry.stdout + retry.stderr);
  const release = JSON.parse(readFileSync(stateFile));
  assert.equal(release.draft, false);
  assert.equal(release.ipa, retryIpa);

  const ipaHash = createHash('sha256').update(retryIpa).digest('hex');
  const provenance = { sha, version: '0.4.7', build: '9969', ipa_sha256: ipaHash };
  const workflowRun = (id, conclusion, record = provenance, title = 'Hotfix Pre-alpha 0.4.7') => ({
    id, conclusion, run_number: id, head_branch: 'main', event: 'workflow_dispatch',
    workflow_id: 123, display_title: title, provenance: record,
  });
  const records = [
    workflowRun(860, 'success', { ...provenance, ipa_sha256: 'a'.repeat(64) }, 'Hotfix Pre-alpha 0.4.7 (9969)'),
    workflowRun(861, 'failure'),
    workflowRun(864, 'success', { ...provenance, sha: 'f'.repeat(40) }),
    workflowRun(862, 'success'),
    workflowRun(863, 'failure'),
    workflowRun(865, 'success', { ...provenance, build: '9970' }),
    workflowRun(866, 'success', { ...provenance, version: '0.4.6' }),
    workflowRun(867, 'success', null),
  ];
  const notedRun = release.notes.match(/actions\/runs\/(\d+)/)[1];
  assert.equal(notedRun, '862');
  for (const name of ['promote-alpha', 'promote-alpha-fast']) {
    const step = workflow(name).split('\n      - id: r\n')[1].split(/\n  (?:# The alpha tests|publish:)/)[0];
    for (const candidate of [
      { records, id: 862, hash: ipaHash },
      { records: records.slice(0, 1), id: 860, hash: 'a'.repeat(64) },
    ]) {
      writeFileSync(outputs, '');
      const selected = run(commands(step), {
        env: { WANT: tag, HOTFIX: 'true', RUN_RECORDS: JSON.stringify(candidate.records) },
      });
      assert.equal(selected.status, 0, selected.stdout + selected.stderr);
      const result = Object.fromEntries(readFileSync(outputs, 'utf8').trim().split('\n').map(line => line.split('=')));
      assert.equal(result.run, String(candidate.id), name);
      assert.equal(result.ipa_sha256, candidate.hash, name);
    }
  }
});

test('ordinary Alpha defaults to the main push artifact when a hotfix dispatch has the same workflow head', t => {
  const { run, outputs } = mock(t);
  for (const name of ['promote-alpha', 'promote-alpha-fast']) {
    writeFileSync(outputs, '');
    const step = workflow(name).split('\n      - id: r\n')[1].split(/\n  (?:# The alpha tests|publish:)/)[0];
    const result = run(commands(step));
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.match(readFileSync(outputs, 'utf8'), /^run=700$/m);
  }
});

test('Alpha rejects a version or build mismatch even when the IPA matches the recorded checksum', t => {
  const { dir, run } = mock(t);
  symlinkSync(root, join(dir, 'pipeline'), 'dir');
  const step = workflow('promote-alpha').split("\n      - name: The pre-alpha's IPA\n")[1].split('\n      - name:')[0];
  for (const [version, build, expected] of [['0.4.7', '9969', 0], ['0.4.6', '9969', 1], ['0.4.7', '1930', 1]]) {
    const ipa = join(dir, 'fixture.ipa');
    makeIpa(ipa, version, build);
    const result = run(commands(step), { env: {
      FIXTURE_IPA: ipa, IPA_SHA: createHash('sha256').update(readFileSync(ipa)).digest('hex'),
    } });
    assert.equal(result.status, expected, result.stdout + result.stderr);
    if (expected) assert.match(result.stdout + result.stderr, /CFBundleShortVersionString|CFBundleVersion/);
  }
});

test('Beta uses the published hotfix package even if a main push built the same commit', t => {
  const { dir, run, calls } = mock(t);
  const ipaName = 'Poki-external-0.4.7-9969.ipa';
  const hotfix = join(dir, 'hotfix');
  const signing = join(hotfix, 'Poki-signing.zip');
  const mainIpa = join(dir, 'main.ipa');
  mkdirSync(hotfix);
  mkdirSync(join(dir, 'deploy/cf-relay'), { recursive: true });
  symlinkSync(root, join(dir, 'pipeline'), 'dir');
  writeFileSync(join(dir, 'deploy/cf-relay/worker.js'), '// fixture\n');
  makeIpa(join(hotfix, ipaName), '0.4.7', '9969');
  makeIpa(mainIpa, '0.4.7', '1926');
  writeFileSync(signing, 'signing fixture');
  const hash = file => createHash('sha256').update(readFileSync(file)).digest('hex');
  writeFileSync(join(hotfix, 'SHA256SUMS'), hash(join(hotfix, ipaName)) + '  ' + ipaName + '\n');
  const step = workflow('publish-promotion').split("\n      - name: The promoted build's files\n")[1].split('\n      - name:')[0];
  const result = run(commands(step), { env: {
    CHANNEL: 'beta', BASE: '0.4.7', SOURCE: 'app-0.4.7-alpha.9969', SHA: sha, GITHUB_SHA: sha,
    FIXTURE_IPA: mainIpa, FIXTURE_SIGNING: signing, HOTFIX_TAG: tag, HOTFIX_FILES: hotfix,
    SIGNING_DIGEST: 'sha256:' + hash(signing),
  } });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.deepEqual(readFileSync(join(dir, 'dist', ipaName)), readFileSync(join(hotfix, ipaName)));
  assert.ok(calls().some(line => line.startsWith('gh release download ' + tag + ' ')));
});
