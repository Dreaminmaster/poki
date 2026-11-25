import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const headSha = '5abf641df0fe27e9bb7f214579ad6abcbf093494';
const promotedSha = '31b7915c5b958326a7b6e4b9c39f5f8491b96f70';

const ghStub = [
  '#!/usr/bin/env node',
  'const { appendFileSync, mkdirSync, writeFileSync } = require("node:fs");',
  'const { join } = require("node:path");',
  'const args = process.argv.slice(2);',
  'if (process.env.CALLS) appendFileSync(process.env.CALLS, "gh " + args.join(" ") + "\\n");',
  'const state = JSON.parse(process.env.GH_STATE || "{}");',
  'const endpoint = args.find(arg => arg.startsWith("repos/")) ?? "";',
  'if (args[0] === "api" && endpoint.includes("/git/ref/tags/")) {',
  '  const tag = endpoint.split("/git/ref/tags/")[1];',
  '  process.exit((state.tags || []).includes(tag) ? 0 : 1);',
  '}',
  'if (args[0] === "api" && /\\/actions\\/runs\\/\\d+\\/artifacts/.test(endpoint)) {',
  '  const runId = Number(endpoint.match(/\\/actions\\/runs\\/(\\d+)\\/artifacts/)[1]);',
  '  const artifacts = (state.artifacts || {})[String(runId)] || [];',
  '  const jqIndex = args.indexOf("--jq");',
  '  if (jqIndex >= 0 && args[jqIndex + 1] === ".artifacts[].name") {',
  '    if (artifacts.length) console.log(artifacts.map(item => item.name).join("\\n"));',
  '  } else {',
  '    console.log(JSON.stringify({ total_count: artifacts.length, artifacts }));',
  '  }',
  '  process.exit(0);',
  '}',
  'if (args[0] === "run" && args[1] === "list") {',
  '  const commit = args.includes("--commit") ? args[args.indexOf("--commit") + 1] : null;',
  '  const runs = (state.runs || []).filter(run => !commit || !run.headSha || run.headSha === commit);',
  '  const jqIndex = args.indexOf("--jq");',
  '  if (jqIndex >= 0) {',
  '    const expr = args[jqIndex + 1];',
  '    const filtered = expr.includes(\'status == "completed"\') ? runs.filter(run => run.status === "completed") : runs;',
  '    if (filtered.length) console.log(filtered.map(run => run.databaseId).join("\\n"));',
  '  } else {',
  '    console.log(JSON.stringify(runs));',
  '  }',
  '  process.exit(0);',
  '}',
  'if (args[0] === "run" && args[1] === "download") {',
  '  const runId = String(args[2]);',
  '  const name = args[args.indexOf("--name") + 1];',
  '  const dir = args[args.indexOf("--dir") + 1];',
  '  const files = ((state.downloads || {})[runId] || {})[name];',
  '  if (!files) process.exit(1);',
  '  mkdirSync(dir, { recursive: true });',
  '  for (const [fileName, content] of Object.entries(files)) {',
  '    writeFileSync(join(dir, fileName), content);',
  '  }',
  '  process.exit(0);',
  '}',
  'if (args[0] === "release" && args[1] === "view") {',
  '  const tag = args[2];',
  '  const release = (state.releases || {})[tag];',
  '  if (!release) process.exit(1);',
  '  console.log(JSON.stringify(release));',
  '  process.exit(0);',
  '}',
  'if (args[0] === "issue" && args[1] === "list") {',
  '  const blockers = state.blockers || [];',
  '  if (blockers.length) console.log(blockers.join("\\n"));',
  '  process.exit(0);',
  '}',
  'process.exit(1);',
].join('\n');

function workflow(name) {
  return readFileSync(join(root, '.github/workflows', name + '.yml'), 'utf8');
}

function jobBlock(source, id) {
  const block = source.split(`\n  ${id}:\n`)[1]?.split(/\n  \S/, 1)[0];
  assert.ok(block, `Missing workflow job ${id}`);
  return block;
}

function jobIf(source, id) {
  const match = jobBlock(source, id).match(/^    if:\s*(.+)$/m);
  assert.ok(match, `Missing if expression on job ${id}`);
  return match[1].trim();
}

function stepBlock(source, jobId, marker) {
  const steps = jobBlock(source, jobId).split('\n      - ').slice(1);
  const step = steps.find(item => item.includes(marker));
  assert.ok(step, `Missing step ${marker} in job ${jobId}`);
  return step;
}

function stepCommands(step) {
  const match = step.match(/^        run: (.+)$/m);
  assert.ok(match, 'workflow step has a shell command');
  return match[1] === '|' ? step.slice(match.index + match[0].length).trimEnd() : match[1];
}

function evalWorkflowExpr(expr, context) {
  const jsExpr = expr
    .replace(/^\$\{\{\s*|\s*\}\}$/g, '')
    .replace(/contains\(\s*github\.event\.pull_request\.labels\.\*\.name\s*,\s*'([^']+)'\s*\)/g,
      (_, label) => `ctx.labels.includes(${JSON.stringify(label)})`)
    .replace(/github\.event\.action/g, 'ctx.action')
    .replace(/github\.event\.label\.name/g, 'ctx.labelName')
    .replace(/github\.event\.pull_request\.number/g, 'ctx.prNumber')
    .replace(/needs\.read\.outputs\.channel/g, 'ctx.channel')
    .replace(/needs\.read\.outputs\.gym_run/g, 'ctx.gymRun');
  return Function('ctx', `return Boolean(${jsExpr});`)(context);
}

function makeSandbox(t, { channels, ghState = {} } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'poki-promotion-gate-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  mkdirSync(join(dir, 'bin'));
  mkdirSync(join(dir, '.github/scripts'), { recursive: true });
  writeFileSync(join(dir, 'bin/gh'), ghStub);
  chmodSync(join(dir, 'bin/gh'), 0o755);
  writeFileSync(join(dir, '.github/scripts/promotion.py'), readFileSync(join(root, '.github/scripts/promotion.py')));
  writeFileSync(
    join(dir, '.github/channels.json'),
    JSON.stringify(channels ?? {
      soak_days: 3,
      promotions: [
        {
          channel: 'beta',
          proposed: '2026-11-24T10:01:01Z',
          version: '0.5.1-beta.1',
          tag: 'app-0.5.1-beta.1',
          base_version: '0.5.1',
          build: '2505',
          source: 'app-0.5.1-alpha.2505',
          sha: promotedSha,
        },
      ],
    }, null, 2) + '\n',
  );
  const calls = join(dir, 'calls');
  const outputs = join(dir, 'outputs');
  writeFileSync(calls, '');
  writeFileSync(outputs, '');
  return {
    dir,
    outputs,
    calls: () => readFileSync(calls, 'utf8').trim().split('\n').filter(Boolean),
    runBash(command, env = {}) {
      return spawnSync('bash', ['-e', '-c', command], {
        cwd: dir,
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${join(dir, 'bin')}:${process.env.PATH}`,
          GH_TOKEN: 'stub-token',
          GH_REPO: 'example/poki',
          GITHUB_RUN_ID: '900',
          GITHUB_OUTPUT: outputs,
          CALLS: calls,
          GH_STATE: JSON.stringify(ghState),
          ...env,
        },
      });
    },
    runPython(args, env = {}) {
      return spawnSync('python3', ['.github/scripts/promotion.py', ...args], {
        cwd: dir,
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${join(dir, 'bin')}:${process.env.PATH}`,
          GH_TOKEN: 'stub-token',
          GH_REPO: 'example/poki',
          CALLS: calls,
          GH_STATE: JSON.stringify(ghState),
          ...env,
        },
      });
    },
  };
}

function parseOutputs(path) {
  const text = readFileSync(path, 'utf8').trim();
  if (!text) return {};
  return Object.fromEntries(text.split('\n').map(line => {
    const idx = line.indexOf('=');
    return [line.slice(0, idx), line.slice(idx + 1)];
  }));
}

test('label events do not cancel an in-progress promotion gate while preserving soak-override rechecks', () => {
  const gate = workflow('promotion-gate');
  const propose = workflow('propose-promotion');
  assert.match(propose, /gh pr create .*--label promotion/);
  assert.match(gate, /types:\s*\[opened,\s*synchronize,\s*reopened,\s*labeled,\s*unlabeled\]/);

  const concurrencyMatch = gate.match(/^concurrency:\n((?:  .+\n)+)/m);
  assert.ok(concurrencyMatch, 'promotion-gate defines concurrency');
  const block = concurrencyMatch[1];
  const groupLine = block.match(/^  group:\s*(.+)$/m)?.[1].trim();
  const cancelLine = block.match(/^  cancel-in-progress:\s*(.+)$/m)?.[1].trim();
  assert.equal(groupLine, 'promotion-gate-${{ github.event.pull_request.number }}');
  assert.ok(cancelLine, 'promotion-gate defines cancel-in-progress');

  // Code-changing PR events cancel stale runs; label events queue behind an active Gym run.
  for (const action of ['opened', 'synchronize', 'reopened']) {
    assert.equal(
      evalWorkflowExpr(cancelLine, { action, labelName: '' }),
      true,
      `${action} should cancel stale runs`,
    );
  }
  for (const [action, labelName] of [['labeled', 'promotion'], ['labeled', 'soak-override'], ['unlabeled', 'soak-override']]) {
    assert.equal(
      evalWorkflowExpr(cancelLine, { action, labelName }),
      false,
      `${action} (${labelName}) must not cancel an in-progress Gym run`,
    );
  }

  // Stable PRs still evaluate soak unless soak-override is present on the PR.
  const soakStep = stepBlock(gate, 'verdict', 'name: Stable waits after its beta');
  const soakIf = soakStep.match(/^        if:\s*(.+)$/m)?.[1].trim();
  assert.ok(soakIf);
  assert.equal(evalWorkflowExpr(soakIf, { channel: 'stable', labels: ['promotion'] }), true);
  assert.equal(evalWorkflowExpr(soakIf, { channel: 'stable', labels: ['promotion', 'soak-override'] }), false);
  assert.equal(evalWorkflowExpr(soakIf, { channel: 'beta', labels: ['promotion'] }), false);
});

test('beta promotion from promote-alpha-fast or after a cancelled run still runs Gym on labeled when no scorecard exists', t => {
  const gate = workflow('promotion-gate');
  const readCmd = stepCommands(stepBlock(gate, 'read', 'id: r'));
  const gymCondition = jobIf(gate, 'gym');

  // No prior completed run with scorecards (e.g. first beta from promote-alpha-fast or cancelled opened run).
  const sandbox = makeSandbox(t, {
    ghState: {
      runs: [
        { databaseId: 900, status: 'in_progress', conclusion: null, headSha },
        { databaseId: 899, status: 'completed', conclusion: 'cancelled', headSha },
        { databaseId: 898, status: 'completed', conclusion: 'success', headSha },
      ],
      artifacts: {
        899: [],
        898: [
          { name: 'gym-scorecard', expired: true },
          { name: 'gym-scorecard-inprocess', expired: true },
        ],
      },
    },
  });

  const res = sandbox.runBash(readCmd, {
    EVENT_ACTION: 'labeled',
    HEAD_SHA: headSha,
    GITHUB_RUN_ID: '900',
  });
  assert.equal(res.status, 0, res.stdout + res.stderr);
  const out = parseOutputs(sandbox.outputs);
  assert.equal(out.channel, 'beta');
  assert.equal(out.sha, promotedSha);
  assert.equal(out.gym_run, '');

  assert.equal(
    evalWorkflowExpr(gymCondition, { channel: out.channel, action: 'labeled', gymRun: out.gym_run }),
    true,
    'labeled must run Gym when no valid scorecard exists yet',
  );
  assert.equal(
    evalWorkflowExpr(gymCondition, { channel: out.channel, action: 'opened', gymRun: '850' }),
    true,
    'opened always runs Gym for beta',
  );
});

test('labeled beta event reuses the newest completed Gym run with non-expired scorecards and passes verdict', t => {
  const gate = workflow('promotion-gate');
  const readCmd = stepCommands(stepBlock(gate, 'read', 'id: r'));
  const scorecardsCmd = stepCommands(stepBlock(gate, 'verdict', "name: This build's scorecards"));
  const gymCondition = jobIf(gate, 'gym');

  const sandbox = makeSandbox(t, {
    ghState: {
      runs: [
        { databaseId: 905, status: 'in_progress', conclusion: null, headSha },
        { databaseId: 904, status: 'completed', conclusion: 'cancelled', headSha },
        { databaseId: 903, status: 'completed', conclusion: 'failure', headSha },
        { databaseId: 902, status: 'completed', conclusion: 'success', headSha },
      ],
      artifacts: {
        904: [],
        903: [{ name: 'gym-scorecard', expired: false }],
        902: [
          { name: 'gym-scorecard', expired: false },
          { name: 'gym-scorecard-inprocess', expired: false },
        ],
      },
      downloads: {
        902: {
          'gym-scorecard': { 'gym-scorecard.txt': 'summary\nfailures: 0\n' },
          'gym-scorecard-inprocess': { 'gym-scorecard-inprocess.txt': 'summary\nfailures: 0\n' },
        },
      },
    },
  });

  const readRes = sandbox.runBash(readCmd, {
    EVENT_ACTION: 'labeled',
    HEAD_SHA: headSha,
    GITHUB_RUN_ID: '905',
  });
  assert.equal(readRes.status, 0, readRes.stdout + readRes.stderr);
  const out = parseOutputs(sandbox.outputs);
  assert.equal(out.gym_run, '902', 'prefers the newest completed run carrying both scorecards');
  assert.equal(
    evalWorkflowExpr(gymCondition, { channel: out.channel, action: 'labeled', gymRun: out.gym_run }),
    false,
    'skips Gym when a completed run already produced valid scorecards',
  );

  const dlRes = sandbox.runBash(scorecardsCmd, {
    HEAD_SHA: headSha,
    GYM: 'skipped',
    GYM_RUN: out.gym_run,
    GITHUB_RUN_ID: '905',
  });
  assert.equal(dlRes.status, 0, dlRes.stdout + dlRes.stderr);

  mkdirSync(join(sandbox.dir, 'base'), { recursive: true });
  writeFileSync(join(sandbox.dir, 'base/gym-scorecard.txt'), 'failures: 0\n');
  writeFileSync(join(sandbox.dir, 'base/gym-scorecard-inprocess.txt'), 'failures: 0\n');
  const verdictRes = sandbox.runPython(['gym', 'base', 'new']);
  assert.equal(verdictRes.status, 0, verdictRes.stdout + verdictRes.stderr);
});

test('missing, partial, or forged scorecards are still rejected by verdict and promotion.py', t => {
  const gate = workflow('promotion-gate');
  const scorecardsCmd = stepCommands(stepBlock(gate, 'verdict', "name: This build's scorecards"));

  // 1. Completed run exists on HEAD_SHA but has no scorecard artifacts: must fail with a clear error.
  const noScorecardBox = makeSandbox(t, {
    ghState: {
      runs: [
        { databaseId: 910, status: 'completed', conclusion: 'cancelled', headSha },
      ],
      artifacts: {
        910: [],
      },
    },
  });
  const missingRun = noScorecardBox.runBash(scorecardsCmd, {
    HEAD_SHA: headSha,
    GYM: 'skipped',
    GYM_RUN: '',
    GITHUB_RUN_ID: '911',
  });
  assert.notEqual(missingRun.status, 0);
  assert.match(missingRun.stdout + missingRun.stderr, new RegExp(`::error::no Gym run for ${headSha} yet`));

  // 2. Partial artifacts (in-process scorecard missing): gym-run still resolves it so verdict fails fast instead of bypassing or looping.
  const partialBox = makeSandbox(t, {
    ghState: {
      runs: [
        { databaseId: 920, status: 'completed', conclusion: 'failure', headSha },
      ],
      artifacts: {
        920: [{ name: 'gym-scorecard', expired: false }],
      },
      downloads: {
        920: {
          'gym-scorecard': { 'gym-scorecard.txt': 'failures: 0\n' },
        },
      },
    },
  });
  const partialLookup = partialBox.runPython(['gym-run', headSha, '921']);
  assert.equal(partialLookup.status, 0, partialLookup.stdout + partialLookup.stderr);
  assert.equal(partialLookup.stdout.trim(), '920');

  const partialDl = partialBox.runBash(scorecardsCmd, {
    HEAD_SHA: headSha,
    GYM: 'skipped',
    GYM_RUN: partialLookup.stdout.trim(),
    GITHUB_RUN_ID: '921',
  });
  assert.equal(partialDl.status, 0, partialDl.stdout + partialDl.stderr);
  mkdirSync(join(partialBox.dir, 'base'), { recursive: true });
  const partialVerdict = partialBox.runPython(['gym', 'base', 'new']);
  assert.notEqual(partialVerdict.status, 0);
  assert.match(partialVerdict.stdout + partialVerdict.stderr, /gym-scorecard-inprocess\.txt has no scorecard/);

  // 3. Invalid SHA is rejected by gym-run; forged / malformed scorecard or regression is rejected by gym.
  const invalidSha = partialBox.runPython(['gym-run', 'not-a-sha']);
  assert.notEqual(invalidSha.status, 0);

  const forgedBox = makeSandbox(t);
  mkdirSync(join(forgedBox.dir, 'base'), { recursive: true });
  mkdirSync(join(forgedBox.dir, 'new'), { recursive: true });
  writeFileSync(join(forgedBox.dir, 'base/gym-scorecard.txt'), 'failures: 0\n');
  writeFileSync(join(forgedBox.dir, 'base/gym-scorecard-inprocess.txt'), 'failures: 0\n');
  writeFileSync(join(forgedBox.dir, 'new/gym-scorecard.txt'), 'all green trust me\n');
  writeFileSync(join(forgedBox.dir, 'new/gym-scorecard-inprocess.txt'), 'failures: 0\n');
  const forged = forgedBox.runPython(['gym', 'base', 'new']);
  assert.notEqual(forged.status, 0);
  assert.match(forged.stdout + forged.stderr, /gym-scorecard\.txt has no scorecard/);

  writeFileSync(join(forgedBox.dir, 'new/gym-scorecard.txt'), 'failures: 1\n');
  const regressed = forgedBox.runPython(['gym', 'base', 'new']);
  assert.notEqual(regressed.status, 0);
  assert.match(regressed.stdout + regressed.stderr, /gym-scorecard\.txt: 1 failures, the last beta had 0/);
});
