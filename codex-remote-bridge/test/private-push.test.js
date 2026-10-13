const { root } = require('./helpers/isolated-state.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { generateKeyPairSync } = require('node:crypto');
const { loadPrivatePush, privatePushStatus, privateRelayPushOptions } = require('../src/private-push');
const { buildReadiness } = require('../../scripts/push-readiness.cjs');
function fixture() {
  const dir = fs.mkdtempSync(path.join(root, 'push-'));
  const keyFile = path.join(dir, 'test.p8');
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  fs.writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  const config = { enabled: true, teamId: 'TEAM123456', keyId: 'KEY1234567', bundleId: 'com.example.test', privateKeyFile: keyFile };
  const write = value => fs.writeFileSync(path.join(dir, 'push-config.json'), JSON.stringify(value), { mode: 0o600 });
  write(config); return { dir, config, keyFile, write };
}
test('absent or explicitly disabled configuration never opens a push state store', () => {
  const dir = fs.mkdtempSync(path.join(root, 'empty-'));
  const push = loadPrivatePush({ stateDir: dir });
  assert.equal(push.reason, 'not_configured');
  assert.deepEqual(privateRelayPushOptions(push), {});
  assert.deepEqual(fs.readdirSync(dir), []);
  fs.writeFileSync(path.join(dir, 'push-config.json'), '{"enabled":false}');
  assert.equal(loadPrivatePush({ stateDir: dir }).reason, 'disabled');
});
test('readiness distinguishes missing entitlement, identity mismatch and unverified delivery', () => {
  const f = fixture(), push = loadPrivatePush({ stateDir: f.dir });
  assert(buildReadiness({ entitlements: {}, push }).blockers.includes('signed_app_has_no_apns_entitlement'));
  const ready = buildReadiness({ entitlements: { 'aps-environment': 'development', 'application-identifier': 'TEAM123456.com.example.test' }, push });
  assert.equal(ready.localConfigurationReady, true); assert.equal(ready.deliveryVerified, false);
  assert.equal(buildReadiness({ entitlements: { 'aps-environment': 'development', 'application-identifier': 'OTHER12345.com.other.app' }, push }).localConfigurationReady, false);
});
test('valid local ES256 key config produces a redacted status, never claims delivery', () => {
  const f = fixture(), push = loadPrivatePush({ stateDir: f.dir });
  assert.equal(push.enabled, true);
  assert.equal(push.stateFile, path.join(f.dir, 'private-push-state.json'));
  assert.deepEqual(privatePushStatus(push), { enabled: true, reason: 'configured_not_delivery_verified', bundleId: 'com.example.test', deliveryVerified: false });
  assert(!JSON.stringify(privatePushStatus(push)).includes('PRIVATE KEY'));
  assert(!JSON.stringify(privatePushStatus(push)).includes(f.keyFile));
});
test('invalid config, broad key permissions, wrong curve and missing files disable only push', () => {
  const f = fixture();
  fs.chmodSync(f.keyFile, 0o644);
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'private_key_permissions_must_be_600');
  fs.chmodSync(f.keyFile, 0o600);
  f.write({ ...f.config, privateKeyFile: 'relative.p8' });
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'absolute_private_key_file_required');
  f.write({ ...f.config, privateKeyFile: path.join(f.dir, 'missing') });
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'private_key_unavailable_or_invalid');
  f.write(f.config);
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'secp384r1' });
  fs.writeFileSync(f.keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'private_key_must_be_es256');
  fs.writeFileSync(path.join(f.dir, 'push-config.json'), '{');
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'invalid_config_json');
  fs.writeFileSync(path.join(f.dir, 'push-config.json'), 'null');
  assert.equal(loadPrivatePush({ stateDir: f.dir }).reason, 'invalid_config_json');
});
