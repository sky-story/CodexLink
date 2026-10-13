// Owns the private Relay lifecycle inside the existing launchd Bridge service.
// Never enables Tailscale, exposes a public listener, or starts a Codex runtime.
const fs = require('node:fs');
const net = require('node:net');
const { execFileSync } = require('node:child_process');
const { loadPrivatePush, privateRelayPushOptions, privatePushStatus } = require('./private-push');

function addressFromStatus(status) {
  if (status?.BackendState !== 'Running') return null;
  return (status.TailscaleIPs || []).find(ip => net.isIPv4(ip) &&
    ip.split('.')[0] === '100' && Number(ip.split('.')[1]) >= 64 && Number(ip.split('.')[1]) <= 127) || null;
}
function readTailscaleAddress({ exec = execFileSync, exists = fs.existsSync, env = process.env } = {}) {
  const appCLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';
  // The bundled Mac binary treats launchd's service name as a GUI/XPC launch and
  // returns no CLI output. Remove only this inherited hint for the child process.
  const childEnv = { ...env };
  delete childEnv.XPC_SERVICE_NAME;
  childEnv.TAILSCALE_BE_CLI = '1';
  const output = exec(exists(appCLI) ? appCLI : 'tailscale', ['status', '--json'], {
    encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'], env: childEnv,
  });
  return addressFromStatus(JSON.parse(output));
}
function startPrivateNetwork({
  config, startBridge, publishStatus = () => {}, onPairingSession,
  readAddress = readTailscaleAddress,
  createRelay = options => require('../../relay/server').createRelayServer(options),
  readPush = loadPrivatePush,
  pushOptions = privateRelayPushOptions,
  reportPush = status => console.log(`[codex-remote] private push: ${JSON.stringify(status)}`),
  schedule = fn => setInterval(fn, 15000), cancel = clearInterval,
  exit = code => process.exit(code),
}) {
  const port = config.privateRelayPort ?? 9100;
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid private Relay port');
  let address = null, relay, timer, stopped = false, starting = false;
  function fail(message) {
    if (stopped) return;
    stopped = true; cancel(timer);
    publishStatus({ state: 'error', connectionStatus: 'disconnected', pid: process.pid, lastError: message });
    // launchd restarts with a fresh binding. Only this network client exits, never Codex.
    exit(1);
  }
  function check() {
    if (stopped || starting) return;
    let next, unavailable = '';
    try { next = readAddress(); } catch (error) { next = null; unavailable = ` (${error.code || error.name || 'CLI error'})`; }
    // Validate again at the binding boundary, including injected address providers.
    next = addressFromStatus({ BackendState: 'Running', TailscaleIPs: [next] });
    if (address) {
      if (next !== address) fail('Tailscale disconnected or changed address; restarting private listener');
      return;
    }
    if (!next) {
      publishStatus({ state: 'waiting-network', connectionStatus: 'disconnected', pid: process.pid,
        lastError: `Waiting for Tailscale${unavailable}. No public or LAN listener is opened.` });
      return;
    }
    starting = true;
    const push = readPush();
    reportPush(privatePushStatus(push));
    relay = createRelay(pushOptions(push));
    relay.server.on('error', error => fail(`Private Relay listener failed: ${error.message}`));
    relay.server.listen(port, next, () => {
      if (stopped) return;
      address = next; starting = false;
      try {
        startBridge({
          config: { ...config, relayUrl: `ws://${address}:${port}/relay`,
            pushServiceUrl: push.enabled ? `http://${address}:${port}` : '',
            // Completion bodies are generic until the user explicitly chooses a
            // content policy; APNs payloads do not share the Relay's E2EE boundary.
            pushPreviewMaxChars: 0 },
          printPairingQr: false, onPairingSession, onBridgeStatus: publishStatus,
        });
      } catch (error) { fail(error.message); }
    });
  }
  timer = schedule(check);
  check();
  return { check, stop() { stopped = true; cancel(timer); relay?.wss?.clients?.forEach(client => client.terminate()); relay?.wss?.close(); relay?.server.close(); } };
}
module.exports = { addressFromStatus, readTailscaleAddress, startPrivateNetwork };
