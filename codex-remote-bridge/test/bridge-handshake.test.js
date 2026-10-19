// Exercise the real phone-facing router, including its warm-handshake shortcut.
// Network, device state, Keychain, notifications and daemon execution are mocked.
require('./helpers/isolated-state.cjs');
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const { createRequire } = require('node:module');
const { EventEmitter } = require('node:events');

function phoneRouter(mode = 'shared') {
  const filename = path.resolve(__dirname, '../src/bridge.js');
  const localRequire = createRequire(filename);
  const replies = [], forwarded = [], sockets = [];
  class RelaySocket extends EventEmitter {
    static OPEN = 1;
    constructor() { super(); this.readyState = 1; sockets.push(this); }
    send() {}
  }
  const noop = () => {};
  const deviceState = { macDeviceId: 'fixture-mac', macIdentityPublicKey: 'fixture-public', trustedPhones: {} };
  const mocks = {
    ws: RelaySocket,
    './secure-device-state': {
      loadOrCreateBridgeDeviceState: () => deviceState,
      resolveBridgeRelaySession: state => ({ deviceState: state, sessionId: 'fixture-session' }),
      rememberLastSeenPhoneAppVersion: state => state,
    },
    './secure-transport': { createBridgeSecureTransport: () => ({
      createPairingPayload: () => ({ v: 1, expiresAt: 1 }),
      bindLiveSendWireMessage: noop,
      handleIncomingWireMessage: (message, handlers) => { handlers.onApplicationMessage(message); return true; },
      queueOutboundApplicationMessage: message => replies.push(JSON.parse(message)),
    }) },
    './codex-transport': { createCodexTransport: () => ({ mode, onError: noop, onStarted: noop, onMessage: noop, onClose: noop, send: message => forwarded.push(JSON.parse(message)) }) },
    './codex-desktop-refresher': { CodexDesktopRefresher: class {} },
    './push-notification-service-client': { createPushNotificationServiceClient: () => ({ logUnavailable: noop }) },
    './notifications-handler': { createNotificationsHandler: () => ({}) },
    './push-notification-tracker': { createPushNotificationTracker: () => ({}) },
    './attention-notifications': { createAttentionNotifications: () => ({}) },
    './bark-push': { createBarkNotifications: () => ({}) },
    './voice-handler': { createVoiceHandler: () => ({}) },
    './package-version-status': { createBridgePackageVersionStatusReader: () => noop },
  };
  const module = { exports: {} };
  const timer = () => ({ unref: noop });
  vm.runInNewContext(fs.readFileSync(filename, 'utf8'), {
    module, exports: module.exports,
    require: name => Object.hasOwn(mocks, name) ? mocks[name] : localRequire(name),
    process: { env: {}, platform: 'darwin', pid: 1, on: noop },
    console: { log: noop, warn: noop, error: noop },
    setInterval: timer, clearInterval: noop, setTimeout: timer, clearTimeout: noop,
    Buffer, URL,
  }, { filename });
  module.exports.startBridge({ printPairingQr: false, config: { codexEndpoint: 'unix:///tmp/fixture.sock', relayUrl: 'ws://127.0.0.1:0/relay' } });
  return { replies, forwarded, request(message) { sockets[0].emit('message', JSON.stringify(message)); }, initialize(id) { sockets[0].emit('message', JSON.stringify({ id, method: 'initialize', params: { clientInfo: { name: 'codexmobile_ios', version: '1.3.8' } } })); } };
}

test('phone initialize and reconnect advertise shared settings through the outer Bridge', () => {
  const router = phoneRouter();
  for (const id of ['first-connection', 'phone-reconnect']) {
    router.initialize(id);
    const response = router.replies.find(r => r.id === id);
    const contract = require('./fixtures/client-handshake-v1.json');
    for (const [key, expected] of Object.entries(contract)) assert.deepEqual(response.result[key], expected, key);
    assert.equal(response?.result?.sessionSettings, true);
    assert.equal(response.result.claudeChannels, true);
    assert.equal(response.result.turnStateSnapshot, true);
    assert.equal(response.result.sharedSession, true);
    assert.equal(response.result.macTerminalOpen, true);
  }
  assert.equal(router.forwarded.length, 0, 'warm handshake is answered by Bridge, not runtime');
});

test('legacy phone initialize without capability preferences retains the v1 handshake', () => {
  const router = phoneRouter();
  router.request({ id: 'legacy-phone', method: 'initialize', params: { clientInfo: { name: 'fixture-legacy' } } });
  const response = router.replies.find(r => r.id === 'legacy-phone');
  for (const [key, expected] of Object.entries(require('./fixtures/client-handshake-v1.json'))) {
    assert.deepEqual(response.result[key], expected, key);
  }
  assert.equal(router.forwarded.length, 0);
});

test('non-shared transport never advertises shared settings', () => {
  const router = phoneRouter('spawn');
  router.initialize('legacy');
  assert.notEqual(router.replies[0]?.result?.sessionSettings, true);
  assert.notEqual(router.replies[0]?.result?.turnStateSnapshot, true);
});

test('phone Claude requests use their own handler and never reach the Codex transport', () => {
  const router = phoneRouter();
  router.request({ id: 'claude-list', method: 'claude/sessions' });
  assert(Array.isArray(router.replies.find(r => r.id === 'claude-list').result.data));
  router.request({ id: 'wrong-control', method: 'claude/interrupt', params: {} });
  assert.equal(router.replies.find(r => r.id === 'wrong-control').error.code, -32601);
  assert.equal(router.forwarded.length, 0);
});
