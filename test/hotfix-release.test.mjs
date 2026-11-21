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

function mock(t) {
  const dir = mkdtempSync(join(tmpdir(), 'poki-hotfix-release-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'bin'));
  for (const [name, contents] of Object.entries({ gh, git })) {
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
  const workflowRun = (id, conclusion, record = provenance) => ({
    id, conclusion, run_number: id, head_branch: 'main', event: 'workflow_dispatch',
    workflow_id: 123, display_title: 'Hotfix Pre-alpha 0.4.7 (9969)', provenance: record,
  });
  const records = [
    workflowRun(860, 'success', { ...provenance, ipa_sha256: 'a'.repeat(64) }),
    workflowRun(861, 'failure'),
    workflowRun(864, 'success', { ...provenance, sha: 'f'.repeat(40) }),
    workflowRun(862, 'success'),
    workflowRun(863, 'failure'),
    workflowRun(865, 'success', { ...provenance, build: '9970' }),
    workflowRun(866, 'success', { ...provenance, version: '0.4.6' }),
  ];
  const notedRun = release.notes.match(/actions\/runs\/(\d+)/)[1];
  const step = workflow('promote-alpha').split('\n      - id: r\n')[1].split('\n  # The alpha tests')[0];
  const selected = run(commands(step), {
    env: { WANT: tag, HOTFIX: 'true', HOTFIX_RUN: '861', RUN_RECORDS: JSON.stringify(records) },
  });
  assert.deepEqual({ notedRun, alphaStatus: selected.status }, { notedRun: '862', alphaStatus: 0 },
    selected.stdout + selected.stderr);
  assert.match(readFileSync(outputs, 'utf8'), /^run=862$/m);
  assert.ok(readFileSync(outputs, 'utf8').includes('ipa_sha256=' + ipaHash));
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
