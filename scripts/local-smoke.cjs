// Private loopback-only integration fixture. Does not install launchd or touch existing pairing.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const state = path.join(root, '.build', 'smoke-state');
fs.mkdirSync(state, { recursive: true, mode: 0o700 });
process.env.CODEX_REMOTE_DEVICE_STATE_DIR = state;
process.env.CODEX_REMOTE_STATE_DIR = state;
process.env.CODEX_REMOTE_DEVICE_STATE_KEYCHAIN_MOCK_FILE = path.join(state, 'keychain.json');
process.env.CODEX_REMOTE_RELAY = 'ws://127.0.0.1:19100/relay';
const { createRelayServer } = require('../relay/server');
const { startBridge } = require('../codex-remote-bridge/src/bridge');
const { server } = createRelayServer();
server.listen(19100, '127.0.0.1', () => {
  startBridge({ printPairingQr: false, onPairingSession(session) {
    fs.writeFileSync(path.join(state, 'pairing.json'), JSON.stringify(session.pairingPayload), { mode: 0o600 });
    console.log('Loopback smoke bridge ready; pairing fixture saved privately.');
  } });
});
