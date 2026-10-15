const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { updateHooks, manageHooks, MARKER, quote } = require('../../scripts/claude-notifications.cjs');
const { HOOK_EVENTS } = require('../src/claude-notifications');
const command = `'node' '/runtime/claude-notification-hook.js' '${MARKER}'`;
test('install is idempotent; uninstall preserves all user settings and permission hooks', () => {
  const original = { env: { PRIVATE: 'secret' }, permissions: { allow: ['Read'] }, hooks: {
    Notification: [],
    PermissionRequest: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'my-approval-policy' }] }],
    Stop: [{ hooks: [{ type: 'prompt', prompt: 'my-stop-policy' }] }],
  } };
  const installed = updateHooks(original, { command });
  assert.deepEqual(updateHooks(installed, { command }), installed);
  assert.deepEqual(updateHooks(installed, { remove: true }), original);
  assert.deepEqual(installed.permissions, original.permissions);
  for (const event of HOOK_EVENTS) {
    const ours = installed.hooks[event].at(-1);
    assert.equal(ours.hooks[0].timeout, 5); assert.equal(ours.hooks[0].async, undefined);
    if (event === 'PreToolUse') assert.equal(ours.matcher, 'AskUserQuestion');
  }
});
test('installer backs up exact original, uses pinned runtime, and restores unrelated settings', t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'claude-hooks-install-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const stateDir = path.join(root, 'state'), settingsFile = path.join(root, 'settings.json');
  fs.mkdirSync(stateDir);
  fs.writeFileSync(path.join(stateDir, 'bark-config.json'), JSON.stringify({ enabled: true, serverUrl: 'https://example.test', deviceKey: 'fixtureKeyOnly123' }), { mode: 0o600 });
  const entry = path.join(root, 'runtime', 'codex-remote-bridge/bin/claude-notification-hook.js');
  fs.mkdirSync(path.dirname(entry), { recursive: true }); fs.writeFileSync(entry, '');
  const original = '{"permissions":{"allow":["Read"]},"env":{"PRIVATE":"secret"}}\n';
  fs.writeFileSync(settingsFile, original);
  const options = { stateDir, settingsFile, installRuntime: () => ({ root: path.join(root, 'runtime') }) };
  const first = manageHooks({ ...options, operation: 'install' });
  assert.equal(fs.readFileSync(first.backup, 'utf8'), original);
  assert.equal(fs.statSync(first.backup).mode & 0o077, 0);
  assert.equal(manageHooks({ ...options, operation: 'install' }).changed, false);
  assert.equal(manageHooks({ ...options, operation: 'status' }).installed, true);
  const changed = JSON.parse(fs.readFileSync(settingsFile, 'utf8')); changed.model = 'new-choice';
  fs.writeFileSync(settingsFile, JSON.stringify(changed));
  manageHooks({ ...options, operation: 'uninstall' });
  assert.deepEqual(JSON.parse(fs.readFileSync(settingsFile, 'utf8')), { ...JSON.parse(original), model: 'new-choice' });
});
test('malformed/disabled settings refuse installation; shell quoting treats special paths literally', () => {
  for (const value of [null, [], { hooks: [] }, { hooks: { Stop: {} } }, { disableAllHooks: true }]) assert.throws(() => updateHooks(value, { command }));
  assert.equal(quote("a'b $(secret) `secret`"), "'a'\"'\"'b $(secret) `secret`'");
});
