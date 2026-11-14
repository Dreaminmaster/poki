import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const exec = promisify(execFile);
const fixture = fileURLToPath(new URL('./fixtures/notification-response/', import.meta.url));

test('notification response completion returns to UIKit on the main thread', { skip: process.platform !== 'darwin' }, async () => {
  const dir = await mkdtemp(join(tmpdir(), 'poki-notification-response-'));
  try {
    const contents = join(dir, 'NotificationCheck.app', 'Contents');
    const executable = join(contents, 'MacOS', 'check');
    await mkdir(join(contents, 'MacOS'), { recursive: true });
    await writeFile(join(contents, 'Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>check</string>
      <key>CFBundleIdentifier</key><string>test.poki.notification-response</string>
      </dict></plist>`);
    const source = await readFile(new URL('../native/ios-app/Poki/Activity/ApprovalNotice.swift', import.meta.url), 'utf8');
    const begin = source.indexOf('final class ApprovalNoticeDelegate:');
    const end = source.indexOf('\n}\n', begin) + 2;
    await writeFile(join(dir, 'Delegate.swift'), `import Foundation\nimport UserNotifications\n${source.slice(begin, end)}\n`);
    await exec('clang', ['-fobjc-arc', '-c', join(fixture, 'Delivery.m'), '-o', join(dir, 'Delivery.o')]);
    await exec('swiftc', ['-import-objc-header', join(fixture, 'Delivery.h'), join(dir, 'Delegate.swift'),
      join(fixture, 'main.swift'), join(dir, 'Delivery.o'), '-o', executable]);
    const { stdout } = await exec(executable, [], { timeout: 10_000 });
    process.stdout.write(stdout);
    assert.match(stdout, /PASS: notification responses complete on the main thread/);
  } catch (error) {
    if (error.stdout) process.stdout.write(error.stdout);
    if (error.stderr) process.stderr.write(error.stderr);
    throw error;
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
