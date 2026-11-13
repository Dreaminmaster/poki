import { fileURLToPath } from 'node:url';
import { Bridge } from './bridge.mjs';

export function updateResult(ok, code, reason, simulated = false) {
  console.log(JSON.stringify({ event: 'update_result', ok, code, ...(reason ? { reason } : {}), ...(simulated ? { simulated: true } : {}) }));
}

export async function updateOnly({ bridgePath, setupHome, udid, json, dryRun }) {
  let bridge;
  let renewing = false;
  let simulated = false;
  let readingBack = false;
  const emit = (event, fields) => console.log(json ? JSON.stringify({ event, ...fields }) : `${event}: ${Object.entries(fields).map(([key, value]) => `${key}=${value}`).join(' ')}`);
  try {
    const path = dryRun ? fileURLToPath(new URL('./fake-bridge.mjs', import.meta.url)) : await bridgePath();
    ({ bridge } = await Bridge.start(path, { env: setupHome ? { POKI_SETUP_HOME: setupHome } : {} }));
    const info = await bridge.request('app_info');
    simulated = info.simulated === true;
    if (info.update_only !== 1) {
      updateResult(false, 'update_unsupported', 'This Poki Setup cannot verify a configuration-preserving update; install a Poki Setup build with update-only support and retry.');
      return 2;
    }
    const plan = await bridge.request('update_inspect', { udid });
    emit('update_installed', { version: plan.installed.version, build: plan.installed.build, channel: plan.installed.channel, team: 'verified (identifier withheld)' });
    emit('update_target', { version: plan.target.version, build: plan.target.build });
    emit('update_checks', { build: 'passed', channel: 'passed', team: 'passed', identity: 'passed', extensions: 'passed', app_group: 'passed' });
    renewing = true;
    await bridge.request('renew', { udid: plan.udid, update_only: true, expected: plan.target });
    readingBack = true;
    const installed = await bridge.request('update_readback', { udid: plan.udid });
    emit('update_readback', { version: installed.version, build: installed.build });
    if (installed.version !== plan.target.version || installed.build !== plan.target.build) {
      updateResult(false, 'update_readback_mismatch', 'The installed version does not match the target; keep Poki installed and ask for help checking this update.');
      return 4;
    }
    updateResult(true, 'updated', undefined, simulated);
    return 0;
  } catch (error) {
    if (readingBack) {
      updateResult(false, 'update_readback_failed', 'The update finished but its installed version could not be read; unlock the iPhone and verify the version before retrying.');
      return 4;
    }
    if (renewing && error.kind !== 'update_preflight') {
      updateResult(false, 'update_install_failed', 'The verified update did not finish; keep Poki installed and check the iPhone before retrying update-only.');
      return 3;
    }
    // Only this protocol error contains public, fixed guidance. Other helper errors may contain identifiers.
    const reason = error.kind === 'update_preflight' ? error.message : 'The update could not be verified; keep Poki installed and check the original signing computer and Poki Setup version.';
    updateResult(false, 'update_preflight_failed', reason);
    return 2;
  } finally {
    bridge?.close();
  }
}
