#!/usr/bin/env node
// Manages the existing launchd agent plus its private Relay. Pairing/trust is preserved.
const fs = require('node:fs');
const net = require('node:net');
const {
  startMacOSBridgeService, stopMacOSBridgeService, getMacOSBridgeServiceStatus,
  resolveLaunchAgentPlistPath,
} = require('../codex-remote-bridge/src/macos-launch-agent');
const { readBridgeConfig } = require('../codex-remote-bridge/src/codex-desktop-refresher');
const { readBridgeDeviceState } = require('../codex-remote-bridge/src/secure-device-state');
const { readPairingSession } = require('../codex-remote-bridge/src/daemon-state');
const { readTailscaleAddress } = require('../codex-remote-bridge/src/private-network');

async function assertPortFree(address) {
  if (!address) return;
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', () => reject(new Error('Port 9100 is occupied. Stop the foreground private-service window first; no process was killed.')));
    server.listen(9100, address, () => server.close(resolve));
  });
}
function describe(status) {
  const heartbeat = status.bridgeStatus;
  console.log(JSON.stringify({
    installed: status.installed, loaded: status.launchdLoaded, pid: status.launchdPid,
    privateRelay: status.daemonConfig?.privateRelayEnabled === true,
    state: heartbeat?.state || (status.launchdLoaded ? 'starting' : 'stopped'),
    connection: heartbeat?.connectionStatus || 'unknown',
    lastError: heartbeat?.lastError || null, updatedAt: heartbeat?.updatedAt,
    log: status.stderrLogPath,
  }, null, 2));
}
async function start(restart = false) {
  const current = getMacOSBridgeServiceStatus();
  if (current.launchdLoaded && !current.daemonConfig?.privateRelayEnabled) throw new Error('A different Bridge service is loaded; stop it explicitly before switching to private mode.');
  if (current.launchdLoaded && current.launchdPid && !restart) { describe(current); return; }
  let address;
  try { address = readTailscaleAddress(); } catch { address = null; }
  if (!current.launchdLoaded) await assertPortFree(address);
  const config = { ...readBridgeConfig(), privateRelayEnabled: true, privateRelayPort: 9100,
    relayUrl: address ? `ws://${address}:9100/relay` : '', pushServiceUrl: '' };
  const runtime = require('./service-runtime.cjs').installRuntime();
  await startMacOSBridgeService({ config: { ...config, runtimeRevision: runtime.revision }, cliPath: runtime.cliPath, waitForPairing: false });
  // Starting before Tailscale is ready is valid: launchd service waits without binding a public port.
  for (let i = 0; i < 40; i++) {
    const state = getMacOSBridgeServiceStatus();
    if (state.bridgeStatus?.connectionStatus === 'connected' || state.bridgeStatus?.state === 'waiting-network') { describe(state); return; }
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  describe(getMacOSBridgeServiceStatus());
}
async function pair() {
  await start();
  let session = readPairingSession();
  if (!session?.pairingPayload || session.pairingPayload.expiresAt - Date.now() < 30000) {
    await start(true); session = readPairingSession();
  }
  if (!session?.pairingPayload || session.pairingPayload.expiresAt <= Date.now()) throw new Error('No current QR. Ensure Tailscale is connected, then run pair again.');
  require('./pairing-page.cjs').showPairing(session, { background: true });
}
async function main(command = process.argv[2] || 'start') {
  if (process.platform !== 'darwin') throw new Error('This service manager requires macOS.');
  if (command === 'start') {
    await start();
    if (!Object.keys(readBridgeDeviceState()?.trustedPhones || {}).length && readPairingSession()?.pairingPayload?.expiresAt > Date.now()) await pair();
  } else if (command === 'restart') await start(true);
  else if (command === 'pair') await pair();
  else if (command === 'status') describe(getMacOSBridgeServiceStatus());
  else if (command === 'stop' || command === 'uninstall') {
    stopMacOSBridgeService();
    if (command === 'uninstall') fs.rmSync(resolveLaunchAgentPlistPath(), { force: true });
    console.log(command === 'uninstall' ? 'Login agent removed. Pairing and Codex sessions retained.' : 'Service stopped. Pairing retained; it can start again at next login.');
  } else throw new Error('Usage: node scripts/private-service.cjs start|status|restart|pair|stop|uninstall');
}
if (require.main === module) main().catch(error => { console.error(error.message); process.exitCode = 1; });
