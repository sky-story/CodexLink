// Foreground private-network launcher. Uses real pairing state; never starts another Codex runtime.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { defaultEndpoint } = require('../codex-remote-bridge/src/shared-runtime');

const { showPairing } = require('./pairing-page.cjs');

function main() {
  const appCLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';
  const cli = fs.existsSync(appCLI) ? appCLI : 'tailscale';
  const status = JSON.parse(execFileSync(cli, ['status', '--json'], { encoding: 'utf8', timeout: 15000 }));
  const address = (status.TailscaleIPs || []).find(ip => /^100\.(\d+)\.\d+\.\d+$/.test(ip) && Number(ip.split('.')[1]) >= 64 && Number(ip.split('.')[1]) <= 127);
  if (status.BackendState !== 'Running' || !address) throw new Error('Connect Tailscale on this Mac first. No public or LAN fallback is used.');
  const socketPath = defaultEndpoint().slice('unix://'.length);
  if (!fs.existsSync(socketPath)) throw new Error('Open the normal Codex CLI first; its shared daemon socket is missing.');
  const port = 9100;
  const relayURL = `ws://${address}:${port}/relay`;
  console.log(`Private relay: ${relayURL}`);
  if (process.argv.includes('--check')) return;
  process.env.CODEX_REMOTE_RELAY = relayURL;
  process.env.CODEX_REMOTE_PUSH_SERVICE_URL = '';
  const { createRelayServer } = require('../relay/server');
  const { startBridge } = require('../codex-remote-bridge/src/bridge');
  const { server } = createRelayServer();
  server.on('error', error => { console.error(`Cannot listen on the Tailscale interface: ${error.message}`); process.exitCode = 1; });
  server.listen(port, address, () => {
    console.log('Keep this window open. Scan the QR with Codex Remote on your iPhone.');
    console.log('Press Control-C to stop this Bridge and Relay; Codex tasks continue on the daemon.');
    try { startBridge({ printPairingQr: true, onPairingSession: showPairing }); }
    catch (error) { console.error(error.message); server.close(); process.exitCode = 1; }
  });
}
try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
