const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

test('direct encrypted-handshake tests cannot overwrite caller pairing or Keychain mirror', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-isolation-regression-'));
  const state = path.join(root, 'device-state.json');
  const mirror = path.join(root, 'keychain.json');
  const sentinel = '{"sentinel":"existing-pairing-must-not-change"}';
  try {
    fs.writeFileSync(state, sentinel); fs.writeFileSync(mirror, sentinel);
    const child = spawnSync(process.execPath, ['--test', path.join(__dirname, 'secure-transport.test.js')], {
      env: { ...process.env, CODEX_REMOTE_DEVICE_STATE_DIR: root,
        CODEX_REMOTE_DEVICE_STATE_FILE: state, CODEX_REMOTE_DEVICE_STATE_KEYCHAIN_MOCK_FILE: mirror },
      encoding: 'utf8', timeout: 30000,
    });
    assert.equal(child.status, 0, child.stdout + child.stderr);
    assert.equal(fs.readFileSync(state, 'utf8'), sentinel);
    assert.equal(fs.readFileSync(mirror, 'utf8'), sentinel);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
