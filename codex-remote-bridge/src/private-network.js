// Owns the private Relay lifecycle inside the existing launchd Bridge service.
// Never enables Tailscale, exposes a public listener, or starts a Codex runtime.
const fs = require('node:fs');
const net = require('node:net');
const { execFileSync, execFile } = require('node:child_process');
const { loadPrivatePush, privateRelayPushOptions, privatePushStatus } = require('./private-push');

function addressFromStatus(status) {
  if (status?.BackendState !== 'Running') return null;
  return (status.TailscaleIPs || []).find(ip => net.isIPv4(ip) &&
    ip.split('.')[0] === '100' && Number(ip.split('.')[1]) >= 64 && Number(ip.split('.')[1]) <= 127) || null;
}
function tailscaleCommand({ exists = fs.existsSync, env = process.env } = {}) {
  const appCLI = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';
  // The bundled Mac binary treats launchd's service name as a GUI/XPC launch and
  // returns no CLI output. Remove only this inherited hint for the child process.
  const childEnv = { ...env };
  delete childEnv.XPC_SERVICE_NAME;
  childEnv.TAILSCALE_BE_CLI = '1';
  return [exists(appCLI) ? appCLI : 'tailscale', ['status', '--json'], {
    encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL', maxBuffer: 4 * 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'], env: childEnv,
  }];
}
function parseAddress(output) {
  const status = JSON.parse(output);
  if (!status || typeof status.BackendState !== 'string') throw new Error('Invalid Tailscale status');
  return addressFromStatus(status);
}
function readTailscaleAddress({ exec = execFileSync, ...options } = {}) {
  return parseAddress(exec(...tailscaleCommand(options)));
}
// The service must keep forwarding frames while the Mac app answers its CLI probe.
function readTailscaleAddressAsync({ exec = execFile, ...options } = {}) {
  return new Promise((resolve, reject) => {
    exec(...tailscaleCommand(options), (error, output) => {
      if (error) { reject(error); return; }
      try { resolve(parseAddress(output)); } catch (error) { reject(error); }
    });
  });
}
function startPrivateNetwork({
  config, startBridge, publishStatus = () => {}, onPairingSession,
  readAddress = readTailscaleAddressAsync,
  createRelay = options => require('../../relay/server').createRelayServer(options),
  readPush = loadPrivatePush,
  pushOptions = privateRelayPushOptions,
  reportPush = status => console.log(`[codex-remote] private push: ${JSON.stringify(status)}`),
  reportError = message => console.warn(`[codex-remote] ${new Date().toISOString()} pid=${process.pid} ${message}`),
  schedule = fn => setInterval(fn, 15000), cancel = clearInterval,
  exit = code => process.exit(code),
}) {
  const port = config.privateRelayPort ?? 9100;
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid private Relay port');
  let address = null, relay, timer, stopped = false, starting = false, checking = false, probeFailures = 0;
  function fail(message) {
    if (stopped) return;
    stopped = true; cancel(timer);
    reportError(message);
    publishStatus({ state: 'error', connectionStatus: 'disconnected', pid: process.pid, lastError: message });
    // launchd restarts with a fresh binding. Only this network client exits, never Codex.
    exit(1);
  }
  async function check() {
    if (stopped || starting || checking) return;
    checking = true;
    let next;
    try {
      next = await readAddress();
      probeFailures = 0;
    } catch (error) {
      if (stopped) return;
      const reason = error.code || error.name || 'CLI error';
      probeFailures++;
      reportError(`Tailscale status probe failed (${reason}), attempt ${probeFailures}/3`);
      // A failed probe is not evidence that a private address changed. Keep the
      // existing binding during brief CLI stalls; never fall back to another interface.
      if (address && probeFailures >= 3) fail('Tailscale status unavailable after 3 probes; restarting private listener');
      else if (!address) publishStatus({ state: 'waiting-network', connectionStatus: 'disconnected', pid: process.pid,
        lastError: `Waiting for Tailscale (${reason}). No public or LAN listener is opened.` });
      return;
    } finally { checking = false; }
    if (stopped) return;
    // Validate again at the binding boundary, including injected address providers.
    next = addressFromStatus({ BackendState: 'Running', TailscaleIPs: [next] });
    if (address) {
      if (next !== address) fail('Tailscale disconnected or changed address; restarting private listener');
      return;
    }
    if (!next) {
      publishStatus({ state: 'waiting-network', connectionStatus: 'disconnected', pid: process.pid,
        lastError: 'Waiting for Tailscale. No public or LAN listener is opened.' });
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
  const ready = check();
  return { check, ready, stop() { stopped = true; cancel(timer); relay?.wss?.clients?.forEach(client => client.terminate()); relay?.wss?.close(); relay?.server.close(); } };
}
module.exports = { addressFromStatus, readTailscaleAddress, readTailscaleAddressAsync, startPrivateNetwork };
