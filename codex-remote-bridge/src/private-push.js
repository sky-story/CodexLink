// Optional APNs configuration for the existing private launchd service.
// Secrets stay outside the runtime snapshot; configuration errors disable push only.
const fs = require('node:fs');
const path = require('node:path');
const { createPrivateKey } = require('node:crypto');
const { resolveCodexRemoteStateDir } = require('./daemon-state');

function loadPrivatePush({ stateDir = resolveCodexRemoteStateDir(), fsImpl = fs } = {}) {
  const file = path.join(stateDir, 'push-config.json');
  if (!fsImpl.existsSync(file)) return { enabled: false, reason: 'not_configured' };
  let config;
  try { config = JSON.parse(fsImpl.readFileSync(file, 'utf8')); }
  catch { return { enabled: false, reason: 'invalid_config_json' }; }
  if (!config || typeof config !== 'object' || Array.isArray(config)) return { enabled: false, reason: 'invalid_config_json' };
  if (config.enabled !== true) return { enabled: false, reason: 'disabled' };
  if (!/^[A-Z0-9]{10}$/.test(config.teamId || '') || !/^[A-Z0-9]{10}$/.test(config.keyId || '')
    || !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(config.bundleId || '')) {
    return { enabled: false, reason: 'invalid_app_identifiers' };
  }
  if (typeof config.privateKeyFile !== 'string' || !path.isAbsolute(config.privateKeyFile)) {
    return { enabled: false, reason: 'absolute_private_key_file_required' };
  }
  let privateKey;
  try {
    const stat = fsImpl.statSync(config.privateKeyFile);
    if (!stat.isFile() || (stat.mode & 0o077)) return { enabled: false, reason: 'private_key_permissions_must_be_600' };
    privateKey = fsImpl.readFileSync(config.privateKeyFile, 'utf8');
    const key = createPrivateKey(privateKey);
    if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
      return { enabled: false, reason: 'private_key_must_be_es256' };
    }
  } catch { return { enabled: false, reason: 'private_key_unavailable_or_invalid' }; }
  return { enabled: true, reason: 'configured_not_delivery_verified',
    apnsConfig: { teamId: config.teamId, keyId: config.keyId, bundleId: config.bundleId, privateKey },
    stateFile: path.join(stateDir, 'private-push-state.json') };
}

// Only this projection may be logged; never serialize loadPrivatePush's full result.
function privatePushStatus(push) {
  return { enabled: push.enabled, reason: push.reason, bundleId: push.apnsConfig?.bundleId || null,
    deliveryVerified: false };
}
function privateRelayPushOptions(push) {
  if (!push.enabled) return {};
  return {
    enablePushService: true,
    apnsClient: require('../../relay/apns-client').createAPNsClient(push.apnsConfig),
    pushStateStore: require('../../relay/push-service').createFileBackedPushStateStore({ stateFilePath: push.stateFile }),
  };
}
module.exports = { loadPrivatePush, privatePushStatus, privateRelayPushOptions };
