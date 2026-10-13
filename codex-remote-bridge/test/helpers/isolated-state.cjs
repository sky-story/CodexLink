// Load before production modules: even full encrypted handshakes persist trust.
// Tests must never read/write the developer's real pairing or macOS Keychain.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-remote-test-state-'));
process.env.CODEX_REMOTE_DEVICE_STATE_DIR = root;
process.env.CODEX_REMOTE_DEVICE_STATE_FILE = path.join(root, 'device-state.json');
process.env.CODEX_REMOTE_DEVICE_STATE_KEYCHAIN_MOCK_FILE = path.join(root, 'keychain.json');
// Nested test fixtures override the directory, so do not pin a separate file.
delete process.env.CODEX_REMOTE_DEVICE_STATE_FILE;
process.on('exit', () => fs.rmSync(root, { recursive: true, force: true }));
module.exports = { root };
