import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export async function unlockDevice(device, signal) {
  const passcode = process.env.POKI_IPHONE_PASSCODE;
  if (!passcode) throw new Error('No iPhone passcode is configured locally. Unlock input was not sent.');
  // Any passcode iOS allows: 4 or 6 digits, a custom numeric code, or an alphanumeric one.
  if (!/^[ -~]{4,128}$/.test(passcode)) throw new Error('The configured passcode must be 4 to 128 characters typed on a US keyboard. Unlock input was not sent.');
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
