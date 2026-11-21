import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export async function unlockDevice(device, signal) {
  const passcode = process.env.POKI_IPHONE_PASSCODE;
  if (!passcode) throw new Error('No iPhone passcode is configured locally. Unlock input was not sent.');
  // iOS allows 4 or 6 digits, a custom numeric code, or an alphanumeric one. Only the first two go
  // on the keypad. The others are typed into the lock screen's field, which this helper cannot see,
  // so keys sent blind could land in an open app. It refuses those instead of guessing.
  if (!/^(\d{4}|\d{6})$/.test(passcode)) throw new Error('The configured passcode is a custom numeric or alphanumeric code. This helper only taps 4- or 6-digit codes on the keypad and does not type other passcodes without seeing the lock screen. Unlock input was not sent: ask the owner to unlock the phone, or use Automatic Unlock in Poki on the iPhone, which checks the lock screen first.');
  const env = { ...process.env };
  delete env.POKI_IPHONE_PASSCODE;
  const args = [fileURLToPath(new URL('./skills/iphone-unlock/scripts/unlock.py', import.meta.url)), '--device', device, '--stdin'];
  if (process.env.POKI_UNLOCK_NATIVE) args.push('--native', process.env.POKI_UNLOCK_NATIVE);
  await new Promise((resolve, reject) => {
    const child = spawn('python3', args, { env, signal, timeout: 30000, stdio: ['pipe', 'ignore', 'ignore'] });
    child.on('error', () => reject(new Error('Unlock helper could not run. Inspect the current screen before continuing.')));
    child.on('close', code => code === 0 ? resolve() : reject(new Error('Unlock input did not complete. Inspect the current screen before continuing.')));
    child.stdin.on('error', () => {});
    child.stdin.end(passcode);
  });
}
