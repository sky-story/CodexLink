#!/usr/bin/env node
// Read-only local preflight. No APNs call, notification, signing edit or Keychain access.
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { loadPrivatePush, privatePushStatus } = require('../codex-remote-bridge/src/private-push');
function buildReadiness({ entitlements, push, signedBuildReadable = true }) {
  const environment = entitlements?.['aps-environment'];
  const appId = entitlements?.['application-identifier'] || '';
  const blockers = [];
  if (!signedBuildReadable) blockers.push('signed_build_unavailable');
  else if (!['development', 'production'].includes(environment)) blockers.push('signed_app_has_no_apns_entitlement');
  if (!push.enabled) blockers.push(`provider_${push.reason}`);
  if (push.enabled && appId !== `${push.apnsConfig.teamId}.${push.apnsConfig.bundleId}`) blockers.push('signed_app_and_provider_identity_mismatch');
  return { localConfigurationReady: blockers.length === 0, deliveryVerified: false,
    signedBuild: { readable: signedBuildReadable, apnsEnvironment: environment || null },
    provider: privatePushStatus(push), blockers,
    next: 'Real delivery additionally requires a valid provisioning profile, APNs registration/device token, notification permission and a physical lockscreen test.' };
}
function inspectSignedApp(app) {
  const xml = execFileSync('/usr/bin/codesign', ['-d', '--entitlements', ':-', app], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  return JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', '--', '-'], { input: xml, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }));
}
if (require.main === module) {
  const app = process.argv[2] || path.join(__dirname, '../.build/iphone/Build/Products/Debug-iphoneos/CodexMobile.app');
  let entitlements, signedBuildReadable = true;
  try { entitlements = inspectSignedApp(app); } catch { signedBuildReadable = false; }
  const result = buildReadiness({ entitlements, signedBuildReadable, push: loadPrivatePush() });
  console.log(JSON.stringify(result, null, 2));
  if (!result.localConfigurationReady) process.exitCode = 2;
}
module.exports = { buildReadiness };
