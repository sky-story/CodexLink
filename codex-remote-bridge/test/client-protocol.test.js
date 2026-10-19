const test = require('node:test');
const assert = require('node:assert/strict');
const { buildClientHandshake } = require('../src/client-protocol');
const v1 = require('./fixtures/client-handshake-v1.json');

test('v1 client fields keep their published meaning and value types', () => {
  const handshake = buildClientHandshake({ mode: 'shared', endpoint: 'unix:///tmp/fixture.sock', platform: 'darwin', bridgeManaged: true, claudeChannels: true });
  // New optional fields may be added without changing the frozen v1 contract.
  for (const [key, value] of Object.entries(v1)) assert.deepEqual(handshake[key], value, key);
});

test('shared runtime and warm Bridge agree on every runtime capability', () => {
  for (const platform of ['darwin', 'linux', 'win32']) {
    for (const endpoint of ['unix:///tmp/fixture.sock', 'ws://127.0.0.1:1']) {
      const runtime = buildClientHandshake({ mode: 'shared', endpoint, platform });
      const bridge = buildClientHandshake({ mode: 'shared', endpoint, platform, bridgeManaged: true, claudeChannels: true });
      const { bridgeManaged, claudeChannels, ...features } = bridge;
      assert.deepEqual(features, (({ bridgeManaged, claudeChannels, ...rest }) => rest)(runtime));
      assert.equal(runtime.macTerminalOpen, platform === 'darwin' && endpoint.startsWith('unix://'));
    }
  }
});

test('unsupported transports do not advertise daemon controls', () => {
  for (const mode of ['spawn', 'websocket', undefined]) {
    const handshake = buildClientHandshake({ mode, endpoint: 'unix:///tmp/fixture.sock', platform: 'darwin' });
    for (const key of ['sharedSession', 'sessionSettings', 'turnStateSnapshot', 'macTerminalOpen']) assert.equal(handshake[key], false);
    assert.equal(handshake.controlProtocol, 0);
  }
});
