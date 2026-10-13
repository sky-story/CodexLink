const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), os = require('node:os');
const { installRuntime } = require('../../scripts/service-runtime.cjs');
test('runtime snapshots are repeatable, exclude secrets/symlinks, and change only when inputs change', () => {
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-runtime-test-'));
  const sourceRoot = path.join(temporary, 'source'), installRoot = path.join(temporary, 'installed');
  const fixture = ['LICENSE', 'ThirdPartyLicenses/license.txt', 'codex-remote-bridge/src/bridge.js',
    'codex-remote-bridge/bin/codex-remote.js', 'codex-remote-bridge/package.json', 'codex-remote-bridge/package-lock.json',
    'codex-remote-bridge/node_modules/ws/index.js', 'relay/server.js', 'relay/relay.js', 'relay/push-service.js',
    'relay/apns-client.js', 'relay/package.json', 'relay/package-lock.json', 'relay/node_modules/ws/index.js'];
  try {
    for (const relative of fixture) { const full = path.join(sourceRoot, relative); fs.mkdirSync(path.dirname(full), { recursive: true }); fs.writeFileSync(full, relative); }
    const secret = path.join(sourceRoot, 'codex-remote-bridge/src/private-defaults.json'); fs.writeFileSync(secret, 'PRIVATE');
    fs.symlinkSync(secret, path.join(sourceRoot, 'codex-remote-bridge/src/linked-secret'));
    const first = installRuntime({ sourceRoot, installRoot });
    assert.equal(installRuntime({ sourceRoot, installRoot }).root, first.root);
    assert(fs.existsSync(first.cliPath)); assert(fs.existsSync(path.join(first.root, 'LICENSE')));
    assert(!fs.existsSync(path.join(first.root, 'codex-remote-bridge/src/private-defaults.json')));
    assert(!fs.existsSync(path.join(first.root, 'codex-remote-bridge/src/linked-secret')));
    fs.writeFileSync(path.join(sourceRoot, 'codex-remote-bridge/src/bridge.js'), 'updated');
    const second = installRuntime({ sourceRoot, installRoot }); assert.notEqual(first.root, second.root);
    assert(fs.existsSync(first.cliPath), 'Previous running snapshot must remain intact');
  } finally { fs.rmSync(temporary, { recursive: true }); }
});
