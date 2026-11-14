import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const exec = promisify(execFile);

test('an installed update gives restart instructions when the old process survives', { skip: process.platform !== 'darwin' }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-update-finish-'));
  try {
    const source = await readFile(new URL('../native/ios-app/Poki/Signing/SelfSigner.swift', import.meta.url), 'utf8');
    // Compile the real signer with platform adapters; the C bridge and iOS process are simulated.
    await writeFile(join(dir, 'SelfSigner.swift'), source.slice(0, source.indexOf('enum SignerBridge {'))
      .replace('import UIKit', 'import Observation').replace('import UserNotifications', '')
      .replace(/\bexit\(/g, 'ProcessExit.terminate('));
    const app = await readFile(new URL('../native/ios-app/Poki/App/AppModel.swift', import.meta.url), 'utf8');
    const method = (name) => {
      const begin = app.indexOf(`    func ${name}(`);
      const end = app.indexOf('\n    }', begin) + '\n    }'.length;
      return app.slice(begin, end);
    };
    const wiring = app.split('\n').filter((line) => line.includes('signer.') && line.includes('windDownForUpdate()')).join('\n');
    await writeFile(join(dir, 'AppModel.swift'), `import Foundation
    @MainActor final class AppModel {
      let signer: SelfSigner
      let core = FakeCore()
      let log = AppLog.shared
      let background = BackgroundKeeper()
      let pairingKeepAlive = KeepAlive()
      let activity = ActivityController()
      let launcher = Launcher()
      let voice = VoiceModel()
      let pairer = Pairer()
      var sessionOn = true
      var sessionStartTask: Task<Void, Never>?
      var idleTimer: Timer?
      enum AutomationPath { case inProcess, runner }
      var automationPath = AutomationPath.inProcess
      static let onSimulator = false
      init(signer: SelfSigner) { self.signer = signer }
      func wireSigner() { ${wiring} }
      func closeInProcess(_ why: String, then: (@MainActor () -> Void)? = nil) {
        if UpdateResources.holdClose {
          UpdateResources.finishClose = {
            UpdateResources.automation = false
            then?()
          }
        } else {
          UpdateResources.automation = false
          then?()
        }
      }
      ${method('phoneTool')}
      ${method('windDownForUpdate')}
    }`);
    await exec('swiftc', ['-parse-as-library', join(dir, 'SelfSigner.swift'), join(dir, 'AppModel.swift'),
      fileURLToPath(new URL('./fixtures/update-finish/Runtime.swift', import.meta.url)),
      '-o', join(dir, 'check')]);
    const result = await exec(join(dir, 'check'), { timeout: 60_000 });
    process.stdout.write(result.stdout);
    assert.match(result.stdout, /PASS: timeout shows restart instructions/);
    const exited = await exec(join(dir, 'check'), ['--exit-process'], { timeout: 60_000 });
    assert.match(exited.stdout, /PASS: confirmed update terminates the process with status 0/);
    process.stdout.write('PASS: confirmed update terminates the process with status 0\n');
  } catch (error) {
    if (error.stdout) process.stdout.write(error.stdout);
    if (error.stderr) process.stderr.write(error.stderr);
    throw error;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
